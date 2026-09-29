package main

import marmot "../marmot"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import rl "sdlrl"

@(test)
forward_snapshot_survives_source_changes :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	old_page := timeline_page
	defer {timeline_page = old_page}
	ui := Ui_State {
		account_ref = "original-account",
		selected    = 0,
		fwd_msg     = "wanted",
		fwd_source  = "source",
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "source"}, Chat_Row_Ui{group_id = "other"})
	append(&ui.messages, Msg_Ui{id = "newer"}, Msg_Ui{id = "wanted"})
	defer {delete(ui.chats); delete(ui.messages)}
	testing.expect_value(t, forward_source(&ui), 1)
	locator := marmot.Media_Locator {
		strings.clone_to_cstring("url"),
		strings.clone_to_cstring("https://example.com/original"),
	}
	media := marmot.Media_Attachment_Outcome {
		tag = .ACCEPTED,
	}
	media.body.accepted.reference = {
		locators         = &locator,
		locators_len     = 1,
		file_name        = strings.clone_to_cstring("original.png"),
		source_epoch     = 7,
		plaintext_sha256 = strings.clone_to_cstring("original-sha"),
		dim              = strings.clone_to_cstring("1024x768"),
	}
	record := marmot.Timeline_Message_Record {
		message_id_hex = "wanted",
		media          = &media,
		media_len      = 1,
	}
	page := marmot.Timeline_Page {
		messages     = &record,
		messages_len = 1,
	}
	timeline_page = &page
	job := forward_snapshot(&ui, nil)
	defer forward_free(job)
	delete(locator.kind); delete(locator.value)
	delete(media.body.accepted.reference.file_name)
	delete(media.body.accepted.reference.plaintext_sha256)
	delete(media.body.accepted.reference.dim)
	timeline_page = nil
	ui.selected = 1
	ui.account_ref = "different-account"
	testing.expect_value(t, forward_source(&ui), -1)
	testing.expect_value(t, string(job.account), "original-account")
	testing.expect_value(t, string(job.source), "source")
	testing.expect_value(t, string(job.refs[0].file_name), "original.png")
	testing.expect_value(t, string(job.refs[0].locators[0].value), "https://example.com/original")
	testing.expect_value(t, string(job.refs[0].plaintext_sha256), "original-sha")
	testing.expect_value(t, string(job.refs[0].dim), "1024x768")
	testing.expect_value(t, job.refs[0].source_epoch, 7)
	testing.expect(t, !job.invalid)
}

@(test)
forward_failure_retry_and_dismissal :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	old_threads := send_threads
	send_threads = {}
	ui: Ui_State
	old_ui := g_ui
	g_ui = &ui
	defer {g_ui = old_ui}
	defer {
		for worker in send_threads {thread.join(worker); thread.destroy(worker)}
		delete(send_threads); send_threads = old_threads
		for &p in ui.pending {free_pending(&p)}
		delete(ui.pending); delete(ui.client_status)
	}
	job := new(Forward_Job)
	job^ = {
		invalid = true,
		done    = true,
	}
	append(
		&ui.pending,
		Pending_Send {
			ticket = 4,
			body = strings.clone("do not send without attachments"),
			forward = job,
		},
	)
	testing.expect(
		t,
		reload_jobs_busy(),
		"a completed preparation still needs its frame-boundary handoff",
	)
	drain_forwards(&ui, nil)
	testing.expect(t, ui.pending[0].failed)
	testing.expect_value(t, len(send_threads), 0)
	testing.expect(t, ui.pending[0].forward == job, "failure must retain the source for retry")
	ui.pending[0].failed = false
	forward_start(&ui.pending[0])
	ui.pending[0].dismissed = true
	thread.join(send_threads[0])
	thread.destroy(send_threads[0])
	clear(&send_threads)
	drain_forwards(&ui, nil)
	testing.expect(t, len(ui.pending) == 0, "late preparation must not send a dismissed forward")
}

@(test)
forward_success_preserves_destination_and_tags :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	old_threads, old_done, old_ticket := send_threads, sends_done, send_ticket
	send_threads, sends_done = {}, {}
	ui := Ui_State {
		account_ref = "changed-account",
	}
	defer {
		for worker in send_threads {thread.join(worker); thread.destroy(worker)}
		for done in sends_done {delete(done.err); for id in done.ids {delete(id)}; delete(done.ids)}
		delete(send_threads); delete(sends_done)
		send_threads, sends_done, send_ticket = old_threads, old_done, old_ticket
		for &p in ui.pending {free_pending(&p)}
		delete(ui.pending)
	}
	// Independent completed preparations model repeated clicks, not a singleton
	// result slot. The second destination may finish before the first.
	destinations := []string{"first-target", "second-target"}
	for destination in destinations {
		job := new(Forward_Job)
		job.done, job.ok = true, true
		append(
			&job.atts,
			Pending_Att {
				name = strings.clone("note.txt"),
				media_type = "text/plain",
				data = transmute([]u8)strings.clone("payload"),
			},
		)
		append(&job.images, rl.Image{})
		send_ticket += 1
		append(
			&ui.pending,
			Pending_Send {
				ticket = send_ticket,
				forward = job,
				account_ref = strings.clone("original-account"),
				group_id = strings.clone(destination),
				body = strings.clone("caption"),
				effect = 1,
				sticker = Sticker_Ref{sha = strings.clone("sticker-sha")},
			},
		)
	}
	drain_forwards(&ui, nil)
	testing.expect_value(t, len(ui.pending), 4)
	for destination in destinations {
		texts, albums := 0, 0
		for p in ui.pending {
			if p.group_id != destination {continue}
			testing.expect_value(t, p.account_ref, "original-account")
			testing.expect(t, p.forward == nil)
			if len(p.atts) > 0 {
				albums += 1
				testing.expect_value(t, string(p.atts[0].data), "payload")
				testing.expect_value(t, p.effect, 1)
				testing.expect_value(t, p.sticker.sha, "sticker-sha")
				testing.expect_value(t, p.body, "")
			} else {
				texts += 1
				testing.expect_value(t, p.body, "caption")
				testing.expect_value(t, p.effect, 0)
			}
		}
		testing.expect_value(t, texts, 1)
		testing.expect_value(t, albums, 1)
	}
}
