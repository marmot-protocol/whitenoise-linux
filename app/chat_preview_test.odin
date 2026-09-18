package main

import "core:testing"
import marmot "../marmot"

@(test)
chat_audio_preview :: proc(t: ^testing.T) {
	for tc in ([]struct { body, sender: cstring, kind: i32, has_kind, deleted: bool, want: string }{
		{"", "self", CHAT_ATTACHMENT_AUDIO, true, false, "You: Audio message"},
		{nil, "self", CHAT_ATTACHMENT_AUDIO, true, false, "You: Audio message"},
		{"  \n", "peer", CHAT_ATTACHMENT_AUDIO, true, false, "Audio message"},
		{"Listen to this", "self", CHAT_ATTACHMENT_AUDIO, true, false, "You: Listen to this"},
		{"", "self", CHAT_ATTACHMENT_AUDIO, false, false, ""},
		{"", "self", CHAT_ATTACHMENT_AUDIO, true, true, ""},
		{"", "self", 0, true, false, ""},
	}) {
		last := marmot.Chat_List_Message_Preview{plaintext = tc.body, sender = tc.sender,
			kind = 9, attachment_kind = tc.kind, has_attachment_kind = tc.has_kind, deleted = tc.deleted}
		row := marmot.Chat_List_Row{group_id_hex = "group", last_message = &last}
		ui := row_to_ui(nil, &row, "self")
		testing.expect_value(t, ui.preview, tc.want)
		chat_free(ui)
	}
}
