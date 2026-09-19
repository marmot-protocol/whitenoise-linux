// Group hero, the top of the members panel: big avatar with a photo
// chooser, group title, and inline description editing.
//
// The description publishes through marmot_update_group_profile. The
// photo has two sources: "Search images" (Openverse, openverse.odin)
// publishes a plain URL avatar via marmot_update_group_avatar_url;
// "From file" is encrypted, uploaded to Blossom and committed as the
// group image (marmot_update_group_image), which only an admin may do.
//
// Both directions block on the network, so they run on the group-image
// worker and land back on the UI thread in drain_gimg, where texture
// creation belongs:
//
//   pick file  ─┐                            ┌─► chat-list reload
//              ├─► gimg_queue ─► worker ─► ┤
//   chat rows  ─┘   (upload/download)        └─► round texture
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

// group id → session-local photo pseudo-URL (group://<gid>), so the
// pick renders instantly, before and regardless of the upload.
gpic_local: map[string]string

// Cache key for a group's decrypted Blossom avatar; "" when the group
// has none.
blossom_pic_url :: proc(image_hash: string) -> string {
	if len(image_hash) == 0 {
		return ""
	}
	return fmt.tprintf("blossom://%s", image_hash)
}

// The chat's photo texture: the local pick first, then a published
// URL avatar (which marmot gives precedence), then the decrypted
// Blossom image once the worker has landed it.
chat_pic :: proc(chat: Chat_Row_Ui) -> ^rl.Texture2D {
	if url, ok := gpic_local[chat.group_id]; ok {
		return url_pic(url)
	}
	if len(chat.avatar_url) > 0 {
		return url_pic(chat.avatar_url)
	}
	return local_pic(blossom_pic_url(chat.image_hash))
}

group_hero :: proc(ui: ^Ui_State) {
	chat := ui.chats[ui.selected]
	if clay.UI(clay.ID("GroupHero"))(
	{layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 8, childAlignment = {x = .Center}, padding = {top = 4, bottom = 4}}},
	) {
		avatar("HeroAvatar", 0, chat.avatar_key, chat.title, 72, chat_pic(chat))
		clay.Text(chat.title, {fontId = FONT_TITLE, fontSize = 16, textColor = TEXT})
		clay.Text(fmt.tprintf("%d members", len(ui.members)), {fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO, letterSpacing = 1})
		micro_button("HeroPicBtn", "Change photo")
		if ui.gpic_menu_open {
			if clay.UI(clay.ID("GpicMenu"))({layout = {childGap = 8}}) {
				micro_button("GpicFile", "From file")
				micro_button("GpicSearch", "Search images")
			}
		}

		if ui.desc_editing {
			if clay.UI(clay.ID("DescBox"))(
			{
				layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(34)}, padding = {left = 10, right = 10}, childAlignment = {y = .Center}},
				backgroundColor = ROW_BG,
				cornerRadius = rr(8),
				border = ui.focus == .Desc ? clay.BorderElementConfig{color = ACCENT, width = bw()} : {},
			},
			) {
				field_text(ui, "DescBox", &ui.desc_input, "Describe the group", ui.focus == .Desc)
			}
			if clay.UI(clay.ID("DescActions"))({layout = {childGap = 8}}) {
				micro_button("DescSave", "Save")
				micro_button("DescCancel", "Cancel")
			}
		} else {
			if len(ui.group_desc) > 0 {
				clay.Text(ui.group_desc, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
			} else {
				clay.Text("No description.", {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO})
			}
			micro_button("DescEditBtn", "Edit")
		}
	}
}

// Hero clicks; true when the frame's input was consumed.
handle_hero :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	if clicked("HeroPicBtn") || (mouse_released() && clay.PointerOver(clay.ID("HeroAvatar", 0))) {
		ui.gpic_menu_open = !ui.gpic_menu_open
		return true
	}
	if ui.gpic_menu_open {
		if clicked("GpicFile") {
			ui.gpic_menu_open = false
			ui.picking_gpic = true
			rl.OpenFileDialog(false)
			return true
		}
		if clicked("GpicSearch") {
			ui.gpic_menu_open = false
			ov_show(ui)
			return true
		}
	}

	if clicked("DescEditBtn") {
		ui.desc_editing = true
		ed_set(ui, &ui.desc_input, ui.group_desc)
		ui.focus = .Desc
		return true
	}
	if !ui.desc_editing {
		return false
	}
	if field_mouse(ui, &ui.desc_input, "DescBox") {
		ui.focus = .Desc
		return true
	}
	if clicked("DescCancel") || rl.IsKeyPressed(.ESCAPE) {
		ui.desc_editing = false
		ui.focus = .Invite
		return true
	}
	if clicked("DescSave") || (ui.focus == .Desc && rl.IsKeyPressed(.ENTER)) {
		save_description(ui, client)
		return true
	}
	return false
}

