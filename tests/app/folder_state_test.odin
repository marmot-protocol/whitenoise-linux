package main

import marmot "../marmot"
import "base:runtime"
import "core:sync"
import "core:testing"

@(private = "file")
folder_state_fixture :: proc(ui: ^Ui_State, kind: Folder_Rule_Kind) {
	ui.account_ref = "receiver"
	ui.prefs.folders = make([dynamic]string, context.temp_allocator)
	append(&ui.prefs.folders, "State")
	ui.prefs.folder_rules = make(map[string]Folder_Rules, context.temp_allocator)
	rules := make([dynamic]Folder_Rule, context.temp_allocator)
	append(&rules, Folder_Rule{kind = kind})
	ui.prefs.folder_rules["State"] = {
		rules = rules,
	}
}

@(test)
folder_state_mentions_follow_read_results :: proc(t: ^testing.T) {
	ui: Ui_State
	folder_state_fixture(&ui, .Unread_Mention)
	nested := ui.prefs.folder_rules["State"]
	rules := make([dynamic]Folder_Rule, context.temp_allocator)
	append(&rules, Folder_Rule{kind = .Group_Node, nested = nested})
	ui.prefs.folder_rules["State"] = {
		rules = rules,
	}
	testing.expect(t, .Mention in folder_async_facts(ui.prefs))
	testing.expect(t, .Pending not_in folder_async_facts(ui.prefs))
	ui.prefs.unread_ids = make(map[string]bool, context.temp_allocator)
	ui.prefs.unread_ids["chat"] = true
	job := Chat_List_Work {
		account      = "receiver",
		folder_facts = make(map[string]Folder_Async_Facts, context.temp_allocator),
	}
	row := marmot.Presented_Chat_Row {
		row = {group_id_hex = "chat", unread_count = 2, unread_mention_count = 1},
	}
	lookup := folder_lookup(&ui)
	plain := chat_work_row_to_ui(&job, &row)
	defer chat_free(plain)
	// Native mentions can also come from inline text. A manual unread mark
	// and a positive native count are both insufficient for this rule.
	testing.expect_value(t, chat_folder_slot(&ui, &plain, lookup), 1)
	job.folder_facts["chat"] = {.Mention}
	typed := chat_work_row_to_ui(&job, &row)
	defer chat_free(typed)
	testing.expect_value(t, chat_folder_slot(&ui, &typed, lookup), 0)
	previous := chat_facts_previous([]Chat_Row_Ui{typed}, {.Mention})
	clear(&job.folder_facts)
	retained := chat_work_row_to_ui(&job, &row, previous)
	defer chat_free(retained)
	testing.expect_value(t, chat_folder_slot(&ui, &retained, lookup), 0)
	typed.pending = true
	testing.expect_value(t, chat_folder_slot(&ui, &typed, lookup), 1)
	typed.pending = false
	row.row.unread_mention_count = 0
	read := chat_work_row_to_ui(&job, &row, previous)
	defer chat_free(read)
	testing.expect_value(t, chat_folder_slot(&ui, &read, lookup), 1)
}

