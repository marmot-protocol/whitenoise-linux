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
folder_rules_file_unplaced_chats :: proc(t: ^testing.T) {
	ui: Ui_State
	append(&ui.prefs.folders, "Unread", "Small", "Acme")
	unread := Folder_Rules {
		match = .Any,
	}
	append(&unread.rules, Folder_Rule{kind = .Unread})
	small := Folder_Rules {
		match = .All,
	}
	append(
		&small.rules,
		Folder_Rule{kind = .Fewer_Than, count = 3},
		Folder_Rule{kind = .Has_Member, value = "bob"},
	)
	acme := Folder_Rules {
		match = .Any,
	}
	append(
		&acme.rules,
		Folder_Rule{kind = .Name_Has, value = "acme"},
		Folder_Rule{kind = .More_Than, count = 10},
	)
	ui.prefs.folder_rules["Unread"] = unread
	ui.prefs.folder_rules["Small"] = small
	ui.prefs.folder_rules["Acme"] = acme
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "placed", title = "Lunch", unread = 5},
		Chat_Row_Ui{group_id = "unread", title = "ACME team", unread = 1},
		Chat_Row_Ui{group_id = "dm-bob", title = "Bob"},
		Chat_Row_Ui{group_id = "dm-carol", title = "Carol"},
		Chat_Row_Ui{group_id = "unread-members", title = "Two of us"},
		Chat_Row_Ui{group_id = "acme", title = "Acme corp"},
		Chat_Row_Ui{group_id = "big", title = "Town hall"},
		Chat_Row_Ui{group_id = "stale", title = "acme ops"},
	)
	ui.prefs.folder_of["placed"] = "Acme" // by hand, over the Unread rule
	ui.prefs.folder_of["stale"] = "Removed folder" // gone, so rules decide
	big := make([]string, 11)
	for &id in big {id = "someone"}
	ui.chat_members["dm-bob"] = []string{"me", "bob"}
	ui.chat_members["dm-carol"] = []string{"me", "carol"}
	ui.chat_members["big"] = big
	defer {
		delete(ui.prefs.folders)
		delete(unread.rules)
		delete(small.rules)
		delete(acme.rules)
		delete(ui.prefs.folder_rules)
		delete(ui.prefs.folder_of)
		delete(ui.chats)
		delete(big)
		delete(ui.chat_members)
	}

	order := []int{0, 1, 2, 3, 4, 5, 6, 7}
	sections, grouped := chat_folder_sections(&ui, order, context.allocator)
	defer delete(sections)
	defer delete(grouped)
	if !testing.expect_value(t, len(sections), 4) {return}

	// "unread" also names Acme, but Unread comes first in folder order.
	// "unread-members" has no member list yet, so no size rule holds.
	expected := [][]int{{1}, {2}, {0, 5, 6, 7}, {3, 4}}
	for rows, slot in expected {
		section := sections[slot]
		if !testing.expect_value(t, section.count, len(rows)) {continue}
		for index, i in rows {
			testing.expect_value(t, grouped[section.start + i], index)
		}
	}
}

@(test)
folder_rules_parse_rows :: proc(t: ^testing.T) {
	ui: Ui_State
	defer {
		for draft in ui.folder_rules {delete(draft.input)}
		delete(ui.folder_rules)
	}
	draft :: proc(ui: ^Ui_State, kind: Folder_Rule_Kind, text: string) {
		row := Folder_Rule_Draft {
			kind = kind,
		}
		append(&row.input, text)
		append(&ui.folder_rules, row)
	}
	bob := "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
	ui.folder_match = .Any
	draft(&ui, .Name_Has, "  Acme Team ")
	draft(&ui, .Name_Has, "   ") // blank rows are skipped
	draft(&ui, .Unread, "")
	draft(&ui, .More_Than, "12")
	npub := hex_npub(bob)
	defer delete(npub)
	draft(&ui, .Has_Member, npub)

	set, bad, _ := folder_rules_parse(&ui)
	defer folder_rules_free(set)
	testing.expect_value(t, bad, -1)
	testing.expect_value(t, set.match, Folder_Match.Any)
	if !testing.expect_value(t, len(set.rules), 4) {return}
	testing.expect_value(t, set.rules[0].value, "acme team")
	testing.expect_value(t, set.rules[1].kind, Folder_Rule_Kind.Unread)
	testing.expect_value(t, set.rules[2].count, 12)
	testing.expect_value(t, set.rules[3].value, bob)

	// A row that doesn't parse names itself and yields no rules.
	draft(&ui, .Fewer_Than, "-1")
	draft(&ui, .Has_Member, "npub1nope")
	failed, index, why := folder_rules_parse(&ui)
	testing.expect_value(t, index, 5)
	testing.expect(t, why != "")
	testing.expect_value(t, len(failed.rules), 0)
	delete(ui.folder_rules[5].input)
	ordered_remove(&ui.folder_rules, 5)
	_, index, _ = folder_rules_parse(&ui)
	testing.expect_value(t, index, 5)
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
