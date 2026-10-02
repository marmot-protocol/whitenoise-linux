// Global literal search over locally stored history. The request and
// result pages survive closing the modal and jumping into a chat.
package main

import "core:fmt"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

GS_RECENT_MAX :: 8
GS_HITS_MAX :: 40

Gs_Hit :: struct {
	group:   string, // stable across chat-list reorderings
	chat:    int, // index into ui.chats
	msg_id:  string,
	title:   string, // chat title
	sender:  string, // display label, "you" for own
	snippet: string, // one flattened line around the match
	at:      string, // full date + time stamp
	when_at: u64, // sort key
}

// Case fold + latin-1 diacritic strip: "É" matches "e". A tiny fold
// table; anything past latin-1 passes through lowercased, a real
// Unicode normalizer is not worth vendoring here.
gs_fold :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for r in s {
		c := unicode.to_lower(r)
		switch c {
		case 'à' ..= 'å':
			c = 'a'
		case 'ç':
			c = 'c'
		case 'è' ..= 'ë':
			c = 'e'
		case 'ì' ..= 'ï':
			c = 'i'
		case 'ñ':
			c = 'n'
		case 'ò' ..= 'ö', 'ø':
			c = 'o'
		case 'ù' ..= 'ü':
			c = 'u'
		case 'ý', 'ÿ':
			c = 'y'
		}
		strings.write_rune(&b, c)
	}
	return strings.to_string(b)
}

// Ordered subsequence: every needle rune appears in the haystack in
// order ("wnl" hits "white noise linux").
gs_subseq :: proc(hay, needle: string) -> bool {
	rest := needle
	for r in hay {
		if len(rest) == 0 {
			return true
		}
		nr, w := utf8.decode_rune_in_string(rest)
		if r == nr {
			rest = rest[w:]
		}
	}
	return len(rest) == 0
}

// One line around the match: newlines flatten to spaces, long bodies
// clip to a window starting shortly before the hit rune.
// A profile token is never cut and counts as one rune of the window:
// it renders as a short mention chip, and a cut one would not parse.
gs_snippet :: proc(body: string, match_rune: int) -> string {
	SNIP_BEFORE :: 24
	SNIP_RUNES :: 90
	start := max(match_rune - SNIP_BEFORE, 0)
	b := strings.builder_make()
	if start > 0 {
		strings.write_string(&b, "…")
	}
	i, shown := 0, 0 // runes walked, window runes written
	for at := 0; at < len(body); {
		if shown >= SNIP_RUNES {
			strings.write_string(&b, "…")
			break
		}
		if body[at] == '@' || body[at] == 'n' {
			if end, _, ok := mention_at(body, at); ok {
				i += utf8.rune_count(body[at:end])
				if i > start {
					strings.write_string(&b, body[at:end])
					shown += 1
				}
				at = end
				continue
			}
		}
		r, w := utf8.decode_rune(body[at:])
		at += w
		i += 1
		if i <= start {
			continue
		}
		strings.write_rune(&b, r == '\n' || r == '\r' ? ' ' : r)
		shown += 1
	}
	return strings.to_string(b)
}

gs_free_hit :: proc(h: Gs_Hit) {
	delete(h.group)
	delete(h.msg_id)
	delete(h.title)
	delete(h.sender)
	delete(h.snippet)
	delete(h.at)
}

gs_clear_hits :: proc(ui: ^Ui_State) {
	for h in ui.gs_hits {
		gs_free_hit(h)
	}
	clear(&ui.gs_hits)
}

gs_check_account :: proc(ui: ^Ui_State) {
	if ui.gs_account == ui.account_ref {return}
	gs_clear_hits(ui)
	for chat in ui.gs_chats {chat_free(chat)}
	clear(&ui.gs_chats)
	for text in ([]^string{&ui.gs_group, &ui.gs_sender, &ui.gs_cursor_id, &ui.gs_cursor_group, &ui.gs_error, &ui.gs_account}) {delete(text^); text^ = ""}
	for buffer in ([]^[dynamic]u8{&ui.gs_input, &ui.gs_sender_input, &ui.gs_since, &ui.gs_until}) {clear(buffer)}
	ui.gs_more, ui.gs_loading, ui.gs_append, ui.gs_resume = false, false, false, false
	ui.gs_attachment, ui.gs_picker, ui.gs_cursor_at = 0, 0, 0
	if ui.gs_jump_pending {
		delete(ui.jump_id)
		ui.jump_id = ""
		ui.gs_jump_pending = false
	}
	ui.gs_account = strings.clone(ui.account_ref)
}