@(test)
folder_state_read_fences_live_mentions :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	context.allocator = runtime.default_context().allocator
	revision := chat_list_revision
	defer chat_list_revision = revision
	defer profile_session_clear()
	ui := Ui_State {
		selected = -1,
	}
	folder_state_fixture(&ui, .Unread_Mention)
	defer {
		chats_collect()
		for chat in ui.chats {chat_free(chat)}
		delete(ui.chats)
		delete(ui.filter_hits)
	}
	last := marmot.Chat_List_Message_Preview {
		message_id_hex = "newest",
	}
	rows := [?]marmot.Presented_Chat_Row {
		{
			row = {
				group_id_hex = "chat",
				last_message = &last,
				last_read_message_id_hex = "before",
				first_unread_message_id_hex = "typed",
				unread_count = 2,
				unread_mention_count = 2,
			},
		},
	}
	list := marmot.Presented_Chat_List {
		rows     = raw_data(rows[:]),
		rows_len = len(rows),
	}
	job := Chat_List_Work {
		account      = "receiver",
		rows         = &list,
		revision     = revision,
		read_facts   = {.Mention},
		folder_facts = make(map[string]Folder_Async_Facts, context.temp_allocator),
	}
	job.folder_facts["chat"] = {.Mention}
	live: Live
	live_apply(&live, &ui, nil, &job)
	if !testing.expect_value(t, len(ui.chats), 1) {return}
	adopted_revision := chat_list_revision
	job.revision = adopted_revision
	lookup := folder_lookup(&ui)
	testing.expect_value(t, chat_folder_slot(&ui, &ui.chats[0], lookup), 0)
	chat_read_apply(&ui, &rows[0].row, &ui.chats[0])
	testing.expect_value(t, chat_list_revision, adopted_revision)
	testing.expect(t, !ui.chat_read_dirty)
	testing.expect_value(t, chat_folder_slot(&ui, &ui.chats[0], lookup), 0)

	read := rows[0].row
	read.last_read_message_id_hex = "typed"
	read.first_unread_message_id_hex = "newest"
	read.unread_count, read.unread_mention_count = 1, 1
	chat_read_apply(&ui, &read, &ui.chats[0])
	testing.expect_value(t, chat_list_revision, adopted_revision + 1)
	testing.expect_value(t, chat_folder_slot(&ui, &ui.chats[0], lookup), 1)
	testing.expect_value(t, ui.chats[0].first_unread, "newest")
	drain_live(&live, &ui, nil)
	testing.expect(t, live.refresh_dirty)
	live_apply(&live, &ui, nil, &job)
	testing.expect_value(t, chat_folder_slot(&ui, &ui.chats[0], lookup), 1)
	testing.expect_value(t, ui.chats[0].unread, 1)

	// A fresh lookup may find a new typed mention beyond the read cursor.
	rows[0].row = read
	rows[0].row.unread_count = 2
	job.revision = chat_list_revision
	live_apply(&live, &ui, nil, &job)
	testing.expect_value(t, chat_folder_slot(&ui, &ui.chats[0], lookup), 0)
	testing.expect_value(t, ui.chats[0].unread, 2)

	last.message_id_hex = "older-preview"
	read.last_read_message_id_hex = "another-read"
	chat_read_apply(&ui, &read, &ui.chats[0])
	testing.expect_value(t, chat_folder_slot(&ui, &ui.chats[0], lookup), 1)
	testing.expect_value(t, ui.chats[0].unread, 2)
}

@(test)
folder_state_read_results_cannot_rewind_cursor :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	revision := chat_list_revision
	defer chat_list_revision = revision
	ui: Ui_State
	append(
		&ui.chats,
		chat_clone(
			{
				group_id = "chat",
				last_id = "newest",
				last_read = "before",
				first_unread = "older",
				unread = 2,
				unread_mention = true,
			},
		),
	)
	chat := &ui.chats[0]
	defer {chat_free(chat^); delete(ui.chats)}
	last := marmot.Chat_List_Message_Preview {
		message_id_hex = "newest",
	}
	older := marmot.Chat_List_Row {
		group_id_hex                = "chat",
		last_message                = &last,
		last_read_message_id_hex    = "older",
		first_unread_message_id_hex = "newest",
		unread_count                = 1,
		unread_mention_count        = 1,
	}
	newer := marmot.Chat_List_Row {
		group_id_hex             = "chat",
		last_message             = &last,
		last_read_message_id_hex = "newest",
	}
	for read_chat in ([]^Chat_Row_Ui{nil, chat}) {
		request_revision := chat_list_revision
		chat_read_apply(&ui, &newer, chat, explicit = true)
		committed_revision := chat_list_revision
		testing.expect(t, committed_revision != request_revision)
		ui.chat_read_dirty = false
		timeline_read_apply(&ui, &older, read_chat, request_revision)
		testing.expect_value(t, chat.last_read, "newest")
		testing.expect_value(t, chat.first_unread, "")
		testing.expect_value(t, chat.unread, 0)
		testing.expect(t, !chat.unread_mention)
		testing.expect(t, ui.chat_read_dirty && chat_list_revision != committed_revision)
	}
}

