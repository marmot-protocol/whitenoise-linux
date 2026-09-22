// Chat-list row actions: the right-click menu on a rail row (pin,
// mute, mark read/unread, folders, export) plus the folder modal and
// the rail ordering/filtering they drive.
//
// marmot's C API exports no per-group pin, mute or mark-unread setter
// (only marmot_set_group_archived and marmot_mark_timeline_message_read),
// so those three live in Prefs, keyed by group id. The local mute is
// folded into the row's `muted` flag in row_to_ui, which is what the
// notification gate already reads.
package main

import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

// Rail order: pinned chats first, each half keeping marmot's activity
// order. Returns indices into `chats`.
rail_order :: proc(
	chats: []Chat_Row_Ui,
	pinned: map[string]bool,
	allocator := context.temp_allocator,
) -> [dynamic]int {
	order := make([dynamic]int, 0, len(chats), allocator)
	for chat, i in chats {
		if pinned[chat.group_id] {
			append(&order, i)
		}
	}
	for chat, i in chats {
		if !pinned[chat.group_id] {
			append(&order, i)
		}
	}
	return order
}

// Folder chip predicate: no active chip shows every chat, otherwise
// only the chats assigned to that folder.
in_folder :: proc(folder_of: map[string]string, group_id: string, filter: string) -> bool {
	return len(filter) == 0 || folder_of[group_id] == filter
}

// Flip a group id in a local set; returns the new state. The removed
// key's clone is left to the process, like the other local sets here.
toggle_flag :: proc(set: ^map[string]bool, group_id: string) -> bool {
	if set[group_id] {
		delete_key(set, group_id)
		return false
	}
	set[strings.clone(group_id)] = true
	return true
}

// Right-click menu for a rail row, the slint chat-list row menu.
// The row a menu was opened on. It outlives the close (which sets the
// index to -1), so the menu can finish animating out over the chat it
// belongs to.
row_menu_shown: int

// The row the menu is showing, live while open and remembered while it
// closes.
row_menu_index :: proc(ui: ^Ui_State) -> int {
	if ui.row_menu >= 0 {
		row_menu_shown = ui.row_menu
	}
	return row_menu_shown
}

chat_row_menu :: proc(ui: ^Ui_State) {
	chat := ui.chats[row_menu_index(ui)]

	if clay.UI(clay.ID("RowMenu"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFit({min = 210})},
			padding = clay.PaddingAll(4),
			childGap = 1,
		},
		floating = {
			attachTo = .Root,
			offset = {ui.row_menu_x, ui.row_menu_y + rise(clay.ID("RowMenu"))},
			zIndex = 10,
		},
		backgroundColor = CARD,
		cornerRadius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		ctx_item("RowPin", ICON_PIN, ui.prefs.pinned[chat.group_id] ? "Unpin" : "Pin to top")
		ctx_item("RowMute", ICON_BELL_OFF, ui.prefs.muted_ids[chat.group_id] ? "Unmute" : "Mute")
		ctx_item("RowRead", ICON_ENVELOPE_OPEN, "Mark read")
		ctx_item("RowUnread", ICON_ENVELOPE, "Mark unread")
		ctx_item("RowFolder", ICON_FOLDER, "Move to folder")
		ctx_item("RowExportHtml", ICON_DOWNLOAD, "Export as HTML")
		ctx_item("RowExportMd", ICON_DOWNLOAD, "Export as Markdown")
	}
}

