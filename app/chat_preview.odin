package main

import marmot "../marmot"
import "core:fmt"
import "core:strings"

// Webxdc state updates feed the running app, never reading previews.
@(private = "file")
is_xdc_blob :: proc(text: string) -> bool {
	return strings.has_prefix(strings.trim_space(text), XDC_SENTINEL)
}

// Read the existing Markdown tree without allocating renderer rows or styles.
@(private = "file")
preview_blocks :: proc(builder: ^strings.Builder, blocks: [^]marmot.Markdown_Block, count: uint) {
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
			preview_blocks(
				builder,
				block.body.block_quote.blocks,
				block.body.block_quote.blocks_len,
			)
		case .LIST_BLOCK:
			list := &block.body.list_block
			for j in 0 ..< list.items_len {
				preview_blocks(builder, list.items[j].blocks, list.items[j].blocks_len)
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

// Temp-allocated reading text. Filter hidden payloads before parsing or capping.
// The C parser requires a live client; nil-client callers retain the cover.
@(private = "file")
preview_reading_text :: proc(client: ^marmot.Client, text: string) -> string {
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
	preview_blocks(&builder, doc.blocks, doc.blocks_len)
	reading := strings.trim_space(strings.to_string(builder))
	reading, _ = strings.replace_all(reading, "\r\n", " ", context.temp_allocator)
	reading, _ = strings.replace_all(reading, "\n", " ", context.temp_allocator)
	reading, _ = strings.replace_all(reading, "\r", " ", context.temp_allocator)
	return reading
}

@(private)
Chat_Preview_Mode :: enum {
	Immediate,
	Worker,
}

// The same selection runs on a blocked-state snapshot in Chat_List_Work and
// when archive/search snapshots are converted into owned UI rows.
@(private)
chat_row_preview :: proc(
	client: ^marmot.Client,
	row: ^marmot.Chat_List_Row,
	account_ref: string,
	blocked: map[string]bool,
	page: ^marmot.Timeline_Page = nil,
	mode: Chat_Preview_Mode = .Immediate,
) -> (
	preview: string,
	system_page: ^marmot.Timeline_Page,
) {
	last := row.last_message
	if last == nil {return "", nil}
	mine := last.sender != nil && string(last.sender) == account_ref
	is_blocked := !mine && last.sender != nil && blocked[string(last.sender)]
	raw := last.plaintext != nil ? string(last.plaintext) : ""
	if last.kind == 1210 && last.group_system != nil {
		return chat_preview(system_text(client, last.group_system)), nil
	}
	xdc := is_xdc_blob(raw)
	if last.kind == 1210 || xdc || is_blocked {
		page := page
		owned := page == nil
		if owned {page = window_preview(client, account_ref, row)}
		phrased, system := preview_text(client, page, blocked, mode)
		// Profile labels use UI-owned caches. Only these fallback pages
		// survive worker preparation, to be phrased on UI adoption.
		if system && mode == .Worker {return "", page}
		if owned && page != nil {marmot.timeline_page_free(page)}
		if phrased != "" {return chat_preview(phrased), nil}
		if xdc || is_blocked {return "", nil}
	}
	preview = preview_reading_text(client, raw)
	if strings.trim_space(raw) == "" &&
	   !last.deleted &&
	   last.has_attachment_kind &&
	   last.attachment_kind == CHAT_ATTACHMENT_AUDIO {
		preview = tr("Audio message")
	}
	if mine && strings.trim_space(preview) != "" {preview = fmt.tprintf(tr("You: %s"), preview)}
	return chat_preview(preview), nil
}

// Read a bounded timeline window only for rows whose newest record cannot
// speak for itself. The caller owns the page.
@(private = "file")
window_preview :: proc(
	client: ^marmot.Client,
	account_ref: string,
	row: ^marmot.Chat_List_Row,
) -> ^marmot.Timeline_Page {
	if client == nil {return nil}
	query := marmot.Timeline_Message_Query {
		group_id_hex = row.group_id_hex,
		has_limit    = true,
		limit        = 16,
	}
	page: ^marmot.Timeline_Page
	account := strings.clone_to_cstring(account_ref, context.temp_allocator)
	if marmot.timeline_messages(client, account, &query, &page) != .OK {return nil}
	return page
}

@(private = "file")
preview_text :: proc(
	client: ^marmot.Client,
	page: ^marmot.Timeline_Page,
	blocked: map[string]bool,
	mode: Chat_Preview_Mode,
) -> (
	text: string,
	system: bool,
) {
	if page == nil {return "", false}
	for i := int(page.messages_len) - 1; i >= 0; i -= 1 {
		record := &page.messages[i]
		if record.kind == 1009 || record.kind == 5 || record.kind == KIND_POLL_VOTE {continue}
		if record.kind == 1210 {
			if record.group_system != nil {
				if mode == .Worker {return "", true}
				return strings.clone(
						system_text(client, record.group_system),
						context.temp_allocator,
					),
					true
			}
			continue
		}
		if record.sender != nil && blocked[string(record.sender)] {continue}
		raw := record.plaintext != nil ? string(record.plaintext) : ""
		if raw == "" || is_xdc_blob(raw) {continue}
		text = preview_reading_text(client, raw)
		if text == "" {continue}
		if record.direction != nil &&
		   string(record.direction) == "sent" {return fmt.tprintf(tr("You: %s"), text), false}
		return strings.clone(text, context.temp_allocator), false
	}
	return "", false
}