@(test)
folder_state_snapshot_cursors_fence_pending_reads :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	context.allocator = runtime.default_context().allocator
	revision := chat_list_revision
	defer chat_list_revision = revision
	defer profile_session_clear()
	last := marmot.Chat_List_Message_Preview {
		message_id_hex = "newest",
	}
	older := marmot.Chat_List_Row {
		group_id_hex                = "snapshot-chat",
		last_message                = &last,
		last_read_message_id_hex    = "older",
		first_unread_message_id_hex = "newest",
		unread_count                = 1,
		unread_mention_count        = 1,
	}
	for archived in ([]bool{false, true}) {
		ui := Ui_State {
			account_ref = "receiver",
			selected    = -1,
		}
		cache := archived ? &ui.archived : &ui.chats
		defer {
			chats_collect()
			for chat in cache^ {chat_free(chat)}
			delete(cache^)
			delete(ui.filter_hits)
		}
		older.archived = archived
		rows := [?]marmot.Presented_Chat_Row{{row = older}}
		list := marmot.Presented_Chat_List {
			rows     = raw_data(rows[:]),
			rows_len = len(rows),
		}
		job := Chat_List_Work {
			account          = "receiver",
			rows             = &list,
			include_archived = archived,
		}
		append(cache, chat_work_row_to_ui(&job, &rows[0]))
		request_revision := chat_list_revision
		job.revision = request_revision
		rows[0].row.last_read_message_id_hex = "newest"
		rows[0].row.first_unread_message_id_hex = nil
		rows[0].row.unread_count, rows[0].row.unread_mention_count = 0, 0
		if archived {
			archived_apply(&ui, &job)
		} else {
			live: Live
			live_apply(&live, &ui, nil, &job)
		}
		if !testing.expect_value(t, len(cache^), 1) {return}
		adopted_revision := chat_list_revision
		testing.expect(t, adopted_revision != request_revision)
		timeline_read_apply(&ui, &older, nil, request_revision)
		testing.expect_value(t, cache^[0].last_read, "newest")
		testing.expect_value(t, cache^[0].first_unread, "")
		testing.expect_value(t, cache^[0].unread, 0)
		testing.expect(t, ui.chat_read_dirty && chat_list_revision != adopted_revision)
	}
}

@(test)
folder_state_pending_only_for_outstanding_sends :: proc(t: ^testing.T) {
	ui: Ui_State
	folder_state_fixture(&ui, .Pending_Send)
	ui.drafts = make(map[string]string, context.temp_allocator)
	ui.drafts[draft_key(ui.account_ref, "chat")] = "saved draft"
	ui.pending = make([dynamic]Pending_Send, context.temp_allocator)
	chat := Chat_Row_Ui {
		group_id = "chat",
	}
	testing.expect_value(t, chat_folder_slot(&ui, &chat, folder_lookup(&ui)), 1)
	append(&ui.pending, Pending_Send{group_id = "chat", account_ref = "other account"})
	testing.expect_value(t, chat_folder_slot(&ui, &chat, folder_lookup(&ui)), 1)
	for tc in ([]struct {
			queued, failed, dismissed, acknowledged, thread_unavailable, purged: bool,
			attempts, slot:                                                      int,
		}{{slot = 0}, {queued = true, attempts = 1, slot = 0}, {attempts = 1, slot = 0}, {failed = true, slot = 1}, {acknowledged = true, slot = 1}, {dismissed = true, slot = 1}, {thread_unavailable = true, slot = 1}, {purged = true, slot = 1}}) {
		ui.pending[0] = {
			group_id           = "chat",
			account_ref        = ui.account_ref,
			queued             = tc.queued,
			failed             = tc.failed,
			dismissed          = tc.dismissed,
			acknowledged       = tc.acknowledged,
			thread_unavailable = tc.thread_unavailable,
			purged             = tc.purged,
			attempts           = tc.attempts,
		}
		testing.expect_value(t, chat_folder_slot(&ui, &chat, folder_lookup(&ui)), tc.slot)
	}
	chat.pending_send = true
	testing.expect_value(t, chat_folder_slot(&ui, &chat, folder_lookup(&ui)), 0)
	chat.pending_send = false
	testing.expect_value(t, chat_folder_slot(&ui, &chat, folder_lookup(&ui)), 1)
}