// Folder modal: create, rename and delete folders, and put the
// right-clicked chat in one (a chat belongs to at most one folder;
// clicking its current folder takes it out again).
folder_modal :: proc(ui: ^Ui_State) {
	current := ui.prefs.folder_of[ui.folder_gid]

	if clay.UI(clay.ID("FolderModal"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(modal_w(clay.ID("FolderModal"), 380))},
			padding = clay.PaddingAll(20),
			childGap = 12,
		},
		floating = {
			attachTo = .Root,
			zIndex = 13,
			offset = {0, rise(clay.ID("FolderModal"))},
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		if clay.UI(clay.ID("FolderHead"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}},
		) {
			clay.Text(tr("Folders"), {fontId = FONT_TITLE, fontSize = 18, textColor = TEXT})
			if clay.UI(clay.ID("FolderHeadGap"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			if clay.UI(clay.ID("FolderClose"))(
			{
				layout = {padding = clay.PaddingAll(6)},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(6),
			},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}
		clay.Text(
			tr(
				"Pick a folder for this chat, or make a new one. A chat sits in one folder at a time.",
			),
			{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
		)

		eyebrow("FOLDERS")
		if len(ui.prefs.folders) == 0 {
			clay.Text(
				tr("No folders yet."),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
			)
		}
		for name, i in ui.prefs.folders {
			active := name == current
			if clay.UI(clay.ID("FolderRow", u32(i)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					padding = {left = 12, right = 10, top = 8, bottom = 8},
					childGap = 10,
					childAlignment = {y = .Center},
				},
				backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
				cornerRadius = rr(10),
			},
			) {
				clay.Text(
					ICON_FOLDER,
					{fontId = FONT_ICON, fontSize = 12, textColor = active ? ACCENT : TEXT_DIM},
				)
				clay.Text(name, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
				if clay.UI(clay.ID("FolderRowGap", u32(i)))(
				{layout = {sizing = {width = clay.SizingGrow()}}},
				) {}
				action_chip("FolderRename", u32(i), tr("Rename"))
				action_chip("FolderDelete", u32(i), tr("Delete"))
			}
		}

		eyebrow(ui.folder_rename >= 0 ? "RENAME FOLDER" : "NEW FOLDER")
		if clay.UI(clay.ID("FolderBox"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(34)},
				padding = {left = 12, right = 12},
				childAlignment = {y = .Center},
			},
			backgroundColor = ROW_BG,
			cornerRadius = rr(10),
			border = {color = ui.focus == .Folder ? ACCENT : FIELD_BORDER, width = bw()},
		},
		) {
			field_text(
				ui,
				"FolderBox",
				&ui.folder_input,
				"Folder name",
				ui.focus == .Folder,
				13,
				TEXT_LO,
			)
		}
		if clay.UI(clay.ID("FolderActions"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}},
		) {
			micro_button("FolderSave", ui.folder_rename >= 0 ? "Save" : "Create folder")
			if len(current) > 0 {
				micro_button("FolderClear", "Take out of folder")
			}
		}
	}
}

// Rail head chips, one per folder plus the all-chats chip.
folder_chips :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("FolderChips"))(
	{layout = {sizing = {width = clay.SizingGrow()}, childGap = 6, padding = {top = 2}}},
	) {
		folder_chip("FolderAllChip", 0, tr("All folders"), len(ui.folder_filter) == 0)
		for name, i in ui.prefs.folders {
			folder_chip("FolderFilter", u32(i), name, ui.folder_filter == name)
		}
	}
}

folder_chip :: proc(id_str: string, index: u32, label: string, active: bool) {
	if clay.UI(clay.ID(id_str, index))(
	{
		layout = {padding = {left = 10, right = 10, top = 4, bottom = 4}},
		backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
		cornerRadius = rr(8),
		border = {color = FIELD_BORDER, width = bw()},
	},
	) {
		clay.Text(
			label,
			{fontId = FONT_BODY, fontSize = 11, textColor = active ? ACCENT : TEXT_DIM},
		)
	}
}

// Open the row menu at the pointer, clamped like the message one
// (ponytail: rough clamp from an estimated panel size).
open_row_menu :: proc(ui: ^Ui_State, index: int) {
	m := rl.GetMousePosition()
	ui.row_menu = index
	ui.row_menu_x, ui.row_menu_y = panel_pos(m.x / UI_ZOOM, m.y / UI_ZOOM, 230, 250)
}

// Clicks in the open row menu; anything unhandled closes it.
handle_row_menu :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if ui.row_menu < 0 || ui.row_menu >= len(ui.chats) || rl.IsKeyPressed(.ESCAPE) {
		ui.row_menu = -1
		return
	}
	if rl.IsMouseButtonPressed(.RIGHT) && !clay.PointerOver(clay.ID("RowMenu")) {
		ui.row_menu = -1
		return
	}
	if !mouse_released() {
		return
	}
	index := ui.row_menu
	gid := ui.chats[index].group_id
	ui.row_menu = -1

	if clay.PointerOver(clay.ID("RowFolder")) {
		delete(ui.folder_gid)
		ui.folder_gid = strings.clone(gid)
		ui.folder_rename = -1
		clear(&ui.folder_input)
		ui.folder_open = true
		ui.focus = .Folder
		return
	}
	if clay.PointerOver(clay.ID("RowPin")) {
		toggle_flag(&ui.prefs.pinned, gid)
		save_settings(ui)
		return
	}
	if clay.PointerOver(clay.ID("RowMute")) {
		toggle_flag(&ui.prefs.muted_ids, gid)
		save_settings(ui)
		refresh_after_action(ui, client) // row_to_ui folds the flag back in
		return
	}
	if clay.PointerOver(clay.ID("RowRead")) {
		mark_chat_read(ui, client, index)
		return
	}
	if clay.PointerOver(clay.ID("RowUnread")) {
		ui.prefs.unread_ids[strings.clone(gid)] = true
		save_settings(ui)
		return
	}
	if clay.PointerOver(clay.ID("RowExportHtml")) {
		export_chat(ui, client, .Html, index)
		return
	}
	if clay.PointerOver(clay.ID("RowExportMd")) {
		export_chat(ui, client, .Markdown, index)
		return
	}
}

