// Rail ordering and folder grouping for the chat list.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:os"
import "core:sync"
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

@(test)
folder_delete_confirmation :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-folder-confirm", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	previous_config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", home)
	defer {
		if previous_config == "" {
			os.unset_env("XDG_CONFIG_HOME")
		} else {
			os.set_env("XDG_CONFIG_HOME", previous_config)
		}
	}
	previous_shown := confirm_shown
	defer confirm_shown = previous_shown

	ui: Ui_State
	append(&ui.prefs.folders, "Work", "Family")
	append(&ui.chats, Chat_Row_Ui{group_id = "work-chat"}, Chat_Row_Ui{group_id = "family-chat"})
	ui.prefs.folder_of["work-chat"] = "Work"
	ui.prefs.folder_of["family-chat"] = "Family"
	ui.prefs.collapsed_folders["Work"] = true
	ui.prefs.folder_icons["Work"] = 2
	ui.prefs.folder_colors["Work"] = 0x123456
	ui.prefs.folder_icons["Family"] = 3
	defer {
		delete(ui.prefs.folders)
		delete(ui.chats)
		delete(ui.prefs.folder_of)
		delete(ui.prefs.collapsed_folders)
		delete(ui.prefs.folder_icons)
		delete(ui.prefs.folder_colors)
		delete(ui.confirm.arg)
		delete(ui.confirm.name)
	}
	save_settings(&ui)
	before, read_err := os.read_entire_file(settings_path(), context.temp_allocator)
	if !testing.expect(t, read_err == nil) {return}

	confirm_ask(&ui, .Delete_Folder, "Work", "Work")
	testing.expect(t, len(ui.prefs.folders) == 2, "asking must not delete the folder")
	testing.expect_value(t, ui.confirm.name, "Work")
	confirm_close(&ui) // Cancel, Escape, and backdrop all use this dismissal.
	run_confirm(&ui, nil) // A stale confirmation event after dismissal must do nothing.
	testing.expect_value(t, len(ui.prefs.folders), 2)
	testing.expect_value(t, ui.prefs.folder_of["work-chat"], "Work")
	testing.expect(t, ui.prefs.collapsed_folders["Work"])
	testing.expect_value(t, ui.prefs.folder_icons["Work"], 2)
	testing.expect_value(t, ui.prefs.folder_colors["Work"], u32(0x123456))
	after_cancel, cancel_err := os.read_entire_file(settings_path(), context.temp_allocator)
	testing.expect(t, cancel_err == nil)
	testing.expect(
		t,
		string(after_cancel) == string(before),
		"cancel must not change persisted metadata",
	)

	confirm_ask(&ui, .Delete_Folder, "Work", "Work")
	ui.prefs.folders[0], ui.prefs.folders[1] = ui.prefs.folders[1], ui.prefs.folders[0]
	run_confirm(&ui, nil)
	testing.expect_value(t, ui.confirm.kind, Confirm_Kind.None)
	if !testing.expect_value(t, len(ui.prefs.folders), 1) {return}
	testing.expect(
		t,
		ui.prefs.folders[0] == "Family",
		"confirm must follow the name after reordering",
	)
	testing.expect(t, !("work-chat" in ui.prefs.folder_of))
	testing.expect(t, !("Work" in ui.prefs.collapsed_folders))
	testing.expect(t, !("Work" in ui.prefs.folder_icons))
	testing.expect(t, !("Work" in ui.prefs.folder_colors))
	testing.expect_value(t, ui.prefs.folder_of["family-chat"], "Family")
	testing.expect_value(t, ui.prefs.folder_icons["Family"], 3)
	testing.expect(t, len(ui.chats) == 2, "deleting organization must not delete chats")
	testing.expect_value(t, ui.chats[0].group_id, "work-chat")
	testing.expect_value(t, ui.chats[1].group_id, "family-chat")

	confirm_ask(&ui, .Delete_Folder, "Work", "Work")
	run_confirm(&ui, nil)
	testing.expect(
		t,
		len(ui.prefs.folders) == 1,
		"a missing target must not delete another folder",
	)
	testing.expect_value(t, ui.prefs.folders[0], "Family")
}
