// Global cross-chat search, the slint global-search modal: Ctrl+K or
// the rail-head search chip opens a centered modal; a worker searches
// cached recent timelines and lists hit cards that jump to the
// message. Matching folds case and latin-1 diacritics over the latest
// GS_FETCH_LIMIT messages per chat: a folded-substring hit ranks
// above a folded-subsequence ("fuzzy") hit, both newest first. An
// empty field shows the persisted recent searches.
package main

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

GS_RECENT_MAX :: 8
GS_HITS_MAX :: 40
GS_FETCH_LIMIT :: 100 // per-chat page, same depth as the open timeline

Gs_Hit :: struct {
	group: string, // stable across chat-list reorderings
	chat:    int, // index into ui.chats
	msg_id:  string,
	title:   string, // chat title
	sender:  string, // display label, "you" for own
	snippet: string, // one flattened line around the match
	at:      string, // full date + time stamp
	when_at: u64, // sort key
	exact:   bool, // substring tier, above subsequence
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
gs_snippet :: proc(body: string, match_rune: int) -> string {
	SNIP_BEFORE :: 24
	SNIP_RUNES :: 90
	start := max(match_rune - SNIP_BEFORE, 0)
	b := strings.builder_make()
	if start > 0 {
		strings.write_string(&b, "…")
	}
	i := 0
	for r in body {
		defer i += 1
		if i < start {
			continue
		}
		if i >= start + SNIP_RUNES {
			strings.write_string(&b, "…")
			break
		}
		strings.write_rune(&b, r == '\n' || r == '\r' ? ' ' : r)
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

gs_open_modal :: proc(ui: ^Ui_State) {
	ui.gs_open = true
	ui.focus = .GSearch
	clear(&ui.gs_input)
	gs_clear_hits(ui)
}

gs_close :: proc(ui: ^Ui_State) {
	ui.gs_open = false
	ui.focus = .Compose
	// The hits are freed by the next open, not here: the modal is still
	// on screen animating out and would empty in front of the user.
}

gs_refresh :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	gs_clear_hits(ui)
	search_request(ui, client, .Global)
}

// Push the current query to the front of the persisted recents.
gs_remember :: proc(ui: ^Ui_State) {
	q := strings.trim_space(string(ui.gs_input[:]))
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
	for chat, i in ui.chats { if chat.group_id == group { chat_index = i; break } }
	if chat_index < 0 {
		delete(id)
		return
	}
	select_chat(ui, client, chat_index)
	delete(ui.jump_id)
	ui.jump_id = id
}

gsearch_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("GsModal"))(
	{
		layout = {sizing = {width = clay.SizingFixed(modal_w(clay.ID("GsModal"), 560))}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 12},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {attachTo = .Root, zIndex = 13, offset = {0, rise(clay.ID("GsModal"))}, attachment = {element = .CenterCenter, parent = .CenterCenter}},
	},
	) {
		if clay.UI(clay.ID("GsHead"))({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}}) {
			clay.Text("Search all chats", {fontId = FONT_TITLE, fontSize = 20, textColor = TEXT})
			if clay.UI(clay.ID("GsHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("GsClose"))(
			{layout = {sizing = {width = clay.SizingFixed(26), height = clay.SizingFixed(26)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(7)},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}

		if clay.UI(clay.ID("GsInput"))(
		{
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(36)}, padding = {left = 12, right = 12}, childGap = 8, childAlignment = {y = .Center}},
			backgroundColor = ROW_BG,
			cornerRadius = rr(8),
			border = {color = ui.focus == .GSearch ? ACCENT : FIELD_BORDER, width = bw()},
		},
		) {
			clay.Text(ICON_SEARCH, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_LO})
			field_text(ui, "GsInput", &ui.gs_input, "Search messages", ui.focus == .GSearch, 13, TEXT_LO)
		}

		empty := len(strings.trim_space(string(ui.gs_input[:]))) == 0
		if empty && len(ui.prefs.recent_searches) > 0 {
			if clay.UI(clay.ID("GsRecentHead"))({layout = {padding = {left = 4, top = 2}}}) {
				clay.Text("RECENT", {fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO, letterSpacing = 2})
			}
			for q, i in ui.prefs.recent_searches {
				if clay.UI(clay.ID("GsRecent", u32(i)))(
				{
					layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 10, right = 10, top = 8, bottom = 8}, childGap = 10, childAlignment = {y = .Center}},
					backgroundColor = hovered() ? HOVER : {},
					cornerRadius = rr(8),
				},
				) {
					clay.Text(ICON_SEARCH, {fontId = FONT_ICON, fontSize = 11, textColor = TEXT_LO})
					clay.Text(q, {fontId = FONT_BODY, fontSize = 13, textColor = TEXT})
				}
			}
		} else if empty {
			clay.Text("Type to search all chats.", {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
		} else if search_pending[.Global] != nil || (search_active[.Global] != nil && search_active[.Global].worker != nil) {
			clay.Text(tr("Searching…"), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
		} else if len(ui.gs_hits) == 0 {
			clay.Text("No matches.", {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
		}

		if clay.UI(clay.ID("GsList"))(
		{
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFit({max = 400})}, layoutDirection = .TopToBottom, childGap = 2},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			for hit, i in ui.gs_hits {
				// Each hit lands a beat after the one above it.
				arrived := stagger(clay.ID("GsList").id, i)
				if clay.UI(clay.ID("GsHit", u32(i)))(
				{
					layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(10), childGap = 3},
					backgroundColor = fade(hovered() ? HOVER : {}, arrived),
					cornerRadius = rr(8),
				},
				) {
					if clay.UI(clay.ID("GsHitTop", u32(i)))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 8, childAlignment = {y = .Center}}}) {
						clay.Text(hit.title, {fontId = FONT_TITLE, fontSize = 13, textColor = fade(TEXT, arrived)})
						clay.Text(hit.sender, {fontId = FONT_BODY, fontSize = 12, textColor = fade(TEXT_DIM, arrived)})
						if clay.UI(clay.ID("GsHitGap", u32(i)))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
						clay.Text(hit.at, {fontId = FONT_MONO, fontSize = 10, textColor = fade(TEXT_LO, arrived)})
					}
					clay.Text(hit.snippet, {fontId = FONT_BODY, fontSize = 12, textColor = fade(TEXT_DIM, arrived)})
				}
			}
		}
		scrollbar(clay.ID("GsList"), 14) // the modal floats at 13
	}
}

// Input while the modal is open; anything outside dismisses it.
handle_gsearch :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if rl.IsKeyPressed(.ESCAPE) {
		gs_close(ui)
		return
	}

	before := strings.clone(string(ui.gs_input[:]), context.temp_allocator)
	edit_text(ui, &ui.gs_input)
	if string(ui.gs_input[:]) != before {
		gs_refresh(ui, client)
	}

	// Enter jumps to the top hit.
	if rl.IsKeyPressed(.ENTER) && len(ui.gs_hits) > 0 {
		gs_remember(ui)
		gs_jump(ui, client, ui.gs_hits[0].group, ui.gs_hits[0].msg_id)
		return
	}

	if field_mouse(ui, &ui.gs_input, "GsInput") {
		ui.focus = .GSearch
		return
	}
	if !mouse_released() {
		return
	}
	if len(strings.trim_space(string(ui.gs_input[:]))) == 0 {
		for q, i in ui.prefs.recent_searches {
			if clay.PointerOver(clay.ID("GsRecent", u32(i))) {
				ed_set(ui, &ui.gs_input, q)
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
