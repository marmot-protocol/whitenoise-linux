package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Drop coordinates come from SDL, not the mouse: desktop drags need not
// deliver normal mouse motion to the receiving window.
@(private)
chat_drop_target :: proc(ui: ^Ui_State, position: rl.Vector2) -> bool {
	if ui.page != .Chats ||
	   len(ui.accounts) == 0 ||
	   ui.selected < 0 ||
	   ui.selected >= len(ui.chats) ||
	   ui.chats[ui.selected].pending ||
	   ui.chat_preview_w > 0 ||
	   ui.lock_requested ||
	   ui.add_account_open ||
	   ui.new_chat_open ||
	   ui.show_members ||
	   ui.group_files_open ||
	   (ui.issues_open && ui.compose_issue == "") ||
	   ui.editing != "" ||
	   ui.picker_open ||
	   ui.poll_open ||
	   ui.ctx_open ||
	   ui.row_menu >= 0 ||
	   ui.folder_menu_open ||
	   modal_open(ui) ||
	   blocked_peer(ui) != "" {
		return false
	}
	body := clay.GetElementData(clay.ID("ChatBody"))
	composer := clay.GetElementData(clay.ID("Composer"))
	if !body.found || !composer.found {return false}
	box := body.boundingBox
	x, y := position.x / UI_ZOOM, position.y / UI_ZOOM
	return x >= box.x && x < box.x + box.width && y >= box.y && y < box.y + box.height
}

@(private)
handle_file_drop :: proc(ui: ^Ui_State) {
	files := rl.DroppedFiles()
	defer delete(files)
	for file in files {
		if chat_drop_target(ui, file.position) {
			stage_file(ui, file.path)
			ui.focus = .Compose
		}
		delete(file.path)
	}
}

@(private)
chat_drop_overlay :: proc(ui: ^Ui_State) {
	if !rl.FileDropActive() || !chat_drop_target(ui, rl.FileDropPosition()) {return}
	box := clay.GetElementData(clay.ID("ChatBody")).boundingBox
	if clay.UI(clay.ID("ChatDropTarget"))(
	{
		layout = {
			sizing = {clay.SizingFixed(box.width), clay.SizingFixed(box.height)},
			childAlignment = {x = .Center, y = .Center},
		},
		floating = {attachTo = .ElementWithId, parentId = clay.ID("ChatBody").id, zIndex = 8},
		backgroundColor = OVERLAY,
		border = {color = ACCENT, width = {left = 2, right = 2, top = 2, bottom = 2}},
	},
	) {
		if clay.UI(clay.ID("ChatDropLabel"))(
		{layout = {padding = clay.PaddingAll(16)}, backgroundColor = CARD, cornerRadius = rr(8)},
		) {
			clay.Text(
				tr("Drop files to attach"),
				{fontId = FONT_BODY, fontSize = 18, textColor = TEXT},
			)
		}
	}
}