// Clear a chat's badge without opening it: drop the manual reminder
// and tell marmot the latest message was read.
mark_chat_read :: proc(ui: ^Ui_State, client: ^marmot.Client, index: int) {
	chat := ui.chats[index]
	if chat.group_id in ui.prefs.unread_ids {
		delete_key(&ui.prefs.unread_ids, chat.group_id)
		save_settings(ui)
	}
	if len(chat.last_id) == 0 {
		return
	}

	row: ^marmot.Chat_List_Row
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	group := strings.clone_to_cstring(chat.group_id, context.temp_allocator)
	message := strings.clone_to_cstring(chat.last_id, context.temp_allocator)
	if marmot.mark_timeline_message_read(client, account, group, message, &row) != .OK {
		ui.client_status = fmt.aprintf("Couldn't mark the chat read. %s", marmot.last_error())
		return
	}
	ui.chats[index].unread = row.unread_count
	delete(ui.chats[index].first_unread)
	ui.chats[index].first_unread = strings.clone(string(row.first_unread_message_id_hex))
	marmot.chat_list_row_free(row)
}

// Clicks and typing in the open folder modal.
handle_folder_modal :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	edit_text(ui, &ui.folder_input)

	if rl.IsKeyPressed(.ESCAPE) ||
	   clicked("FolderClose") ||
	   (mouse_released() && !clay.PointerOver(clay.ID("FolderModal"))) {
		ui.folder_open = false
		ui.focus = .Compose
		return
	}
	if field_mouse(ui, &ui.folder_input, "FolderBox") {
		ui.focus = .Folder
		return
	}

	released := mouse_released()
	for name, i in ui.prefs.folders {
		if released && clay.PointerOver(clay.ID("FolderRename", u32(i))) {
			ui.folder_rename = i
			ed_set(ui, &ui.folder_input, name)
			ui.focus = .Folder
			return
		}
		if released && clay.PointerOver(clay.ID("FolderDelete", u32(i))) {
			// Chats in a deleted folder fall back to no folder (the
			// keys are gathered first, deleting while iterating a map
			// is not safe).
			orphans := make([dynamic]string, context.temp_allocator)
			for gid, folder in ui.prefs.folder_of {
				if folder == name {
					append(&orphans, gid)
				}
			}
			for gid in orphans {
				delete_key(&ui.prefs.folder_of, gid)
			}
			if ui.folder_filter == name {
				ui.folder_filter = ""
			}
			ordered_remove(&ui.prefs.folders, i)
			ui.folder_rename = -1
			save_settings(ui)
			return
		}
		if released && clay.PointerOver(clay.ID("FolderRow", u32(i))) {
			assign_folder(ui, ui.prefs.folder_of[ui.folder_gid] == name ? "" : name)
			return
		}
	}

	if clicked("FolderClear") {
		assign_folder(ui, "")
		return
	}
	if clicked("FolderSave") || rl.IsKeyPressed(.ENTER) {
		name := strings.trim_space(string(ui.folder_input[:]))
		if len(name) == 0 {
			return
		}
		if ui.folder_rename >= 0 && ui.folder_rename < len(ui.prefs.folders) {
			old := ui.prefs.folders[ui.folder_rename]
			for gid, folder in ui.prefs.folder_of {
				if folder == old {
					ui.prefs.folder_of[gid] = strings.clone(name)
				}
			}
			if ui.folder_filter == old {
				ui.folder_filter = strings.clone(name)
			}
			ui.prefs.folders[ui.folder_rename] = strings.clone(name)
			ui.folder_rename = -1
		} else {
			append(&ui.prefs.folders, strings.clone(name))
		}
		clear(&ui.folder_input)
		save_settings(ui)
	}
}

// Put the modal's chat in `name` ("" takes it out of every folder).
assign_folder :: proc(ui: ^Ui_State, name: string) {
	if len(name) == 0 {
		delete_key(&ui.prefs.folder_of, ui.folder_gid)
	} else {
		ui.prefs.folder_of[strings.clone(ui.folder_gid)] = strings.clone(name)
	}
	save_settings(ui)
}
