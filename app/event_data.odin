package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "nendo"
import rl "sdlrl"

@(private)
Event_Card_Link :: struct {
	key, byline, open_url: string,
}

@(private)
unsupported_event_card :: proc(
	index: u32,
	kind: u64,
	summary: Event_Summary,
	link: Event_Card_Link = {},
) {
	kind_label, icon, kind_detail := event_kind_label(kind)
	width := att_w(380)
	PAD :: 14
	inner := width - 2 * PAD
	if nendo.box(nendo.id(link.key == "" ? "UnsupportedEvent" : "NevCard", index))(
	{
		width = nendo.fixed(width),
		direction = .Column,
		color = PLATE,
		radius = rr(12),
		border = {color = mix_color(CARD_BORDER, ACCENT, 0.26), width = bw()},
	},
	) {
		if nendo.box(nendo.id_local("UnsupportedEventMain"))(
		{width = nendo.fixed(width), direction = .Column, padding = nendo.pad(PAD), gap = 9},
		) {
			if nendo.box(nendo.id_local("UnsupportedEventHeader"))(
			{width = nendo.fixed(inner), align = {y = .Center}, gap = 10},
			) {
				if nendo.box(nendo.id_local("UnsupportedEventIcon"))(
				{
					width = nendo.fixed(34),
					height = nendo.fixed(34),
					align = {x = .Center, y = .Center},
					color = fade(ACCENT, 0.15),
					radius = rr(9),
				},
				) {
					nendo.text(icon, {font = FONT_ICON, size = 16, color = ACCENT})
				}
				if nendo.box(nendo.id_local("UnsupportedEventKind"))(
				{width = nendo.fixed(inner - 44), direction = .Column, gap = 3},
				) {
					nendo.text(
						kind_label,
						{font = FONT_TITLE, size = 10, color = ACCENT, spacing = 1},
					)
					if kind_detail != "" {
						nendo.text(kind_detail, {font = FONT_MONO, size = 10, color = TEXT_DIM})
					}
				}
			}
			if link.byline != "" {
				nendo.text(
					text_ellipsis(link.byline, inner, FONT_BODY, 11),
					{font = FONT_BODY, size = 11, color = TEXT_DIM, wrap = .None},
				)
			}
			if summary.title != "" {
				nendo.text(
					text_ellipsis(summary.title, inner, FONT_TITLE, 18),
					{font = FONT_TITLE, size = 18, color = TEXT, wrap = .None},
				)
			}
			if summary.description != "" {
				MAX_LINES :: 3
				if nendo.box(nendo.id_local("UnsupportedEventDescription"))(
				{width = nendo.fixed(inner), direction = .Column, gap = 2},
				) {
					lines := wrapped_lines(summary.description, inner, 13, .Plain)
					for line, i in lines[:min(len(lines), MAX_LINES)] {
						text := summary.description[line.start:line.end]
						if i == MAX_LINES - 1 &&
						   len(lines) > MAX_LINES {text = fmt.tprintf("%s…", text)}
						nendo.text(
							text_ellipsis(text, inner, FONT_BODY, 13),
							{font = FONT_BODY, size = 13, color = TEXT_DIM, wrap = .None},
						)
					}
				}
			}
		}
		if nendo.box(nendo.id_local("UnsupportedEventFooter"))(
		{
			width = nendo.fixed(width),
			direction = .Column,
			gap = 6,
			padding = {left = PAD, right = PAD, top = 8, bottom = 9},
			color = mix_color(PLATE, BG, 0.32),
			radius = {bottom_left = 12 * R_SCALE, bottom_right = 12 * R_SCALE},
			border = {color = CARD_BORDER, width = {top = 1}},
		},
		) {
			if summary.details != "" {
				nendo.text(summary.details, {font = FONT_MONO, size = 11, color = TEXT})
			}
			if nendo.box(nendo.id_local("EventDataRow"))(
			{
				width = nendo.fixed(inner),
				direction = inner < 240 ? .Column : .Row,
				align = {y = .Center},
				gap = 6,
			},
			) {
				nendo.text(
					tr("Unsupported event"),
					{font = FONT_BODY, size = 11, color = TEXT_DIM},
				)
				if inner >= 240 {
					if nendo.box(nendo.id_local("EventDataGap"))({width = nendo.grow()}) {}
				}
				button := link.key == "" ? "EventDataButton" : "NevEventDataButton"
				action_chip(button, index, tr("View event data"))
				if link.key != "" &&
				   nendo.pointer_over(nendo.id(button, index)) {nev_data_hover = link.key}
			}
			if link.open_url != "" {
				action_chip("NevOpen", index, tr("Open in client"))
				if nendo.pointer_over(nendo.id("NevOpen", index)) {link_hover = link.open_url}
			}
		}
	}
}