@(test)
folder_state_resolved_kind_invite_mute_and_pin :: proc(t: ^testing.T) {
	ui: Ui_State
	folder_state_fixture(&ui, .Direct)
	ui.prefs.muted_ids = make(map[string]bool, context.temp_allocator)
	ui.prefs.pinned = make(map[string]bool, context.temp_allocator)
	members := make(map[string][]string, context.temp_allocator)
	members["chat"] = {"receiver", "sender"}
	row := marmot.Presented_Chat_Row {
		row = {group_id_hex = "chat", pending_confirmation = true, self_membership = .MEMBER},
	}
	chat := row_to_ui(nil, &row, ui.account_ref, members = members)
	defer chat_free(chat)
	lookup := folder_lookup(&ui)
	rules := ui.prefs.folder_rules["State"].rules
	testing.expect_value(t, chat_folder_slot(&ui, &chat, lookup), 0)
	rules[0].kind = .Accepted
	testing.expect_value(t, chat_folder_slot(&ui, &chat, lookup), 1)
	row.row.pending_confirmation = false
	row.row.group_name = "Named pair"
	accepted := row_to_ui(nil, &row, ui.account_ref, members = members)
	defer chat_free(accepted)
	testing.expect_value(t, chat_folder_slot(&ui, &accepted, lookup), 0)
	rules[0].kind = .Group
	testing.expect_value(t, chat_folder_slot(&ui, &accepted, lookup), 0)
	testing.expect_value(t, chat_folder_slot(&ui, &chat, lookup), 1)
	rules[0].kind = .Accepted
	row.row.leave_request_pending = true
	declined := row_to_ui(nil, &row, ui.account_ref, members = members)
	defer chat_free(declined)
	testing.expect_value(t, chat_folder_slot(&ui, &declined, lookup), 1)

	rules[0].kind = .Muted
	lookup.now_ms = 100
	chat.native_muted, chat.has_muted_until, chat.muted_until = true, true, 101
	testing.expect_value(t, chat_folder_slot(&ui, &chat, lookup), 0)
	lookup.now_ms = 101
	testing.expect_value(t, chat_folder_slot(&ui, &chat, lookup), 1)
	chat.has_muted_until = false
	testing.expect_value(t, chat_folder_slot(&ui, &chat, lookup), 0)
	chat.native_muted = false
	ui.prefs.muted_ids["chat"] = true
	testing.expect_value(t, chat_folder_slot(&ui, &chat, lookup), 0)
	ui.prefs.muted_ids["chat"] = false
	testing.expect_value(t, chat_folder_slot(&ui, &chat, lookup), 1)

	rules[0].kind = .Pinned
	testing.expect_value(t, chat_folder_slot(&ui, &chat, lookup), 1)
	ui.prefs.pinned["chat"] = true
	testing.expect_value(t, chat_folder_slot(&ui, &chat, lookup), 0)
	ui.prefs.pinned["chat"] = false
	testing.expect_value(t, chat_folder_slot(&ui, &chat, lookup), 1)
}

@(test)
folder_state_archive_scope_placement_and_order :: proc(t: ^testing.T) {
	ui: Ui_State
	folder_state_fixture(&ui, .Archived)
	append(&ui.prefs.folders, "Manual", "Also archived")
	ui.prefs.folder_rules["Also archived"] = ui.prefs.folder_rules["State"]
	ui.prefs.folder_of = make(map[string]string, context.temp_allocator)
	ui.prefs.folder_of["manual"] = "Manual"
	ui.prefs.folder_of["unfiled"] = ""
	ui.prefs.folder_sorts = make(map[string]Folder_Sort, context.temp_allocator)
	ui.prefs.folder_sorts["State"] = .Name
	ui.chats = make([dynamic]Chat_Row_Ui, context.temp_allocator)
	ui.archived = make([dynamic]Chat_Row_Ui, context.temp_allocator)
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "active"},
		Chat_Row_Ui{group_id = "from-search", archived = true, search_only = true},
	)
	append(
		&ui.archived,
		Chat_Row_Ui{group_id = "manual", archived = true},
		Chat_Row_Ui{group_id = "first", title = "Zebra", activity_at = 30, archived = true},
		Chat_Row_Ui{group_id = "second", title = "Apple", activity_at = 20, archived = true},
		Chat_Row_Ui{group_id = "unfiled", archived = true},
	)
	sections, active := inbox_sections(&ui, inbox_all(&ui))
	testing.expect_value(t, sections[0].count, 0)
	testing.expect_value(t, len(active), 1)
	testing.expect_value(t, active[0].key, "active")

	rows := inbox_rows(&ui, []int{0, 1, 2, 3}, ui.archived[:])
	archive_sections, archived := inbox_sections(&ui, rows, source = ui.archived[:])
	testing.expect_value(t, archive_sections[0].count, 2)
	testing.expect_value(t, archive_sections[1].count, 1)
	testing.expect_value(t, archive_sections[2].count, 0)
	testing.expect_value(t, archive_sections[3].count, 1)
	for key, i in ([]string{"second", "first", "manual", "unfiled"}) {
		testing.expect_value(t, archived[i].key, key)
	}

	// Restoring an automatic chat removes it from the Archive rule. The
	// other archived chats and the saved manual placements stay put.
	ui.archived[1].archived = false
	append(&ui.chats, ui.archived[1])
	sections, active = inbox_sections(&ui, inbox_all(&ui))
	testing.expect_value(t, sections[0].count, 0)
	testing.expect_value(t, sections[3].count, 2)
	testing.expect_value(t, ui.prefs.folder_of["manual"], "Manual")
}
