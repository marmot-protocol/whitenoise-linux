package main

import marmot "../marmot"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "nendo"

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
	search_mentions_page(job, "group", &page)
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
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	context.allocator = runtime.default_context().allocator
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {nendo.set_context(previous); delete(memory)}
	nendo.begin()
	if nendo.box(nendo.id("Timeline"))(
	{width = nendo.fixed(800), height = nendo.fixed(600), clip = {y = true}},
	) {
		if nendo.box(nendo.id("Tall"))({height = nendo.fixed(3000)}) {}
	}
	nendo.end(0)
	data := nendo.scroll(nendo.id("Timeline"))
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
		data.position.y = offset
		ui.scroll_pending = false
		ui.timeline_loading = i == 2
		record.message_id_hex = strings.clone_to_cstring(
			fmt.tprintf("message-%d", i),
			context.temp_allocator,
		)
		timeline_apply(nil, &ui, &page)
		testing.expect_value(t, ui.scroll_pending, i != 0)
		testing.expect_value(t, data.position.y, offset)
	}
}

// A commit row stamped when this device processed it arrives ahead of
// its epoch's older messages; rows render by wall clock, the read
// cursor keeps the page's MLS position.
@(test)
timeline_renders_by_wall_clock :: proc(t: ^testing.T) {
	// timeline_apply shares the retired message list with incoming_preserves_scroll.
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
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

// The reaction picker borrows its message's row ID. A reload while it
// is open retires that row; a pick afterwards sent freed bytes to
// marmot ("string argument was not valid UTF-8").
@(test)
reload_rebinds_picker_target :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
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
	record := marmot.Timeline_Message_Record {
		kind           = 1210,
		message_id_hex = "target",
		group_system   = &event,
	}
	page := marmot.Timeline_Page {
		messages     = &record,
		messages_len = 1,
	}
	timeline_apply(nil, &ui, &page)
	ui.picker_open, ui.picker_target = true, ui.messages[0].id

	// Same row again: the target follows it into the new storage.
	timeline_apply(nil, &ui, &page)
	messages_collect()
	testing.expect(t, raw_data(ui.picker_target) == raw_data(ui.messages[0].id))
	testing.expect(t, ui.picker_open)

	// Row gone: nothing to react to, so the picker closes.
	record.message_id_hex = "other"
	timeline_apply(nil, &ui, &page)
	testing.expect_value(t, ui.picker_target, "")
	testing.expect(t, !ui.picker_open)
}

