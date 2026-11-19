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
	mine := message_is_mine(nil, last.sender, account_ref)
	is_blocked := !mine && last.sender != nil && blocked[string(last.sender)]
	raw := last.plaintext != nil ? string(last.plaintext) : ""
	class := record_class(last.kind, raw)
	if class == .System && last.group_system != nil {
		return rail_preview(system_text(client, last.group_system)), nil
	}
	if is_blocked || (class != .Message && class != .Unsupported) {
		page := page
		owned := page == nil
		if owned {page = window_preview(client, account_ref, row)}
		phrased, system := preview_text(client, page, account_ref, blocked, mode)
		// Profile labels use UI-owned caches. Only these fallback pages
		// survive worker preparation, to be phrased on UI adoption.
		if system && mode == .Worker {return "", page}
		if owned && page != nil {marmot.timeline_page_free(page)}
		if phrased == "" {return "", nil}
		return rail_preview(phrased), nil
	}
	if class == .Unsupported {
		preview = tr("Unsupported event")
	} else if strings.trim_space(raw) == "" &&
	   !last.deleted &&
	   last.has_attachment_kind &&
	   last.attachment_kind == CHAT_ATTACHMENT_AUDIO {
		preview = tr("Audio message")
	} else {
		preview = reading_text(client, raw)
	}
	if mine && strings.trim_space(preview) != "" {preview = fmt.tprintf(tr("You: %s"), preview)}
	return rail_preview(preview), nil
}

// Decode the whole link before either preview limit can cut its checksum.
@(private = "file")
rail_preview :: proc(text: string) -> string {
	cover, _ := hidden_message(text)
	builder: strings.Builder
	start := 0
	for i := 0; i < len(cover) && strings.builder_len(builder) + i - start < PREVIEW_BYTES; {
		end, ref := nostr_at(cover, i)
		if ref.kind == .None {
			if cover[i] == 'h' {
				if end, _, ok := url_at(cover, i); ok {
					i = end
					continue
				}
			}
			i += 1
			continue
		}
		if ref.kind == .Event || ref.kind == .Address {
			if start == 0 {builder = strings.builder_make(context.temp_allocator)}
			strings.write_string(&builder, cover[start:i])
			strings.write_string(&builder, tr("Nostr event"))
			start = end
		}
		i = end
	}
	if start == 0 {return cap_preview(cover)}
	remaining := max(0, PREVIEW_BYTES + 1 - strings.builder_len(builder))
	strings.write_string(&builder, cover[start:start + min(remaining, len(cover) - start)])
	return cap_preview(strings.to_string(builder))
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
	account_ref: string,
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
		class := record_class(record.kind, raw)
		switch class {
		case .System:
			if record.group_system == nil {continue}
			if mode == .Worker {return "", true}
			return strings.clone(system_text(client, record.group_system), context.temp_allocator),
				true
		case .Theme, .Webxdc, .Agent_Stream, .Agent_State, .Modifier:
			continue
		case .Message, .Unsupported:
		}
		mine := message_is_mine(record.direction, record.sender, account_ref)
		if !mine && record.sender != nil && blocked[string(record.sender)] {continue}
		text = class == .Unsupported ? tr("Unsupported event") : reading_text(client, raw)
		if text == "" {continue}
		if mine {return fmt.tprintf(tr("You: %s"), text), false}
		return strings.clone(text, context.temp_allocator), false
	}
	return "", false
}
