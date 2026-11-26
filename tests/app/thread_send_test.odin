package main

import marmot "../marmot"
import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

@(test)
thread_send_uses_native_placement :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	previous_ticket := send_ticket
	defer send_ticket = previous_ticket
	job := Timeline_Work {
		account = "me",
		group   = "chat",
	}
	previous_job, previous_prefs := timeline_job, g_prefs
	timeline_job = &job
	defer {timeline_job = previous_job; g_prefs = previous_prefs
		delete(job.thread_request.parent)}
	ui := Ui_State {
		account_ref = "me",
		messages_account = "me",
		messages_group = "chat",
		prefs = {reduce_motion = true},
	}
	g_prefs = &ui.prefs
	append(&ui.chats, Chat_Row_Ui{group_id = "chat"})
	append(&ui.messages, Msg_Ui{id = "reply", thread_of = "parent", sender_id = "author"})
	append(&ui.compose, "keep this :D")
	append(&ui.staged, Staged_File{name = strings.clone("file.txt")})
	defer {
		thread_clear(&ui)
		for &pending in ui.pending {free_pending(&pending)}
		delete(ui.pending)
		delete(ui.chats); delete(ui.thread_stack); delete(ui.messages); delete(ui.compose)
		staged_files_free(ui.staged); delete(ui.toast)
	}
	thread_push(&ui, "parent")
	testing.expect_value(t, thread_placement_state(&ui), Thread_Placement.Checking)
	testing.expect_value(t, string(job.thread_request.parent), "parent")

	job.thread_result = {job.thread_request.revision, .Ready}
	timeline_drain(&ui, nil)
	testing.expect(t, thread_can_send(&ui), "native placement can use a parent outside the window")
	queue_send(&ui, nil, "reply to an older message")
	if !testing.expect_value(t, len(ui.pending), 1) {return}
	testing.expect_value(t, ui.pending[0].thread, "parent")
	free_pending(&ui.pending[0])
	clear(&ui.pending)

	// Loading the parent into the window cannot authorize a reply if the
	// native root or parent evidence is missing.
	append(&ui.messages, Msg_Ui{id = "parent", sender_id = "author"})
	for state in ([]Thread_Placement{.Checking, .Unavailable, .Error}) {
		job.thread_result = {job.thread_request.revision, state}
		timeline_drain(&ui, nil)
		testing.expect_value(t, thread_placement_state(&ui), state)
		testing.expect(t, !thread_can_send(&ui))
		send_composer(&ui, nil, false)
		queue_send(&ui, nil, "shortcut send")
		queue_staged(&ui, nil)
		perform_composer_action(&ui, .Poll)
		testing.expect_value(t, string(ui.compose[:]), "keep this :D")
		testing.expect_value(t, len(ui.staged), 1)
		testing.expect_value(t, len(ui.pending), 0)
		testing.expect(t, !ui.poll_open)
		testing.expect_value(t, ui.messages[0].thread_of, thread_cur(&ui))
	}
}

@(test)
thread_placement_ignores_stale_routes :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	job := Timeline_Work {
		account = "me",
		group   = "chat",
	}
	previous_job, previous_retired, previous_page := timeline_job, timeline_retired, timeline_page
	previous_prefs := g_prefs
	timeline_job, timeline_retired, timeline_page = &job, {}, nil
	defer {
		delete(timeline_retired)
		timeline_job, timeline_retired, timeline_page =
			previous_job, previous_retired, previous_page
		g_prefs = previous_prefs
		delete(job.thread_request.parent)
	}
	ui := Ui_State {
		account_ref = "me",
		prefs = {reduce_motion = true},
	}
	g_prefs = &ui.prefs
	append(&ui.chats, Chat_Row_Ui{group_id = "chat"})
	defer {
		thread_clear(&ui)
		delete(ui.thread_stack); delete(ui.chats); delete(ui.jump_id); delete(ui.gs_flash_id)
	}
	thread_push(&ui, "parent")
	parent_revision := job.thread_request.revision
	thread_push(&ui, "nested")
	job.thread_result = {parent_revision, .Ready}
	timeline_drain(&ui, nil)
	testing.expect_value(t, thread_placement_state(&ui), Thread_Placement.Checking)

	nested_revision := job.thread_request.revision
	ui.replying = "nested reply"
	thread_back(&ui)
	testing.expect_value(t, ui.replying, "")
	job.thread_result = {nested_revision, .Ready}
	timeline_drain(&ui, nil)
	testing.expect_value(t, thread_cur(&ui), "parent")
	testing.expect_value(t, thread_placement_state(&ui), Thread_Placement.Checking)
	job.thread_result = {parent_revision, .Ready}
	timeline_drain(&ui, nil)
	testing.expect(t, !thread_can_send(&ui), "an earlier check for the same parent is stale")

	job.thread_result = {job.thread_request.revision, .Ready}
	timeline_drain(&ui, nil)
	ui.chats[0].group_id = "other chat"
	testing.expect(t, !thread_can_send(&ui), "a matching parent and account cannot cross chats")
	ui.chats[0].group_id = "chat"
	thread_check_placement(&ui)
	job.thread_result = {job.thread_request.revision, .Ready}
	ui.account_ref = "other account"
	timeline_drain(&ui, nil)
	testing.expect(t, !thread_can_send(&ui), "a matching parent and group cannot cross accounts")
	testing.expect(t, timeline_job == nil)
}

