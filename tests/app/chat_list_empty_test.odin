package main

import marmot "../marmot"
import "base:runtime"
import "core:sync"
import "core:testing"

@(test)
archived_inbox_boundary :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	context.allocator = runtime.default_context().allocator
	defer profile_session_clear()
	ui := Ui_State{}
	defer {
		for chat in ui.chats {chat_free(chat)}
		delete(ui.chats)
		delete(ui.prefs.pinned)
	}
	row := marmot.Presented_Chat_Row {
		row = {
			group_id_hex = "archived",
			archived = true,
			conversation_kind = .GROUP,
			unread_count = 2,
		},
	}
	append(&ui.chats, row_to_ui(nil, &row, "account", nil, nil, nil))
	append(
		&ui.chats,
		chat_clone(Chat_Row_Ui{group_id = "active", conversation_kind = .GROUP, unread = 1}),
	)
	ui.prefs.pinned["archived"] = true
	for scope in ([]Chat_Filter{.Chats, .Unread, .Groups}) {
		ui.chat_filter = scope
		rows, total := chat_rail_matches(&ui)
		testing.expect_value(t, total, 1)
		testing.expect(t, len(rows) == 1 && ui.chats[rows[0]].group_id == "active")
	}
}

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
}