@(test)
thread_reply_previews :: proc(t: ^testing.T) {
	if !test_isolated("thread_reply_previews") {return}
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
	parent_tag := [2]cstring{"e", "legacy-parent"}
	quote_tag := [2]cstring{"q", "parent"}
	tags := [2]marmot.Message_Tag{{raw_data(parent_tag[:]), 2}, {raw_data(quote_tag[:]), 2}}
	ref := marmot.Timeline_Thread_Ref {
		root_message_id_hex   = "root",
		parent_message_id_hex = "parent",
	}
	agent := marmot.Agent_Item {
		state = .Done,
	}
	preview := marmot.Timeline_Reply_Preview {
		sender    = "alice",
		plaintext = "Original",
		kind      = KIND_CHAT_MESSAGE,
	}
	record := marmot.Timeline_Message_Record {
		message_id_hex = "message",
		sender         = "alice",
		plaintext      = "Reply",
		tags           = raw_data(tags[:]),
	}
	page := marmot.Timeline_Page {
		messages     = &record,
		messages_len = 1,
	}
	for kind in ([]u64{KIND_CHAT_MESSAGE, KIND_THREAD, KIND_POLL, KIND_AGENT_ITEM}) {
		parent: cstring = kind == KIND_POLL ? "legacy-parent" : "parent"
		parent_tag[1] = parent
		record.kind = kind
		record.thread = kind == KIND_THREAD || kind == KIND_AGENT_ITEM ? &ref : nil
		record.agent_item = kind == KIND_AGENT_ITEM ? &agent : nil
		record.reply_to_message_id_hex = parent
		preview.message_id_hex = parent
		quote_tag[1] = parent
		thread_parent := kind == KIND_CHAT_MESSAGE ? "" : string(parent)
		for quoted in ([]bool{false, true}) {
			for available in ([]bool{false, true}) {
				record.tags_len = quoted ? 2 : 1
				record.reply_preview = available ? &preview : nil
				timeline_apply(nil, &ui, &page)
				if !testing.expect_value(t, len(ui.messages), 1) {return}
				msg := ui.messages[0]
				show := kind == KIND_CHAT_MESSAGE || quoted
				testing.expect_value(t, msg.thread_of, thread_parent)
				testing.expect_value(t, msg.reply_id, show ? string(parent) : "")
				testing.expect_value(
					t,
					msg.reply_text,
					show ? (available ? "Original" : "Original message unavailable") : "",
				)
				testing.expect_value(t, len(msg.reply_from) > 0, show && available)
				testing.expect_value(t, msg.reply_image, "")
			}
		}
		record.deleted = true
		record.agent_item = nil
		record.reply_preview = nil
		timeline_apply(nil, &ui, &page)
		if !testing.expect_value(t, len(ui.messages), 1) {return}
		testing.expect(t, ui.messages[0].deleted)
		testing.expect_value(t, ui.messages[0].thread_of, thread_parent)
		testing.expect_value(t, ui.messages[0].reply_id, "")
		record.deleted = false
	}
	// Numeric-k comments can have q or e in the old reply target field.
	record.kind = KIND_THREAD
	record.thread = &ref
	quote_tag[1] = "body-quote"
	kind_tag := [2]cstring{"k", "9"}
	comment_tags := [?]marmot.Message_Tag{tags[0], tags[1], {raw_data(kind_tag[:]), 2}}
	record.tags, record.tags_len = raw_data(comment_tags[:]), len(comment_tags)
	quote := marmot.Timeline_Reply_Preview {
		message_id_hex = "body-quote",
		sender         = "bob",
		plaintext      = "Quoted body",
		kind           = KIND_CHAT_MESSAGE,
	}
	for legacy in ([]bool{false, true}) {
		record.reply_to_message_id_hex = legacy ? "body-quote" : "parent"
		record.reply_preview = legacy ? &quote : &preview
		record.body_quote_preview = legacy ? nil : &quote
		timeline_apply(nil, &ui, &page)
		if !testing.expect_value(t, len(ui.messages), 1) {return}
		msg := ui.messages[0]
		testing.expect_value(t, msg.thread_of, "parent")
		testing.expect_value(t, msg.reply_id, "body-quote")
		testing.expect_value(t, msg.reply_text, "Quoted body")
		testing.expect(t, msg.read_markable)
	}
	for hidden_kind in ([]u64{1200, 1202, KIND_EDIT}) {
		quote.kind = hidden_kind
		quote.plaintext = "Private wire payload"
		timeline_apply(nil, &ui, &page)
		if !testing.expect_value(t, len(ui.messages), 1) {return}
		testing.expect_value(t, ui.messages[0].reply_text, "Original message unavailable")
		testing.expect_value(t, ui.messages[0].reply_from, "")
		testing.expect_value(t, ui.messages[0].reply_from_id, "")
	}
}

@(test)
agent_item_timeline_visibility :: proc(t: ^testing.T) {
	if !test_isolated("agent_item_timeline_visibility") {return}
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
	agent := marmot.Agent_Item {
		title = "Not the message body",
		state = .Running,
	}
	records := [?]marmot.Timeline_Message_Record {
		{
			kind = KIND_AGENT_ITEM,
			sender = "agent",
			message_id_hex = "item",
			plaintext = "Checking files",
			agent_item = &agent,
		},
		{kind = 1200, sender = "agent", message_id_hex = "retired", plaintext = "retired payload"},
		{kind = 1202, sender = "agent", message_id_hex = "control", plaintext = "control payload"},
		{
			kind = KIND_AGENT_ITEM,
			sender = "agent",
			message_id_hex = "unreadable",
			plaintext = "unreadable payload",
		},
	}
	page := marmot.Timeline_Page {
		messages     = raw_data(records[:]),
		messages_len = len(records),
	}
	for body in ([]cstring{"Checking files", "Finished checking files"}) {
		records[0].plaintext = body
		timeline_apply(nil, &ui, &page)
		if !testing.expect_value(t, len(ui.messages), 1) {return}
		testing.expect_value(t, ui.messages[0].id, "item")
		testing.expect_value(t, ui.messages[0].body, string(body))
		testing.expect(t, !ui.messages[0].unsupported)
		agent.state = .Done
	}
	job := new(Transcript_Job)
	ui.transcript = job
	job.page = &page
	export_page_snapshot(&ui, job)
	job.page = nil
	if testing.expect_value(t, len(job.messages), 1) {
		testing.expect_value(t, job.messages[0].body, "Finished checking files")
	}
	export_stop(&ui)

	records[0].agent_item = nil
	records[0].deleted = true
	timeline_apply(nil, &ui, &page)
	if !testing.expect_value(t, len(ui.messages), 1) {return}
	testing.expect(t, ui.messages[0].deleted)
	testing.expect_value(t, ui.messages[0].body, "")

	job = new(Transcript_Job)
	ui.transcript = job
	job.page = &page
	export_page_snapshot(&ui, job)
	job.page = nil
	defer export_stop(&ui)
	if testing.expect_value(t, len(job.messages), 1) {
		testing.expect(t, job.messages[0].deleted)
		testing.expect_value(t, job.messages[0].body, "")
		testing.expect(t, job.messages[0].record == nil)
	}
}
