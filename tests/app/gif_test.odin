package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:text/edit"
import "core:thread"
import rl "sdlrl"

@(private)
GIF_WEBP_FIXTURE :: "UklGRsoAAABXRUJQVlA4WAoAAAACAAAAAQAAAQAAQU5JTQYAAAD/////AABBTk1GSgAAAAAAAAAAAAEAAAEAAPQBAAJWUDggMgAAALABAJ0BKgIAAgACADQlmAJ0AQ72nkAAzj91oWJPVVOq5fyNPKxhNJOj+Zvwo+Tr/AAAQU5NRkwAAAAAAAAAAAABAAABAAD0AQAAVlA4IDQAAAC0AQCdASoCAAIAAAA0JZACdAEO+KbQAP7Pgfk/BDpqiY0OGj6I7XFzZEUfo/7v/Ul7AAAA"

@(test)
gif_ios_message :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	old_lines, old_deleted, old_moving := sel_lines, del_seen, anim_moving
	sel_lines, del_seen = {}, {}
	defer {
		delete(sel_lines)
		for key in del_seen {delete(key)}
		delete(del_seen)
		sel_lines, del_seen, anim_moving = old_lines, old_deleted, old_moving
	}
	url :: "https://media3.giphy.com/media/v1.Y2lkPWFjZTYxYTllYWpldGZ0Ym05em5sbmhvc3ZxMDBjdjh6MG1kMDJxbm01YXQ5OHZ6ZCZlcD12MV9naWZzX3NlYXJjaCZjdD1n/l4FATJpd4LWgeruTK/giphy.gif"
	msg := Msg_Ui {
		body = strings.clone(url + " via GIPHY"),
	}
	defer message_free(msg)
	view := Video_View {
		w       = 320,
		h       = 240,
		looping = true,
	}
	old_views := video_views
	video_views = {}
	video_views[url] = &view
	defer {delete(video_views); video_views = old_views}
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 2000})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	clay.BeginLayout()
	message_row(0, msg)
	commands := clay.EndLayout(0)
	drawn := false
	for command in commands.internalArray[:commands.length] {
		if command.commandType == .Image && command.renderData.image.imageData == &view.tex {
			drawn = true
		}
	}
	testing.expect(t, drawn, "iOS GIPHY shares must render the looping GIF")
	for size in ([][2]i32{{0, 240}, {320, 0}, {-1, 240}, {320, -1}}) {
		view.w, view.h = size[0], size[1]
		clay.BeginLayout()
		message_row(0, msg)
		commands = clay.EndLayout(0)
		text := strings.builder_make(context.temp_allocator)
		for command in commands.internalArray[:commands.length] {
			if command.commandType == .Image {
				testing.expect(t, command.renderData.image.imageData != &view.tex)
			}
			if command.commandType == .Text {
				part := command.renderData.text.stringContents
				strings.write_string(&text, string(part.chars[:part.length]))
			}
		}
		testing.expect(
			t,
			strings.contains(strings.to_string(text), url),
			"invalid dimensions must leave the original link visible",
		)
	}
	view.w, view.h = 320, 240
	testing.expect_value(t, giphy_message_url("\n" + url + "\nvia GIPHY\n"), url)
	query :: "https://media.giphy.com/media/test/giphy.gif?size=small"
	testing.expect_value(t, giphy_message_url(query + " via GIPHY"), query)
	for body in ([]string{url, "Look at " + url + " via GIPHY", url + " via GIPHY extra", "https://media3.giphy.com.evil.test/media/test/giphy.gif via GIPHY", "https://media3.giphy.com@evil.test/media/test/giphy.gif via GIPHY", "https://mediaevil.giphy.com/media/test/giphy.gif via GIPHY", "https://media3.giphy.com/media/test/video.mp4 via GIPHY", "http://media3.giphy.com/media/test/giphy.gif via GIPHY"}) {
		testing.expect_value(t, giphy_message_url(body), "")
	}
	msg.deleted = true
	clay.BeginLayout()
	message_row(0, msg)
	commands = clay.EndLayout(0)
	for command in commands.internalArray[:commands.length] {
		if command.commandType == .Image {
			testing.expect(
				t,
				command.renderData.image.imageData != &view.tex,
				"deleted shares must not render GIFs",
			)
		}
	}
}
@(test)
gif_data :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	for bad in ([]string{"http://gifsnap.com/a", "https://gifsnap.com.evil.test/a", "https://127.0.0.1/a", "file:///tmp/a", "https://user@gifsnap.com/a"}) {testing.expect(t, !gif_asset_url(bad))}
	items, more, ok := gif_parse(
		transmute([]u8)string(
			`{"data":[{"title":"Cat","url":"https://media.gifsnap.com/gifs/cat.gif","preview_url":"https://media.gifsnap.com/thumbnails/cat.webp","width":220,"height":180},{"url":"https://evil.test/a","preview_url":"https://media.gifsnap.com/thumbnails/a.webp"}],"pagination":{"page":1,"has_next":true}}`,
		),
	)
	testing.expect(t, ok && more && len(items) == 1)
	if len(items) == 1 {
		testing.expect_value(t, items[0].url, "https://media.gifsnap.com/gifs/cat.gif")
		testing.expect_value(t, items[0].thumb, "https://media.gifsnap.com/thumbnails/cat.webp")
		testing.expect_value(t, items[0].width, 220)
		testing.expect_value(t, items[0].height, 180)
	}
	for item in items {gif_item_free(item)}; delete(items)
	for invalid in ([]string{"{}", "bad", `{"data":[],"pagination":{"page":0}}`, `{"data":42}`}) {
		_, _, parsed := gif_parse(transmute([]u8)invalid); testing.expect(t, !parsed)
	}
	_, _, empty := gif_parse(transmute([]u8)string(`{"data":[],"pagination":{"page":1}}`))
	testing.expect(t, empty, "empty results are not a network error")
	bytes, err := base64.decode("R0lGODlhAQABAIAAAAAAAP///yH5BAAAAAAALAAAAAABAAEAAAIBRAA7")
	testing.expect(t, err == nil); defer delete(bytes)
	testing.expect(t, gif_valid(bytes))
	testing.expect(t, !gif_valid(bytes[:12]))
	bytes[6], bytes[7] = 255, 255
	testing.expect(t, !gif_valid(bytes), "reject huge canvases before decoding")
	bytes[6], bytes[7] = 1, 0
	webp, webp_err := base64.decode(GIF_WEBP_FIXTURE)
	testing.expect(t, webp_err == nil); defer delete(webp)
	testing.expect(t, gif_valid(webp), "accept animated WebP from the provider")
	testing.expect(t, !gif_valid(webp[:29]), "reject a truncated WebP canvas")
	webp[24], webp[25] = 255, 15
	testing.expect(t, gif_valid(webp), "accept the 4096-pixel canvas boundary")
	webp[24], webp[25] = 0, 16
	testing.expect(t, !gif_valid(webp), "reject oversized WebP before decoding")
	webp[24], webp[25] = 1, 0
	webp[16] = 9
	testing.expect(t, !gif_valid(webp), "reject an invalid extended header")
	sync.lock(&test_home_lock); defer sync.unlock(&test_home_lock)
	defer vault_lock()
	previous := data_home; data_home = "/tmp/wn-gif-storage-test"
	defer {data_home = previous}
	os.make_directory(data_home); defer os.remove_all(data_home)
	testing.expect_value(t, vault_create("test"), Vault_Err.None)
	sha := string(hex.encode(hash.hash_bytes(.SHA256, bytes, context.temp_allocator)))
	defer delete(sha)
	item := Gif_Item {
		title = "Saved cat",
		sha   = sha,
	}
	index, marshal_err := json.marshal([]Gif_Item{item}); testing.expect(t, marshal_err == nil)
	save := new(Gif_Job); save^ = {
		op    = .Save,
		item  = gif_item_clone(item),
		data  = make([]u8, len(bytes)),
		index = index,
	}
	copy(save.data, bytes)
	worker := thread.Thread {
		data = save,
	}; gif_worker(&worker)
	testing.expect_value(t, save.error, "")
	gif_job_free(save)
	sealed, read_err := os.read_entire_file(gif_path(sha), context.temp_allocator)
	testing.expect(
		t,
		read_err == nil && string(sealed) != string(bytes),
		"saved GIF bytes stay encrypted",
	)
	loaded := gif_read(sha); testing.expect_value(t, string(loaded), string(bytes)); delete(loaded)
	load := new(Gif_Job); load.op = .Library; worker.data = load; gif_worker(&worker)
	testing.expect_value(t, load.error, "")
	testing.expect_value(t, len(load.items), 1)
	// Opening Saved reads only its index; image bytes are loaded per visible tile.
	thumb_data := gif_read(load.items[0].sha)
	thumb := rl.LoadImageFromMemory(".gif", raw_data(thumb_data), i32(len(thumb_data)))
	testing.expect(t, thumb.data != nil, "saved thumbnails work offline")
	rl.UnloadImage(thumb); delete(thumb_data)
	gif_job_free(load)
	testing.expect_value(t, vault_rekey("second"), Vault_Err.None)
	vault_lock()
	testing.expect_value(t, vault_open("second"), Vault_Err.None)
	again := gif_read(sha)
	testing.expect_value(t, string(again), string(bytes))
	delete(again)
	load_again := new(Gif_Job)
	load_again.op = .Library
	worker.data = load_again
	gif_worker(&worker)
	testing.expect_value(t, load_again.error, "")
	testing.expect_value(t, len(load_again.items), 1)
	gif_job_free(load_again)
	remove := new(Gif_Job); remove^ = {
		op    = .Remove,
		item  = gif_item_clone(item),
		index = transmute([]u8)strings.clone("[]"),
	}
	worker.data = remove; gif_worker(&worker)
	testing.expect_value(t, remove.error, "")
	testing.expect(t, !os.exists(gif_path(sha)))
	gif_job_free(remove)
	// A queued save completes during shutdown, even before a frame starts its worker.
	ui: Ui_State
	job := gif_start(&ui, .Save); job.item = gif_item_clone(item)
	job.data = make([]u8, len(bytes)); copy(job.data, bytes)
	job.index, _ = json.marshal([]Gif_Item{item})
	gif_stop(&ui)
	testing.expect(t, os.exists(gif_path(sha)))
	testing.expect(t, media_write_sealed(gif_path(sha), []u8{1, 2, 3}))
	testing.expect(t, len(gif_read(sha)) == 0, "corrupt saved files are not staged")
}

