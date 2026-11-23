package main

import marmot "../marmot"
import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

@(test)
thread_send_preserves_unavailable_draft :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	ui := Ui_State {
		account_ref      = "me",
		messages_account = "me",
		messages_group   = "chat",
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "chat"})
	append(&ui.thread_stack, "root", "parent")
	append(&ui.messages, Msg_Ui{id = "root", sender_id = "author"})
	append(&ui.messages, Msg_Ui{id = "reply", thread_of = "parent", sender_id = "author"})
	append(&ui.compose, "keep this :D")
	append(&ui.staged, Staged_File{name = "file.txt"})
	defer {
		delete(ui.chats); delete(ui.thread_stack); delete(ui.messages); delete(ui.compose)
		delete(ui.staged); delete(ui.toast)
	}
	for parent in ([]Msg_Ui{{}, {id = "parent", sender_id = "author", deleted = true}, {id = "parent"}}) {
		resize(&ui.messages, 2)
		if parent.id != "" {append(&ui.messages, parent)}
		testing.expect(t, !thread_can_send(&ui))
		send_composer(&ui, nil, false)
		queue_send(&ui, nil, "shortcut send")
		queue_staged(&ui, nil)
		testing.expect_value(t, string(ui.compose[:]), "keep this :D")
		testing.expect_value(t, len(ui.staged), 1)
		testing.expect_value(t, len(ui.pending), 0)
		testing.expect_value(t, ui.messages[1].thread_of, thread_cur(&ui))
	}
	ui.messages[2].sender_id = "author"
	ui.messages[0].deleted = true
	testing.expect(t, thread_can_send(&ui), "only the direct parent must still be available")
	ui.messages_group = "other chat"
	testing.expect(t, !thread_can_send(&ui), "a stale timeline must not authorize a new send")
}

@(test)
thread_poll_canonical_tags :: proc(t: ^testing.T) {
	placement := marmot.Thread_Reply_Context {
		root_message_id_hex = "root-id",
		root_author         = "alice",
		root_kind           = 9,
	}
	for parent, i in ([]cstring{"root-id", "parent-id"}) {
		placement.parent_author = i == 0 ? placement.root_author : "bob"
		placement.parent_kind = i == 0 ? placement.root_kind : KIND_THREAD
		values: [5][4]cstring
		tags := poll_thread_tags(parent, &placement, &values)
		root := []cstring{"E", "root-id", "", "alice"}
		child := []cstring{"e", parent, "", placement.parent_author}
		expected := [5][]cstring {
			root,
			{"K", "9"},
			{"P", "alice"},
			child,
			{"k", i == 0 ? "9" : "1111"},
		}
		for tag, j in tags {
			if !testing.expect_value(t, tag.values_len, uint(len(expected[j]))) {continue}
			for value, k in expected[j] {
				testing.expect_value(t, string(tag.values[k]), string(value))
			}
		}
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
