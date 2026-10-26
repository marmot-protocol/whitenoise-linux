package main

import "core:testing"

@(test)
whip_activity_folder_ownership :: proc(t: ^testing.T) {
	ui: Ui_State
	defer whip_avatar_stop(&ui)
	defer {
		for folder in ui.prefs.whip_activity {delete(folder)}
		delete(ui.prefs.whip_activity)
	}
	whip_activity_record(&ui, "/tmp/wn-recency-project", 200)
	testing.expect_value(t, ui.prefs.whip_activity["/tmp/wn-recency-project"], u64(200))
	testing.expect(t, ui.settings_dirty)
	ui.settings_dirty = false
	whip_activity_record(&ui, "/tmp/wn-recency-project/", 100)
	whip_activity_record(&ui, "/tmp/wn-recency-project", 200)
	testing.expect(
		t,
		!ui.settings_dirty,
		"older or repeated activity does not rewrite preferences",
	)
	testing.expect_value(t, len(ui.prefs.whip_activity), 1)
	whip_activity_record(&ui, "/tmp/wn-recency-project/", 300)
	testing.expect(t, ui.settings_dirty)
	testing.expect_value(t, len(ui.prefs.whip_activity), 1)
	testing.expect_value(t, ui.prefs.whip_activity["/tmp/wn-recency-project"], u64(300))
}

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
	rows := inbox_rows(&ui, []int{0, 2, 1}, nil)
	if !testing.expect_value(t, len(rows), 3) {return}
	for key, i in ([]string{"new", "middle", "old"}) {
		testing.expect_value(t, rows[i].key, key)
		testing.expect_value(t, rows[i].kind, Inbox_Kind.Chat)
	}
	ui.prefs.pinned["old"] = true
	rows = inbox_rows(&ui, []int{0, 2, 1}, nil)
	for key, i in ([]string{"old", "new", "middle"}) {testing.expect_value(t, rows[i].key, key)}
	ui.chats[0].activity_at, ui.chats[1].activity_at, ui.chats[2].activity_at = 200, 200, 200
	delete_key(&ui.prefs.pinned, "old")
	rows = inbox_rows(&ui, []int{2, 1, 0}, nil)
	for row, i in rows {testing.expect_value(t, row.index, i)}
}

@(test)
inbox_whip_rule :: proc(t: ^testing.T) {
	rule := Folder_Rule {
		kind = .Is_Whip,
	}
	chat := Chat_Facts {
		title  = "whip terminal",
		unread = true,
		known  = true,
	}
	terminal := Chat_Facts {
		title = "work",
		whip  = true,
	}
	testing.expect(
		t,
		!folder_rule_holds(rule, chat),
		"a chat title cannot turn an engine chat into a terminal",
	)
	testing.expect(t, folder_rule_holds(rule, terminal), "Is Whip reads terminal facts")
	rules := Folder_Rules {
		match = .All,
	}
	append(&rules.rules, rule, Folder_Rule{kind = .Unread})
	defer delete(rules.rules)
	testing.expect(t, !folder_rules_match(rules, terminal))
	terminal.unread = true
	testing.expect(t, folder_rules_match(rules, terminal), "Is Whip combines with attention rules")
	testing.expect(t, !folder_rules_match(rules, chat))
}

