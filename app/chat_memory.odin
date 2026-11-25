package main

import marmot "../marmot"
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
chat_read_row_apply :: proc(
	chat: ^Chat_Row_Ui,
	row: ^marmot.Chat_List_Row,
	explicit := false,
) -> bool {
	cursor := string(row.last_read_message_id_hex)
	advanced := cursor != "" && cursor != chat.last_read
	if advanced {
		delete(chat.last_read)
		chat.last_read = strings.clone(cursor)
		// The remaining native count may include only inline references.
		chat.unread_mention = false
	}
	// The rail may already know about a message that arrived after the read.
	if last := row.last_message;
	   explicit || (last != nil && chat.last_id == string(last.message_id_hex)) {
		chat.unread = row.unread_count
		chat.unread_mention &= row.unread_mention_count > 0
		if first := string(row.first_unread_message_id_hex); chat.first_unread != first {
			delete(chat.first_unread)
			chat.first_unread = strings.clone(first)
		}
	}
	return advanced
}

@(private)
chat_read_invalidate :: proc(ui: ^Ui_State) {
	chat_list_revision += 1
	ui.chat_read_dirty = true
}

@(private)
chat_read_apply :: proc(
	ui: ^Ui_State,
	row: ^marmot.Chat_List_Row,
	chat: ^Chat_Row_Ui,
	explicit := false,
) {
	group := string(row.group_id_hex)
	target := chat
	if target == nil {
		for &item in ui.chats {
			if item.group_id == group {target = &item; break}
		}
	}
	advanced := target != nil && chat_read_row_apply(target, row, explicit)
	known := target != nil
	if row.archived || (target != nil && target.archived) {
		for &item in ui.archived {
			if item.group_id == group {
				advanced |= chat_read_row_apply(&item, row)
				known = true
				break
			}
		}
	}
	if explicit || advanced || (!known && row.last_read_message_id_hex != nil) {
		chat_read_invalidate(ui)
	}
}

@(private)
retired_chats: [dynamic]Chat_Row_Ui

@(private)
chat_free :: proc(chat: Chat_Row_Ui) {
	for value in ([]string{chat.group_id, chat.peer_hex, chat.title, chat.preview, chat.at, chat.first_unread, chat.last_read, chat.avatar_url, chat.avatar_key, chat.image_hash, chat.last_id}) {
		delete(value)
	}
}

@(private)
chat_clone :: proc(chat: Chat_Row_Ui) -> Chat_Row_Ui {
	copy := chat
	for value in ([]^string{&copy.group_id, &copy.peer_hex, &copy.title, &copy.preview, &copy.at, &copy.first_unread, &copy.last_read, &copy.avatar_url, &copy.avatar_key, &copy.image_hash, &copy.last_id}) {value^ = strings.clone(value^)}
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
chats_replace :: proc(
	rows: ^[dynamic]Chat_Row_Ui,
	fresh: [dynamic]Chat_Row_Ui,
	fence_reads := false,
) {
	previous := make(map[string]int, context.temp_allocator)
	for row, i in rows^ {
		previous[row.group_id] = i
	}
	cursor_changed := false
	for &row in fresh {
		if i, ok := previous[row.group_id]; ok {
			old := &rows^[i]
			if old^ == row {
				chat_free(row)
				row, old^ = old^, {}
			} else {
				cursor_changed ||= fence_reads && old.last_read != row.last_read
			}
		} else {
			cursor_changed ||= fence_reads && row.last_read != ""
		}
	}
	append(&retired_chats, ..rows^[:])
	delete(rows^)
	rows^ = fresh
	if cursor_changed {chat_list_revision += 1}
}
