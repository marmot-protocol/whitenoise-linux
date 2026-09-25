package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
live_refresh_does_not_wait :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	gate: sync.Sema
	job := new(Chat_List_Work)
	job.account = strings.clone_to_cstring("old-account")
	job.err = strings.clone("obsolete failure")
	job.worker = thread.create(proc(t: ^thread.Thread) {
		sync.sema_wait_with_timeout((^sync.Sema)(t.data), time.Second)
	})
	job.worker.data = &gate
	thread.start(job.worker)
	live := Live {
		refresh = job,
	}
	ui := Ui_State {
		account_ref = "new-account",
		selected    = -1,
	}
	started := time.tick_now()
	for _ in 0 ..< 1000 {
		live.dirty = true
		drain_live(&live, &ui, nil)
	}
	fmt.printf(
		"live refresh: 1000 UI polls with blocked reader = %.3f ms\n",
		time.duration_milliseconds(time.tick_since(started)),
	)
	testing.expect(
		t,
		!thread.is_done(job.worker),
		"UI polls must not join a pending database reader",
	)
	testing.expect(
		t,
		live.refresh == job && live.refresh_dirty,
		"events must coalesce behind one reader",
	)
	sync.sema_post(&gate)
	thread.join(job.worker)
	drain_live(&live, &ui, nil)
	testing.expect(t, live.refresh == nil)
	testing.expect_value(t, ui.client_status, "")
	// A synchronous user action also supersedes an earlier read of this account.
	job = new(Chat_List_Work)
	job.account = strings.clone_to_cstring(ui.account_ref)
	job.revision = chat_list_revision + 1
	job.err = strings.clone("obsolete snapshot")
	job.worker = thread.create(proc(_: ^thread.Thread) {})
	thread.start(job.worker)
	thread.join(job.worker)
	live.refresh = job
	drain_live(&live, &ui, nil)
	testing.expect(t, live.refresh == nil)
	testing.expect_value(t, ui.client_status, "")
}

@(test)
mentions_background_handoff :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	account := "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
	npub := hex_npub(account)
	defer delete(npub)
	body := strings.clone_to_cstring(fmt.tprintf("hello @%s", npub))
	defer delete(body)
	records := [?]marmot.Timeline_Message_Record {
		{message_id_hex = "match", plaintext = body, sender = "you", kind = 9, timeline_at = 100},
		{message_id_hex = "hidden", plaintext = body, kind = 9},
		{message_id_hex = "deleted", plaintext = body, kind = 9, deleted = true},
		{message_id_hex = "own", plaintext = body, kind = 9, direction = "sent"},
		{message_id_hex = "edit", plaintext = body, kind = 1009},
	}
	page := marmot.Timeline_Page {
		messages     = raw_data(records[:]),
		messages_len = len(records),
	}
	job := new(Search_Job)
	job.kind, job.account = .Mentions, strings.clone(account)
	append(&job.groups, strings.clone("group"))
	job.hidden[strings.clone("hidden")] = true
	job.cache[strings.clone("group")] = {
		page = &page,
	}
	worker := thread.Thread {
		data = job,
	}
	search_worker(&worker)
	testing.expect_value(t, len(job.hits), 1)
	ui := Ui_State {
		account_ref = account,
		selected    = -1,
	}
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "other"},
		Chat_Row_Ui{group_id = "group", title = "Renamed"},
	)
	defer {mi_clear(&ui); delete(ui.mi_hits); delete(ui.chats)}
	testing.expect(t, search_current(job, &ui), "mentions do not depend on an open search modal")
	ui.account_ref = "other-account"
	testing.expect(t, !search_current(job, &ui))
	ui.account_ref = account
	entry := job.cache["group"]
	entry.page = nil // fixture page is stack-owned
	job.cache["group"] = entry
	job.ready = true
	search_active[.Mentions] = job
	search_drain(&ui, nil)
	testing.expect(
		t,
		search_active[.Mentions] == nil,
		"completed mention scans must release their pages",
	)
	testing.expect_value(t, len(ui.mi_hits), 1)
	testing.expect_value(t, ui.mi_hits[0].group, "group")
	testing.expect_value(t, ui.mi_hits[0].title, "Renamed")
	testing.expect(t, ui.mi_hits[0].unread)
}

@(test)
incoming_preserves_scroll :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	context.allocator = runtime.default_context().allocator
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	clay.BeginLayout()
	if clay.UI(clay.ID("Timeline"))(
	{layout = {sizing = {clay.SizingFixed(800), clay.SizingFixed(600)}}, clip = {vertical = true}},
	) {
		if clay.UI(clay.ID("Tall"))({layout = {sizing = {height = clay.SizingFixed(3000)}}}) {}
	}
	clay.EndLayout(0)
	data := clay.GetScrollContainerData(clay.ID("Timeline"))
	testing.expect(t, data.found)
	ui := Ui_State {
		account_ref = "account",
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "group"})
	defer {
		for msg in ui.messages {message_free(msg)}
		delete(ui.messages); delete(ui.chats)
		delete(ui.messages_account); delete(ui.messages_group)
		messages_collect()
	}
	event := marmot.Group_System_Event {
		text = "A member joined",
	}
	record := marmot.Timeline_Message_Record {
		kind           = 1210,
		message_id_hex = "first",
		group_system   = &event,
	}
	page := marmot.Timeline_Page {
		messages     = &record,
		messages_len = 1,
	}
	for offset, i in ([]f32{-800, -2400, -800}) {
		data.scrollPosition.y = offset
		ui.scroll_pending = false
		ui.timeline_loading = i == 2
		record.message_id_hex = strings.clone_to_cstring(
			fmt.tprintf("message-%d", i),
			context.temp_allocator,
		)
		timeline_apply(nil, &ui, &page)
		testing.expect_value(t, ui.scroll_pending, i != 0)
		testing.expect_value(t, data.scrollPosition.y, offset)
	}
}

