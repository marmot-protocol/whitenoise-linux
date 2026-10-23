package main

import marmot "../marmot"
import "core:strings"
import "core:sync"
import "core:testing"

@(test)
conversation_kind_precedence :: proc(t: ^testing.T) {
	for tc in ([]struct {
			kind:  marmot.Chat_Conversation_Kind,
			name:  string,
			count: int,
			want:  marmot.Chat_Conversation_Kind,
		}{{.DIRECT, "Named direct", 3, .DIRECT}, {.DIRECT, "", 0, .DIRECT}, {.GROUP, "", 2, .GROUP}, {.GROUP, "Named pair", 2, .GROUP}, {.UNKNOWN, "Named pair", 2, .GROUP}, {.UNKNOWN, "", 2, .DIRECT}, {.UNKNOWN, " \t\n", 2, .DIRECT}, {.UNKNOWN, "\u200b\u202e\u034f\u2060", 2, .DIRECT}, {.UNKNOWN, "\u200d", 2, .GROUP}, {.UNKNOWN, "", 3, .GROUP}, {.UNKNOWN, "", 1, .GROUP}, {.UNKNOWN, "", -1, .GROUP}}) {
		testing.expect_value(t, chat_conversation_kind(tc.kind, tc.name, tc.count), tc.want)
	}
}

@(test)
conversation_row_identity :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	context.allocator = context.temp_allocator
	row := marmot.Presented_Chat_Row {
		row = {group_id_hex = "conversation"},
	}
	row.presentation.peer_id = "old-peer"
	members: map[string][]string
	members["conversation"] = []string{"self", "current-peer"}
	chat := row_to_ui(nil, &row, "self", members = members)
	testing.expect_value(t, chat.conversation_kind, marmot.Chat_Conversation_Kind.DIRECT)
	testing.expect_value(t, chat.peer_hex, "current-peer")
	testing.expect_value(t, chat.avatar_key, "current-peer")
	chat_free(chat)

	// A current roster beats the presentation's last-known pair count/peer.
	row.presentation.title.tag = .Unnamed_Group
	row.presentation.title.body.unnamed_group = {
		has_member_count = true,
		member_count     = 2,
	}
	members["conversation"] = []string{"self", "current-peer", "third"}
	chat = row_to_ui(nil, &row, "self", members = members)
	testing.expect_value(t, chat.conversation_kind, marmot.Chat_Conversation_Kind.GROUP)
	testing.expect_value(t, chat.peer_hex, "")
	testing.expect_value(t, chat.avatar_key, "conversation")
	chat_free(chat)

	// Archive/search snapshots can resolve from an available presentation count.
	chat = row_to_ui(nil, &row, "self")
	testing.expect(t, chat_is_dm(chat))
	testing.expect_value(t, chat.peer_hex, "old-peer")
	chat_free(chat)
	row.row.conversation_kind = .GROUP
	chat = row_to_ui(nil, &row, "self")
	testing.expect(t, !chat_is_dm(chat))
	testing.expect_value(t, chat.peer_hex, "")
	chat_free(chat)
	row.row.conversation_kind = .DIRECT
	row.row.pending_confirmation = true
	chat = row_to_ui(nil, &row, "self")
	testing.expect(t, chat_is_dm(chat))
	testing.expect_value(t, chat.peer_hex, "")
	testing.expect_value(t, chat.avatar_key, "old-peer")
	chat_free(chat)
	row.row.pending_confirmation = false
	members["conversation"] = []string{"self"}
	chat = row_to_ui(nil, &row, "self", members = members)
	testing.expect(t, chat_is_dm(chat)) // explicit DIRECT survives a departed peer
	testing.expect_value(t, chat.peer_hex, "")
	testing.expect_value(t, chat.avatar_key, "conversation")
	chat_free(chat)
}

@(test)
conversation_peer_lifetime :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	ui := Ui_State {
		selected = 0,
	}
	original := Chat_Row_Ui {
		group_id          = strings.clone("conversation"),
		conversation_kind = .DIRECT,
		peer_hex          = strings.clone("peer"),
	}
	copy := chat_clone(original)
	testing.expect(t, raw_data(copy.peer_hex) != raw_data(original.peer_hex))
	chat_free(original)
	append(&ui.chats, copy)
	testing.expect_value(t, chat_peer(&ui), "peer")
	ui.chats[0].pending = true
	testing.expect_value(t, chat_peer(&ui), "")
	ui.chats[0].pending = false
	ui.chats[0].conversation_kind = .GROUP
	testing.expect_value(t, chat_peer(&ui), "")
	ui.chats[0].conversation_kind = .DIRECT
	delete(ui.chats[0].peer_hex)
	ui.chats[0].peer_hex = strings.clone("replacement")
	testing.expect_value(t, chat_peer(&ui), "replacement")
	ui.selected = len(ui.chats)
	testing.expect(t, !selected_chat_is_dm(&ui))
	testing.expect_value(t, chat_peer(&ui), "")
	ui.selected = -1
	testing.expect_value(t, chat_peer(&ui), "")
	testing.expect_value(t, chat_peer(nil), "")
	chat_free(ui.chats[0])
	delete(ui.chats)
}
