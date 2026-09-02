// Mentions, the slint mentions.rs port: composer @-autocomplete over
// the chat's members, inline mention chips in bodies, and the mentions
// inbox behind the chat-header bell.
//
// Wire format matches the slint app so the two interoperate: the
// composer inserts "@npub1... " (at + bare npub + space); bodies
// recognize npub1/nprofile1 tokens bare, "@"-prefixed, or "nostr:"-
// prefixed; the inbox counts incoming messages whose current text
// carries a token resolving to the local account.
package main

import "core:encoding/hex"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:text/edit"
import "core:unicode"
import "core:unicode/utf8"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

// Set once in main. Mention chips resolve names during render, where
// no ui/client parameter reaches (render_segs is shared plumbing).
g_ui: ^Ui_State
g_client: ^marmot.Client

// Mention chip under the pointer (account hex), rebound every build.
mention_hover: string

// ── token parsing ───────────────────────────────────────────────────

// npub/nprofile bech32 → pubkey hex ("" when undecodable). nprofile
// wraps TLV records; type 0 is the 32-byte pubkey.
mention_hex :: proc(tok: string) -> string {
	hrp, data, ok := bech32_decode(tok)
	if !ok {
		return ""
	}
	if hrp == "npub" && len(data) == 32 {
		return string(hex.encode(data, context.temp_allocator))
	}
	if hrp == "nprofile" {
		i := 0
		for i + 2 <= len(data) {
			t := data[i]
			l := int(data[i + 1])
			i += 2
			if i + l > len(data) {
				break
			}
			if t == 0 && l == 32 {
				return string(hex.encode(data[i:i + 32], context.temp_allocator))
			}
			i += l
		}
	}
	return ""
}

// Parse a mention token at text[i:]: optional "@", optional "nostr:",
// then npub1/nprofile1 plus its bech32 data run. end is the byte past
// the token; hx the pubkey hex (temp-allocated).
mention_at :: proc(text: string, i: int) -> (end: int, hx: string, ok: bool) {
	j := i
	if j < len(text) && text[j] == '@' {
		j += 1
	}
	if strings.has_prefix(text[j:], "nostr:") {
		j += 6
	}
	start := j
	if strings.has_prefix(text[j:], "npub1") {
		j += 5
	} else if strings.has_prefix(text[j:], "nprofile1") {
		j += 9
	} else {
		return 0, "", false
	}
	for j < len(text) && strings.index_byte(BECH32_CHARSET, text[j]) >= 0 {
		j += 1
	}
	hx = mention_hex(text[start:j])
	if len(hx) == 0 {
		return 0, "", false
	}
	return j, hx, true
}

// Chip label: local nickname first, then the kind-0 name, then the
// truncated hex. profile_info memoizes, so this is a map read per call.
mention_label :: proc(hx: string) -> string {
	if g_ui != nil {
		if nick, has := g_ui.nicknames[hx]; has && len(nick) > 0 {
			return nick
		}
	}
	if g_client != nil {
		info := profile_info(g_client, hx)
		if len(info.name) > 0 {
			return info.name
		}
	}
	return short_hex(hx)
}

// True when text carries a token resolving to my_hex.
text_mentions_me :: proc(text: string, my_hex: string) -> bool {
	for i := 0; i + 5 <= len(text); i += 1 {
		if text[i] != 'n' && text[i] != '@' {
			continue
		}
		if end, hx, ok := mention_at(text, i); ok {
			if hx == my_hex {
				return true
			}
			i = end - 1
		}
	}
	return false
}

// Click a mention chip: own account routes to the profile page, peers
// open the popup (same routing as the avatar click).
handle_mention_click :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if mention_hover == "" || !mouse_released() {
		return
	}
	hx := mention_hover
	mention_hover = ""
	if hx == ui.account_ref {
		ui.page = .Profile
		load_profile(client, ui)
		return
	}
	info := profile_info(client, hx)
	open_peer(ui, client, hx, len(info.name) > 0 ? info.name : short_hex(hx), info.pic_url)
}

// ── composer @-autocomplete ─────────────────────────────────────────

MENTION_CANDS_MAX :: 8