gs_open_modal :: proc(ui: ^Ui_State) {
	gs_check_account(ui)
	ui.gs_open = true
	ui.focus = .GSearch
	ui.gs_picker = 0
	if len(ui.gs_chats) == 0 {ui.gs_resume = true}
}

gs_close :: proc(ui: ^Ui_State) {
	ui.gs_open = false
	ui.focus = .Compose
	ui.gs_resume = ui.gs_loading
	ui.gs_loading = false
}

// UI dates are UTC calendar days. The end day includes all its seconds.
gs_day :: proc(text: string) -> (seconds: u64, valid: bool) {
	if len(text) != 10 || text[4] != '-' || text[7] != '-' {return 0, false}
	year, month, day := 0, 0, 0
	for c, i in transmute([]u8)text {
		if i == 4 || i == 7 {continue}
		if c < '0' || c > '9' {return 0, false}
		if i <
		   4 {year = year * 10 + int(c - '0')} else if i < 7 {month = month * 10 + int(c - '0')} else {day = day * 10 + int(c - '0')}
	}
	if year < 1970 || month < 1 || month > 12 {return 0, false}
	leap := year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
	months := [12]int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	if leap {months[1] = 29}
	if day < 1 || day > months[month - 1] {return 0, false}
	previous := year - 1
	days := 365 * (year - 1970) + previous / 4 - previous / 100 + previous / 400 - 477
	for i in 0 ..< month - 1 {days += months[i]}
	days += day - 1
	return u64(days) * 86400, true
}

gs_dates :: proc(ui: ^Ui_State) -> (since, until: u64, valid: bool) {
	valid = true
	if len(ui.gs_since) > 0 {
		since, valid = gs_day(string(ui.gs_since[:]))
		if !valid {return}
	}
	if len(ui.gs_until) > 0 {
		until, valid = gs_day(string(ui.gs_until[:]))
		if !valid {return}
		until += 86400
	}
	if len(ui.gs_since) > 0 && len(ui.gs_until) > 0 && since >= until {valid = false}
	return
}

gs_has_filters :: proc(ui: ^Ui_State) -> bool {
	return(
		ui.gs_group != "" ||
		ui.gs_sender != "" ||
		len(ui.gs_sender_input) > 0 ||
		len(ui.gs_since) > 0 ||
		len(ui.gs_until) > 0 ||
		ui.gs_attachment != 0 \
	)
}

gs_sender_key :: proc(ui: ^Ui_State) -> (key: string, valid: bool) {
	text := strings.trim_space(string(ui.gs_sender_input[:]))
	if text == "" {return "", true}
	if key := deeplink_hex(text);
	   key != "" {return strings.to_lower(key, context.temp_allocator), true}
	if strings.equal_fold(text, tr("you")) && ui.account_ref != "" {return ui.account_ref, true}
	for contact in ui.contacts {
		if strings.equal_fold(text, contact_label(ui, contact)) ||
		   strings.equal_fold(text, contact.name) ||
		   text == contact.npub {
			if key != "" && key != contact.id_hex {return "", false}
			key = contact.id_hex
		}
	}
	for member in ui.members {
		if strings.equal_fold(text, member.name) || text == member.npub {
			if key != "" && key != member.id_hex {return "", false}
			key = member.id_hex
		}
	}
	return key, key != ""
}

gs_remove_filter :: proc(ui: ^Ui_State, index: u32) {
	switch index {
	case 0:
		clear(&ui.gs_input)
	case 1:
		delete(ui.gs_group); ui.gs_group = ""
	case 2:
		delete(ui.gs_sender); ui.gs_sender = ""; clear(&ui.gs_sender_input)
	case 3:
		clear(&ui.gs_since)
	case 4:
		clear(&ui.gs_until)
	case 5:
		ui.gs_attachment = 0
	}
}

