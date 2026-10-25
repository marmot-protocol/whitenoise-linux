package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:sync"
import "core:testing"
import rl "sdlrl"

@(test)
chat_drop_boundaries :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous := clay.GetCurrentContext()
	zoom := UI_ZOOM
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {clay.SetCurrentContext(previous); delete(memory); UI_ZOOM = zoom}
	clay.BeginLayout()
	if clay.UI(clay.ID("DropFixture"))(
	{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}},
	) {
		if clay.UI(clay.ID("RailFixture"))(
		{layout = {sizing = {clay.SizingFixed(200), clay.SizingGrow()}}},
		) {}
		if clay.UI(clay.ID("ChatBody"))(
		{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}},
		) {
			if clay.UI(clay.ID("Composer"))(
			{layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(100)}}},
			) {}
		}
	}
	clay.EndLayout(0)
	ui := Ui_State {
		page     = .Chats,
		selected = 0,
		row_menu = -1,
	}
	append(&ui.accounts, "account")
	append(&ui.chats, Chat_Row_Ui{group_id = "chat"})
	defer {delete(ui.accounts); delete(ui.chats); delete(ui.blocked)}
	for scale in ([]f32{1, 1.875}) {
		UI_ZOOM = scale
		testing.expect(t, chat_drop_target(&ui, {200 * scale, 0}))
		testing.expect(t, chat_drop_target(&ui, {799 * scale, 599 * scale}))
		testing.expect(
			t,
			!chat_drop_target(&ui, {199 * scale, 300 * scale}),
			"rail is not a drop target",
		)
		testing.expect(t, !chat_drop_target(&ui, {800 * scale, 300 * scale}))
		testing.expect(t, !chat_drop_target(&ui, {400 * scale, 600 * scale}))
	}
	UI_ZOOM = 1
	position := rl.Vector2{400, 300}
	ui.confirm.kind = .Delete_All
	testing.expect(t, !chat_drop_target(&ui, position), "modal captures drops")
	ui.confirm.kind = .None
	ui.location_open = true
	testing.expect(t, modal_open(&ui), "location picker owns the modal backdrop")
	testing.expect(t, !chat_drop_target(&ui, position), "location picker captures drops")
	ui.location_open = false
	testing.expect(t, chat_drop_target(&ui, position), "closing location restores the drop target")
	ui.editing = "message"
	testing.expect(t, !chat_drop_target(&ui, position), "editing cannot send attachments")
	ui.editing = ""
	ui.lock_requested = true
	testing.expect(t, !chat_drop_target(&ui, position), "lock cannot accept files")
	ui.lock_requested = false
	ui.group_files_open = true
	testing.expect(t, !chat_drop_target(&ui, position), "file browser has no composer")
	ui.group_files_open = false
	ui.chats[0].pending = true
	testing.expect(t, !chat_drop_target(&ui, position), "unaccepted invite is not writable")
	ui.chats[0].pending = false
	ui.chats[0].conversation_kind = .DIRECT
	ui.chats[0].peer_hex = "blocked"
	ui.blocked["blocked"] = true
	testing.expect(t, !chat_drop_target(&ui, position), "blocked DM has no composer")
	ui.blocked["blocked"] = false
	ui.selected = -1
	testing.expect(t, !chat_drop_target(&ui, position))
	ui.selected = 0
	ui.page = .Settings
	testing.expect(t, !chat_drop_target(&ui, position), "hidden chat layout cannot accept files")
}