// Find an active "@token" ending at the caret: the "@" sits at the
// start or after whitespace, no whitespace between it and the caret.
detect_mention :: proc(text: string, cursor: int) -> (at: int, query: string, ok: bool) {
	if cursor > len(text) {
		return
	}
	prefix := text[:cursor]
	i := len(prefix)
	for i > 0 {
		r, w := utf8.decode_last_rune_in_string(prefix[:i])
		if r == '@' {
			pos := i - w
			if pos > 0 {
				pr, _ := utf8.decode_last_rune_in_string(prefix[:pos])
				if !unicode.is_space(pr) {
					return
				}
			}
			return pos, prefix[i:], true
		}
		if unicode.is_space(r) {
			return
		}
		i -= w
	}
	return
}

// Rebuild the candidate list from the caret's "@token". Members load
// lazily on the first "@" in a chat.
mention_update :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	ui.mention_active = false
	if ui.focus != .Compose || ui.ed_target != &ui.compose {
		return
	}
	text := string(ui.compose[:])
	_, _, head := field_sel(ui, &ui.compose)
	at, query, ok := detect_mention(text, head)
	if !ok {
		ui.mention_dismissed = -1
		return
	}
	if ui.mention_dismissed == at {
		return
	}
	if len(ui.members) == 0 {
		load_members(client, ui)
	}
	if ui.mention_at_b != at {
		ui.mention_sel = 0
		ui.mention_at_b = at
	}

	clear(&ui.mention_cands)
	q := strings.to_lower(query, context.temp_allocator)
	for member, i in ui.members {
		if len(q) > 0 && !strings.contains(strings.to_lower(member.name, context.temp_allocator), q) {
			np := hex_npub(member.id_hex)
			defer delete(np)
			if !strings.contains(np, q) {
				continue
			}
		}
		append(&ui.mention_cands, i)
		if len(ui.mention_cands) >= MENTION_CANDS_MAX {
			break
		}
	}
	if len(ui.mention_cands) == 0 {
		return
	}
	ui.mention_sel = clamp(ui.mention_sel, 0, len(ui.mention_cands) - 1)
	ui.mention_active = true
}

// Splice "@npub1... " over the active "@token", caret after the space.
mention_commit :: proc(ui: ^Ui_State, index: int) {
	ui.mention_active = false
	if index < 0 || index >= len(ui.mention_cands) {
		return
	}
	member := ui.members[ui.mention_cands[index]]
	np := hex_npub(member.id_hex)
	defer delete(np)
	if len(np) == 0 {
		return
	}
	_, _, head := field_sel(ui, &ui.compose)
	at := ui.mention_at_b
	if at > head || head > len(ui.compose) {
		return
	}
	ed_begin(ui, &ui.compose)
	ui.ed.selection = {at, head}
	edit.input_text(&ui.ed, fmt.tprintf("@%s ", np))
	ed_end(ui, &ui.compose)
}

// Keys and clicks while the popover is open. Returns true when the
// frame's Escape/Enter/click was consumed (the caller stops there so
// Enter can't also send). Runs after edit_text, so typed characters
// already narrowed the query.
handle_mention :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	mention_update(ui, client)
	if !ui.mention_active {
		return false
	}
	n := len(ui.mention_cands)
	if rl.IsKeyPressed(.ESCAPE) {
		ui.mention_dismissed = ui.mention_at_b
		ui.mention_active = false
		return true
	}
	if key_hit(.UP) {
		ui.mention_sel = (ui.mention_sel + n - 1) % n
	}
	if key_hit(.DOWN) {
		ui.mention_sel = (ui.mention_sel + 1) % n
	}
	if rl.IsKeyPressed(.ENTER) {
		mention_commit(ui, ui.mention_sel)
		return true
	}
	if mouse_released() {
		for _, i in ui.mention_cands {
			if clay.PointerOver(clay.ID("MentionCand", u32(i))) {
				mention_commit(ui, i)
				return true
			}
		}
	}
	return false
}

// The popover, floated above the composer. Declared inside ComposeBox
// so attachTo .Parent resolves without a forward id reference.
mention_popover :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("MentionPop"))(
	{
		layout = {sizing = {width = clay.SizingFixed(280)}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(6), childGap = 2},
		backgroundColor = CARD,
		cornerRadius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
		floating = {attachTo = .Parent, zIndex = 12, offset = {0, -8 - rise(clay.ID("MentionPop"))}, attachment = {element = .LeftBottom, parent = .LeftTop}},
	},
	) {
		for mi, i in ui.mention_cands {
			member := ui.members[mi]
			sel := i == ui.mention_sel
			if clay.UI(clay.ID("MentionCand", u32(i)))(
			{layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(6), childGap = 8, childAlignment = {y = .Center}}, backgroundColor = sel ? SELECTED : (hovered() ? HOVER : {}), cornerRadius = rr(8)},
			) {
				avatar("MentionCandAv", u32(i), member.id_hex, member.name, 22, url_pic(member.pic_url))
				clay.Text(member.name, {fontId = FONT_BODY, fontSize = 13, textColor = sel ? ACCENT : TEXT})
			}
		}
	}
}