gs_refresh :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	gs_check_account(ui)
	gs_clear_hits(ui)
	ui.gs_more, ui.gs_append, ui.gs_resume = false, false, false
	ui.gs_cursor_at = 0
	delete(ui.gs_cursor_id); ui.gs_cursor_id = ""
	delete(ui.gs_cursor_group); ui.gs_cursor_group = ""
	delete(ui.gs_error); ui.gs_error = ""
	key, sender_valid := gs_sender_key(ui)
	delete(ui.gs_sender); ui.gs_sender = strings.clone(key)
	_, _, dates_valid := gs_dates(ui)
	ui.gs_loading = false
	if !sender_valid {
		ui.gs_error = strings.clone(
			tr("Choose a known sender or enter a 64-character hex public key."),
		)
		return
	}
	if !dates_valid {
		ui.gs_error = strings.clone(
			tr("Use valid YYYY-MM-DD UTC dates with the start on or before the end."),
		)
		return
	}
	if len(ui.gs_input) == 0 && !gs_has_filters(ui) {return}
	ui.gs_loading = true
	search_request(ui, client, .Global)
}

gs_next :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if ui.gs_loading || !ui.gs_more || ui.gs_error != "" {return}
	ui.gs_append, ui.gs_loading = true, true
	search_request(ui, client, .Global)
}

// Push the current query to the front of the persisted recents.
gs_remember :: proc(ui: ^Ui_State) {
	q := string(ui.gs_input[:])
	if len(q) == 0 {
		return
	}
	for recent, i in ui.prefs.recent_searches {
		if recent == q {
			delete(recent)
			ordered_remove(&ui.prefs.recent_searches, i)
			break
		}
	}
	inject_at(&ui.prefs.recent_searches, 0, strings.clone(q))
	for len(ui.prefs.recent_searches) > GS_RECENT_MAX {
		delete(pop(&ui.prefs.recent_searches))
	}
	save_settings(ui)
}

// Select the hit's chat and hand the message id to the frame loop,
// which centers the row once the new timeline has laid out.
gs_jump :: proc(ui: ^Ui_State, client: ^marmot.Client, group, msg_id: string) {
	id := strings.clone(msg_id)
	gs_close(ui)
	chat_index := -1
	for chat, i in ui.chats {if chat.group_id == group {chat_index = i; break}}
	if chat_index < 0 {
		gs_keep_open_chat(ui, group)
		for chat, i in ui.chats {if chat.group_id == group {chat_index = i; break}}
	}
	if chat_index < 0 {
		delete(id)
		return
	}
	select_chat(ui, client, chat_index)
	ui.page = .Chats
	delete(ui.jump_id)
	ui.jump_id = id
	ui.gs_jump_pending = true
	ui.scroll_pending = false
}

// Called before the frame loop consumes jump_id. Keep paging the existing
// timeline subscription until an older search result is in the layout.
gs_seek_jump :: proc(ui: ^Ui_State) -> bool {
	if !ui.gs_jump_pending {return false}
	for msg in ui.messages {
		if msg.id == ui.jump_id {
			if thread_cur(ui) != msg.thread_of {
				thread_clear(ui)
				if msg.thread_of != "" {thread_push(ui, msg.thread_of)}
				ui.scroll_pending = false
				return true // the next layout must render the selected thread
			}
			ui.gs_jump_pending = false
			return false
		}
	}
	if ui.jump_id == "" || !ui.tl_has_more || ui.timeline_error != "" || timeline_job == nil {
		ui.gs_jump_pending = false
		return false
	}
	timeline_paginate(ui, .Older, preserve_anchor = true)
	return true
}

GS_ATTACHMENT_LABELS := [6]string {
	N_("Any type"),
	N_("Images"),
	N_("Videos"),
	N_("Audio"),
	N_("Files"),
	N_("Any attachment"),
}

// An archived destination is navigation state, not an unarchive operation.
gs_keep_open_chat :: proc(ui: ^Ui_State, group: string) {
	if group == "" {return}
	for chat in ui.chats {if chat.group_id == group {return}}
	for chat in ui.gs_chats {
		if chat.group_id != group {continue}
		copy := chat_clone(chat)
		copy.search_only = true
		append(&ui.chats, copy)
		return
	}
}

gs_chat_choices :: proc(ui: ^Ui_State) -> []Chat_Row_Ui {
	return len(ui.gs_chats) > 0 ? ui.gs_chats[:] : ui.chats[:]
}

gs_chat_label :: proc(ui: ^Ui_State) -> string {
	if ui.gs_group == "" {return tr("All chats")}
	for chat in gs_chat_choices(ui) {if chat.group_id == ui.gs_group {return chat.title}}
	return ui.gs_group
}

