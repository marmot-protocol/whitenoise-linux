package main

import "core:encoding/json"
import "core:testing"

@(test)
inbox_activity_pin_order :: proc(t: ^testing.T) {
	ui: Ui_State
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "old", activity_at = 100},
		Chat_Row_Ui{group_id = "new", activity_at = 300},
		Chat_Row_Ui{group_id = "middle", activity_at = 200},
	)
	defer {delete(ui.chats); delete(ui.prefs.pinned)}
	rows := inbox_rows(&ui, []int{0, 2, 1})
	if !testing.expect_value(t, len(rows), 3) {return}
	for key, i in ([]string{"new", "middle", "old"}) {
		testing.expect_value(t, rows[i].key, key)
	}
	ui.prefs.pinned["old"] = true
	rows = inbox_rows(&ui, []int{0, 2, 1})
	for key, i in ([]string{"old", "new", "middle"}) {testing.expect_value(t, rows[i].key, key)}
	ui.chats[0].activity_at, ui.chats[1].activity_at, ui.chats[2].activity_at = 200, 200, 200
	delete_key(&ui.prefs.pinned, "old")
	rows = inbox_rows(&ui, []int{2, 1, 0})
	for row, i in rows {testing.expect_value(t, row.index, i)}
}

@(test)
inbox_folder_sort_order :: proc(t: ^testing.T) {
	ui: Ui_State
	append(&ui.prefs.folders, "Work", "Other")
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "pinned-new", title = "Zebra", activity_at = 700},
		Chat_Row_Ui{group_id = "pinned-old", title = "Aardvark", activity_at = 600, unread = 1},
		Chat_Row_Ui{group_id = "recent", title = "Zebra", activity_at = 500},
		Chat_Row_Ui{group_id = "native", title = "Beta", activity_at = 400, unread = 1},
		Chat_Row_Ui{group_id = "manual", title = "alpha", activity_at = 200},
		Chat_Row_Ui{group_id = "same-title", title = "Alpha", activity_at = 300},
		Chat_Row_Ui{group_id = "old", title = "Aaron", activity_at = 100},
		Chat_Row_Ui{group_id = "other-new", title = "Zebra", activity_at = 900},
		Chat_Row_Ui{group_id = "other-old", title = "Alpha", activity_at = 800, unread = 1},
		Chat_Row_Ui{group_id = "unfiled-new", title = "Zebra", activity_at = 1000},
		Chat_Row_Ui{group_id = "unfiled-old", title = "Alpha", activity_at = 50, unread = 1},
	)
	for chat in ui.chats[:7] {ui.prefs.folder_of[chat.group_id] = "Work"}
	for chat in ui.chats[7:9] {ui.prefs.folder_of[chat.group_id] = "Other"}
	ui.prefs.pinned["pinned-new"] = true
	ui.prefs.pinned["pinned-old"] = true
	ui.prefs.unread_ids["manual"] = true
	defer {
		delete(ui.chats)
		delete(ui.prefs.folders)
		delete(ui.prefs.folder_of)
		delete(ui.prefs.folder_sorts)
		delete(ui.prefs.pinned)
		delete(ui.prefs.unread_ids)
	}
	order := inbox_all(&ui)
	expected := [3][7]int{{0, 1, 2, 3, 5, 4, 6}, {0, 1, 6, 5, 4, 3, 2}, {0, 1, 3, 4, 2, 5, 6}}
	for mode in Folder_Sort {
		if mode != .Recent {ui.prefs.folder_sorts["Work"] = mode}
		sections, grouped := inbox_sections(&ui, order, context.allocator)
		defer {delete(sections); delete(grouped)}
		if !testing.expect_value(t, len(sections), 3) {return}
		if !testing.expect_value(t, len(grouped), len(ui.chats)) {return}
		testing.expect_value(t, sections[0].count, 7)
		testing.expect_value(t, sections[0].unread, 3)
		for index, i in expected[int(mode)] {testing.expect_value(t, grouped[i].index, index)}
		for index, i in ([]int{7, 8, 9, 10}) {testing.expect_value(t, grouped[7 + i].index, index)}
	}
}

