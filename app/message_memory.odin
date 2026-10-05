package main

import marmot "../marmot"
import "core:mem"

// A reload may run inside a click handler. Keep the previous rows alive
// until every handler and render command for that frame has finished.
@(private)
retired_messages: [dynamic]Msg_Ui

// Ordinary immutable text rows are the common case. Mutable projections
// (edits, reactions, replies, media, polls) retain the full conversion path.
@(private)
message_matches :: proc(
	old: Msg_Ui,
	record: ^marmot.Timeline_Message_Record,
	label, picture: string,
) -> bool {
	if record.kind != 9 ||
	   record.deleted ||
	   old.deleted ||
	   old.edited ||
	   old.system ||
	   old.effect != 0 ||
	   old.thread_of != "" ||
	   len(old.poll_opts) != 0 ||
	   old.theme_name != "" ||
	   record.tags_len != 0 ||
	   record.media_len != 0 ||
	   len(old.attachments) != 0 ||
	   record.reactions.by_emoji_len != 0 ||
	   len(old.reactions) != 0 ||
	   record.reply_to_message_id_hex != nil ||
	   record.reply_preview != nil ||
	   old.reply_id != "" {
		return false
	}
	if old.body != string(record.plaintext) ||
	   old.sender_id != string(record.sender) ||
	   old.sender != label ||
	   old.pic_url != picture ||
	   old.mine != (string(record.direction) == "sent") {
		return false
	}
	// Time/date preferences and midnight can change labels without a wire update.
	context.allocator = context.temp_allocator
	return(
		old.at == format_when(record.timeline_at) &&
		old.at_full == format_full(record.timeline_at) &&
		old.day == format_day(record.timeline_at) \
	)
}

@(private)
blocks_free :: proc(blocks: [dynamic]Md_Block_Ui) {
	for block in blocks {
		mem.zero_slice(transmute([]u8)block.text)
		delete(block.text)
		delete(block.fonts)
		delete(block.alignments)
		delete(block.code_kinds)
		for row in block.cell_fonts {
			for fonts in row {delete(fonts)}
			delete(row)
		}
		delete(block.cell_fonts)
		for row in block.cells {
			for cell in row {
				mem.zero_slice(transmute([]u8)cell)
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
	sticker_ref_free(msg.sticker)
	for value in ([]string{msg.id, msg.sender, msg.sender_id, msg.pic_url, msg.body, msg.reply_from, msg.reply_from_id, msg.reply_text, msg.reply_id, msg.reply_image, msg.at, msg.at_full, msg.day, msg.sys_text, msg.sys_added_hex, msg.theme_name, msg.theme_toml, msg.thread_of}) {
		mem.zero_slice(transmute([]u8)value)
		delete(value)
	}
	blocks_free(msg.blocks)
	for secret in msg.secrets {
		blocks_free(secret.blocks)
	}
	delete(msg.secrets)
	for reaction in msg.reactions {
		delete(reaction.label)
		delete(reaction.emoji)
		delete(reaction.count)
		delete(reaction.who)
	}
	delete(msg.reactions)
	for version in msg.history {
		delete(version.at)
		mem.zero_slice(transmute([]u8)version.text)
		delete(version.text)
		blocks_free(version.blocks)
	}
	delete(msg.history)
	for opt in msg.poll_opts {
		delete(opt.id)
		delete(opt.label)
		blocks_free(opt.blocks)
	}
	delete(msg.poll_opts)
	// Views and textures belong to the session caches; slots own only strings.
	for slot in msg.attachments {
		delete(slot.name)
		delete(slot.key)
	}
	delete(msg.attachments)
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
	reacting := ui.picker_target != ""
	for target in ([]^string{&ui.replying, &ui.editing, &ui.picker_target}) {
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
	// The message a reaction picker was opened on left the timeline: close
	// it rather than let the next pick fall through to the composer.
	if reacting && ui.picker_target == "" && ui.picker_open {
		close_picker(ui)
	}
}