gs_filter_button :: proc(id, label: string, active: bool) {
	if clay.UI(clay.ID(id))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(30)},
			padding = {left = 10, right = 10},
			childGap = 6,
			childAlignment = {y = .Center},
		},
		backgroundColor = active ? SELECTED : hovered() ? HOVER : ROW_BG,
		cornerRadius = rr(6),
		border = {color = active ? ACCENT : FIELD_BORDER, width = bw()},
	},
	) {
		if clay.UI(clay.ID_LOCAL("GsFilterLabel"))(
		{layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}},
		) {
			clay.Text(
				label,
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT, wrapMode = .None},
			)
		}
		clay.Text("⌄", {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
		if hovered() {cursor_raise(.Pointer)}
	}
}

gs_chip :: proc(index: u32, label: string) {
	if clay.UI(clay.ID("GsChip", index))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(26)},
			padding = {left = 8, right = 8},
			childGap = 6,
			childAlignment = {y = .Center},
		},
		backgroundColor = SELECTED,
		cornerRadius = rr(13),
	},
	) {
		if clay.UI(clay.ID_LOCAL("GsChipLabel"))(
		{layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}},
		) {
			clay.Text(
				label,
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT, wrapMode = .None},
			)
		}
		clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 9, textColor = ACCENT})
		if hovered() {tooltip(label); cursor_raise(.Pointer)}
	}
}

gs_option :: proc(ui: ^Ui_State, index: int) -> (label, key: string) {
	switch ui.gs_picker {
	case 1:
		if index == 0 {return tr("All chats"), ""}
		chats := gs_chat_choices(ui)
		return chats[index - 1].title, chats[index - 1].group_id
	case 2:
		if index == 0 {return tr("Any sender"), ""}
		if index == 1 {return tr("you"), ui.account_ref}
		contact := ui.contacts[index - 2]
		return fmt.tprintf("%s · %s", contact_label(ui, contact), npub_tail(contact.npub)),
			contact.id_hex
	case 3:
		return tr(GS_ATTACHMENT_LABELS[index]), ""
	}
	return
}

gs_filter_options :: proc(ui: ^Ui_State) {
	if ui.gs_picker == 0 {return}
	count :=
		ui.gs_picker == 1 ? len(gs_chat_choices(ui)) + 1 : ui.gs_picker == 2 ? len(ui.contacts) + 2 : 6
	if clay.UI(clay.ID("GsOptions"))(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(min(420, modal_w(clay.ID("GsModal"), 560) - 40)),
				height = clay.SizingFixed(f32(min(count, 6) * 32)),
			},
			layoutDirection = .TopToBottom,
		},
		backgroundColor = CARD,
		border = {color = CARD_BORDER, width = bw()},
		cornerRadius = rr(8),
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		floating = {
			attachTo = .ElementWithId,
			parentId = clay.ID(ui.gs_picker == 2 ? "GsSenderRow" : "GsFilters").id,
			zIndex = 15,
			offset = {0, 4},
			attachment = {element = .LeftTop, parent = .LeftBottom},
		},
	},
	) {
		data := clay.GetScrollContainerData(clay.ID("GsOptions"))
		first := data.found ? clamp(int(-data.scrollPosition.y / 32), 0, count) : 0
		last := min(first + 8, count)
		if clay.UI(clay.ID("GsOptionsBefore"))(
		{layout = {sizing = {height = clay.SizingFixed(f32(first * 32))}}},
		) {}
		for i in first ..< last {
			label, key := gs_option(ui, i)
			selected :=
				ui.gs_picker == 1 ? ui.gs_group == key : ui.gs_picker == 2 ? ui.gs_sender == key : int(ui.gs_attachment) == i
			if clay.UI(clay.ID("GsOption", u32(i)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(32)},
					padding = {left = 10, right = 10},
					childGap = 8,
					childAlignment = {y = .Center},
				},
				backgroundColor = hovered() ? HOVER : {},
				clip = {horizontal = true},
			},
			) {
				clay.Text(
					selected ? ICON_CHECK : " ",
					{fontId = FONT_ICON, fontSize = 10, textColor = ACCENT},
				)
				clay.Text(
					label,
					{fontId = FONT_BODY, fontSize = 12, textColor = TEXT, wrapMode = .None},
				)
				if hovered() {cursor_raise(.Pointer)}
			}
		}
		if clay.UI(clay.ID("GsOptionsAfter"))(
		{layout = {sizing = {height = clay.SizingFixed(f32((count - last) * 32))}}},
		) {}
	}
	scrollbar(clay.ID("GsOptions"), 16)
}

