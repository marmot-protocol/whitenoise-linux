package main

import marmot "../marmot"
import "core:strings"
import "core:testing"

@(test)
agent_preview_updates :: proc(t: ^testing.T) {
	// C enum plus aligned 24-byte union, including the record's padded u8.
	testing.expect_value(t, size_of(marmot.Agent_Stream_Update), 32)
	testing.expect_value(t, offset_of(marmot.Agent_Stream_Update, data), 8)
	p: Agent_Preview
	defer delete(p.text)
	progress := marmot.Agent_Stream_Update {
		tag = .PROGRESS,
	}
	progress.data.chunk.text = "Checking "
	agent_apply(&p, &progress)
	progress.data.chunk.text = "the files"
	agent_apply(&p, &progress)
	testing.expect_value(t, string(p.text[:]), "Checking the files")
	chunk := marmot.Agent_Stream_Update {
		tag = .CHUNK,
	}
	chunk.data.chunk.text = "hello"
	agent_apply(&p, &chunk)
	chunk.data.chunk.text = " world"
	agent_apply(&p, &chunk)
	testing.expect_value(t, string(p.text[:]), "hello world")
	agent_apply(&p, &progress)
	testing.expect_value(t, string(p.text[:]), "hello world")
	checkpoint := marmot.Agent_Stream_Update {
		tag = .RECORD,
	}
	checkpoint.data.record.record_type = .CHECKPOINT
	checkpoint.data.record.text = "corrected"
	agent_apply(&p, &checkpoint)
	finish := marmot.Agent_Stream_Update {
		tag = .FINISHED,
	}
	finish.data.finished.text = "old chunks"
	agent_apply(&p, &finish)
	testing.expect_value(t, string(p.text[:]), "corrected")
	agent_apply(&p, &chunk)
	testing.expect_value(t, string(p.text[:]), "corrected")
	p.final = false
	p.checkpoint = false
	agent_apply(&p, &finish)
	testing.expect_value(t, string(p.text[:]), "old chunks")
	p.final = false
	checkpoint.data.record.record_type = .ABORT
	agent_apply(&p, &checkpoint)
	testing.expect(t, p.failed)
	agent_apply(&p, &chunk)
	testing.expect_value(t, string(p.text[:]), "old chunks")
	large := strings.repeat("あ", AGENT_PREVIEW_BYTES / 3 + 1)
	defer delete(large)
	agent_set_text(&p, large)
	testing.expect(t, len(p.text) <= AGENT_PREVIEW_BYTES)
	testing.expect_value(t, len(p.text) % 3, 0)
}

@(test)
agent_final_reconciliation :: proc(t: ^testing.T) {
	ui := Ui_State {
		account_ref = "test",
		selected    = 0,
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "group"})
	defer delete(ui.chats)
	defer agent_shutdown()
	start := marmot.Timeline_Message_Record {
		kind                   = AGENT_STREAM_START,
		sender                 = "agent",
		message_id_hex         = "start",
		agent_text_stream_json = `{"stream_id_hex":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"started"}`,
	}
	final := marmot.Timeline_Message_Record {
		kind                   = 9,
		sender                 = "agent",
		message_id_hex         = "final",
		agent_text_stream_json = `{"stream_id_hex":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"finalized"}`,
	}
	start.timeline_at = 1
	plain := marmot.Timeline_Message_Record {
		kind           = 9,
		sender         = "agent",
		message_id_hex = "commentary",
		timeline_at    = 2,
	}
	live_records := [?]marmot.Timeline_Message_Record{start, plain}
	live_page := marmot.Timeline_Page {
		messages     = raw_data(live_records[:]),
		messages_len = len(live_records),
	}
	agent_collect(nil, &ui, &live_page)
	_, live_visible := agent_body(&start)
	testing.expect(t, live_visible, "A plain message must not cancel a live stream")
	records := [?]marmot.Timeline_Message_Record{start, final}
	page := marmot.Timeline_Page {
		messages     = raw_data(records[:]),
		messages_len = len(records),
	}
	agent_collect(nil, &ui, &page)
	_, visible := agent_body(&start)
	testing.expect(
		t,
		!visible,
		"Final anchor suppresses start even when it follows it in the page",
	)
	start.agent_text_stream_json = `{"stream_id_hex":"bad","status":"started"}`
	id, _ := agent_projection(&start)
	testing.expect_value(t, id, "")
	start.agent_text_stream_json = "{"
	id, _ = agent_projection(&start)
	testing.expect_value(t, id, "")
}