@(private)
Event_Data_View :: struct {
	id, title, sender, at: string,
	source:                Event_Data_Source,
	fields:                []Event_Data_Field,
}

@(private)
Event_Data_Source :: enum {
	Timeline,
	Linked,
}

@(private = "file")
Event_Data_Record :: struct {
	id, author, content: string,
	kind:                u64,
	tags:                Event_Tags,
}

@(private)
Event_Data_Field :: struct {
	name, value: string,
}

@(private)
event_kind_label :: proc(kind: u64) -> (label, icon, detail: string) {
	switch kind {
	case KIND_VIDEO, KIND_VIDEO_ADDRESS:
		label = tr("VIDEO EVENT")
	case KIND_SHORT_VIDEO, KIND_SHORT_VIDEO_ADDRESS:
		label = tr("SHORT VIDEO EVENT")
	case:
		return fmt.tprintf(tr("Unknown event kind %d"), kind), ICON_GLOBE, ""
	}
	return label, "\uf03d", fmt.tprintf(tr("KIND %d"), kind)
}

@(private)
event_data_open :: proc(
	view: ^Event_Data_View,
	source: Event_Data_Source,
	id, title, sender, at: string,
) {
	event_data_close(view)
	view^ = {
		id     = strings.clone(id),
		title  = strings.clone(title),
		sender = strings.clone(sender),
		at     = strings.clone(at),
		source = source,
	}
	if record, ok := event_data_record(view); ok {
		fields := event_data_fields(record.content)
		view.fields = make([]Event_Data_Field, len(fields))
		for field, i in fields {
			view.fields[i] = {strings.clone(field.name), strings.clone(field.value)}
		}
	}
	if scroll := nendo.scroll(nendo.id("EventDataScroll")); scroll.found {scroll.position^ = {}}
}

@(private = "file")
event_data_record :: proc(view: ^Event_Data_View) -> (Event_Data_Record, bool) {
	if view.source == .Linked {
		card := nev_cards[view.id]
		return {card.id, card.pubkey, card.content, u64(card.kind), card.tags}, card.raw != ""
	}
	record := timeline_record(view.id)
	if record == nil || record.deleted {return {}, false}
	return {
			view.id,
			string(record.sender),
			string(record.plaintext),
			record.kind,
			record.tags[:record.tags_len],
		},
		true
}

@(private)
event_data_json :: proc(view: ^Event_Data_View) -> string {
	if view.source == .Linked {return nev_cards[view.id].raw}
	if record := timeline_record(view.id); record != nil && !record.deleted {
		return record_json(record, context.temp_allocator)
	}
	return ""
}

@(private)
handle_event_data :: proc(ui: ^Ui_State) {
	if rl.IsKeyPressed(.ESCAPE) ||
	   clicked("EventDataClose") ||
	   (mouse_released() && !nendo.pointer_over(nendo.id("EventDataModal"))) {
		event_data_close(&ui.event_data)
	} else if clicked("EventDataCopy") {
		if text := event_data_json(&ui.event_data); text != "" {copy_text(ui, text, tr("Copied"))}
	}
}

@(private)
event_data_close :: proc(view: ^Event_Data_View) {
	for text in ([4]^string{&view.id, &view.title, &view.sender, &view.at}) {
		session_string_forget(text)
	}
	for &field in view.fields {
		session_string_forget(&field.name)
		session_string_forget(&field.value)
	}
	delete(view.fields)
	view.fields = nil
}

