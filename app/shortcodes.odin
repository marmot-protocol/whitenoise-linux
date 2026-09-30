// Composer :shortcode: autocomplete, the emoji twin of @-mentions:
// typing ":smi" after whitespace pops a list of emoji whose shortcode
// matches; Enter or a click replaces the ":token" with the emoji.
//
//   "lol :joy"  --Enter-->  "lol 😂 "
//   "hi :part"  --Enter-->  "hi :party: "   (custom, ships as NIP-30)
package main

import "core:fmt"
import "core:strings"
import "core:text/edit"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

SHORTCODE_CANDS_MAX :: 8

// Two characters before the popover opens, so "a :)" or a lone ":"
// in prose stays quiet.
SHORTCODE_QUERY_MIN :: 2

// One popover row. Strings slice long-lived storage (the catalog,
// custom_emoji_names, BUILTIN_EMOJI), so the list survives the
// popover's close animation.
Shortcode_Cand :: struct {
	emoji: string, // catalog emoji to insert; "" = custom shortcode
	code:  string, // shortcode without colons, "joy"
}

// Shortcode alphabet: the catalog's aliases use [a-z0-9_+-] (":+1:",
// ":t-rex:"), custom codes the same minus '+'.
@(private = "file")
query_ok :: proc(query: string) -> bool {
	if len(query) < SHORTCODE_QUERY_MIN {
		return false
	}
	for c in transmute([]u8)query {
		alnum := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		if !alnum && c != '_' && c != '-' && c != '+' {
			return false
		}
	}
	return true
}

// 0 = exact, 1 = prefix, 2 = substring, -1 = no hit.
SHORTCODE_TIERS :: 3

@(private = "file")
code_rank :: proc(code, q: string) -> int {
	if code == q {
		return 0
	}
	if strings.has_prefix(code, q) {
		return 1
	}
	if strings.contains(code, q) {
		return 2
	}
	return -1
}

// Best-ranked alias of a catalog row, whose search name carries its
// aliases colon-wrapped: "grinning squinting face :laughing: laughing
// :satisfied: satisfied".
@(private = "file")
catalog_alias :: proc(name, q: string) -> (alias: string, rank: int) {
	rank = -1
	rest := name
	for word in strings.fields_iterator(&rest) {
		if len(word) < 3 || word[0] != ':' || word[len(word) - 1] != ':' {
			continue
		}
		code := word[1:len(word) - 1]
		r := code_rank(code, q)
		if r >= 0 && (rank < 0 || r < rank) {
			alias, rank = code, r
		}
	}
	return
}

// Rebuild the candidate list from the caret's ":token". Exact hits
// come first, then prefix, then substring; custom codes lead each tier.
shortcode_update :: proc(ui: ^Ui_State) {
	ui.shortcode_active = false
	if ui.focus != .Compose || ui.ed_target != &ui.compose {
		return
	}
	_, _, head := field_sel(ui, &ui.compose)
	at, query, ok := detect_token(string(ui.compose[:]), head, ':')
	if !ok || !query_ok(query) {
		ui.shortcode_dismissed = -1
		return
	}
	if ui.shortcode_dismissed == at {
		return
	}
	if ui.shortcode_at_b != at {
		ui.shortcode_sel = 0
		ui.shortcode_at_b = at
	}

	clear(&ui.shortcode_cands)
	q := strings.to_lower(query, context.temp_allocator)
	tiers: [SHORTCODE_TIERS][dynamic]Shortcode_Cand
	for &tier in tiers {
		tier = make([dynamic]Shortcode_Cand, context.temp_allocator)
	}
	for code in picker_custom(q) {
		rank := code_rank(strings.to_lower(code, context.temp_allocator), q)
		append(&tiers[rank], Shortcode_Cand{code = code})
	}
	for entry in emoji_catalog {
		if len(entry.pixels) == 0 {
			continue
		}
		alias, rank := catalog_alias(entry.name, q)
		if rank >= 0 && len(tiers[rank]) < SHORTCODE_CANDS_MAX {
			append(&tiers[rank], Shortcode_Cand{emoji = entry.emoji, code = alias})
		}
	}
	for tier in tiers {
		append(&ui.shortcode_cands, ..tier[:])
	}
	resize(&ui.shortcode_cands, min(len(ui.shortcode_cands), SHORTCODE_CANDS_MAX))
	if len(ui.shortcode_cands) == 0 {
		return
	}
	ui.shortcode_sel = clamp(ui.shortcode_sel, 0, len(ui.shortcode_cands) - 1)
	ui.shortcode_active = true
}