// ── mentions inbox ──────────────────────────────────────────────────

MI_FETCH_LIMIT :: 100 // per-chat page, same depth as global search
MI_HITS_MAX :: 50
MI_REFRESH_SECS :: 60.0
MENTION_READ_CAP :: 200 // stored read-ids cap (prefs)

Mention_Hit :: struct {
	chat:    int, // index into ui.chats
	msg_id:  string,
	title:   string, // chat title
	sender:  string, // display label
	snippet: string,
	at:      string, // full date + time
	when_at: u64,
	unread:  bool, // not in the persisted read set at refresh time
}

mi_free_hit :: proc(h: Mention_Hit) {
	delete(h.msg_id)
	delete(h.title)
	delete(h.sender)
	delete(h.snippet)
	delete(h.at)
}

mi_clear :: proc(ui: ^Ui_State) {
	for h in ui.mi_hits {
		mi_free_hit(h)
	}
	clear(&ui.mi_hits)
}

mi_is_read :: proc(ui: ^Ui_State, id: string) -> bool {
	for r in ui.prefs.mention_read {
		if r == id {
			return true
		}
	}
	return false
}

mi_mark_read :: proc(ui: ^Ui_State, id: string) {
	if mi_is_read(ui, id) {
		return
	}
	inject_at(&ui.prefs.mention_read, 0, strings.clone(id))
	for len(ui.prefs.mention_read) > MENTION_READ_CAP {
		delete(pop(&ui.prefs.mention_read))
	}
}

mi_unread_count :: proc(ui: ^Ui_State) -> int {
	n := 0
	for h in ui.mi_hits {
		if h.unread {
			n += 1
		}
	}
	return n
}

// Re-scan every chat's recent page for messages mentioning me, newest
// first. Same query shape as gs_refresh; edits ride the timeline as
// the record's current text already (load path parity is a caveat:
// this reads plaintext, so a 1009 edit body is scanned as its own
// record and the original keeps its pre-edit text).
// ponytail: synchronous N limit-100 queries; worker thread if a large
// account ever makes the refresh hitch.
mi_refresh :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	mi_clear(ui)
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	for chat, ci in ui.chats {
		if chat.pending {
			continue
		}
		query := marmot.Timeline_Message_Query {
			group_id_hex = strings.clone_to_cstring(chat.group_id, context.temp_allocator),
			has_limit    = true,
			limit        = MI_FETCH_LIMIT,
		}
		page: ^marmot.Timeline_Page
		if marmot.timeline_messages(client, account, &query, &page) != .OK {
			continue
		}
		defer marmot.timeline_page_free(page)

		for i := page.messages_len; i > 0; i -= 1 {
			record := &page.messages[i - 1]
			if record.deleted || record.kind == 1009 || record.kind == 5 || record.plaintext == nil {
				continue
			}
			if record.direction != nil && string(record.direction) == "sent" {
				continue
			}
			id := record.message_id_hex != nil ? string(record.message_id_hex) : ""
			if len(id) == 0 || ui.hidden[id] {
				continue
			}
			body := string(record.plaintext)
			if !text_mentions_me(body, ui.account_ref) {
				continue
			}
			sender := record.sender != nil ? string(record.sender) : ""
			append(&ui.mi_hits, Mention_Hit{
				chat    = ci,
				msg_id  = strings.clone(id),
				title   = strings.clone(chat.title),
				sender  = strings.clone(profile_label(client, sender)),
				snippet = gs_snippet(body, 0),
				at      = format_full(record.timeline_at),
				when_at = record.timeline_at,
				unread  = !mi_is_read(ui, id),
			})
		}
	}

	slice.sort_by(ui.mi_hits[:], proc(a, b: Mention_Hit) -> bool {
		return a.when_at > b.when_at
	})
	for len(ui.mi_hits) > MI_HITS_MAX {
		mi_free_hit(pop(&ui.mi_hits))
	}
}

@(private = "file")
mi_last: f64 = -1

// Periodic badge refresh from the frame loop; the first call scans at
// boot so the bell shows a count before the inbox ever opens.
mi_tick :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if client == nil || len(ui.account_ref) == 0 || len(ui.chats) == 0 {
		return
	}
	now := rl.GetTime()
	if mi_last >= 0 && now - mi_last < MI_REFRESH_SECS {
		return
	}
	mi_last = now
	mi_refresh(ui, client)
}