gsearch_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("GsModal"))(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(modal_w(clay.ID("GsModal"), 560)),
				height = clay.SizingFixed(modal_h(660)),
			},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(20),
			childGap = 8,
		},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {
			attachTo = .Root,
			zIndex = 13,
			offset = {0, rise(clay.ID("GsModal"))},
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
	},
	) {
		if clay.UI(clay.ID("GsHead"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}},
		) {
			clay.Text(
				tr("Search all chats"),
				{fontId = FONT_TITLE, fontSize = 20, textColor = TEXT},
			)
			if clay.UI(clay.ID("GsHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("GsClose"))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(26), height = clay.SizingFixed(26)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(7),
			},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}

		clay.Text(
			tr(
				"Searches only history stored on this device. Older or unsynced messages may be missing.",
			),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
		)
		if ui.gs_error != "" {
			clay.Text(ui.gs_error, {fontId = FONT_BODY, fontSize = 12, textColor = DANGER})
			settings_button("GsRetry", tr("Search again"))
		} else if ui.gs_loading {
			clay.Text(
				ui.gs_append ? tr("Loading more matches from local history…") : tr("Searching local history…"),
				{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
			)
			busy_bar("GsBusy")
		}
		if clay.UI(clay.ID("GsBody"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				childGap = 8,
				padding = {right = 6},
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			if clay.UI(clay.ID("GsInput"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(36)},
					padding = {left = 12, right = 12},
					childGap = 8,
					childAlignment = {y = .Center},
				},
				backgroundColor = ROW_BG,
				cornerRadius = rr(8),
				border = {color = ui.focus == .GSearch ? ACCENT : FIELD_BORDER, width = bw()},
			},
			) {
				clay.Text(ICON_SEARCH, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_LO})
				field_text(
					ui,
					"GsInput",
					&ui.gs_input,
					tr("Literal message text"),
					ui.focus == .GSearch,
					13,
					TEXT_LO,
				)
			}

			if clay.UI(clay.ID("GsFilters"))(
			{layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}},
			) {
				gs_filter_button("GsChat", gs_chat_label(ui), ui.gs_group != "")
				gs_filter_button(
					"GsAttachment",
					tr(GS_ATTACHMENT_LABELS[ui.gs_attachment]),
					ui.gs_attachment != 0,
				)
			}
			if clay.UI(clay.ID("GsSenderRow"))(
			{layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}},
			) {
				settings_input(
					ui,
					"GsSenderInput",
					&ui.gs_sender_input,
					tr("Sender name or hex public key"),
					ui.focus == .GSearch_Sender,
				)
				if clay.UI(clay.ID("GsKnownSenderBox"))(
				{layout = {sizing = {width = clay.SizingFixed(120)}}},
				) {
					gs_filter_button("GsSender", tr("Known senders"), ui.gs_picker == 2)
				}
			}
			if clay.UI(clay.ID("GsDates"))(
			{layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}},
			) {
				if clay.UI(clay.ID("GsStartCol"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						layoutDirection = .TopToBottom,
						childGap = 3,
					},
				},
				) {
					clay.Text(
						tr("Start day (UTC)"),
						{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
					)
					settings_input(
						ui,
						"GsSince",
						&ui.gs_since,
						"YYYY-MM-DD",
						ui.focus == .GSearch_Since,
					)
				}
				if clay.UI(clay.ID("GsEndCol"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						layoutDirection = .TopToBottom,
						childGap = 3,
					},
				},
				) {
					clay.Text(
						tr("End day (UTC, inclusive)"),
						{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
					)
					settings_input(
						ui,
						"GsUntil",
						&ui.gs_until,
						"YYYY-MM-DD",
						ui.focus == .GSearch_Until,
					)
				}
			}
			for row in 0 ..< 2 {
				present :=
					row == 0 ? len(ui.gs_input) > 0 || ui.gs_group != "" || len(ui.gs_sender_input) > 0 : len(ui.gs_since) > 0 || len(ui.gs_until) > 0 || ui.gs_attachment != 0
				if !present {continue}
				if clay.UI(clay.ID("GsChips", u32(row)))(
				{layout = {sizing = {width = clay.SizingGrow()}, childGap = 6}},
				) {
					if row == 0 {
						if len(ui.gs_input) >
						   0 {gs_chip(0, fmt.tprintf(tr("Text: %s"), string(ui.gs_input[:])))}
						if ui.gs_group !=
						   "" {gs_chip(1, fmt.tprintf(tr("Chat: %s"), gs_chat_label(ui)))}
						if len(ui.gs_sender_input) >
						   0 {gs_chip(2, fmt.tprintf(tr("Sender: %s"), string(ui.gs_sender_input[:])))}
					} else {
						if len(ui.gs_since) >
						   0 {gs_chip(3, fmt.tprintf(tr("From: %s"), string(ui.gs_since[:])))}
						if len(ui.gs_until) >
						   0 {gs_chip(4, fmt.tprintf(tr("Through: %s"), string(ui.gs_until[:])))}
						if ui.gs_attachment !=
						   0 {gs_chip(5, tr(GS_ATTACHMENT_LABELS[ui.gs_attachment]))}
					}
				}
			}

			empty := len(ui.gs_input) == 0 && !gs_has_filters(ui)
			if empty && len(ui.prefs.recent_searches) > 0 {
				if clay.UI(clay.ID("GsRecentHead"))({layout = {padding = {left = 4, top = 2}}}) {
					clay.Text(
						tr("RECENT"),
						{
							fontId = FONT_MONO,
							fontSize = 11,
							textColor = TEXT_LO,
							letterSpacing = 2,
						},
					)
				}
				for q, i in ui.prefs.recent_searches {
					if clay.UI(clay.ID("GsRecent", u32(i)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							padding = {left = 10, right = 10, top = 8, bottom = 8},
							childGap = 10,
							childAlignment = {y = .Center},
						},
						backgroundColor = hovered() ? HOVER : {},
						cornerRadius = rr(8),
					},
					) {
						clay.Text(
							ICON_SEARCH,
							{fontId = FONT_ICON, fontSize = 11, textColor = TEXT_LO},
						)
						clay.Text(q, {fontId = FONT_BODY, fontSize = 13, textColor = TEXT})
					}
				}
			} else if empty {
				clay.Text(
					tr("Type to search all chats."),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
				)
			} else if !ui.gs_loading && ui.gs_error == "" && len(ui.gs_hits) == 0 {
				clay.Text(
					tr("No matches."),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
				)
			}

			if clay.UI(clay.ID("GsList"))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow(),
						height = clay.SizingFit({min = 44, max = 300}),
					},
					layoutDirection = .TopToBottom,
					childGap = 2,
				},
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
			},
			) {
				for hit, i in ui.gs_hits {
					// Each hit lands a beat after the one above it.
					arrived := stagger(clay.ID("GsList").id, i)
					if clay.UI(clay.ID("GsHit", u32(i)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							layoutDirection = .TopToBottom,
							padding = clay.PaddingAll(10),
							childGap = 3,
						},
						backgroundColor = fade(hovered() ? HOVER : {}, arrived),
						cornerRadius = rr(8),
					},
					) {
						if clay.UI(clay.ID("GsHitTop", u32(i)))(
						{
							layout = {
								sizing = {width = clay.SizingGrow()},
								childGap = 8,
								childAlignment = {y = .Center},
							},
						},
						) {
							clay.Text(
								hit.title,
								{
									fontId = FONT_TITLE,
									fontSize = 13,
									textColor = fade(TEXT, arrived),
								},
							)
							clay.Text(
								hit.sender,
								{
									fontId = FONT_BODY,
									fontSize = 12,
									textColor = fade(TEXT_DIM, arrived),
								},
							)
							if clay.UI(clay.ID("GsHitGap", u32(i)))(
							{layout = {sizing = {width = clay.SizingGrow()}}},
							) {}
							clay.Text(
								hit.at,
								{
									fontId = FONT_MONO,
									fontSize = 10,
									textColor = fade(TEXT_LO, arrived),
								},
							)
						}
						clay.Text(
							hit.snippet,
							{
								fontId = FONT_BODY,
								fontSize = 12,
								textColor = fade(TEXT_DIM, arrived),
							},
						)
					}
				}
			}
			scrollbar(clay.ID("GsList"), 14) // the modal floats at 13
			if ui.gs_more &&
			   !ui.gs_loading &&
			   ui.gs_error == "" {settings_button("GsMore", tr("More results"))}
		}
		scrollbar(clay.ID("GsBody"), 14)
		gs_filter_options(ui)
	}
}