// Splice the emoji (or ":code:" for a custom one) plus a space over
// the active ":token", caret after the space.
shortcode_commit :: proc(ui: ^Ui_State, index: int) {
	ui.shortcode_active = false
	if index < 0 || index >= len(ui.shortcode_cands) {
		return
	}
	cand := ui.shortcode_cands[index]
	_, _, head := field_sel(ui, &ui.compose)
	at := ui.shortcode_at_b
	if at > head || head > len(ui.compose) {
		return
	}
	insert := len(cand.emoji) > 0 ? cand.emoji : fmt.tprintf(":%s:", cand.code)
	ed_begin(ui, &ui.compose)
	ui.ed.selection = {at, head}
	edit.input_text(&ui.ed, fmt.tprintf("%s ", insert))
	ed_end(ui, &ui.compose)
}

// Keys and clicks while the popover is open; the handle_mention
// contract (true = Escape/Enter/click consumed, so Enter can't send).
handle_shortcode :: proc(ui: ^Ui_State) -> bool {
	shortcode_update(ui)
	if !ui.shortcode_active {
		return false
	}
	n := len(ui.shortcode_cands)
	if rl.IsKeyPressed(.ESCAPE) {
		ui.shortcode_dismissed = ui.shortcode_at_b
		ui.shortcode_active = false
		return true
	}
	if key_hit(.UP) {
		ui.shortcode_sel = (ui.shortcode_sel + n - 1) % n
	}
	if key_hit(.DOWN) {
		ui.shortcode_sel = (ui.shortcode_sel + 1) % n
	}
	if rl.IsKeyPressed(.ENTER) {
		shortcode_commit(ui, ui.shortcode_sel)
		return true
	}
	if mouse_released() {
		for _, i in ui.shortcode_cands {
			if clay.PointerOver(clay.ID("ShortcodeCand", u32(i))) {
				shortcode_commit(ui, i)
				return true
			}
		}
	}
	return false
}

// The popover, floated above the composer like mention_popover.
shortcode_popover :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("ShortcodePop"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(280)},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(6),
			childGap = 2,
		},
		backgroundColor = CARD,
		cornerRadius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
		floating = {
			attachTo = .Parent,
			zIndex = 12,
			offset = {0, -8 - rise(clay.ID("ShortcodePop"))},
			attachment = {element = .LeftBottom, parent = .LeftTop},
		},
	},
	) {
		for cand, i in ui.shortcode_cands {
			sel := i == ui.shortcode_sel
			tex := len(cand.emoji) > 0 ? emoji_tex(cand.emoji) : custom_tex_by_code(cand.code)
			if clay.UI(clay.ID("ShortcodeCand", u32(i)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					padding = clay.PaddingAll(6),
					childGap = 8,
					childAlignment = {y = .Center},
				},
				backgroundColor = sel ? SELECTED : (hovered() ? HOVER : {}),
				cornerRadius = rr(8),
			},
			) {
				if clay.UI(clay.ID("ShortcodeCandImg", u32(i)))(
				{
					layout = {sizing = {width = clay.SizingFixed(22)}},
					aspectRatio = {1},
					image = {imageData = tex},
				},
				) {}
				clay.Text(
					fmt.tprintf(":%s:", cand.code),
					{fontId = FONT_BODY, fontSize = 13, textColor = sel ? ACCENT : TEXT},
				)
			}
		}
	}
}