@(test)
inbox_folder_sort_settings :: proc(t: ^testing.T) {
	settings: Settings
	legacy := `{"prefs":{"folders":["Work","Other","Legacy"]}}`
	if !testing.expect(
		t,
		json.unmarshal(transmute([]u8)legacy, &settings, allocator = context.temp_allocator) ==
		nil,
	) {return}
	testing.expect_value(t, settings.prefs.folder_sorts["Work"], Folder_Sort.Recent)
	settings.prefs.folder_sorts = make(map[string]Folder_Sort, context.temp_allocator)
	settings.prefs.folder_sorts["Work"] = .Name
	settings.prefs.folder_sorts["Other"] = .Unread
	data, err := json.marshal(settings, allocator = context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	reopened: Settings
	if !testing.expect(
		t,
		json.unmarshal(data, &reopened, allocator = context.temp_allocator) == nil,
	) {return}
	testing.expect_value(t, reopened.prefs.folder_sorts["Work"], Folder_Sort.Name)
	testing.expect_value(t, reopened.prefs.folder_sorts["Other"], Folder_Sort.Unread)
	testing.expect_value(t, reopened.prefs.folder_sorts["Legacy"], Folder_Sort.Recent)
}

@(test)
inbox_manual_sections_preserve_chats :: proc(t: ^testing.T) {
	ui: Ui_State
	append(&ui.prefs.folders, "Shared", "Other")
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "chat-old", title = "Original chat", activity_at = 100, unread = 4},
		Chat_Row_Ui{group_id = "chat-new", title = "Recent chat", activity_at = 300},
	)
	original := [2]Chat_Row_Ui{ui.chats[0], ui.chats[1]}
	ui.prefs.folder_of["chat-old"] = "Shared"
	ui.prefs.folder_of["chat-new"] = "Other"
	defer {
		delete(ui.chats)
		delete(ui.prefs.folders)
		delete(ui.prefs.folder_of)
	}
	order := inbox_rows(&ui, []int{0, 1})
	sections, grouped := inbox_sections(&ui, order, context.allocator)
	defer {delete(sections); delete(grouped)}
	if !testing.expect_value(t, len(sections), 3) {return}
	if !testing.expect_value(t, len(grouped), 2) {return}
	testing.expect_value(t, sections[0].start, 0)
	testing.expect_value(t, sections[0].count, 1)
	testing.expect_value(t, sections[0].unread, 1)
	testing.expect_value(t, sections[1].start, 1)
	testing.expect_value(t, sections[1].count, 1)
	testing.expect_value(t, sections[2].count, 0)
	for key, i in ([]string{"chat-old", "chat-new"}) {testing.expect_value(t, grouped[i].key, key)}
	for chat, i in ui.chats {testing.expect(t, chat == original[i], "folder partitioning never rewrites chats")}
}

@(test)
inbox_filing_override :: proc(t: ^testing.T) {
	ui: Ui_State
	append(&ui.prefs.folders, "Work", "Shared")
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "ordinary", title = "Work chat", activity_at = 300, unread = 1},
	)
	original := ui.chats[0]
	work := Folder_Rules {
		match = .All,
	}
	append(&work.rules, Folder_Rule{kind = .Name_Has, value = "work"}, Folder_Rule{kind = .Unread})
	shared := Folder_Rules {
		match = .Any,
	}
	append(&shared.rules, Folder_Rule{kind = .Name_Has, value = "work"})
	ui.prefs.folder_rules["Work"] = work
	ui.prefs.folder_rules["Shared"] = shared
	defer {
		delete(work.rules)
		delete(shared.rules)
		delete(ui.prefs.folder_rules)
		delete(ui.prefs.folder_of)
		delete(ui.prefs.folders)
		delete(ui.chats)
	}
	order := inbox_rows(&ui, []int{0})
	for destination, slot in ([]string{"automatic", "Shared", ""}) {
		if destination != "automatic" {ui.prefs.folder_of["ordinary"] = destination}
		sections, grouped := inbox_sections(&ui, order, context.allocator)
		defer {delete(sections); delete(grouped)}
		if !testing.expect_value(t, len(sections), 3) {continue}
		if !testing.expect_value(t, len(grouped), 1) {continue}
		for section, i in sections {
			testing.expect_value(t, section.count, i == slot ? 1 : 0)
			testing.expect_value(t, section.unread, i == slot ? 1 : 0)
		}
		testing.expect_value(t, grouped[0].key, "ordinary")
		testing.expect_value(t, len(ui.chats), 1)
		testing.expect(
			t,
			ui.chats[0] == original,
			"folder rules and manual overrides never mutate chats",
		)
	}
}
