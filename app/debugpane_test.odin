// Debug pane: the state snapshot is hand-built (Ui_State itself holds
// textures and pointers), so this checks it serializes the fields the
// page promises. Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:strings"
import "core:testing"

@(test)
debug_state_snapshot :: proc(t: ^testing.T) {
	ui: Ui_State
	defer delete(ui.chats)
	ui.account_ref = "abc123"
	ui.page = .Settings
	ui.selected = 0
	ui.prefs.dev_mode = true
	append(&ui.chats, Chat_Row_Ui{group_id = "g1", title = "Marmots", unread = 3})

	out := debug_state_json(&ui)
	defer delete(out)

	testing.expect(t, strings.contains(out, `"account": "abc123"`))
	testing.expect(t, strings.contains(out, `"page": "Settings"`))
	testing.expect(t, strings.contains(out, `"selected_chat": "g1"`))
	testing.expect(t, strings.contains(out, `"unread": 3`))
	testing.expect(t, strings.contains(out, `"dev_mode": true`))
}

@(test)
debug_kp_dump :: proc(t: ^testing.T) {
	rows := []Kp_Row{{id = "ev1", kp_ref = "ref1", local = true, relay_urls = {"wss://a"}, bytes = 400}}

	out := kp_json(rows)
	defer delete(out)

	testing.expect(t, strings.contains(out, `"key_package_ref": "ref1"`))
	testing.expect(t, strings.contains(out, `"bytes": 400`))
	testing.expect(t, strings.contains(out, `"wss://a"`))
}