// The header bell with its unread badge, replacing the plain chip.
bell_chip :: proc(ui: ^Ui_State) {
	unread := mi_unread_count(ui)
	if clay.UI(clay.ID("BellBtn"))(
	{layout = {padding = {left = 14, right = 14, top = 8, bottom = 8}}, backgroundColor = ui.mi_open ? ACCENT : ROW_BG, cornerRadius = rr(8)},
	) {
		clay.Text(ICON_BELL, {fontId = FONT_ICON, fontSize = 14, textColor = ui.mi_open ? ON_ACCENT : TEXT})
		if unread > 0 {
			if clay.UI(clay.ID("BellBadge"))(
			{
				layout = {padding = {left = 5, right = 5, top = 1, bottom = 1}},
				floating = {attachTo = .Parent, zIndex = 6, offset = {6, -6}, attachment = {element = .RightTop, parent = .RightTop}},
				backgroundColor = DANGER,
				cornerRadius = rr(8),
			},
			) {
				clay.Text(unread > 99 ? "99+" : fmt.tprintf("%d", unread), {fontId = FONT_BODY, fontSize = 10, textColor = {255, 255, 255, 235}})
			}
		}
	}
}

// Dropdown under the bell: one card per mention hit; a click jumps to
// the chat and centers the message (the gsearch jump).
mention_inbox :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("MiModal"))(
	{
		layout = {sizing = {width = clay.SizingFixed(fit_w(420))}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(12), childGap = 6},
		backgroundColor = CARD,
		cornerRadius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
		floating = {attachTo = .ElementWithId, parentId = clay.ID("BellBtn").id, zIndex = 13, offset = {0, 8 + rise(clay.ID("MiModal"))}, attachment = {element = .RightTop, parent = .RightBottom}},
	},
	) {
		if clay.UI(clay.ID("MiHead"))({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}}) {
			clay.Text("MENTIONS", {fontId = FONT_MONO, fontSize = 11, textColor = TEXT_DIM, letterSpacing = 2})
			if clay.UI(clay.ID("MiHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("MiClose"))(
			{layout = {sizing = {width = clay.SizingFixed(24), height = clay.SizingFixed(24)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(7)},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 11, textColor = TEXT_DIM})
			}
		}

		if len(ui.mi_hits) == 0 {
			clay.Text("No mentions yet.", {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
		}

		if clay.UI(clay.ID("MiList"))(
		{
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFit({max = 380})}, layoutDirection = .TopToBottom, childGap = 2},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			for hit, i in ui.mi_hits {
				if clay.UI(clay.ID("MiHit", u32(i)))(
				{
					layout = {sizing = {width = clay.SizingGrow()}, childGap = 8, padding = clay.PaddingAll(8)},
					backgroundColor = hovered() ? HOVER : {},
					cornerRadius = rr(8),
				},
				) {
					if hit.unread {
						if clay.UI(clay.ID("MiHitDot", u32(i)))({layout = {sizing = {width = clay.SizingFixed(3), height = clay.SizingGrow()}}, backgroundColor = ACCENT, cornerRadius = rr(2)}) {}
					}
					if clay.UI(clay.ID("MiHitCol", u32(i)))(
					{layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 3}},
					) {
						if clay.UI(clay.ID("MiHitTop", u32(i)))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 8, childAlignment = {y = .Center}}}) {
							clay.Text(hit.title, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
							clay.Text(hit.sender, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
							if clay.UI(clay.ID("MiHitGap", u32(i)))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
							clay.Text(hit.at, {fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO})
						}
						clay.Text(hit.snippet, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
					}
				}
			}
		}
		scrollbar(clay.ID("MiList"), 14) // the modal floats at 13
	}
}

// Input while the inbox is open; anything outside dismisses it.
handle_mi :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if rl.IsKeyPressed(.ESCAPE) {
		ui.mi_open = false
		return
	}
	if !mouse_released() {
		return
	}
	for hit, i in ui.mi_hits {
		if clay.PointerOver(clay.ID("MiHit", u32(i))) {
			ui.mi_open = false
			gs_jump(ui, client, hit.chat, hit.msg_id)
			return
		}
	}
	if clicked("MiClose") || (!clay.PointerOver(clay.ID("MiModal")) && !clay.PointerOver(clay.ID("BellBtn"))) {
		ui.mi_open = false
	}
}
