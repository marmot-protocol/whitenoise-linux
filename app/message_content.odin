package main

import marmot "../marmot"
import "core:strings"

// What a timeline record is, decided once for the timeline, chat-list
// previews, search, mentions and exports. Each surface then says which
// classes it shows, and how:
//
//   class         kinds                    timeline      preview, search
//   Message       chat, thread, poll, ...  rich row      reading_text
//   System        1210 group change        sentence row  the same sentence
//   Theme         30078 theme pack         offer card    skipped
//   Webxdc        "wnxdc1:" text           feeds the app skipped
//   Agent_Stream  1200                     live text     skipped (not retained)
//   Agent_State   1201, 1202               skipped       skipped
//   Modifier      edit, deletion, vote     skipped       skipped
//
// MDK applies modifiers before a page reaches the app. An accepted edit
// (the target's author, one e tag, newest by time then id) replaces the
// target's plaintext and sets record.edit; a deletion sets record.deleted;
// votes fold into record.poll. Pages and search therefore already carry
// the effective content, whatever page the edit arrived in, and edit
// history comes from marmot.message_edit_history. Modifier kinds stay
// classified so a stray one is never read as a message.
@(private)
Record_Class :: enum u8 {
	Message,
	System,
	Theme,
	Webxdc,
	Agent_Stream,
	Agent_State,
	Modifier,
}

@(private)
record_class :: proc(kind: u64, plaintext: string) -> Record_Class {
	switch kind {
	case KIND_EDIT, KIND_DELETE, KIND_POLL_VOTE:
		return .Modifier
	case AGENT_ACTIVITY, AGENT_OPERATION:
		return .Agent_State
	case AGENT_STREAM_START:
		return .Agent_Stream
	case KIND_GROUP_SYSTEM:
		return .System
	case THEME_EVENT_KIND:
		return .Theme
	}
	// Webxdc state updates ride ordinary text messages.
	if strings.has_prefix(strings.trim_left_space(plaintext), XDC_SENTINEL) {return .Webxdc}
	return .Message
}

// The words a message shows, without markup, for previews and search.
// Temp-allocated. Hidden payloads are filtered before parsing or capping,
// and maps links read as the card the timeline draws for them. The C
// parser requires a live client; nil-client callers keep the cover.
@(private)
reading_text :: proc(client: ^marmot.Client, text: string) -> string {
	cover, _ := hidden_message(text)
	if client == nil || cover == "" {return cover}
	doc: ^marmot.Markdown_Document
	if marmot.parse_markdown(
		   client,
		   strings.clone_to_cstring(cover, context.temp_allocator),
		   &doc,
	   ) !=
	   .OK {
		return cover
	}
	defer marmot.markdown_document_free(doc)
	builder := strings.builder_make(context.temp_allocator)
	reading_blocks(&builder, doc.blocks, doc.blocks_len)
	reading := strings.trim_space(strings.to_string(builder))
	reading, _ = strings.replace_all(reading, "\r\n", " ", context.temp_allocator)
	reading, _ = strings.replace_all(reading, "\n", " ", context.temp_allocator)
	reading, _ = strings.replace_all(reading, "\r", " ", context.temp_allocator)
	return reading_locations(reading)
}

// Read the existing Markdown tree without allocating renderer rows or styles.
@(private = "file")
reading_blocks :: proc(builder: ^strings.Builder, blocks: [^]marmot.Markdown_Block, count: uint) {
	for i in 0 ..< count {
		block := &blocks[i]
		switch block.tag {
		case .PARAGRAPH, .HEADING:
			inlines: marmot.Markdown_Inlines
			if block.tag == .PARAGRAPH {
				inlines = block.body.paragraph
			} else {
				inlines = {block.body.heading.inlines, block.body.heading.inlines_len}
			}
			if strings.builder_len(builder^) > 0 {strings.write_byte(builder, ' ')}
			extract_inlines(builder, inlines.inlines, inlines.inlines_len)
		case .CODE_BLOCK, .MATH_BLOCK:
			text :=
				block.tag == .CODE_BLOCK ? string(block.body.code_block.content) : string(block.body.math_block.content)
			text = strings.trim_space(text)
			if text == "" {continue}
			if strings.builder_len(builder^) > 0 {strings.write_byte(builder, ' ')}
			strings.write_string(builder, text)
		case .BLOCK_QUOTE:
			reading_blocks(
				builder,
				block.body.block_quote.blocks,
				block.body.block_quote.blocks_len,
			)
		case .LIST_BLOCK:
			list := &block.body.list_block
			for j in 0 ..< list.items_len {
				reading_blocks(builder, list.items[j].blocks, list.items[j].blocks_len)
			}
		case .TABLE:
			table := &block.body.table
			for j in 0 ..< table.header_len {
				if strings.builder_len(builder^) > 0 {strings.write_byte(builder, ' ')}
				extract_inlines(builder, table.header[j].inlines, table.header[j].inlines_len)
			}
			for r in 0 ..< table.rows_len {
				row := &table.rows[r]
				for j in 0 ..< row.cells_len {
					if strings.builder_len(builder^) > 0 {strings.write_byte(builder, ' ')}
					extract_inlines(builder, row.cells[j].inlines, row.cells[j].inlines_len)
				}
			}
		case .THEMATIC_BREAK:
		}
	}
}

// A maps link reads as its card's title, and a plain run that is only
// Android's caption goes with it, as render_segs drops it:
//
//   "Location: https://maps.google.com/maps?q=51.5,-0.12"  ->  "Shared location"
//
// The words do not depend on the link-preview setting: a preview names
// what was shared even where the conversation shows the bare link.
@(private = "file")
reading_locations :: proc(text: string) -> string {
	if !strings.contains(text, "https://") {return text}
	builder := strings.builder_make(context.temp_allocator)
	plain := 0 // where the current run of plain text starts in builder
	for i := 0; i < len(text); {
		if text[i] != 'h' {
			strings.write_byte(&builder, text[i])
			i += 1
			continue
		}
		end, url, ok := url_at(text, i)
		if !ok {
			strings.write_byte(&builder, 'h')
			i += 1
			continue
		}
		if _, geo := geo_ref(url); geo {
			if strings.trim_space(strings.to_string(builder)[plain:]) == GEO_CAPTION {
				resize(&builder.buf, plain)
			}
			strings.write_string(&builder, tr("Shared location"))
		} else {
			strings.write_string(&builder, url)
		}
		plain = strings.builder_len(builder)
		i = end
	}
	return strings.to_string(builder)
}