// Publish the edited description; an empty field clears it.
save_description :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	summary: ^marmot.Send_Summary
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	group := strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator)
	desc := strings.clone_to_cstring(string(ui.desc_input[:]), context.temp_allocator)
	if marmot.update_group_profile(client, account, group, nil, desc, &summary) != .OK {
		ui.client_status = fmt.aprintf("Couldn't update the description. %s", marmot.last_error())
		return
	}
	marmot.send_summary_free(summary)
	ui.desc_editing = false
	ui.focus = .Invite
	load_members(client, ui) // re-snapshots group_desc
}

// A file picked for the group photo: decode it for an instant local
// preview, then hand the bytes to the worker, which encrypts and
// uploads them to Blossom and commits them as the group image.
set_group_pic :: proc(ui: ^Ui_State, client: ^marmot.Client, path: string) {
	if ui.selected < 0 {
		return
	}
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		ui.client_status = fmt.aprintf("Couldn't read %s.", path)
		return
	}
	defer delete(data)

	base := path
	if slash := strings.last_index_byte(path, '/'); slash >= 0 {
		base = path[slash + 1:]
	}
	media_type := media_type_for(base)
	if !strings.has_prefix(media_type, "image/") {
		ui.client_status = strings.clone("Couldn't use that file. Choose a PNG or JPEG.")
		return
	}
	ext := strings.clone_to_cstring(fmt.tprintf(".%s", strings.trim_prefix(media_type, "image/")), context.temp_allocator)
	image := rl.LoadImageFromMemory(ext, raw_data(data), i32(len(data)))
	if image.data == nil {
		ui.client_status = strings.clone("Couldn't decode the image. Choose a PNG or JPEG.")
		return
	}

	gid := ui.chats[ui.selected].group_id
	url := fmt.tprintf("group://%s", gid)
	register_local_pic(url, image)
	rl.UnloadImage(image)
	// The local override outlives the upload: it is the same picture,
	// and keeping it saves re-downloading what this client just sent.
	if gid not_in gpic_local {
		gpic_local[strings.clone(gid)] = strings.clone(url)
	}

	gimg_push(
		Gimg_Job {
			kind = .Upload,
			client = client,
			account = strings.clone(ui.account_ref),
			group_id = strings.clone(gid),
			data = slice.clone(data),
			media_type = media_type,
		},
	)
}

// ── Group-image worker ──────────────────────────────────────────────

@(private = "file")
Gimg_Kind :: enum {
	Download,
	Upload,
}

@(private = "file")
Gimg_Job :: struct {
	kind:       Gimg_Kind,
	client:     ^marmot.Client,
	account:    string,
	group_id:   string,
	url:        string, // download only: the blossom:// cache key
	media_type: string, // upload only; a static literal, never freed
	data:       []u8, // upload only, freed by the worker
}

// An upload reports only success or failure (empty url); a download
// reports the cache key it fetched for, with nil data when it failed.
@(private = "file")
Gimg_Result :: struct {
	url:  string,
	data: []u8,
	err:  string, // "" = it worked
}

@(private = "file")
gimg_mutex: sync.Mutex
@(private = "file")
gimg_queue: [dynamic]Gimg_Job
@(private = "file")
gimg_uploads: int

@(private)
gimg_writes_pending :: proc() -> bool {
	sync.lock(&gimg_mutex)
	defer sync.unlock(&gimg_mutex)
	return gimg_uploads > 0
}
@(private = "file")
gimg_done: [dynamic]Gimg_Result
// group ids already downloaded (or tried) this session.
@(private = "file")
gimg_asked: map[string]bool

@(private = "file")
gimg_push :: proc(job: Gimg_Job) {
	sync.lock(&gimg_mutex)
	append(&gimg_queue, job)
	if job.kind == .Upload { gimg_uploads += 1 }
	sync.unlock(&gimg_mutex)
}

