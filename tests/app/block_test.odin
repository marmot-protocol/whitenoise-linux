// Blocked runs: the "N blocked messages" header counts exactly the rows
// it hides, stopping where the timeline draws a marker between rows.
// Run: tests/odin.sh app
package main

import "core:testing"

@(test)
blocked_run_bounds :: proc(t: ^testing.T) {
	ui: Ui_State
	defer {delete(ui.messages); delete(ui.blocked)}
	ui.blocked["troll"] = true
	ui.blocked["spam"] = true
	append(
		&ui.messages,
		Msg_Ui{id = "a", sender_id = "troll", day = "Mon"},
		Msg_Ui{id = "b", sender_id = "spam", day = "Mon"}, // another blocked sender joins
		Msg_Ui{id = "t", sender_id = "friend", day = "Mon", thread_of = "x"}, // other view
		Msg_Ui{id = "c", sender_id = "troll", day = "Mon"},
		Msg_Ui{id = "d", sender_id = "troll", day = "Tue"}, // day marker ends the run
		Msg_Ui{id = "e", sender_id = "troll", day = "Tue"}, // unread marker ends the run
		Msg_Ui{id = "f", sender_id = "friend", day = "Tue"},
		Msg_Ui{id = "g", sender_id = "troll", day = "Tue", mine = true},
		Msg_Ui{id = "h", sender_id = "troll", day = "Tue", system = true},
	)
	ui.unread_mark_id = "e"

	testing.expect_value(t, blocked_run_len(&ui, 0), 3)
	testing.expect_value(t, blocked_run_len(&ui, 4), 1)
	testing.expect_value(t, blocked_run_len(&ui, 5), 1)
	testing.expect(t, !msg_blocked(&ui, ui.messages[7]), "own rows never collapse")
	testing.expect(t, !msg_blocked(&ui, ui.messages[8]), "system rows never collapse")
}