@(test)
thread_poll_canonical_tags :: proc(t: ^testing.T) {
	values: [6][4]cstring
	storage: [6]marmot.Message_Tag
	quote: cstring = "quoted-id"
	plain := poll_message_tags(nil, nil, nil, &values, &storage)
	testing.expect_value(t, len(plain), 0)
	quoted := poll_message_tags(nil, quote, nil, &values, &storage)
	if !testing.expect_value(t, len(quoted), 1) {return}
	testing.expect_value(t, quoted[0].values_len, uint(2))
	testing.expect_value(t, string(quoted[0].values[0]), "q")
	testing.expect_value(t, string(quoted[0].values[1]), string(quote))

	placement := marmot.Thread_Reply_Context {
		root_message_id_hex = "root-id",
		root_author         = "alice",
		root_kind           = 9,
	}
	for parent, i in ([]cstring{"root-id", "parent-id"}) {
		placement.parent_author = i == 0 ? placement.root_author : "bob"
		placement.parent_kind = i == 0 ? placement.root_kind : KIND_THREAD
		tags := poll_message_tags(parent, i == 0 ? nil : quote, &placement, &values, &storage)
		root := []cstring{"E", "root-id", "", "alice"}
		child := []cstring{"e", parent, "", placement.parent_author}
		expected := [6][]cstring {
			root,
			{"K", "9"},
			{"P", "alice"},
			child,
			{"k", i == 0 ? "9" : "1111"},
			{"q", "quoted-id"},
		}
		if !testing.expect_value(t, len(tags), 5 + i) {continue}
		for tag, j in tags {
			if !testing.expect_value(t, tag.values_len, uint(len(expected[j]))) {continue}
			for value, k in expected[j] {
				testing.expect_value(t, string(tag.values[k]), string(value))
			}
		}
	}
}

@(test)
poll_keeps_reselected_reply :: proc(t: ^testing.T) {
	if !test_isolated("poll_keeps_reselected_reply") {return}
	for selection in ([]u64{1, 3}) {
		ui := Ui_State {
			poll_open      = true,
			poll_ticket    = 1,
			replying       = "original message",
			reply_revision = selection,
		}
		// The same message is still selected, either from before the send
		// or after changing to a different reply and back.
		append(&ops_done, Op_Done{ticket = 1, op = .Poll_Create, reply_revision = 1})
		drain_ops(&ui, nil)
		testing.expect(t, !ui.poll_open, "a successful send closes the poll")
		testing.expect_value(t, ui.replying, selection == 1 ? "" : "original message")
	}
}

