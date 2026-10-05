package main

import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

import marmot "../marmot"

@(test)
transcript_owns_loaded_window :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	old_page := timeline_page
	defer {timeline_page = old_page}
	body := strings.clone("First <body> & text")
	values := []cstring{"subject", "original"}
	tags := []marmot.Message_Tag{{raw_data(values), uint(len(values))}}
	records := []marmot.Timeline_Message_Record {
		{
			message_id_hex = "first",
			plaintext = strings.clone_to_cstring("raw original"),
			tags = raw_data(tags),
			tags_len = 1,
		},
	}
	page := marmot.Timeline_Page {
		messages     = raw_data(records),
		messages_len = 1,
	}
	timeline_page = &page
	ui := Ui_State {
		account_ref = "account",
		selected    = 0,
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "group", title = "Title"})
	append(&ui.messages, Msg_Ui{id = "first", body = body, sender = "Alice", at_full = "now"})
	append(
		&ui.messages[0].attachments,
		Att_Slot{name = "missing.png"},
		Att_Slot{name = "file.pdf"},
		Att_Slot{state = .Rejected, rejection = "Invalid attachment."},
	)
	defer {delete(ui.messages[0].attachments)
		delete(ui.messages)
		delete(ui.chats)}
	export_chat(&ui, nil, .Html)
	job := ui.transcript
	defer export_stop(&ui)
	transcript_snapshot(&ui, job)
	// The timeline can be freed/replaced immediately after the snapshot.
	delete(body); delete(records[0].plaintext)
	ui.messages[0].body = "Replacement"
	records[0].plaintext = "replacement raw"
	values[1] = "replacement tag"
	job.worker = thread.create(transcript_worker)
	job.worker.data = job
	thread.start(job.worker)
	thread.join(job.worker)
	html := string(job.bytes)
	testing.expect(t, strings.contains(html, "First &lt;body&gt; &amp; text"))
	testing.expect(t, strings.contains(html, "raw original"))
	testing.expect(t, strings.contains(html, "original"))
	testing.expect(t, !strings.contains(html, "replacement"))
	testing.expect(t, strings.contains(html, "missing.png (image unavailable)"))
	testing.expect(t, strings.contains(html, "file.pdf"))
	testing.expect(t, strings.contains(html, "Invalid attachment."))
	testing.expect_value(t, sync.atomic_load(&job.completed), 1)
	// A repeated request cannot replace work or its destination.
	export_chat(&ui, nil, .Markdown)
	testing.expect(t, ui.transcript == job)
}

@(test)
transcript_discards_changed_account :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	ui := Ui_State {
		account_ref = "old",
		selected    = 0,
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "group", title = "Title"})
	defer delete(ui.chats)
	export_chat(&ui, nil, .Html)
	job := ui.transcript
	job.worker = thread.create(transcript_worker)
	job.worker.data = job
	thread.start(job.worker)
	thread.join(job.worker)
	ui.account_ref = "new"
	export_drain(&ui, nil)
	testing.expect(t, ui.transcript == nil)
}