@(test)
gif_send_failure :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	sync.lock(&test_home_lock); defer sync.unlock(&test_home_lock)
	ui := Ui_State {
		picker_open = true,
		account_ref = "original-account",
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "original-group"})
	old_ui := g_ui; g_ui = &ui; defer {g_ui = old_ui}
	defer {
		for &p in ui.pending {free_pending(&p)}
		delete(ui.pending); delete(ui.chats); delete(ui.client_status); delete(ui.jump_id)
	}
	gif_send(&ui, nil, Gif_Item{url = "https://invalid.test/animation.gif"})
	testing.expect_value(t, len(ui.pending), 1)
	testing.expect(t, !ui.picker_open && reload_jobs_busy())
	ui.account_ref = "other-account"
	ui.chats[0].group_id = "other-group"
	thread.join(ui.pending[0].gif.worker)
	drain_gif_sends(&ui, nil)
	testing.expect(t, ui.pending[0].failed && ui.pending[0].gif != nil)
	testing.expect_value(t, len(ui.pending[0].atts), 0)
	testing.expect_value(t, ui.pending[0].account_ref, "original-account")
	testing.expect_value(t, ui.pending[0].group_id, "original-group")
	testing.expect(t, !reload_jobs_busy(), "a failed preparation must not block reload")
	ui.pending[0].failed = false
	spawn_send(&ui, nil, &ui.pending[0])
	ui.pending[0].dismissed = true
	thread.join(ui.pending[0].gif.worker)
	drain_gif_sends(&ui, nil)
	testing.expect(t, len(ui.pending) == 0, "dismissal must not publish a late GIF")
}

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=gif_keyboard
@(test)
gif_keyboard :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "gif_keyboard" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(900, 760, "GIF keyboard regression"); defer rl.CloseWindow()
	old_threads, old_done, old_ticket := send_threads, sends_done, send_ticket
	send_threads, sends_done = {}, {}
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8; init_layout(&memory, 32768, {900, 760}); defer delete(memory)
	ui := Ui_State {
		row_menu         = -1,
		member_menu      = -1,
		selected_contact = -1,
		picker_open      = true,
		gif_tab          = true,
		gif_saved        = true,
		gif_loaded       = true,
		focus            = .Picker,
		gif_focus        = -1,
		picker_x         = 4,
		picker_y         = 4,
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	ui.prefs.rail_w = RAIL_W_MIN; ui.prefs.reduce_motion = true
	ui.prefs.gif_consent = true
	append(&ui.accounts, "Test"); append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "GIFs"})
	append(&ui.compose, "Keep your draft")
	g_ui, g_prefs = &ui, &ui.prefs; defer {g_ui, g_prefs = nil, nil}
	defer gif_stop(&ui)
	defer {
		for worker in send_threads {thread.join(worker); thread.destroy(worker)}
		for done in sends_done {delete(done.err); for id in done.ids {delete(id)}; delete(done.ids)}
		delete(send_threads); delete(sends_done)
		send_threads, sends_done, send_ticket = old_threads, old_done, old_ticket
		for &p in ui.pending {free_pending(&p)}
		delete(ui.pending); ui.pending = {}
		for len(ui.staged) > 0 {remove_staged(&ui, len(ui.staged) - 1)}
		delete(ui.staged)
	}
	image := rl.LoadImage("vendor/emoji/noto/1f9ab.png")
	defer rl.UnloadImage(image)
	for i in 0 ..< 8 {
		append(
			&ui.gif_library,
			Gif_Item{title = fmt.aprintf("Saved GIF %d", i), thumb = fmt.aprintf("fixture%d", i)},
		)
		register_local_pic(fmt.tprintf("image:fixture%d", i), image)
	}
	press :: proc(t: ^testing.T, ui: ^Ui_State, id: clay.ElementId) {
		data := clay.GetElementData(id); testing.expect(t, data.found)
		clay.SetPointerState(
			{
				data.boundingBox.x + data.boundingBox.width / 2,
				data.boundingBox.y + data.boundingBox.height / 2,
			},
			false,
		)
		forced_release = true; handle_picker(ui, nil); forced_release = false
	}
	for width in ([]i32{900, 420, 320}) {
		rl.SetWindowSize(width, 760); clay.SetLayoutDimensions({f32(width), 760})
		for locale in ([]string{"en", "it", "de", "ja"}) {
			set_locale(locale)
			for _ in 0 ..< 8 {anim_frame += 1; build_layout(&ui, 0)}
			commands := build_layout(&ui, 0)
			panel := clay.GetElementData(clay.ID("PickerPanel")).boundingBox
			for i in 0 ..< 8 {
				box := clay.GetElementData(clay.ID("GifTile", u32(i))).boundingBox
				testing.expect(
					t,
					box.width > 0 &&
					box.x >= panel.x &&
					box.x + box.width <= panel.x + panel.width,
				)
			}
			rl.BeginDrawing()
			draw_frame(&commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-gifs-%d-%s.png", width, locale))
			rl.EndDrawing()
		}
	}
	set_locale("en")
	// An in-flight search must not swallow typing or publish an obsolete response.
	ui.gif_saved = false
	job := gif_start(&ui, .Search); job.query = strings.clone("old query")
	rl.PushChar('c'); handle_gif_picker(&ui, nil)
	testing.expect_value(t, string(ui.picker_filter[:]), "c")
	testing.expect(t, ui.gif_due > rl.GetTime())
	job.worker = thread.create_and_start(proc() {})
	thread.join(job.worker); gif_drain(&ui)
	testing.expect_value(t, len(ui.gif_hits), 0)
	ed_set(&ui, &ui.picker_filter, ""); ui.gif_due = 0
	delete(ui.gif_filter); ui.gif_filter = ""
	// Metadata pages append without moving the viewport; only visible tiles load.
	for i in 0 ..< GIF_PAGE_SIZE {
		append(
			&ui.gif_hits,
			Gif_Item {
				title = fmt.aprintf("Result %d", i),
				thumb = fmt.aprintf("https://gifsnap.com/fixture%d", i),
				width = 200,
				height = 200,
			},
		)
	}
	ui.gif_page, ui.gif_more = 1, true
	for _ in 0 ..< 8 {anim_frame += 1; build_layout(&ui, 0)}
	testing.expect(t, gif_visible(0) && !gif_visible(GIF_PAGE_SIZE - 1))
	_, first_loading, _ := gif_thumb(ui.gif_hits[0], 0)
	_, last_loading, _ := gif_thumb(ui.gif_hits[GIF_PAGE_SIZE - 1], GIF_PAGE_SIZE - 1)
	testing.expect(t, first_loading && !last_loading, "offscreen thumbnails are not requested")
	clay.SetPointerState({0, 0}, false)
	handle_gif_picker(&ui, nil)
	testing.expect(t, ui.gif_job == nil, "do not fetch more metadata at the top")
	scroll := clay.GetScrollContainerData(clay.ID("GifGrid"))
	scroll.scrollPosition.y =
		scroll.scrollContainerDimensions.height - scroll.contentDimensions.height
	position := scroll.scrollPosition.y
	handle_gif_picker(&ui, nil)
	testing.expect(t, ui.gif_job != nil, "reaching the end requests the next page")
	if ui.gif_job != nil {
		testing.expect_value(t, ui.gif_job.page, 2)
		append(&ui.gif_job.items, Gif_Item{title = strings.clone("Next page")})
		ui.gif_job.worker = thread.create_and_start(proc() {})
		thread.join(ui.gif_job.worker); gif_drain(&ui)
		testing.expect_value(t, len(ui.gif_hits), GIF_PAGE_SIZE + 1)
		testing.expect_value(t, ui.gif_hits[0].title, "Result 0")
		testing.expect_value(t, scroll.scrollPosition.y, position)
		testing.expect(t, !ui.gif_more, "stop when the provider has no next page")
	}
	scroll.scrollPosition^ = {}
	// A broken full GIF disappears while other results remain usable.
	ui.gif_hits[0].url = strings.clone("https://gifsnap.com/broken")
	broken := gif_start(&ui, .Preview)
	broken.item = gif_item_clone(ui.gif_hits[0])
	broken.error = "Couldn't load the GIF. Please try again."
	broken.worker = thread.create_and_start(proc() {})
	thread.join(broken.worker); gif_drain(&ui)
	testing.expect(t, ui.gif_hits[0].failed)
	testing.expect_value(t, len(gif_matches(&ui)), GIF_PAGE_SIZE)
	testing.expect_value(t, ui.gif_error, "")
	for &item in ui.gif_hits {item.failed = true}
	for _ in 0 ..< 8 {anim_frame += 1; build_layout(&ui, 0)}
	testing.expect_value(t, len(gif_matches(&ui)), 0)
	empty_box := clay.GetElementData(clay.ID("GifEmpty")).boundingBox
	grid_box := clay.GetElementData(clay.ID("GifGrid")).boundingBox
	testing.expect(t, empty_box.width >= grid_box.width - 1, "the error uses the full grid width")
	testing.expect(
		t,
		clay.GetElementData(clay.ID("GifEmpty")).found &&
		clay.GetElementData(clay.ID("GifRetry")).found,
	)
	gif_retry(&ui)
	testing.expect_value(t, len(gif_matches(&ui)), GIF_PAGE_SIZE + 1)
	ui.gif_saved = true
	// Picking queues a send immediately, without consuming the draft or its files.
	bytes, _ := base64.decode("R0lGODlhAQABAIAAAAAAAP///yH5BAAAAAAALAAAAAABAAEAAAIBRAA7")
	draft, _ := base64.decode("R0lGODlhAQABAIAAAAAAAP///yH5BAAAAAAALAAAAAABAAEAAAIBRAA7")
	stage_bytes(&ui, "draft.gif", draft)
	ui.gif_view = video_view_make(bytes, .Loop)
	ui.gif_library[0].url = strings.clone("https://gifsnap.com/test")
	ui.gif_selected = gif_item_clone(ui.gif_library[0])
	ui.replying = "reply-target"
	for _ in 0 ..< 8 {anim_frame += 1; build_layout(&ui, 0)}
	press(t, &ui, clay.ID("GifTile", 0))
	testing.expect_value(t, len(ui.staged), 1)
	testing.expect_value(t, ui.staged[0].name, "draft.gif")
	testing.expect_value(t, len(ui.pending), 1)
	testing.expect_value(t, ui.pending[0].reply_to, "reply-target")
	gif_send(&ui, nil, ui.gif_selected)
	testing.expect(t, len(ui.pending) == 1, "a closing picker cannot send twice")
	testing.expect_value(t, string(ui.compose[:]), "Keep your draft")
	testing.expect_value(t, ui.replying, "reply-target")
	testing.expect(t, !ui.picker_open && ui.focus == .Compose)
	thread.join(ui.pending[0].gif.worker)
	drain_gif_sends(&ui, nil)
	testing.expect(t, ui.pending[0].gif == nil)
	testing.expect_value(t, len(ui.pending[0].atts), 1)
	if len(ui.pending[0].atts) != 1 {return}
	testing.expect_value(t, ui.pending[0].atts[0].media_type, "image/gif")
	testing.expect_value(t, string(ui.pending[0].atts[0].data), string(draft))
	webp, webp_err := base64.decode(GIF_WEBP_FIXTURE)
	testing.expect(t, webp_err == nil)
	ui.gif_view = video_view_make(webp, .Loop)
	ui.picker_open = true
	gif_send(&ui, nil, ui.gif_selected)
	testing.expect_value(t, len(ui.staged), 1)
	testing.expect_value(t, len(ui.pending), 2)
	thread.join(ui.pending[1].gif.worker)
	drain_gif_sends(&ui, nil)
	testing.expect_value(t, len(ui.pending[1].atts), 1)
	if len(ui.pending[1].atts) != 1 {return}
	testing.expect_value(t, ui.pending[1].atts[0].name, "animation.webp")
	testing.expect_value(t, ui.pending[1].atts[0].media_type, "image/webp")
	// Received animated WebP must become a looping tile, not a failed still image.
	{
		sync.lock(&test_home_lock); defer sync.unlock(&test_home_lock)
		old_home := data_home; data_home = "/tmp/wn-gif-animated-media-test"
		defer {vault_lock(); os.remove_all(data_home); data_home = old_home}
		os.make_directory(data_home)
		testing.expect_value(t, vault_create("test"), Vault_Err.None)
		bytes := ui.pending[1].atts[0].data
		sha := string(hex.encode(hash.hash_bytes(.SHA256, bytes, context.temp_allocator)))
		defer delete(sha)
		sealed, sealed_ok := vault_seal_blob(bytes, context.temp_allocator)
		testing.expect(t, sealed_ok)
		os.make_directory(media_cache_dir())
		testing.expect(
			t,
			os.write_entire_file(fmt.tprintf("%s/%s.bin", media_cache_dir(), sha), sealed) == nil,
		)
		ref := marmot.Media_Attachment_Reference {
			file_name        = "animation.webp",
			media_type       = "image/webp",
			plaintext_sha256 = strings.clone_to_cstring(sha, context.temp_allocator),
		}
		job := Media_Job {
			kind      = .Image,
			key       = sha,
			reference = ref,
		}
		worker := thread.create(media_worker); worker.data = &job
		thread.start(worker); thread.join(worker); thread.destroy(worker)
		view := (^Video_View)(job.view)
		testing.expect(t, view != nil)
		if view == nil {return}
		defer video_view_free(view)
		testing.expect(t, view.looping && !view.failed && job.image.data == nil)
		old_views, old_sizes := video_views, blob_sizes
		video_views, blob_sizes = {}, {}
		defer {
			for key in video_views {delete(key)}; delete(video_views)
			for key in blob_sizes {delete(key)}; delete(blob_sizes)
			video_views, blob_sizes = old_views, old_sizes
		}
		media_publish(&job)
		msg: Msg_Ui
		defer message_free(msg)
		outcome := marmot.Media_Attachment_Outcome {
			body = {accepted = {0, ref}},
		}
		media_attach(&msg, nil, "", "", &outcome, "")
		testing.expect_value(t, msg.attachments[0].state, Att_State.Ready)
		testing.expect_value(t, msg.attachments[0].kind, Media_Kind.Loop)
		testing.expect(t, msg.attachments[0].view == view)
	}
	ui.picker_mode = .Quick_Reaction; ui.gif_tab = true
	open_picker(&ui, ""); testing.expect(t, !ui.gif_tab)
	if os.get_env("WN_TEST_GIF_LIVE", context.temp_allocator) != "" {
		start_pic_worker(); defer stop_pic_worker()
		rl.SetWindowSize(900, 760); clay.SetLayoutDimensions({900, 760})
		rl.SetTargetFPS(30)
		ui.picker_mode = .Message; ui.gif_tab = true; ui.gif_saved = false
		ed_set(&ui, &ui.picker_filter, "cat")
		gif_search(&ui); gif_drain(&ui)
		thread.join(ui.gif_job.worker); gif_drain(&ui)
		testing.expect_value(t, ui.gif_error, "")
		testing.expect(t, len(ui.gif_hits) > 0, "keyless live search returns GIFs")
		if len(ui.gif_hits) > 0 {
			preview := gif_start(&ui, .Preview); preview.item = gif_item_clone(ui.gif_hits[0])
			gif_drain(&ui); thread.join(ui.gif_job.worker); gif_drain(&ui)
			testing.expect_value(t, ui.gif_error, "")
			testing.expect(t, ui.gif_view != nil)
			if ui.gif_view != nil {
				for _ in 0 ..< 150 {
					drain_pics(); advance_videos(); anim_frame += 1
					commands := build_layout(&ui, 0)
					rl.BeginDrawing()
					draw_frame(&commands)
					rl.EndDrawing()
				}
				commands := build_layout(&ui, 0)
				rl.BeginDrawing()
				draw_frame(&commands)
				rl.TakeScreenshot("/tmp/wn-gif-live-preview.png")
				rl.EndDrawing()
			}
		}
	}
}
