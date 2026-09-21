package main

import marmot "../marmot"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

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
