package main

@(private)
retired_chats: [dynamic]Chat_Row_Ui

@(private)
chat_free :: proc(chat: Chat_Row_Ui) {
	for value in ([]string{chat.group_id, chat.title, chat.preview, chat.at, chat.first_unread, chat.avatar_url, chat.avatar_key, chat.image_hash, chat.last_id}) {
		delete(value)
	}
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
