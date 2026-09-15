package main

import marmot "../marmot"

// A reload may run inside a click handler. Keep the previous rows alive
// until every handler and render command for that frame has finished.
@(private)
retired_messages: [dynamic]Msg_Ui

// Ordinary immutable text rows are the common case. Mutable projections
// (edits, reactions, replies, media, polls) retain the full conversion path.
@(private)
message_matches :: proc(old: Msg_Ui, record: ^marmot.Timeline_Message_Record, label, picture: string) -> bool {
	if record.kind != 9 || record.deleted || old.deleted || old.edited || old.system ||
		old.effect != 0 || old.thread_of != "" || len(old.poll_opts) != 0 || old.theme_name != "" ||
		record.tags_len != 0 || record.media_len != 0 || len(old.att_names) != 0 ||
		record.reactions.by_emoji_len != 0 || len(old.reactions) != 0 ||
		record.reply_to_message_id_hex != nil || record.reply_preview != nil || old.reply_id != "" {
		return false
	}
	if old.body != string(record.plaintext) || old.sender_id != string(record.sender) ||
		old.sender != label || old.pic_url != picture || old.mine != (string(record.direction) == "sent") {
		return false
	}
	// Time/date preferences and midnight can change labels without a wire update.
	context.allocator = context.temp_allocator
	return old.at == format_when(record.timeline_at) && old.at_full == format_full(record.timeline_at) &&
		old.day == format_day(record.timeline_at)
}

@(private)
blocks_free :: proc(blocks: [dynamic]Md_Block_Ui) {
	for block in blocks {
		delete(block.text)
		for row in block.cells {
			for cell in row {
				delete(cell)
			}
			delete(row)
		}
		delete(block.cells)
	}
	delete(blocks)
}

@(private)
message_free :: proc(msg: Msg_Ui) {
	for value in ([]string{msg.id, msg.sender, msg.sender_id, msg.pic_url,
		msg.body, msg.reply_from, msg.reply_text, msg.reply_id, msg.at,
		msg.at_full, msg.day, msg.sys_actor, msg.sys_added_hex,
		msg.theme_name, msg.theme_toml, msg.thread_of}) {
		delete(value)
	}
	blocks_free(msg.blocks)
	for reaction in msg.reactions {
		delete(reaction.label)
		delete(reaction.emoji)
		delete(reaction.count)
		delete(reaction.who)
	}
	delete(msg.reactions)
	for version in msg.history {
		delete(version.at)
		delete(version.text)
	}
	delete(msg.history)
	for opt in msg.poll_opts {
		delete(opt.id)
		delete(opt.label)
		blocks_free(opt.blocks)
	}
	delete(msg.poll_opts)
	for name in msg.att_names {
		delete(name)
	}
	for key in msg.att_keys {
		delete(key)
	}
	for entry in msg.img_failed {
		delete(entry.view)
	}
	delete(msg.att_names)
	delete(msg.att_keys)
	delete(msg.img_failed)
	delete(msg.files)
	delete(msg.media_pending)
	// Views and textures belong to the session caches, only arrays belong here.
	delete(msg.images)
	delete(msg.models)
	delete(msg.videos)
	delete(msg.audios)
	delete(msg.gcodes)
	delete(msg.pdfs)
	delete(msg.arcs)
	delete(msg.xdcs)
	delete(msg.txts)
	delete(msg.codes)
	delete(msg.fonts)
}

@(private)
messages_collect :: proc() {
	for msg in retired_messages {
		message_free(msg)
	}
	clear(&retired_messages)
}

// These IDs borrow row storage across frames. Rebind before retiring it.
@(private)
messages_rebind :: proc(ui: ^Ui_State) {
	for target in ([]^string{&ui.replying, &ui.editing}) {
		id := target^
		target^ = ""
		if id == "" {
			continue
		}
		for msg in ui.messages {
			if msg.id == id {
				target^ = msg.id
				break
			}
		}
	}
}