// Flat object fields keep their wire order, including repeated keys and exact numbers.
@(private)
event_data_fields :: proc(payload: string) -> []Event_Data_Field {
	if len(payload) > 2048 {return nil}
	content := strings.trim_left_space(payload)
	if content == "" || content[0] != '{' {return nil}
	p := json.make_parser_from_string(content, .JSON, true, context.temp_allocator)
	json.advance_token(&p)
	fields := make([dynamic]Event_Data_Field, context.temp_allocator)
	for p.curr_token.kind == .String && len(fields) < 24 {
		key := p.curr_token
		json.advance_token(&p)
		if !json.allow_token(&p, .Colon) {return nil}
		token := p.curr_token
		value := token.text
		#partial switch token.kind {
		case .String:
			decoded, err := json.unquote_string(token, .JSON, context.temp_allocator)
			if err != nil {return nil}
			value = decoded
		case .Integer, .Float, .Null, .True, .False:
		case:
			return nil
		}
		name, err := json.unquote_string(key, .JSON, context.temp_allocator)
		if err != nil {return nil}
		append(&fields, Event_Data_Field{name, value})
		json.advance_token(&p)
		if !json.allow_token(&p, .Comma) {break}
		if p.curr_token.kind != .String {return nil}
	}
	if !json.allow_token(&p, .Close_Brace) || p.curr_token.kind != .EOF {return nil}
	return fields[:]
}

@(private = "file")
event_data_text :: proc(value: string, width: f32, font, size: u16, color: nendo.Color) {
	text := value == "" ? "\"\"" : value
	MAX_BYTES :: 1024
	MAX_LINES :: 6
	cut := len(text) > MAX_BYTES
	if cut {text = text[:rune_snap(text, MAX_BYTES)]}
	lines := wrapped_lines(text, width, size, .Plain, plain_font = font)
	shown := min(len(lines), MAX_LINES)
	for line, i in lines[:shown] {
		part := text[line.start:line.end]
		if i == shown - 1 && (cut || shown < len(lines)) {part = fmt.tprintf("%s…", part)}
		nendo.text(
			part == "" ? " " : text_ellipsis(part, width, font, size),
			{font = font, size = size, color = color, wrap = .None},
		)
	}
}

@(private = "file")
event_tag_name :: proc(key: string) -> string {
	switch key {
	case "title", "subject":
		return tr("Title")
	case "description", "summary":
		return tr("Description")
	case "alt":
		return tr("Alt text")
	case "imeta":
		return tr("Media metadata")
	case:
		return ""
	}
}

@(private = "file")
event_field_row :: proc(id: nendo.Id, name: string, values: []string, width: f32) {
	GAP :: 12
	PAD :: 10
	inner := width - 2 * PAD
	wide := inner >= 320
	label_w := wide ? inner * 0.3 : inner
	value_w := wide ? inner - label_w - GAP : inner
	if nendo.box(id)(
	{
		width = nendo.fixed(width),
		direction = wide ? .Row : .Column,
		gap = wide ? GAP : 4,
		padding = nendo.pad(PAD),
		color = PLATE,
		radius = rr(7),
	},
	) {
		if nendo.box(nendo.id_local("Key"))({width = nendo.fixed(label_w), direction = .Column}) {
			event_data_text(name, label_w, FONT_MONO, 11, ACCENT)
		}
		if len(values) > 0 &&
		   nendo.box(nendo.id_local("Values"))(
		   {width = nendo.fixed(value_w), direction = .Column, gap = 3},
		   ) {
			for value in values {event_data_text(value, value_w, FONT_BODY, 13, TEXT)}
		}
	}
}

