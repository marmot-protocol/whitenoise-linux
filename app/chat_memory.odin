package main

import "core:strings"

@(private)
chat_is_dm :: proc(chat: Chat_Row_Ui) -> bool {
	return chat.conversation_kind == .DIRECT
}

@(private)
selected_chat_is_dm :: proc(ui: ^Ui_State) -> bool {
	return(
		ui != nil &&
		ui.selected >= 0 &&
		ui.selected < len(ui.chats) &&
		chat_is_dm(ui.chats[ui.selected]) \
	)
}

@(private)
chat_peer :: proc(ui: ^Ui_State) -> string {
	if !selected_chat_is_dm(ui) || ui.chats[ui.selected].pending {return ""}
	return ui.chats[ui.selected].peer_hex
}

@(private)
retired_chats: [dynamic]Chat_Row_Ui

@(private)
chat_free :: proc(chat: Chat_Row_Ui) {
	for value in ([]string{chat.group_id, chat.peer_hex, chat.title, chat.preview, chat.at, chat.first_unread, chat.avatar_url, chat.avatar_key, chat.image_hash, chat.last_id}) {
		delete(value)
	}
}

@(private)
chat_clone :: proc(chat: Chat_Row_Ui) -> Chat_Row_Ui {
	copy := chat
	for value in ([]^string{&copy.group_id, &copy.peer_hex, &copy.title, &copy.preview, &copy.at, &copy.first_unread, &copy.avatar_url, &copy.avatar_key, &copy.image_hash, &copy.last_id}) {value^ = strings.clone(value^)}
	return copy
}

// Handlers and render commands can still borrow the replaced rows this frame.
@(private)
chats_collect :: proc() {
	for chat in retired_chats {
		chat_free(chat)
	}
	clear(&retired_chats)
}

@(private)
chats_replace :: proc(rows: ^[dynamic]Chat_Row_Ui, fresh: [dynamic]Chat_Row_Ui) {
	previous := make(map[string]int, context.temp_allocator)
	for row, i in rows^ {
		previous[row.group_id] = i
	}
	for &row in fresh {
		if i, ok := previous[row.group_id]; ok && rows^[i] == row {
			chat_free(row)
			row = rows^[i]
			rows^[i] = {}
		}
	}
	append(&retired_chats, ..rows^[:])
	delete(rows^)
	rows^ = fresh
}
