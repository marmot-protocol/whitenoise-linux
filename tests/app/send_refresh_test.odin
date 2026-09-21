package main

import marmot "../marmot"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import rl "sdlrl"

@(test)
send_reveals_preview :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	old_threads, old_done, old_ticket := send_threads, sends_done, send_ticket
	send_threads, sends_done = {}, {}
	ui := Ui_State {
		account_ref = "preview-test",
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "group"})
	defer {
		for worker in send_threads {thread.join(worker); thread.destroy(worker)}
		for done in sends_done {
			delete(done.err)
			for id in done.ids {delete(id)}
			delete(done.ids)
		}
		delete(send_threads); delete(sends_done)
		send_threads, sends_done, send_ticket = old_threads, old_done, old_ticket
		for &pending in ui.pending {free_pending(&pending)}
		delete(ui.pending); delete(ui.staged); delete(ui.chats)
		delete(ui.jump_id)
	}
	// No client: workers cannot publish. The preview must still become visible.
	ui.jump_id = strings.clone("older-message")
	queue_send(&ui, nil, "preview")
	testing.expect(t, ui.scroll_pending)
	testing.expect_value(t, ui.jump_id, "")
	testing.expect_value(t, len(ui.pending), 1)
	ui.scroll_pending = false
	queue_staged(&ui, nil)
	testing.expect(t, !ui.scroll_pending, "empty staging must preserve the viewport")
	ui.jump_id = strings.clone("older-message")
	append(&ui.staged, Staged_File{name = strings.clone("note.txt"), media_type = "text/plain"})
	queue_staged(&ui, nil)
	testing.expect(t, ui.scroll_pending)
	testing.expect_value(t, ui.jump_id, "")
	testing.expect_value(t, len(ui.pending), 2)
	testing.expect_value(t, len(ui.staged), 0)
	ui.scroll_pending = false
	append(
		&ui.staged,
		Staged_File {
			name = strings.clone("photo.png"),
			media_type = "image/png",
			tex = new(rl.Texture2D),
		},
	)
	queue_staged(&ui, nil)
	testing.expect(t, ui.scroll_pending, "image albums must reveal their preview too")
	testing.expect_value(t, len(ui.pending), 3)
}

@(test)
send_waits_for_timeline :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	old_job, old_page, old_retired := timeline_job, timeline_page, timeline_retired
	old_done, old_home := sends_done, data_home
	timeline_job, timeline_page, timeline_retired, sends_done = nil, nil, {}, {}
	data_home = "/tmp/wn-send-refresh-test-unused"
	defer {
		timeline_page = nil // the fixture page is stack-owned
		timeline_stop()
		timeline_job, timeline_page, timeline_retired = old_job, old_page, old_retired
		sends_done, data_home = old_done, old_home
	}
	ui := Ui_State {
		account_ref = "account",
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "group"})
	defer {delete(ui.chats); delete(ui.pending)}
	append(&ui.pending, Pending_Send{ticket = 1, group_id = strings.clone("group")})
	append(&ui.pending[0].atts, Pending_Att{name = strings.clone("photo.png")})
	done := Send_Done {
		ticket = 1,
	}
	for id in ([]string{"photo-id", "second-id"}) {
		append(&done.ids, strings.clone(id))
	}
	append(&sends_done, done)
	job := Timeline_Work {
		account = "account",
		group   = "group",
		search  = "",
	}
	timeline_job = &job
	// A stale page must retain the attachment and request a fresh subscription.
	drain_sends(&ui, nil)
	clear(&timeline_retired) // the retired fixture job is stack-owned
	testing.expect(t, job.cancel)
	testing.expect_value(t, len(ui.pending), 1)
	testing.expect_value(t, ui.pending[0].atts[0].name, "photo.png")
	testing.expect(t, sends_done[0].refresh_requested)
	thread.join(timeline_job.worker)
	records := [?]marmot.Timeline_Message_Record {
		{message_id_hex = "second-id"},
		{message_id_hex = "photo-id"},
	}
	page := marmot.Timeline_Page {
		messages     = raw_data(records[:]),
		messages_len = 1,
	}
	timeline_page = &page
	drain_sends(&ui, nil)
	testing.expect_value(t, len(ui.pending), 1)
	// All confirmed IDs replace the preview regardless of snapshot order.
	page.messages_len = len(records)
	drain_sends(&ui, nil)
	testing.expect_value(t, len(ui.pending), 0)
	testing.expect_value(t, len(sends_done), 0)
}
