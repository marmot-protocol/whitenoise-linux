// Group hero, the top of the members panel: big avatar with a photo
// chooser, group title, and inline description editing.
//
// The description publishes through marmot_update_group_profile. The
// photo has two sources: "Search images" (Openverse, openverse.odin)
// publishes a real URL avatar via marmot_update_group_avatar_url;
// "From file" stays session-local, because marmot-c exports no
// encrypted-Blossom group-image upload (download only), so a local
// file has nowhere to publish to.
package main

import "core:fmt"
import "core:os"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

// group id → session-local photo pseudo-URL (group://<gid>), so a
// "From file" pick survives chat-list reloads. Never published.
gpic_local: map[string]string

// The chat's photo texture: local override first, else the published
// avatar_url through the shared fetch pipeline.
chat_pic :: proc(chat: Chat_Row_Ui) -> ^rl.Texture2D {
	if url, ok := gpic_local[chat.group_id]; ok {
		return url_pic(url)
	}
	return url_pic(chat.avatar_url)
}

group_hero :: proc(ui: ^Ui_State) {
	chat := ui.chats[ui.selected]
	if clay.UI(clay.ID("GroupHero"))(
	{layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 8, childAlignment = {x = .Center}, padding = {top = 4, bottom = 4}}},
	) {
		avatar("HeroAvatar", 0, chat.group_id, chat.title, 72, chat_pic(chat))
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

// A file picked for the group photo: decode, register the round
// texture under a group:// pseudo-URL, remember the override.
// Session-local only; peers never see it (no upload path, see the
// module doc).
set_group_pic :: proc(ui: ^Ui_State, path: string) {
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
	if gid not_in gpic_local {
		gpic_local[strings.clone(gid)] = strings.clone(url)
	}
}