// Queue the decrypt-download for every chat that has a committed
// Blossom image and no plain URL avatar to prefer over it. Called
// from the chat-list load, where the client and account are in hand.
queue_group_pics :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	for chat in ui.chats {
		if len(chat.image_hash) == 0 || len(chat.avatar_url) > 0 || gimg_asked[chat.group_id] {
			continue
		}
		gimg_asked[strings.clone(chat.group_id)] = true
		gimg_push(
			Gimg_Job {
				kind = .Download,
				client = client,
				account = strings.clone(ui.account_ref),
				group_id = strings.clone(chat.group_id),
				url = strings.clone(blossom_pic_url(chat.image_hash)),
			},
		)
	}
}

// ponytail: one worker, 100ms poll, same shape as the picture fetcher.
// Group avatars change rarely, so a queue of one is the normal case.
@(private = "file")
gimg_worker :: proc(_: ^thread.Thread) {
	context.allocator = reload_allocator()
	for {
		sync.lock(&gimg_mutex)
		if gimg_stopping { sync.unlock(&gimg_mutex); return }
		job: Gimg_Job
		have := len(gimg_queue) > 0
		if have {
			job = gimg_queue[0]
			ordered_remove(&gimg_queue, 0)
		}
		sync.unlock(&gimg_mutex)
		if !have {
			time.sleep(100 * time.Millisecond)
			continue
		}

		account := strings.clone_to_cstring(job.account, context.temp_allocator)
		group := strings.clone_to_cstring(job.group_id, context.temp_allocator)
		result: Gimg_Result

		switch job.kind {
		case .Download:
			data: [^]u8
			length: uint
			// marmot's last_error is thread-local, so the message is
			// built here rather than on the UI thread.
			if marmot.download_group_blossom_image(job.client, account, group, &data, &length) == .OK && length > 0 {
				result.data = slice.clone(data[:length])
				marmot.bytes_free(data, length)
			} else {
				fmt.eprintfln("gimg: download failed for %s: %s", job.group_id, marmot.last_error())
			}
			result.url = job.url

		case .Upload:
			summary: ^marmot.Send_Summary
			media := strings.clone_to_cstring(job.media_type, context.temp_allocator)
			if marmot.update_group_image(job.client, account, group, raw_data(job.data), uint(len(job.data)), media, &summary) != .OK {
				result.err = fmt.aprintf("Couldn't publish the photo. %s", marmot.last_error())
			} else {
				marmot.send_summary_free(summary)
			}
			delete(job.data)
		}

		delete(job.account)
		delete(job.group_id)
		free_all(context.temp_allocator)

		sync.lock(&gimg_mutex)
		append(&gimg_done, result)
		if job.kind == .Upload { gimg_uploads -= 1 }
		sync.unlock(&gimg_mutex)
	}
}

start_gimg_worker :: proc() {
	context.allocator = reload_allocator()
	gimg_thread = thread.create(gimg_worker)
	thread.start(gimg_thread)
}

@(private = "file")
gimg_thread: ^thread.Thread
@(private = "file")
gimg_stopping: bool

@(private)
stop_gimg_worker :: proc() {
	context.allocator = reload_allocator()
	if gimg_thread == nil { return }
	sync.lock(&gimg_mutex)
	gimg_stopping = true
	sync.unlock(&gimg_mutex)
	thread.join(gimg_thread)
	thread.destroy(gimg_thread)
	gimg_thread = nil
}

// Frame-loop drain: decode downloaded avatars into round textures and
// report a failed upload.
drain_gimg :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	sync.lock(&gimg_mutex)
	done := gimg_done
	gimg_done = {}
	sync.unlock(&gimg_mutex)

	reload := false
	for r in done {
		if len(r.err) > 0 {
			ui.client_status = r.err
			continue
		}
		if len(r.url) == 0 {
			// An upload landed: the reload picks up the committed
			// image hash, and peers see it on their next sync.
			reload = true
			continue
		}
		if r.data != nil {
			image := rl.LoadImageFromMemory(".img", raw_data(r.data), i32(len(r.data)))
			if image.data != nil {
				register_local_pic(r.url, image)
				rl.UnloadImage(image)
			}
			delete(r.data)
		}
		delete(r.url)
	}
	delete(done)

	if reload && client != nil {
		load_chat_list(client, ui.account_ref, ui)
	}
}
