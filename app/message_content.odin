package main

import marmot "../marmot"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

@(private)
message_is_mine :: proc(direction, sender: cstring, account_id: string) -> bool {
	if string(direction) == "sent" {return true}
	if len(account_id) != 64 {return false}
	sender_id := string(sender)
	if len(sender_id) != 64 {return false}
	for i in 0 ..< 64 {
		a, b := account_id[i], sender_id[i]
		if 'A' <= a && a <= 'F' {a += 'a' - 'A'}
		if 'A' <= b && b <= 'F' {b += 'a' - 'A'}
		if a != b || !(('0' <= a && a <= '9') || ('a' <= a && a <= 'f')) {return false}
	}
	return true
}

// What a timeline record is, decided once for the timeline, chat-list
// previews, search, mentions and exports. Each surface then says which
// classes it shows, and how:
//
//   class         kinds                    timeline      preview, search
//   Message       chat, thread, poll, ...  rich row      reading_text
//   System        1210 group change        sentence row  the same sentence
//   Theme         30078 theme pack         offer card    skipped
//   Webxdc        "wnxdc1:" text           feeds the app skipped
//   Agent_Item    1201                     rich row      skipped, reading_text
//   Hidden        1200, 1202               skipped       skipped
//   Modifier      edit, deletion, vote     skipped       skipped
//   Unsupported   other kinds              summary card  label, skipped
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
	Agent_Item,
	Hidden,
	Modifier,
	Unsupported,
}

@(private)
record_class :: proc(kind: u64, plaintext: string) -> Record_Class {
	switch kind {
	case KIND_EDIT, KIND_DELETE, KIND_POLL_VOTE, KIND_REACTION:
		return .Modifier
	case KIND_AGENT_ITEM:
		return .Agent_Item
	case 1200, 1202:
		// Retired stream starts and agent answers or controls.
		return .Hidden
	case KIND_GROUP_SYSTEM:
		return .System
	case THEME_EVENT_KIND:
		return .Theme
	case KIND_CHAT_MESSAGE:
		if strings.has_prefix(strings.trim_left_space(plaintext), XDC_SENTINEL) {
			return .Webxdc
		}
		return .Message
	case KIND_THREAD, KIND_POLL:
		return .Message
	case:
		return .Unsupported
	}
}

@(private)
Event_Tags :: union {
	[]marmot.Message_Tag,
	json.Array,
}

@(private)
Event_Tag :: struct {
	c:    []cstring,
	json: json.Array,
}

@(private)
KIND_AGENT_ITEM :: u64(1201)

@(private)
timeline_record_class :: proc(
	record: ^marmot.Timeline_Message_Record,
	plaintext: string,
) -> Record_Class {
	class := record_class(record.kind, plaintext)
	// MDK clears the projection for tombstones and unreadable agent items.
	if class == .Agent_Item && record.agent_item == nil && !record.deleted {return .Hidden}
	return class
}

@(private)
event_tag_count :: proc(tags: Event_Tags) -> int {
	switch rows in tags {
	case []marmot.Message_Tag:
		return len(rows)
	case json.Array:
		return len(rows)
	}
	return 0
}

@(private)
event_tag_at :: proc(tags: Event_Tags, i: int) -> Event_Tag {
	switch rows in tags {
	case []marmot.Message_Tag:
		return {c = rows[i].values[:rows[i].values_len]}
	case json.Array:
		return {json = rows[i].(json.Array) or_else nil}
	}
	return {}
}

@(private)
event_tag_value :: proc(tag: Event_Tag, i: int) -> string {
	if tag.c != nil {return string(tag.c[i])}
	return string(tag.json[i].(json.String) or_else "")
}

@(private)
Event_Summary :: struct {
	title, description, details: string,
}

@(private)
event_summary :: proc(content: string, tags: Event_Tags) -> Event_Summary {
	title: string
	subject, summary, alt, duration: string
	media: Event_Tag
	for i in 0 ..< event_tag_count(tags) {
		tag := event_tag_at(tags, i)
		if len(tag.c) + len(tag.json) < 2 {continue}
		value := strings.trim_space(event_tag_value(tag, 1))
		switch event_tag_value(tag, 0) {
		case "title":
			if title == "" {title = value}
		case "subject":
			if subject == "" {subject = value}
		case "summary", "description":
			if summary == "" {summary = value}
		case "alt":
			if alt == "" {alt = value}
		case "duration":
			if duration == "" {duration = value}
		case "imeta":
			if media.c == nil && media.json == nil {media = tag}
		}
	}
	if title == "" {title = subject}
	// Structured payloads belong in the inspector, not in chat.
	description := strings.trim_space(content)
	if description == "" || description[0] == '{' || description[0] == '[' {
		description = summary != "" ? summary : alt
	}
	if description == title {description = ""}
	return {
		strings.clone(chat_preview(title)),
		strings.clone(chat_preview(description)),
		strings.clone(unsupported_media_info(media, duration)),
	}
}

@(private = "file")
unsupported_media_info :: proc(media: Event_Tag, duration: string) -> string {
	var_duration, dimensions, mime, host: string
	// Keep dimensions, format and host from the same imeta variant.
	for i in 1 ..< len(media.c) + len(media.json) {
		field := event_tag_value(media, i)
		sep := strings.index_byte(field, ' ')
		if sep < 0 {continue}
		value := strings.trim_space(field[sep + 1:])
		switch field[:sep] {
		case "duration":
			var_duration = value
		case "dim":
			if x := strings.index_byte(value, 'x'); x > 0 && len(value) <= 13 {
				w, wok := strconv.parse_u64(value[:x])
				h, hok := strconv.parse_u64(value[x + 1:])
				if wok && hok && w > 0 && h > 0 {dimensions = fmt.tprintf("%d×%d", w, h)}
			}
		case "m":
			if strings.index_byte(value, '/') > 0 &&
			   len(value) <= 32 &&
			   strings.index_any(value, " \t\r\n") < 0 {mime = value}
		case "url":
			if strings.has_prefix(value, "https://") || strings.has_prefix(value, "http://") {
				domain := url_host(value)
				if len(domain) <= 63 && strings.index_any(domain, "@ \t\r\n") < 0 {host = domain}
			}
		}
	}
	parts: [4]string
	n := 0
	seconds, ok := strconv.parse_f64(var_duration != "" ? var_duration : duration)
	if ok && seconds > 0 && seconds < 360_000 {
		total := int(seconds + 0.5)
		parts[n] =
			total < 3600 ? fmt.tprintf("%d:%02d", total / 60, total % 60) : fmt.tprintf("%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
		n += 1
	}
	for part in ([3]string{dimensions, mime, host}) {
		if part == "" {continue}
		parts[n] = part
		n += 1
	}
	return strings.join(parts[:n], " · ", context.temp_allocator)
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
