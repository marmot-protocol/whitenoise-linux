// Rail ordering and folder grouping for the chat list.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
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
chat_folder_sections_keep_order_and_count_unread :: proc(t: ^testing.T) {
	ui: Ui_State
	append(&ui.prefs.folders, "Work", "Family")
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "family-unread", unread = 3},
		Chat_Row_Ui{group_id = "unfiled-read"},
		Chat_Row_Ui{group_id = "work-read"},
		Chat_Row_Ui{group_id = "work-pinned", unread = 5},
		Chat_Row_Ui{group_id = "unfiled-pinned"},
		Chat_Row_Ui{group_id = "family-pinned"},
		Chat_Row_Ui{group_id = "unknown-folder", unread = 2},
		Chat_Row_Ui{group_id = "family-read"},
	)
	ui.prefs.folder_of["family-unread"] = "Family"
	ui.prefs.folder_of["work-read"] = "Work"
	ui.prefs.folder_of["work-pinned"] = "Work"
	ui.prefs.folder_of["family-pinned"] = "Family"
	ui.prefs.folder_of["family-read"] = "Family"
	ui.prefs.folder_of["unknown-folder"] = "Removed folder"
	ui.prefs.unread_ids["work-pinned"] = true // Still one unread chat, not two.
	ui.prefs.unread_ids["unfiled-pinned"] = true
	ui.prefs.unread_ids["family-pinned"] = true
	defer delete(ui.chats)
	defer delete(ui.prefs.folders)
	defer delete(ui.prefs.folder_of)
	defer delete(ui.prefs.unread_ids)

	// The rail has already moved pins first, preserving activity order in each half.
	order := []int{3, 4, 5, 0, 1, 2, 6, 7}
	sections, grouped := chat_folder_sections(&ui, order, context.allocator)
	defer delete(sections)
	defer delete(grouped)
	if !testing.expect_value(t, len(sections), 3) {return}
	if !testing.expect_value(t, len(grouped), len(order)) {return}

	// Folder preference order, then Unfiled; each partition keeps the rail's order.
	expected := []Folder_Section {
		{start = 0, count = 2, unread = 1},
		{start = 2, count = 3, unread = 2},
		{start = 5, count = 3, unread = 2},
	}
	for section, i in sections {
		testing.expect_value(t, section.start, expected[i].start)
		testing.expect_value(t, section.count, expected[i].count)
		testing.expect_value(t, section.unread, expected[i].unread)
	}
	for index, i in ([]int{3, 2, 5, 0, 7, 4, 1, 6}) {
		testing.expect_value(t, grouped[i], index)
	}
}
