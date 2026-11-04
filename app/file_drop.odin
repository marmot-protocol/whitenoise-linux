package main

import "nendo"
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
	body := nendo.element(nendo.id("ChatBody"))
	composer := nendo.element(nendo.id("Composer"))
	if !body.found || !composer.found {return false}
	box := body.rect
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
	box := nendo.element(nendo.id("ChatBody")).rect
	if nendo.box(nendo.id("ChatDropTarget"))(
	{
		width = nendo.fixed(box.width),
		height = nendo.fixed(box.height),
		align = {x = .Center, y = .Center},
		floating = {attach_to = .Element, parent = nendo.id("ChatBody").id, z = 8},
		color = OVERLAY,
		border = {color = ACCENT, width = {left = 2, right = 2, top = 2, bottom = 2}},
	},
	) {
		if nendo.box(nendo.id("ChatDropLabel"))(
		{padding = nendo.pad(16), color = CARD, radius = rr(8)},
		) {
			nendo.text(tr("Drop files to attach"), {font = FONT_BODY, size = 18, color = TEXT})
		}
	}
}