// A commit row stamped when this device processed it arrives ahead of
// its epoch's older messages; rows render by wall clock, the read
// cursor keeps the page's MLS position.
@(test)
timeline_renders_by_wall_clock :: proc(t: ^testing.T) {
	// retired_messages and the agent scope are package-global caches.
	context.allocator = runtime.default_context().allocator
	ui := Ui_State {
		account_ref = "account",
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "group"})
	defer {
		for msg in ui.messages {message_free(msg)}
		delete(ui.messages); delete(ui.chats)
		delete(ui.messages_account); delete(ui.messages_group)
		messages_collect()
	}
	event := marmot.Group_System_Event {
		text = "A member joined",
	}
	records := [?]marmot.Timeline_Message_Record {
		{kind = 1210, group_system = &event, message_id_hex = "commit", timeline_at = 3_000},
		{kind = 1210, group_system = &event, message_id_hex = "sep-24", timeline_at = 1_000},
		{kind = 1210, group_system = &event, message_id_hex = "tie-a", timeline_at = 2_000},
		{kind = 1210, group_system = &event, message_id_hex = "tie-b", timeline_at = 2_000},
	}
	page := marmot.Timeline_Page {
		messages     = raw_data(records[:]),
		messages_len = len(records),
	}
	// Twice: the second pass re-sorts a snapshot that is already sorted.
	for _ in 0 ..< 2 {
		timeline_apply(nil, &ui, &page)
		testing.expect_value(t, len(ui.messages), 4)
		for id, i in ([]string{"sep-24", "tie-a", "tie-b", "commit"}) {
			testing.expect_value(t, ui.messages[i].id, id)
		}
		for order, i in ([]int{1, 2, 3, 0}) {
			testing.expect_value(t, ui.messages[i].mls_order, order)
		}
	}
}

@(test)
chat_preview_uses_snapshot :: proc(t: ^testing.T) {
	event := marmot.Group_System_Event {
		system_type          = "member_added",
		subject_display_name = "Alice",
	}
	last := marmot.Chat_List_Message_Preview {
		kind         = 1210,
		group_system = &event,
	}
	row := marmot.Presented_Chat_Row {
		row = {group_id_hex = "group", last_message = &last},
	}
	chat := row_to_ui(nil, &row, "account")
	defer chat_free(chat)
	testing.expect_value(t, chat.preview, "Alice was added to the group")
}

// tests/odin.sh app -define:ODIN_TEST_NAMES=thread_reply_previews
@(test)
thread_reply_previews :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "thread_reply_previews" {return}
	context.allocator = runtime.default_context().allocator
	ui := Ui_State {
		account_ref      = "account",
		timeline_loading = true,
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "group"})
	defer {
		for msg in ui.messages {message_free(msg)}
		delete(ui.messages); delete(ui.chats)
		delete(ui.messages_account); delete(ui.messages_group)
		messages_collect()
	}
	root_tag := [2]cstring{"e", "root"}
	quote_tag := [2]cstring{"q", "root"}
	tags := [2]marmot.Message_Tag{{raw_data(root_tag[:]), 2}, {raw_data(quote_tag[:]), 2}}
	preview := marmot.Timeline_Reply_Preview {
		message_id_hex = "root",
		sender         = "alice",
		plaintext      = "Original",
	}
	record := marmot.Timeline_Message_Record {
		message_id_hex          = "message",
		sender                  = "alice",
		plaintext               = "Reply",
		tags                    = raw_data(tags[:]),
		reply_to_message_id_hex = "root",
	}
	page := marmot.Timeline_Page {
		messages     = &record,
		messages_len = 1,
	}
	for kind in ([]u64{9, KIND_THREAD, KIND_POLL}) {
		for quoted in ([]bool{false, true}) {
			for available in ([]bool{false, true}) {
				record.kind = kind
				record.tags_len = quoted ? 2 : 1
				record.reply_preview = available ? &preview : nil
				timeline_apply(nil, &ui, &page)
				testing.expect_value(t, len(ui.messages), 1)
				msg := ui.messages[0]
				show := kind == 9 || quoted
				testing.expect_value(t, msg.thread_of, kind == 9 ? "" : "root")
				testing.expect_value(t, msg.reply_id, show ? "root" : "")
				testing.expect_value(
					t,
					msg.reply_text,
					show ? (available ? "Original" : "Original message unavailable") : "",
				)
				testing.expect_value(t, len(msg.reply_from) > 0, show && available)
				testing.expect_value(t, msg.reply_image, "")
			}
		}
	}
	// Issue comments already distinguish their root (E) from their reply target (e).
	append(&ui.issues, Issue_Row{})
	append(&ui.issues[0].comments, Issue_Comment{id = "message"})
	defer {delete(ui.issues[0].comments); delete(ui.issues)}
	record.kind = KIND_THREAD
	record.tags_len = 2
	quote_tag[0] = "E"
	for root in ([]cstring{"issue", "root"}) {
		quote_tag[1] = root
		timeline_apply(nil, &ui, &page)
		testing.expect_value(t, ui.messages[0].reply_id, root == "issue" ? "root" : "")
	}
}