@(private)
event_data_modal :: proc(view: ^Event_Data_View) {
	id := nendo.id("EventDataModal")
	width := modal_w(id, 584)
	PAD :: 18
	inner := width - 2 * PAD - 6
	record, available := event_data_record(view)
	if nendo.box(id)(
	{
		width = nendo.fixed(width),
		height = nendo.fixed(modal_h(680)),
		direction = .Column,
		padding = nendo.pad(PAD),
		gap = 12,
		floating = {
			attach_to = .Root,
			z = 11,
			offset = {0, rise(id)},
			attach = {element = .Center_Center, parent = .Center_Center},
		},
		color = CARD,
		radius = rr(14),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if nendo.box(nendo.id("EventDataHead"))(
		{width = nendo.grow(), align = {y = .Center}, gap = 8},
		) {
			nendo.text(tr("Event data"), {font = FONT_TITLE, size = 20, color = TEXT})
			if nendo.box(nendo.id("EventDataHeadGap"))({width = nendo.grow()}) {}
			micro_button("EventDataClose", tr("Close"))
		}
		if nendo.box(nendo.id("EventDataScroll"))(
		{
			width = nendo.grow(),
			height = nendo.grow(),
			direction = .Column,
			gap = 8,
			padding = {right = 6},
			clip = {y = true, scroll = true},
		},
		) {
			if !available {
				nendo.text(
					tr("This event is no longer available."),
					{font = FONT_BODY, size = 13, color = TEXT_DIM},
				)
			} else {
				event_data_body(view, record, inner)
			}
		}
		scrollbar(nendo.id("EventDataScroll"), 12)
		if available {micro_button("EventDataCopy", tr("Copy JSON"))}
	}
}

@(private = "file")
event_data_body :: proc(view: ^Event_Data_View, record: Event_Data_Record, width: f32) {
	kind, icon, detail := event_kind_label(record.kind)
	if nendo.box(nendo.id("EventDataHero"))(
	{
		width = nendo.fixed(width),
		direction = .Column,
		gap = 7,
		padding = nendo.pad(14),
		color = mix_color(PLATE, ACCENT, 0.08),
		radius = rr(10),
		border = {color = mix_color(CARD_BORDER, ACCENT, 0.26), width = bw()},
	},
	) {
		if nendo.box(nendo.id("EventDataKind"))({align = {y = .Center}, gap = 8}) {
			nendo.text(icon, {font = FONT_ICON, size = 13, color = ACCENT})
			nendo.text(kind, {font = FONT_TITLE, size = 11, color = ACCENT, spacing = 1})
			if detail != "" {
				nendo.text(detail, {font = FONT_MONO, size = 10, color = TEXT_DIM})
			}
		}
		if view.title != "" {event_data_text(view.title, width - 28, FONT_TITLE, 19, TEXT)}
		event_data_text(view.sender, width - 28, FONT_TITLE, 13, TEXT)
		nendo.text(view.at, {font = FONT_BODY, size = 11, color = TEXT_DIM})
	}
	if content := record.content; content != "" {
		eyebrow(tr("CONTENT"))
		if len(view.fields) == 0 {
			if nendo.box(nendo.id("EventContent"))(
			{
				width = nendo.fixed(width),
				direction = .Column,
				padding = nendo.pad(10),
				color = PLATE,
				radius = rr(7),
			},
			) {
				event_data_text(content, width - 20, FONT_BODY, 13, TEXT)
			}
		} else {
			for field, i in view.fields {
				event_field_row(
					nendo.id("EventContentField", u32(i)),
					field.name,
					{field.value},
					width,
				)
			}
		}
	}
	if event_tag_count(record.tags) > 0 {
		eyebrow(tr("TAGS"))
		event_data_tags(record.tags, width)
	}
	eyebrow(tr("DETAILS"))
	event_field_row(nendo.id("EventDataId"), tr("Event id"), {record.id}, width)
	event_field_row(nendo.id("EventDataSender"), tr("Public key"), {record.author}, width)
}

@(private = "file")
event_data_tags :: proc(tags: Event_Tags, width: f32) {
	TAG_LIMIT :: 24
	count := event_tag_count(tags)
	for i in 0 ..< min(count, TAG_LIMIT) {
		tag := event_tag_at(tags, i)
		length := len(tag.c) + len(tag.json)
		if length == 0 {continue}
		key := event_tag_value(tag, 0)
		label := event_tag_name(key)
		if label != "" {label = fmt.tprintf("%s · %s", label, key)} else {label = key}
		VALUE_LIMIT :: 8
		values: [VALUE_LIMIT + 1]string
		n := min(length - 1, VALUE_LIMIT)
		for j in 0 ..< n {
			value := event_tag_value(tag, j + 1)
			if key == "imeta" {value = event_media_value(value)}
			values[j] = value
		}
		if length > VALUE_LIMIT + 1 {values[n] = "…"; n += 1}
		event_field_row(nendo.id("EventDataTag", u32(i)), label, values[:n], width)
	}
	if count > TAG_LIMIT {nendo.text("…", {font = FONT_BODY, size = 13, color = TEXT_DIM})}
}

@(private = "file")
event_media_value :: proc(value: string) -> string {
	sep := strings.index_byte(value, ' ')
	if sep < 1 {return value}
	field := value[:sep]
	switch field {
	case "url":
		field = tr("Source")
	case "m":
		field = tr("Format")
	case "dim":
		field = tr("Dimensions")
	case "duration":
		field = tr("Duration")
	case:
		return value
	}
	return fmt.tprintf("%s · %s", field, value[sep + 1:])
}
