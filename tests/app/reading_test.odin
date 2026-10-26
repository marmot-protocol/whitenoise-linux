package main

import "core:strings"
import "core:testing"

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
