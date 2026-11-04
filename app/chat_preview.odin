package main

import marmot "../marmot"
import "core:fmt"
import "core:strings"

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
	class := record_class(last.kind, raw)
	if class == .System && last.group_system != nil {
		return chat_preview(system_text(client, last.group_system)), nil
	}
	// Only a message speaks for itself. Anything else, and a blocked
	// sender's message, reads the newest previewable row in a window.
	if class != .Message || is_blocked {
		page := page
		owned := page == nil
		if owned {page = window_preview(client, account_ref, row)}
		phrased, system := preview_text(client, page, blocked, mode)
		// Profile labels use UI-owned caches. Only these fallback pages
		// survive worker preparation, to be phrased on UI adoption.
		if system && mode == .Worker {return "", page}
		if owned && page != nil {marmot.timeline_page_free(page)}
		if phrased == "" {return "", nil}
		return chat_preview(phrased), nil
	}
	preview = reading_text(client, raw)
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
		raw := record.plaintext != nil ? string(record.plaintext) : ""
		switch record_class(record.kind, raw) {
		case .System:
			if record.group_system == nil {continue}
			if mode == .Worker {return "", true}
			return strings.clone(system_text(client, record.group_system), context.temp_allocator),
				true
		case .Theme, .Webxdc, .Agent_Stream, .Agent_State, .Modifier:
			continue
		case .Message:
		}
		if record.sender != nil && blocked[string(record.sender)] {continue}
		text = reading_text(client, raw)
		if text == "" {continue}
		if record.direction != nil &&
		   string(record.direction) == "sent" {return fmt.tprintf(tr("You: %s"), text), false}
		return strings.clone(text, context.temp_allocator), false
	}
	return "", false
}
