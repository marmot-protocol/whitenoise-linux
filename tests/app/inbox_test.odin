package main

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
