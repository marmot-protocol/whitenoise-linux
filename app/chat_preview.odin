package main

import marmot "../marmot"
import "core:fmt"
import "core:strings"

@(private)
Chat_Attachment_Kind :: enum i32 {
	// MarmotChatListAttachmentKind
	Photo,
	Video,
	Audio,
	File,
	Mixed,
}

@(private = "file")
CHAT_ATTACHMENT_PREVIEWS := [Chat_Attachment_Kind]struct {
	glyph, label, plural: string,
} {
	.Photo = {GROUP_FILE_ICONS[.Images], N_("Image"), N_("Images")},
	.Video = {GROUP_FILE_ICONS[.Videos], N_("Video"), N_("Videos")},
	.Audio = {GROUP_FILE_ICONS[.Audio], N_("Audio message"), ""},
	.File  = {GROUP_FILE_ICONS[.Documents], N_("File"), N_("Files")},
	.Mixed = {ICON_CLIP, N_("Attachments"), ""},
}

@(private)
Chat_Preview :: struct {
	text: string,
	icon: Chat_Preview_Icon,
}

@(private)
Chat_Preview_Icon :: struct {
	glyph: string, // static glyph, separate from the text used in notifications
	at:    int, // byte offset of the caption or attachment label
}

@(private)
prefix_chat_preview :: proc(preview: ^Chat_Preview, with_sender: string) {
	// The translated sender templates end with the preview text.
	if preview.icon.glyph != "" {
		preview.icon.at = len(with_sender) - len(preview.text)
	}
	preview.text = with_sender
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
	preview: Chat_Preview,
	system_page: ^marmot.Timeline_Page,
) {
	last := row.last_message
	if last == nil || last.deleted {return {}, nil}
	mine := message_is_mine(nil, last.sender, account_ref)
	is_blocked := !mine && last.sender != nil && blocked[string(last.sender)]
	raw := last.plaintext != nil ? string(last.plaintext) : ""
	class := record_class(last.kind, raw)
	if class == .System && last.group_system != nil {
		return {text = rail_preview(system_text(client, last.group_system))}, nil
	}
	if is_blocked || (class != .Message && class != .Unsupported) {
		page := page
		owned := page == nil
		if owned {page = window_preview(client, account_ref, row)}
		phrased, system := preview_text(client, page, account_ref, blocked, mode)
		// Profile labels use UI-owned caches. Only these fallback pages
		// survive worker preparation, to be phrased on UI adoption.
		if system && mode == .Worker {return {}, page}
		if owned && page != nil {marmot.timeline_page_free(page)}
		return {text = rail_preview(phrased)}, nil
	}
	if class == .Unsupported {
		preview.text = tr("Unsupported event")
	} else {
		preview.text = strings.trim_space(reading_text(client, raw))
		kind := Chat_Attachment_Kind(last.attachment_kind)
		if last.has_attachment_kind && kind >= .Photo && kind <= .Mixed {
			attachment := &CHAT_ATTACHMENT_PREVIEWS[kind]
			preview.icon.glyph = attachment.glyph
			if preview.text == "" {
				preview.text = tr(
					last.attachment_count > 1 && attachment.plural != "" ? attachment.plural : attachment.label,
				)
			}
		}
	}
	if mine && preview.text != "" {
		prefix_chat_preview(&preview, fmt.tprintf(tr("You: %s"), preview.text))
	}
	preview.text = rail_preview(preview.text)
	return preview, nil
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
		if record.deleted {continue}
		raw := record.plaintext != nil ? string(record.plaintext) : ""
		class := record_class(record.kind, raw)
		switch class {
		case .System:
			if record.group_system == nil {continue}
			if mode == .Worker {return "", true}
			return strings.clone(system_text(client, record.group_system), context.temp_allocator),
				true
		case .Theme, .Webxdc, .Agent_Item, .Hidden, .Modifier:
			// MDK does not count agent items as chat-list activity.
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
