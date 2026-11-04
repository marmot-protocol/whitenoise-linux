package main

import "core:sync"
import "core:testing"
import "nendo"
import rl "sdlrl"

@(test)
chat_drop_boundaries :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	zoom := UI_ZOOM
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {nendo.set_context(previous); delete(memory); UI_ZOOM = zoom}
	nendo.begin()
	if nendo.box(nendo.id("DropFixture"))({width = nendo.grow(), height = nendo.grow()}) {
		if nendo.box(nendo.id("RailFixture"))({width = nendo.fixed(200), height = nendo.grow()}) {}
		if nendo.box(nendo.id("ChatBody"))({width = nendo.grow(), height = nendo.grow()}) {
			if nendo.box(nendo.id("Composer"))(
			{width = nendo.grow(), height = nendo.fixed(100)},
			) {}
		}
	}
	nendo.end(0)
	ui := Ui_State {
		page     = .Chats,
		selected = 0,
		row_menu = -1,
	}
	append(&ui.accounts, Account_Row_Ui{name = "account"})
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
