// Rail ordering and folder filtering for the chat-list row actions.
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:testing"

@(test)
rail_order_pins_first :: proc(t: ^testing.T) {
	chats := []Chat_Row_Ui{{group_id = "a"}, {group_id = "b"}, {group_id = "c"}, {group_id = "d"}}

	// No pins: marmot's activity order, untouched.
	none: map[string]bool
	defer delete(none)
	plain := rail_order(chats, none, context.allocator)
	defer delete(plain)
	testing.expect_value(t, len(plain), 4)
	for i in 0 ..< 4 {
		testing.expect_value(t, plain[i], i)
	}

	// Pinned rows lead, and both halves keep their relative order.
	pinned: map[string]bool
	pinned["c"] = true
	pinned["b"] = true
	defer delete(pinned)
	order := rail_order(chats, pinned, context.allocator)
	defer delete(order)
	testing.expect_value(t, len(order), 4)
	testing.expect_value(t, order[0], 1) // b
	testing.expect_value(t, order[1], 2) // c
	testing.expect_value(t, order[2], 0) // a
	testing.expect_value(t, order[3], 3) // d
}

@(test)
folder_filter :: proc(t: ^testing.T) {
	folder_of: map[string]string
	folder_of["a"] = "Work"
	folder_of["b"] = "Family"
	defer delete(folder_of)

	// No chip: every chat, assigned or not.
	testing.expect(t, in_folder(folder_of, "a", ""))
	testing.expect(t, in_folder(folder_of, "z", ""))

	testing.expect(t, in_folder(folder_of, "a", "Work"))
	testing.expect(t, !in_folder(folder_of, "b", "Work"))
	testing.expect(t, !in_folder(folder_of, "z", "Work"))
}
