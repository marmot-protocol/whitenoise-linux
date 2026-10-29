package main

import "core:strings"
import "core:sync"
import "core:testing"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
reading_restore_scope :: proc(t: ^testing.T) {
	ui := Ui_State {
		account_ref = "first-account",
		selected    = 0,
	}
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "shared-group"},
		Chat_Row_Ui{group_id = "other-group"},
	)
	ui.reading_places[strings.clone("first-account:shared-group")] = {
		strings.clone("saved-message"),
		-12,
	}
	defer {reading_clear(&ui); delete(ui.jump_id); delete(ui.chats)}

	reading_restore(&ui)
	testing.expect_value(t, ui.jump_id, "saved-message")
	testing.expect_value(t, ui.reading_pending.offset, f32(-12))
	testing.expect(t, ui.gs_jump_pending && !ui.scroll_pending)

	ui.account_ref = "second-account"
	reading_restore(&ui)
	testing.expect_value(t, ui.jump_id, "")
	testing.expect_value(t, ui.reading_pending.message, "")
	testing.expect(t, !ui.gs_jump_pending && ui.scroll_pending)

	ui.account_ref, ui.selected = "first-account", 1
	reading_restore(&ui)
	testing.expect_value(t, ui.jump_id, "")
	testing.expect(t, ui.scroll_pending)

	ui.selected = 0
	reading_restore(&ui)
	testing.expect_value(t, ui.jump_id, "saved-message")
}

@(test)
reply_parent_feedback :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui := Ui_State {
		jump_id = strings.clone("other-jump"),
	}
	append(&ui.messages, Msg_Ui{id = "loaded-parent"})
	defer {
		delete(ui.messages); delete(ui.jump_id); delete(ui.toast); delete(ui.gs_flash_id)
		forced_release = false; reply_jump_hover = ""
		rl.PushMouseButton(.LEFT, false)
	}
	rl.PushMouseButton(.LEFT, true)
	clay.BeginLayout()
	clay.EndLayout(0)
	for id in ([]string{"missing-parent", "loaded-parent"}) {
		reply_jump_hover = id
		forced_release = false
		handle_reply_jump(&ui)
		testing.expect_value(t, ui.toast, "")
		forced_release = true
		handle_reply_jump(&ui)
		testing.expect(t, ui.toast != "" && ui.toast_until > 0)
		testing.expect_value(t, ui.jump_id, "other-jump")
		testing.expect_value(t, reply_jump_hover, "")
		delete(ui.toast); ui.toast = ""
	}
	clay.BeginLayout()
	if clay.UI(clay.ID("MsgRow", 0))({layout = {sizing = {height = clay.SizingFixed(40)}}}) {}
	clay.EndLayout(0)
	ui.reading_pending = {
		message = "saved-place",
		offset  = -12,
	}
	reply_jump_hover = "loaded-parent"
	handle_reply_jump(&ui)
	testing.expect_value(t, ui.jump_id, "loaded-parent")
	testing.expect_value(t, ui.reading_pending.message, "")
	testing.expect_value(t, ui.toast, "")
	testing.expect_value(t, reply_jump_hover, "")
}