@(test)
inbox_mixed_manual_sections :: proc(t: ^testing.T) {
	ui: Ui_State
	append(&ui.prefs.folders, "Shared", "Other")
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "chat-old", title = "Original chat", activity_at = 100, unread = 4},
		Chat_Row_Ui{group_id = "chat-new", title = "Recent chat", activity_at = 300},
	)
	original := [2]Chat_Row_Ui{ui.chats[0], ui.chats[1]}
	terminal_key := "whip:/tmp/wn-inbox-terminal"
	ui.prefs.folder_of[terminal_key] = "Shared"
	ui.prefs.folder_of["chat-old"] = "Shared"
	ui.prefs.folder_of["chat-new"] = "Other"
	defer {
		delete(ui.chats)
		delete(ui.prefs.folders)
		delete(ui.prefs.folder_of)
	}
	order := []Inbox_Row {
		{kind = .Chat, index = 1, key = "chat-new", activity_at = 300},
		{kind = .Terminal, project = 42, key = terminal_key, activity_at = 200, unread = true},
		{kind = .Chat, index = 0, key = "chat-old", activity_at = 100, unread = true},
	}
	sections, grouped := inbox_sections(&ui, order, context.allocator)
	defer {delete(sections); delete(grouped)}
	if !testing.expect_value(t, len(sections), 3) {return}
	if !testing.expect_value(t, len(grouped), 3) {return}
	testing.expect_value(t, sections[0].start, 0)
	testing.expect_value(t, sections[0].count, 2)
	testing.expect_value(t, sections[0].unread, 2)
	testing.expect_value(t, sections[1].start, 2)
	testing.expect_value(t, sections[1].count, 1)
	testing.expect_value(t, sections[2].count, 0)
	for key, i in ([]string{terminal_key, "chat-old", "chat-new"}) {testing.expect_value(t, grouped[i].key, key)}
	for chat, i in ui.chats {testing.expect(t, chat == original[i], "folder partitioning never rewrites engine chats")}
}

@(test)
inbox_whip_filing_override :: proc(t: ^testing.T) {
	ui: Ui_State
	append(&ui.prefs.folders, "Whip", "Shared")
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "ordinary", title = "Work terminal", activity_at = 300},
	)
	original := ui.chats[0]
	whip := Folder_Rules {
		match = .All,
	}
	append(
		&whip.rules,
		Folder_Rule{kind = .Is_Whip},
		Folder_Rule{kind = .Name_Has, value = "work"},
	)
	shared := Folder_Rules {
		match = .Any,
	}
	append(&shared.rules, Folder_Rule{kind = .Name_Has, value = "work"})
	ui.prefs.folder_rules["Whip"] = whip
	ui.prefs.folder_rules["Shared"] = shared
	defer {
		delete(whip.rules)
		delete(shared.rules)
		delete(ui.prefs.folder_rules)
		delete(ui.prefs.folder_of)
		delete(ui.prefs.folders)
		delete(ui.chats)
	}
	terminal_key := "whip:/tmp/wn-inbox-work"
	order := []Inbox_Row {
		{kind = .Chat, index = 0, key = "ordinary", title = "Work terminal", activity_at = 300},
		{
			kind = .Terminal,
			project = 42,
			key = terminal_key,
			title = "WORK project",
			activity_at = 200,
			unread = true,
		},
	}
	for destination in ([]string{"automatic", "Shared", ""}) {
		if destination != "automatic" {ui.prefs.folder_of[terminal_key] = destination}
		sections, grouped := inbox_sections(&ui, order, context.allocator)
		defer {delete(sections); delete(grouped)}
		if !testing.expect_value(t, len(sections), 3) {continue}
		if !testing.expect_value(t, len(grouped), 2) {continue}
		switch destination {
		case "automatic":
			testing.expect_value(t, sections[0].count, 1)
			testing.expect_value(t, sections[0].unread, 1)
			testing.expect_value(t, grouped[0].key, terminal_key)
			testing.expect_value(t, sections[1].count, 1)
			testing.expect_value(t, grouped[1].key, "ordinary")
		case "Shared":
			testing.expect_value(t, sections[0].count, 0)
			testing.expect_value(t, sections[1].count, 2)
			testing.expect_value(t, grouped[0].key, "ordinary")
			testing.expect_value(t, grouped[1].key, terminal_key)
		case "":
			testing.expect_value(t, sections[0].count, 0)
			testing.expect_value(t, sections[1].count, 1)
			testing.expect_value(t, sections[2].count, 1)
			testing.expect_value(t, grouped[1].key, terminal_key)
		}
		testing.expect_value(t, len(ui.chats), 1)
		testing.expect(
			t,
			ui.chats[0] == original,
			"Is Whip and manual overrides never mutate engine chats",
		)
	}
}