// Input while the modal is open; anything outside dismisses it.
handle_gsearch :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if rl.IsKeyPressed(.ESCAPE) {
		if ui.gs_picker != 0 {ui.gs_picker = 0} else {gs_close(ui)}
		return
	}
	if ui.gs_resume {
		ui.gs_resume = false
		ui.gs_loading = true
		search_request(ui, client, .Global)
	}
	if ui.gs_picker != 0 {
		if mouse_released() {
			count :=
				ui.gs_picker == 1 ? len(gs_chat_choices(ui)) + 1 : ui.gs_picker == 2 ? len(ui.contacts) + 2 : 6
			for i in 0 ..< count {
				if !clay.PointerOver(clay.ID("GsOption", u32(i))) {continue}
				_, key := gs_option(ui, i)
				switch ui.gs_picker {
				case 1:
					delete(ui.gs_group); ui.gs_group = strings.clone(key)
				case 2:
					ed_set(ui, &ui.gs_sender_input, key)
				case 3:
					ui.gs_attachment = u32(i)
				}
				ui.gs_picker = 0
				gs_refresh(ui, client)
				return
			}
			ui.gs_picker = 0
		}
		return // floating options must not click or type into fields below
	}

	pasted := false
	if field_mouse(
		ui,
		&ui.gs_input,
		"GsInput",
	) {ui.focus = .GSearch; pasted = rl.IsMouseButtonPressed(.MIDDLE)}
	if field_mouse(
		ui,
		&ui.gs_sender_input,
		"GsSenderInput",
		14,
	) {ui.focus = .GSearch_Sender; pasted = rl.IsMouseButtonPressed(.MIDDLE)}
	if field_mouse(
		ui,
		&ui.gs_since,
		"GsSince",
		14,
	) {ui.focus = .GSearch_Since; pasted = rl.IsMouseButtonPressed(.MIDDLE)}
	if field_mouse(
		ui,
		&ui.gs_until,
		"GsUntil",
		14,
	) {ui.focus = .GSearch_Until; pasted = rl.IsMouseButtonPressed(.MIDDLE)}
	buf: ^[dynamic]u8
	#partial switch ui.focus {
	case .GSearch:
		buf = &ui.gs_input
	case .GSearch_Sender:
		buf = &ui.gs_sender_input
	case .GSearch_Since:
		buf = &ui.gs_since
	case .GSearch_Until:
		buf = &ui.gs_until
	}
	if buf != nil {
		before := strings.clone(string(buf[:]), context.temp_allocator)
		edit_text(ui, buf)
		if pasted || string(buf[:]) != before {gs_refresh(ui, client)}
	}
	if rl.IsKeyPressed(.ENTER) {
		#partial switch ui.focus {
		case .GSearch_Sender:
			ui.focus = .GSearch_Since
		case .GSearch_Since:
			ui.focus = .GSearch_Until
		case .GSearch_Until:
			ui.focus = .GSearch
		case .GSearch:
			if !ui.gs_loading && ui.gs_error == "" && len(ui.gs_hits) > 0 {
				gs_remember(ui)
				gs_jump(ui, client, ui.gs_hits[0].group, ui.gs_hits[0].msg_id)
				return
			}
		}
	}

	if !mouse_released() {
		return
	}
	for i in 0 ..< 6 {
		if clay.PointerOver(clay.ID("GsChip", u32(i))) {
			gs_remove_filter(ui, u32(i))
			gs_refresh(ui, client)
			return
		}
	}
	if clicked("GsChat") {ui.gs_picker = 1; return}
	if clicked("GsSender") {ui.gs_picker = 2; return}
	if clicked("GsAttachment") {ui.gs_picker = 3; return}
	if clicked("GsMore") {gs_next(ui, client); return}
	if clicked("GsRetry") {gs_refresh(ui, client); return}
	if len(ui.gs_input) == 0 && !gs_has_filters(ui) {
		for q, i in ui.prefs.recent_searches {
			if clay.PointerOver(clay.ID("GsRecent", u32(i))) {
				ed_set(ui, &ui.gs_input, q)
				ui.focus = .GSearch
				gs_refresh(ui, client)
				return
			}
		}
	}
	for hit, i in ui.gs_hits {
		if clay.PointerOver(clay.ID("GsHit", u32(i))) {
			gs_remember(ui)
			gs_jump(ui, client, hit.group, hit.msg_id)
			return
		}
	}
	if clicked("GsClose") || !clay.PointerOver(clay.ID("GsModal")) {
		gs_close(ui)
	}
}