@(test)
thread_offline_retry_preflights_destination :: proc(t: ^testing.T) {
	if !test_isolated("thread_offline_retry_preflights_destination") {return}
	context.allocator = runtime.default_context().allocator
	home, err := os.make_directory_temp("", "wn-thread-retry-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(home)
	previous_home := data_home
	data_home = home
	defer {vault_lock(); data_home = previous_home}
	if !testing.expect_value(t, vault_create("disposable-test-password"), Vault_Err.None) {return}
	deployment: ^marmot.Deployment
	if !testing.expect_value(t, restore_test_deployment(&deployment), marmot.Status.OK) {return}
	defer marmot.deployment_free(deployment)
	client: ^marmot.Client
	store := vault_secret_store()
	options := marmot.Client_Options {
		store        = &store,
		relay_policy = 1,
	}
	relays := []cstring{"wss://127.0.0.1:9"}
	if !testing.expect_value(
		t,
		marmot.client_new_with_configuration(
			strings.clone_to_cstring(home, context.temp_allocator),
			raw_data(relays),
			uint(len(relays)),
			&options,
			deployment,
			&client,
		),
		marmot.Status.OK,
	) {return}
	defer marmot.client_free(client)
	identity: rawptr
	if !testing.expect_value(
		t,
		restore_test_identity(client, raw_data(relays), 1, nil, 0, nil, 0, &identity),
		marmot.Status.OK,
	) {return}
	defer restore_test_identity_free(identity)
	account := string((^marmot.Account_Summary)(identity).label)
	group :: "0203"
	parent :: "0000000000000000000000000000000000000000000000000000000000000001"
	available: u8 = 1
	placement: ^marmot.Thread_Reply_Context
	account_c := strings.clone_to_cstring(account, context.temp_allocator)
	testing.expect_value(
		t,
		marmot.thread_reply_context(client, account_c, group, parent, &available, &placement),
		marmot.Status.OK,
	)
	testing.expect_value(t, available, u8(0))
	testing.expect(t, placement == nil)
	marmot.thread_reply_context_free(placement)
	testing.expect_value(
		t,
		marmot.thread_reply_context(client, account_c, "not-a-group-id", parent, &available, nil),
		marmot.Status.INVALID_HEX,
	)
	job := Timeline_Work {
		client  = client,
		account = account_c,
		group   = group,
	}
	testing.expect_value(t, timeline_check_thread(&job, parent), Thread_Placement.Unavailable)
	job.group = "not-a-group-id"
	testing.expect_value(t, timeline_check_thread(&job, parent), Thread_Placement.Error)

	ui := Ui_State {
		account_ref = account,
	}
	append(&ui.accounts, Account_Row_Ui{id_hex = account})
	append(&ui.chats, Chat_Row_Ui{group_id = "not-a-group-id"})
	previous_flush, previous_ticket := next_flush, send_ticket
	next_flush = {}
	defer {
		delete(ui.accounts); delete(ui.chats); delete(ui.client_status)
		for &pending in ui.pending {free_pending(&pending)}
		delete(ui.pending); delete(send_threads)
		send_threads = {}
		next_flush, send_ticket = previous_flush, previous_ticket
	}
	send_ticket += 1
	pending := Pending_Send {
		account_ref = strings.clone(account),
		group_id    = strings.clone(group),
		thread      = strings.clone(parent),
		body        = strings.clone("old caption"),
		ticket      = send_ticket,
		queued      = true,
		attempts    = 1,
	}
	append(
		&pending.atts,
		Pending_Att {
			name = strings.clone("file.txt"),
			media_type = "text/plain",
			data = make([]u8, 1),
		},
	)
	append(&ui.pending, pending)
	flush_queued(&ui, client)
	if !testing.expect_value(t, len(send_threads), 1) {return}
	thread.join(send_threads[0])
	thread.destroy(send_threads[0])
	clear(&send_threads)
	if testing.expect_value(t, len(sends_done), 1) {
		testing.expect_value(t, sends_done[0].status, marmot.Status.OK)
		testing.expect(t, sends_done[0].thread_unavailable)
		testing.expect_value(t, len(sends_done[0].ids), 0)
	}
	drain_sends(&ui, client)
	if !testing.expect_value(t, len(ui.pending), 1) {return}
	testing.expect(t, ui.pending[0].failed && !ui.pending[0].queued)
	testing.expect(t, !pending_send_allowed(&ui, ui.pending[0]))
	free_pending(&ui.pending[0])
	clear(&ui.pending)
	load_offline(&ui)
	if !testing.expect_value(t, len(ui.pending), 1) {return}
	testing.expect(
		t,
		ui.pending[0].failed && ui.pending[0].thread_unavailable && !ui.pending[0].queued,
	)
	next_flush = {}
	flush_queued(&ui, client)
	testing.expect_value(t, len(send_threads), 0)
}
