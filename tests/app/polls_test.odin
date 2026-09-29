package main

import "base:runtime"
import "core:sync"
import "core:testing"

import marmot "../marmot"

// Counts and local selections cover the whole retained conversation, not just
// the visible timeline page. Raw response records must not alter MDK's result.
@(test)
poll_native_projection :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
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
	options := [?]marmot.Poll_Option_Result {
		{id = "tea", label = "Tea", votes = 5},
		{id = "coffee", label = "Coffee", votes = 3},
	}
	selection := [?]cstring{"coffee"}
	projection := marmot.Poll_Projection {
		question            = "What should we drink?",
		options             = raw_data(options[:]),
		options_len         = len(options),
		poll_type           = .Multiple_Choice,
		participants        = 7,
		local_selection     = raw_data(selection[:]),
		local_selection_len = len(selection),
		open                = true,
	}
	vote_target := [?]cstring{"e", "poll"}
	vote_response := [?]cstring{"response", "tea"}
	vote_tags := [?]marmot.Message_Tag {
		{raw_data(vote_target[:]), len(vote_target)},
		{raw_data(vote_response[:]), len(vote_response)},
	}
	records := [?]marmot.Timeline_Message_Record {
		{
			kind = KIND_POLL,
			message_id_hex = "poll",
			sender = "alice",
			plaintext = "Raw body is not the projected question",
			poll = &projection,
		},
		{
			kind = KIND_POLL_VOTE,
			message_id_hex = "vote",
			sender = "account",
			tags = raw_data(vote_tags[:]),
			tags_len = len(vote_tags),
		},
	}
	page := marmot.Timeline_Page {
		messages     = raw_data(records[:]),
		messages_len = 1,
	}
	for visible in 1 ..= len(records) {
		page.messages_len = uint(visible)
		timeline_apply(nil, &ui, &page)
		testing.expect_value(t, len(ui.messages), 1)
		msg := &ui.messages[0]
		testing.expect_value(t, msg.body, "What should we drink?")
		testing.expect_value(t, len(msg.poll_opts), 2)
		testing.expect_value(t, msg.poll_opts[0].label, "Tea")
		testing.expect_value(t, msg.poll_opts[0].count, 5)
		testing.expect_value(t, msg.poll_opts[1].count, 3)
		testing.expect_value(t, msg.poll_total, 7)
		testing.expect(t, !msg.poll_opts[0].mine && msg.poll_opts[1].mine)
		testing.expect(t, msg.poll_multi && msg.poll_open)
	}
	// The next snapshot can replace a selection and close voting. Do not keep
	// stale local state or derive openness from the client clock/deadline.
	selection[0] = "tea"
	projection.open = false
	projection.has_ends_at = true
	projection.ends_at = max(u64)
	timeline_apply(nil, &ui, &page)
	testing.expect(t, !ui.messages[0].poll_open)
	testing.expect(t, ui.messages[0].poll_opts[0].mine && !ui.messages[0].poll_opts[1].mine)

	// If MDK rejects a poll, its raw option tags must not resurrect controls.
	option_tag := [?]cstring{"option", "raw", "Untrusted option"}
	raw_tags := [?]marmot.Message_Tag{{raw_data(option_tag[:]), len(option_tag)}}
	records[0].poll = nil
	records[0].tags = raw_data(raw_tags[:])
	records[0].tags_len = len(raw_tags)
	timeline_apply(nil, &ui, &page)
	testing.expect_value(t, len(ui.messages[0].poll_opts), 0)
}

@(test)
poll_selection_replace :: proc(t: ^testing.T) {
	msg: Msg_Ui
	append(&msg.poll_opts, Poll_Opt_Ui{id = "tea", mine = true})
	append(&msg.poll_opts, Poll_Opt_Ui{id = "coffee"})
	defer delete(msg.poll_opts)
	selected := poll_selection(&msg, 1)
	testing.expect_value(t, len(selected), 1)
	testing.expect_value(t, selected[0], "coffee")

	msg.poll_multi = true
	selected = poll_selection(&msg, 1)
	testing.expect_value(t, len(selected), 2)
	testing.expect_value(t, selected[0], "tea")
	testing.expect_value(t, selected[1], "coffee")
	selected = poll_selection(&msg, 0)
	testing.expect_value(t, len(selected), 0)
}
