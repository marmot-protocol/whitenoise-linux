package main

import "core:testing"

@(test)
inbox_filter_boundaries :: proc(t: ^testing.T) {
	ui := Ui_State{}
	defer delete(ui.chats)
	defer delete(ui.sidebar_filter)
	defer delete(ui.prefs.unread_ids)
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "dm", title = "Alex", conversation_kind = .DIRECT, unread = 2},
		Chat_Row_Ui{group_id = "pair", title = "Project", conversation_kind = .GROUP},
		Chat_Row_Ui{group_id = "group", title = "Team", conversation_kind = .GROUP, unread = 1},
		Chat_Row_Ui {
			group_id = "archive",
			title = "Archived",
			conversation_kind = .GROUP,
			search_only = true,
		},
	)
	ui.prefs.unread_ids["pair"] = true

	rows, total := chat_rail_matches(&ui)
	testing.expect_value(t, total, 3)
	testing.expect(t, len(rows) == 3 && rows[0] == 0 && rows[1] == 1 && rows[2] == 2)

	ui.chat_filter = .Groups
	rows, _ = chat_rail_matches(&ui)
	testing.expect(t, len(rows) == 2 && rows[0] == 1 && rows[1] == 2)

	append(&ui.sidebar_filter, "project")
	rows, _ = chat_rail_matches(&ui)
	testing.expect(t, len(rows) == 1 && ui.chats[rows[0]].group_id == "pair")

	clear(&ui.sidebar_filter)
	ui.chat_filter = .Unread
	rows, _ = chat_rail_matches(&ui)
	testing.expect(t, len(rows) == 3)
	delete_key(&ui.prefs.unread_ids, "pair")
	rows, _ = chat_rail_matches(&ui)
	testing.expect(t, len(rows) == 2 && rows[0] == 0 && rows[1] == 2)

	ui.chat_filter = .Groups
	append(&ui.sidebar_filter, "alex")
	ui.filter_hits = make([dynamic]bool, len(ui.chats))
	defer delete(ui.filter_hits)
	ui.filter_hits[2] = true
	rows, _ = chat_rail_matches(&ui)
	testing.expect(t, len(rows) == 1 && ui.chats[rows[0]].group_id == "group")

	append(
		&ui.archived,
		Chat_Row_Ui {
			group_id = "old",
			title = "Old conversation",
			preview = "project archive",
			conversation_kind = .DIRECT,
		},
	)
	defer delete(ui.archived)
	ui.chat_filter = .Archived
	rows, total = chat_rail_matches(&ui)
	testing.expect_value(t, total, 1)
	testing.expect_value(t, len(rows), 0)
	clear(&ui.sidebar_filter)
	append(&ui.sidebar_filter, "project")
	rows, _ = chat_rail_matches(&ui)
	testing.expect(t, len(rows) == 1 && ui.archived[rows[0]].group_id == "old")
}
