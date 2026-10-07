package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

is_emoji_rune :: proc(r: rune) -> bool {
	switch {
	case r >= 0x1F000 && r <= 0x1FAFF:
		return true
	case r >= 0x2600 && r <= 0x27BF:
		return true
	case r == 0x2764 || r == 0x2B50 || r == 0x203C || r == 0x2049 || (r >= 0x2B00 && r <= 0x2BFF):
		return true
	}
	return false
}

// One inline text/emoji/mention segment of a body line. A mention seg
// keeps the raw token in text (composer lines render it literally) and
// the resolved pubkey in hex (body lines render the chip).
Inline_Seg :: struct {
	text:    string,
	fonts:   string,
	tex:     ^rl.Texture2D,
	hex:     string, // mentioned account, "" = not a mention
	url:     string, // http(s) link, "" = not a link (linkguard.odin)
	bad_ref: bool,
	evid:    string, // nevent/note event id hex, "" = not one (nevent.odin)
	hints:   []string, // the nevent's relay hints
	fx:      u8, // glyph-effect bits from {name} markup (effects.odin)
}

@(private)
Inline_Link :: struct {
	start, end: int,
	url:        string,
}

// Split text into text runs and emoji clusters (VS16/ZWJ ride along;
// a cluster the sheet misses falls back per rune, then raw text).
inline_segs :: proc(
	text: string,
	fonts: string = "",
	links: []Inline_Link = nil,
	offset: int = 0,
) -> [dynamic]Inline_Seg {
	segs := make([dynamic]Inline_Seg, context.temp_allocator)
	plain_start := 0
	i := 0
	link_index := 0
	for i < len(text) {
		for link_index < len(links) && links[link_index].end <= offset + i {link_index += 1}
		if link_index < len(links) && links[link_index].start <= offset + i {
			link := links[link_index]
			end := min(len(text), link.end - offset)
			if i > plain_start {
				append(
					&segs,
					Inline_Seg {
						text = text[plain_start:i],
						fonts = text_fonts(fonts, plain_start, i),
					},
				)
			}
			append(
				&segs,
				Inline_Seg{text = text[i:end], url = link.url, fonts = text_fonts(fonts, i, end)},
			)
			i, plain_start = end, end
			continue
		}
		if text_literal(fonts, i) {i += 1; continue}
		if end, ref := nostr_at(text, i); ref.kind != .None {
			if i >
			   plain_start {append(&segs, Inline_Seg{text = text[plain_start:i], fonts = text_fonts(fonts, plain_start, i)})}
			seg := Inline_Seg {
				text    = text[i:end],
				fonts   = text_fonts(fonts, i, end),
				bad_ref = ref.kind == .Invalid,
			}
			if ref.kind == .Profile {seg.hex = ref.key}
			if ref.kind == .Event ||
			   ref.kind == .Address {seg.evid, seg.hints = ref.key, ref.relays}
			append(&segs, seg)
			i, plain_start = end, end
			continue
		}
		r, w := utf8.decode_rune_in_string(text[i:])
		if r == 'm' || r == 'M' {
			// marmot://profile deep link becomes one mention chip too;
			// clicking it opens the profile like a mention.
			if end, hx, ok := marmot_link_at(text, i); ok {
				if i > plain_start {
					append(
						&segs,
						Inline_Seg {
							text = text[plain_start:i],
							fonts = text_fonts(fonts, plain_start, i),
						},
					)
				}
				append(
					&segs,
					Inline_Seg{text = text[i:end], hex = hx, fonts = text_fonts(fonts, i, end)},
				)
				i = end
				plain_start = end
				continue
			}
		}
		if r == '{' {
			// {name}…{/name} glyph effects: the inner text parses on its
			// own and every seg it yields carries this bit, so nesting
			// ORs the bits together.
			if bit, after, ok := fx_open_at(text, i); ok {
				inner_end, next := fx_close(text, after, bit)
				if i > plain_start {
					append(
						&segs,
						Inline_Seg {
							text = text[plain_start:i],
							fonts = text_fonts(fonts, plain_start, i),
						},
					)
				}
				for seg in inline_segs(text[after:inner_end], text_fonts(fonts, after, inner_end), links[link_index:], offset + after) {
					tagged := seg
					tagged.fx |= bit
					// Motion acts per glyph, so a moving text seg splits
					// into letters. A very long run stays whole: the
					// per-letter ids would collide.
					plain :=
						!tagged.bad_ref &&
						tagged.tex == nil &&
						len(tagged.hex) == 0 &&
						len(tagged.url) == 0 &&
						len(tagged.evid) == 0
					if tagged.fx & FX_MOTION == 0 || !plain || len(tagged.text) > FX_LETTERS_MAX {
						append(&segs, tagged)
						continue
					}
					for at := 0; at < len(tagged.text); {
						_, w := utf8.decode_rune_in_string(tagged.text[at:])
						letter := tagged
						letter.text = tagged.text[at:at + w]
						letter.fonts = text_fonts(tagged.fonts, at, at + w)
						append(&segs, letter)
						at += w
					}
				}
				i = next
				plain_start = next
				continue
			}
		}
		if r == 'h' {
			// http(s) URL becomes its own seg; bodies draw it as a link
			// that routes through the external-link guard.
			if end, link, ok := url_at(text, i); ok {
				if i > plain_start {
					append(
						&segs,
						Inline_Seg {
							text = text[plain_start:i],
							fonts = text_fonts(fonts, plain_start, i),
						},
					)
				}
				append(
					&segs,
					Inline_Seg{text = link, url = link, fonts = text_fonts(fonts, i, end)},
				)
				i = end
				plain_start = end
				continue
			}
		}
		if r == ':' {
			// Known :shortcode: becomes a custom-emoji tile; anything
			// else stays literal text.
			if end, ctex := shortcode_at(text, i); ctex != nil {
				if i > plain_start {
					append(
						&segs,
						Inline_Seg {
							text = text[plain_start:i],
							fonts = text_fonts(fonts, plain_start, i),
						},
					)
				}
				append(&segs, Inline_Seg{tex = ctex})
				i = end
				plain_start = end
				continue
			}
		}
		if !is_emoji_rune(r) && !(r >= '0' && r <= '9') && r != '#' && r != '*' {
			i += w
			continue
		}
		it := utf8.decode_grapheme_iterator_make(text[i:])
		cluster, _, _ := rl.grapheme_iterate(&it)
		j := i + len(cluster)
		tex := text_emoji(cluster)
		if tex == nil {i = j; continue}
		if i > plain_start {
			append(
				&segs,
				Inline_Seg{text = text[plain_start:i], fonts = text_fonts(fonts, plain_start, i)},
			)
		}
		append(&segs, Inline_Seg{tex = tex})
		i = j
		plain_start = j
	}
	if plain_start < len(text) {
		append(
			&segs,
			Inline_Seg {
				text = text[plain_start:],
				fonts = text_fonts(fonts, plain_start, len(text)),
			},
		)
	}
	return segs
}

@(private)
link_cards_enabled :: proc() -> bool {
	return gh_cards_on && (g_ui == nil || !g_ui.prefs.disable_link_previews)
}

// A URL drawn as a card of its own row rather than as a link run.
@(private)
link_card :: proc(url: string) -> bool {
	_, gh := gh_ref(url)
	_, geo := geo_ref(url)
	return gh || geo || hn_ref(url) != "" || nev_image_url(url)
}

// Keep the original clickable link in every state, including loading and failure.
@(private)
image_link :: proc(id: u32, url: string, size: u16, width: f32) {
	cards := gh_cards_on
	gh_cards_on = false
	defer {gh_cards_on = cards}
	inner_w := max(1, width - 20)
	if tex := nev_img(url); tex != nil && tex.width > 0 && tex.height > 0 {
		inner_w = min(inner_w, 200 * f32(tex.width) / f32(tex.height))
	}
	if clay.UI(clay.ID("ImageLink", id))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			childGap = 8,
			padding = clay.PaddingAll(10),
			sizing = {width = clay.SizingFixed(inner_w + 20)},
		},
		backgroundColor = PLATE,
		cornerRadius = rr(10),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		// The picture opens the lightbox; the URL goes through the link guard.
		nev_card_image(id, url, inner_w)
		if clay.PointerOver(clay.ID("NevImage", id)) {
			img_link_hover = url
			cursor_raise(.Pointer)
		}
		if clay.UI(clay.ID("ImageLinkUrl", id))({}) {
			// Plain, single line: body_text would turn an npub inside the host into a mention chip.
			clay.Text(
				text_ellipsis(url, inner_w, FONT_BODY, size),
				{fontId = FONT_BODY, fontSize = size, textColor = ACCENT, wrapMode = .None},
			)
			if hovered() {link_hover = url}
		}
	}
}

// Emit segments inline into the current parent element. Mention segs
// always draw as name plates; chips (bodies) also draws cards and
// links, and makes the plates clickable. Composer lines keep other
// tokens raw, and step over a plate whole (compose_atom).
render_segs :: proc(
	id: u32,
	segs: []Inline_Seg,
	font_size: u16,
	color: clay.Color,
	tile_px: f32,
	chips := false,
) {
	for seg, k in segs {
		card := chips && link_cards_enabled() && seg.text == seg.url
		// Android's "Location: " caption; the location card says it.
		if chips &&
		   link_cards_enabled() &&
		   k + 1 < len(segs) &&
		   strings.trim_space(seg.text) == GEO_CAPTION {
			if _, geo := geo_ref(segs[k + 1].url); geo {continue}
		}
		if seg.tex != nil {
			if clay.UI(clay.ID("SegEmoji", id * 128 + u32(k)))(
			{
				layout = {sizing = {width = clay.SizingFixed(tile_px)}},
				aspectRatio = {1},
				image = {imageData = seg.tex},
			},
			) {}
		} else if card && nev_image_url(seg.url) {
			image_link(id * 128 + u32(k), seg.url, font_size, max(1, att_w() - 24))
		} else if ref, is_gh := gh_ref(seg.url); card && is_gh {
			// A GitHub PR or issue link is drawn as its own card, in
			// place of the URL run.
			gh_card(id * 128 + u32(k), ref)
		} else if key := hn_ref(seg.url); card && key != "" {
			hn_card(id * 128 + u32(k), key, seg.url)
		} else if link, geo := geo_ref(seg.url); card && geo {
			geo_card(id * 128 + u32(k), seg.url, link)
		} else if chips && link_cards_enabled() && len(seg.evid) > 0 {
			// A referenced Nostr event is drawn as its own card, in
			// place of the token.
			nev_card(
				id * 128 + u32(k),
				seg.evid,
				strings.trim_prefix(seg.text, "nostr:"),
				seg.hints,
			)
		} else if chips && seg.bad_ref {
			clay.Text(
				tr("Invalid Nostr reference"),
				{fontId = FONT_BODY, fontSize = font_size, textColor = DANGER, wrapMode = .None},
			)
		} else if chips && len(seg.url) > 0 {
			// Links only in bodies: composer lines keep the raw text so
			// caret hit-mapping stays byte-accurate.
			if clay.UI(clay.ID("SegLink", id * 128 + u32(k)))(
			{
				layout = {padding = {left = 2, right = 2}},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(4),
			},
			) {
				if hovered() {
					link_hover = seg.url
					tooltip(seg.url)
				}
				styled_text(seg.text, seg.fonts, font_size, ACCENT)
			}
		} else if len(seg.hex) > 0 {
			// Chip filled with the exact accent and inked black or white,
			// whichever contrasts more, so it reads on every accent slot
			// of every pack. A mention of me gets a TEXT border, which
			// stands apart from both the fill and the page. Click opens
			// the profile in bodies; in the composer it places the caret.
			me := g_ui != nil && seg.hex == g_ui.account_ref
			if clay.UI(clay.ID("SegMention", id * 128 + u32(k)))(
			{
				layout = {
					padding = {left = MENTION_PAD_X, right = MENTION_PAD_X, top = 1, bottom = 1},
					childGap = 2,
					childAlignment = {y = .Center},
				},
				backgroundColor = ACCENT,
				cornerRadius = rr(7),
				border = me ? clay.BorderElementConfig{color = TEXT, width = bw()} : {},
			},
			) {
				over := chips && hovered()
				if over {
					mention_hover = seg.hex
				}
				peephole_avatar(
					"MentionAvatar",
					id * 128 + u32(k),
					seg.hex,
					mention_label(seg.hex),
					f32(font_size),
					url_pic(profile_info(g_client, seg.hex).pic_url),
					over ? .Open : .Closed,
				)
				clay.Text(
					fmt.tprintf("@%s", mention_label(seg.hex)),
					{
						fontId = FONT_TITLE,
						fontSize = font_size,
						textColor = ink_on(ACCENT),
						userData = rawptr(
							uintptr(
								len(seg.fonts) > 0 ? seg.fonts[0] & (TEXT_ADDED | TEXT_REMOVED) : 0,
							),
						),
					},
				)
			}
		} else if seg.fx != 0 {
			anim_moving += 1
			// The glyph sits in a fixed cell sized to its own text plus
			// the motion budget, and moves by padding inside it: motion
			// never disturbs the line's spacing, and (unlike the
			// floating cell this used to use) it stays inside the
			// timeline's scroll clip instead of painting over the header.
			dx, dy, size_mul, alpha_mul := fx_transform(seg.fx, k, rl.GetTime())
			size := u16(max(f32(font_size) * size_mul, 6))
			tint := color
			tint.a *= alpha_mul
			cell := rl.MeasureTextLine(FONT_BODY, size, seg.text, 0).x
			if clay.UI(clay.ID("SegFx", id * 128 + u32(k)))(
			{
				layout = {
					sizing = {
						width = clay.SizingFixed(cell + 2 * FX_AMP),
						height = clay.SizingFixed(f32(size) + 2 + 2 * FX_AMP),
					},
					padding = {
						left = u16(FX_AMP + clamp(dx, -FX_AMP, FX_AMP)),
						top = u16(FX_AMP + clamp(dy, -FX_AMP, FX_AMP)),
					},
				},
			},
			) {
				styled_text(seg.text, seg.fonts, size, tint)
			}
		} else {
			if len(seg.fonts) > 0 {
				styled_text(seg.text, seg.fonts, font_size, color)
			} else {
				clay.Text(
					seg.text,
					{
						fontId = FONT_BODY,
						fontSize = font_size,
						textColor = color,
						wrapMode = chips ? .Words : .None,
					},
				)
			}
		}
	}
}

// Wrap to the resolved text viewport, including the current pane and zoom.
compose_wrap_w :: proc() -> f32 {
	box := clay.GetElementData(clay.ID("ComposeClip"))
	width := g_ui != nil ? page_w(g_ui) - 64 - CARET_W : 480
	if box.found &&
	   box.boundingBox.width > CARET_W {width = min(width, box.boundingBox.width - CARET_W)}
	return max(width, 1)
}

@(private)
compose_cache: struct {
	text:         string,
	width, scale: f32,
	lines:        [dynamic][2]int,
}

// Byte ranges of the composer's visual lines: each physical '\n' line
// greedily wrapped to the pill's text width. Spaces stay in the ranges
// so every byte keeps exactly one row and caret
// hit-mapping stays byte-accurate.
compose_lines :: proc(text: string) -> [][2]int {
	// Only the wrap cache uses the process heap. Mention lookups inherit the
	// caller's allocator so queued profile IDs stay owned by the UI heap.
	allocator := runtime.default_context().allocator
	compose_cache.lines.allocator = allocator
	width := compose_wrap_w()
	keep := 0
	start := 0
	if compose_cache.width == width &&
	   compose_cache.scale == UI_SCALE &&
	   len(compose_cache.lines) > 0 {
		if compose_cache.text == text {return compose_cache.lines[:]}
		prefix := 0
		for prefix < min(len(text), len(compose_cache.text)) &&
		    text[prefix] == compose_cache.text[prefix] {prefix += 1}
		// Rewrap the preceding line too: deleting a space may pull the
		// next word back onto it. Unchanged prefixes retain their breaks.
		for line, i in compose_cache.lines {
			if line[1] >= prefix {keep = max(i - 1, 0); break}
		}
		start = compose_cache.lines[keep][0]
	}
	resize(&compose_cache.lines, keep)
	for {
		end := len(text)
		if nl := strings.index_byte(text[start:], '\n'); nl >= 0 {
			end = start + nl
		}
		at := start
		for {
			cut := wrap_break(text, at, end, width, BODY_FS, .Compose)
			append(&compose_cache.lines, [2]int{at, cut})
			if cut >= end {
				break
			}
			at = cut
		}
		if end == len(text) {
			break
		}
		start = end + 1
	}
	delete(compose_cache.text, allocator)
	compose_cache.text = strings.clone(text, allocator)
	compose_cache.width, compose_cache.scale = width, UI_SCALE
	return compose_cache.lines[:]
}

// One physical composer line [ls, le): up to three spans split at the
// selection [lo, hi) (middle span highlighted), the caret at the
// selection head, the IME preedit riding at the caret.
compose_line :: proc(i: u32, text: string, ls, le, lo, hi, head: int) {
	if clay.UI(clay.ID("ComposeLine", i))(
	{layout = {sizing = {height = clay.SizingFit({min = 20})}, childAlignment = {y = .Center}}},
	) {
		a := clamp(lo, ls, le)
		b := clamp(hi, ls, le)
		at_caret :: proc(head, pos, ls, le: int) -> bool {
			return head == pos && head >= ls && head <= le
		}

		if a > ls {
			render_segs(0xE00 + i * 8, inline_segs(text[ls:a])[:], BODY_FS, TEXT, 18)
		}
		if at_caret(head, a, ls, le) {
			if preedit := rl.Preedit(); len(preedit) > 0 {
				clay.Text(preedit, {fontId = FONT_BODY, fontSize = BODY_FS, textColor = ACCENT})
			}
			caret()
		}
		if b > a {
			if clay.UI(clay.ID("ComposeSel", i))(
			{backgroundColor = ACCENT, layout = {childGap = 1, childAlignment = {y = .Center}}},
			) {
				render_segs(0xE00 + i * 8 + 2, inline_segs(text[a:b])[:], BODY_FS, ON_ACCENT, 18)
			}
			if at_caret(head, b, ls, le) && head > a {
				caret()
			}
		}
		if b < le {
			render_segs(0xE00 + i * 8 + 4, inline_segs(text[b:le])[:], BODY_FS, TEXT, 18)
		}
	}
}

// Render a pre-wrapped line with the body's measured emoji tile size.
// `sel` is the selected byte range inside this line ({-1,-1} = none,
// bodysel.odin), drawn as a highlighted middle span like the composer.
// `boxed` wraps the line in an element hit-testing can measure; the
// caller sets it for pre-wrapped (selectable) bodies only, because an
// element around a plain Text would take clay's own wrapping away.
body_line :: proc(
	id: u32,
	text: string,
	font_size: u16,
	color: clay.Color,
	sel := [2]int{-1, -1},
	boxed := false,
	tile_px: f32 = 0,
	fonts: string = "",
	links: []Inline_Link = nil,
	offset: int = 0,
) {
	tile_px := tile_px > 0 ? tile_px : body_tile_size(text, font_size)
	if text == "" {
		if clay.UI(clay.ID("BodyLine", id))(
		{layout = {sizing = {height = clay.SizingFixed(f32(font_size))}}},
		) {}
		return
	}
	sel := sel
	if sel[0] >= 0 {
		// A selection through a card token would split it into
		// text runs and lose the card, so a line holding one draws
		// unselected; the copy still carries the token.
		for seg in inline_segs(text, fonts, links, offset) {
			if link_cards_enabled() &&
			   (len(seg.evid) > 0 || (seg.text == seg.url && link_card(seg.url))) {
				sel = {-1, -1}
				break
			}
		}
	}
	if sel[0] >= 0 {
		if clay.UI(clay.ID("BodyLine", id))(
		{layout = {childGap = 2, childAlignment = {y = .Center}}},
		) {
			if sel[0] > 0 {
				render_segs(
					id * 4,
					inline_segs(text[:sel[0]], text_fonts(fonts, 0, sel[0]), links, offset)[:],
					font_size,
					color,
					tile_px,
					true,
				)
			}
			if clay.UI(clay.ID("BodySel", id))(
			{layout = {childGap = 2, childAlignment = {y = .Center}}, backgroundColor = ACCENT},
			) {
				// chips inside the highlight too: a link that turned
				// into a card must not fall back to its URL the moment
				// a selection covers it.
				render_segs(
					id * 4 + 1,
					inline_segs(
						text[sel[0]:sel[1]],
						text_fonts(fonts, sel[0], sel[1]),
						links,
						offset + sel[0],
					)[:],
					font_size,
					ON_ACCENT,
					tile_px,
					true,
				)
			}
			if sel[1] < len(text) {
				render_segs(
					id * 4 + 2,
					inline_segs(
						text[sel[1]:],
						text_fonts(fonts, sel[1], len(text)),
						links,
						offset + sel[1],
					)[:],
					font_size,
					color,
					tile_px,
					true,
				)
			}
		}
		return
	}

	segs := inline_segs(text, fonts, links, offset)
	if len(fonts) == 0 &&
	   len(segs) == 1 &&
	   segs[0].tex == nil &&
	   len(segs[0].hex) == 0 &&
	   len(segs[0].url) == 0 &&
	   !segs[0].bad_ref &&
	   len(segs[0].evid) == 0 &&
	   len(segs[0].text) == len(text) {
		// No emoji or mention at all: plain Text keeps clay's wrapping.
		if !boxed {
			clay.Text(text, {fontId = FONT_BODY, fontSize = font_size, textColor = color})
			return
		}
		if clay.UI(clay.ID("BodyLine", id))({layout = {childAlignment = {y = .Center}}}) {
			clay.Text(text, {fontId = FONT_BODY, fontSize = font_size, textColor = color})
		}
		return
	}

	if clay.UI(clay.ID("BodyLine", id))(
	{layout = {childGap = 2, childAlignment = {y = .Center}}},
	) {
		render_segs(id, segs[:], font_size, color, tile_px, true)
	}
}

// Multi-line wrapper: one body_line per physical line.
// Markdown block list, shared by message bodies, .md/.txt tiles, and

// Content-sized columns share the available width and retain source alignment.
MD_TABLE_COL_MAX :: 140
MD_TABLE_PAD :: 7

@(private)
md_hover :: proc(depth: u16, rest: clay.Color = {}) -> clay.Color {
	if !clay.Hovered() {return rest}
	// Composite once so translucent theme colors cannot stack into a bright wash.
	base := mix_color(CARD, HOVER, HOVER.a / 255)
	shade := mix_color(base, TEXT, 0.06 * f32(depth) / (f32(depth) + 2))
	shade.a = 255
	return shade
}

md_table :: proc(
	id: u32,
	cells: [][]string,
	cell_fonts: [][]string = nil,
	alignments: []marmot.Markdown_Alignment = nil,
	width: f32 = 480,
	depth: u16 = 0,
	cell_links: [][][dynamic]Inline_Link = nil,
) {
	if len(cells) == 0 {
		return
	}
	cols := 0
	for row in cells {
		cols = max(cols, len(row))
	}
	if cols == 0 {
		return
	}

	widths := make([]f32, cols, context.temp_allocator)
	for row, r in cells {
		for cell, c in row {
			fonts := r < len(cell_fonts) && c < len(cell_fonts[r]) ? cell_fonts[r][c] : ""
			width: f32
			it := utf8.decode_grapheme_iterator_make(cell)
			for cluster, g in rl.grapheme_iterate(&it) {width += rl.MeasureTextLine(len(fonts) > 0 ? text_font(fonts, g.byte_index) : (r == 0 ? FONT_TITLE : FONT_BODY), 13, cluster, 0).x}
			widths[c] = max(widths[c], width)
		}
	}
	total: f32
	for &w in widths {
		w = min(min(w, MD_TABLE_COL_MAX) + MD_TABLE_PAD * 2, width / f32(cols))
		total += w
	}
	for &w in widths {
		w *= width / total
	}

	if clay.UI(clay.ID("MsgTable", id))(
	{
		layout = {layoutDirection = .TopToBottom},
		backgroundColor = md_hover(depth),
		border = {color = FIELD_BORDER, width = bw()},
		cornerRadius = rr(4),
	},
	) {
		for row, r in cells {
			if clay.UI(clay.ID("MsgTableRow", id + u32(r) * 64))(
			{layout = {}, backgroundColor = md_hover(depth + 1, r == 0 ? PLATE : {})},
			) {
				for c in 0 ..< cols {
					text := c < len(row) ? row[c] : ""
					pad := u16(min(f32(MD_TABLE_PAD), widths[c] / 4))
					align := c < len(alignments) ? alignments[c] : marmot.Markdown_Alignment.None
					inner_w := max(f32(1), widths[c] - f32(pad) * 2)
					if clay.UI(clay.ID("MsgTableCell", id + u32(r) * 64 + u32(c)))(
					{
						layout = {
							layoutDirection = .TopToBottom,
							sizing = {
								width = clay.SizingFixed(widths[c]),
								height = clay.SizingGrow(),
							},
							padding = clay.PaddingAll(pad),
						},
						backgroundColor = md_hover(depth + 2),
						border = {
							color = FIELD_BORDER,
							width = {0, c < cols - 1 ? 1 : 0, 0, r < len(cells) - 1 ? 1 : 0, 0},
						},
					},
					) {
						fonts :=
							r < len(cell_fonts) && c < len(cell_fonts[r]) ? cell_fonts[r][c] : ""
						if r == 0 && len(fonts) == 0 {
							font := [1]u8{FONT_TITLE}
							fonts = strings.repeat(
								string(font[:]),
								len(text),
								context.temp_allocator,
							)
						}
						for line in wrapped_lines(text, inner_w, 13, fonts = fonts) {
							if clay.UI()(
							{
								layout = {
									sizing = {width = clay.SizingFixed(inner_w)},
									childAlignment = {
										x = align == .Right ? .Right : (align == .Center ? .Center : .Left),
									},
								},
							},
							) {
								body_line(
									(id + u32(r) * 64 + u32(c)) * 128 + line.index,
									text[line.start:line.end],
									13,
									TEXT,
									fonts = text_fonts(fonts, line.start, line.end),
									links = r < len(cell_links) && c < len(cell_links[r]) ? cell_links[r][c][:] : nil,
									offset = line.start,
								)
							}
						}
					}
				}
			}
		}
	}
}
// the preview modal. id_base namespaces the clay ids per call site.
// wrap_w pre-wraps paragraphs to a width (event cards); 0 leaves
// wrapping to clay or, when selectable, the timeline measure.
md_blocks :: proc(
	blocks: []Md_Block_Ui,
	id_base: u32,
	selectable := false,
	wrap_w: f32 = 0,
	max_lines: int = max(int),
	quote_level: u16 = 0,
	indent_base: u16 = 0,
	lines_used: ^int = nil,
	emoji := Emoji_Scale.Inline,
) -> bool {
	remaining := max_lines
	defer {if lines_used != nil {lines_used^ = max_lines - remaining}}
	for j := 0; j < len(blocks); j += 1 {
		block := blocks[j]
		if remaining <= 0 {return true}
		block_id := id_base + u32(j) * 16
		gap_lines := int(block.blank_lines_before)
		if j == 0 && quote_level > 0 {gap_lines = 0}
		// Keep lists close to their introduction; preserve any extra blank lines.
		if block.kind == .List_Item {
			gap_lines = max(gap_lines - 1, 0)
		}
		if gap_lines > 0 {
			// Paragraph spacing is half a line and does not consume the text excerpt.
			gap := f32(gap_lines) * f32(BODY_FS) / 2
			if clay.UI(clay.ID("MdGap", block_id))(
			{layout = {sizing = {height = clay.SizingFixed(gap)}}},
			) {}
		}
		used := 1
		available := wrap_w > 0 ? wrap_w : body_wrap_w()
		indent := min(f32(max(int(block.indent) - int(indent_base), 0)), available / 2)
		depth := max(block.quote_depth, block.kind == .Quote ? u16(1) : 0)
		if depth > quote_level && available - indent > 24 {
			end := j + 1
			for end < len(blocks) {
				next := blocks[end]
				next_depth := max(next.quote_depth, next.kind == .Quote ? u16(1) : 0)
				if next_depth <= quote_level ||
				   next.quote_starts >= next_depth - quote_level {break}
				end += 1
			}
			cropped := false
			if clay.UI(clay.ID("MsgQuoteGroup", block_id * 128 + u32(quote_level)))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(available)},
					padding = {left = u16(indent)},
					childGap = 8,
				},
				backgroundColor = md_hover(quote_level + block.indent / 24),
				cornerRadius = rr(3),
			},
			) {
				if clay.UI(
					quote_level == 0 ? clay.ID("MsgQuoteBar", block_id) : clay.ID("MsgQuoteInner", block_id * 128 + u32(quote_level)),
				)(
				{
					layout = {sizing = {width = clay.SizingFixed(3), height = clay.SizingGrow()}},
					backgroundColor = mix_color(
						ACCENT,
						TEXT_DIM,
						min(f32(quote_level) * 0.3, 0.8),
					),
					cornerRadius = rr(2),
				},
				) {}
				if clay.UI()(
				{
					layout = {
						layoutDirection = .TopToBottom,
						sizing = {width = clay.SizingGrow()},
						childGap = 3,
					},
				},
				) {
					cropped = md_blocks(
						blocks[j:end],
						block_id,
						selectable,
						available - indent - 11,
						remaining,
						quote_level + 1,
						max(indent_base, block.indent),
						&used,
					)
				}
			}
			remaining -= used
			if cropped {return true}
			j = end - 1
			continue
		}
		width := max(f32(1), available - indent)
		if clay.UI(clay.ID("MdBlock", block_id))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingFixed(available)},
				padding = {left = u16(indent)},
			},
		},
		) {
			switch block.kind {
			case .Para, .Quote:
				used = body_text(
					block_id + 1,
					block.text,
					BODY_FS,
					block.kind == .Quote ? TEXT_DIM : TEXT,
					selectable,
					width,
					remaining,
					block.fonts,
					// Jumbo only when this paragraph is the whole body.
					len(blocks) == 1 && block.kind == .Para ? emoji : .Inline,
					block.links[:],
				)
			case .Heading:
				size := u16(max(24 - block.level * 2, 15))
				marks := strings.repeat("#", clamp(block.level, 1, 6), context.temp_allocator)
				fonts := block.fonts
				font := [1]u8{FONT_TITLE}
				if len(fonts) ==
				   0 {fonts = strings.repeat(string(font[:]), len(block.text), context.temp_allocator)}
				if clay.UI(clay.ID("MdHeading", block_id))(
				{layout = {sizing = {width = clay.SizingGrow()}}},
				) {
					show_marks := clay.PointerOver(clay.ID("MdHeading", block_id))
					reveal := anim_to(
						clay.ID("MdHeadingMarks", block_id).id,
						show_marks ? 1 : 0,
						HOVER_RATE,
					)
					full_gutter := rl.MeasureTextLine(FONT_MONO, size, marks, 0).x + 6
					gutter := full_gutter * reveal
					if reveal > 0 {
						if clay.UI(clay.ID("MdHeadingMarks", block_id))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(gutter),
									height = clay.SizingFixed(f32(size)),
								},
								childAlignment = {y = .Center},
							},
							clip = {horizontal = true, childOffset = {gutter - full_gutter, 0}},
						},
						) {clay.Text(marks, {fontId = FONT_MONO, fontSize = size, textColor = fade(TEXT_LO, reveal), wrapMode = .None})}
					}
					if clay.UI(clay.ID("MdHeadingText", block_id))(
					{layout = {layoutDirection = .TopToBottom}},
					) {
						used = body_text(
							block_id + 1,
							block.text,
							size,
							TEXT,
							selectable,
							max(f32(1), width - gutter),
							remaining,
							fonts,
							links = block.links[:],
						)
					}
				}
			case .Math:
				// Typeset when MicroTeX accepts it, centered like display
				// math; otherwise fall through to the source on the plate.
				if tex := math_texture(block.text); tex != nil {
					if clay.UI(clay.ID("MsgMath", block_id))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							padding = clay.PaddingAll(10),
							childAlignment = {x = .Center},
						},
						backgroundColor = CODE_PLATE,
						cornerRadius = rr(6),
						border = {color = FIELD_BORDER, width = {1, 1, 1, 1, 0}},
					},
					) {
						// Wider than the bubble: scale down rather than clip.
						w := min(f32(tex.width) / UI_SCALE, max(f32(1), width - 20))
						if clay.UI()(
						{
							layout = {sizing = {width = clay.SizingFixed(w)}},
							aspectRatio = {f32(tex.width) / f32(tex.height)},
							image = {imageData = tex},
						},
						) {}
					}
					break
				}
				fallthrough
			case .Code:
				text := block.kind == .Math ? strings.trim_right(block.text, "\n") : block.text
				if clay.UI(clay.ID("MsgCode", block_id))(
				{
					layout = {
						layoutDirection = .TopToBottom,
						sizing = {width = clay.SizingGrow()},
						padding = clay.PaddingAll(10),
						childGap = 3,
					},
					backgroundColor = CODE_PLATE,
					cornerRadius = rr(6),
					border = {color = FIELD_BORDER, width = {1, 1, 1, 1, 0}},
				},
				) {
					font := [1]u8{FONT_MONO | (block.kind == .Math ? TEXT_MATH : TEXT_CODE)}
					fonts := strings.repeat(string(font[:]), len(text), context.temp_allocator)
					gutter :=
						block.kind == .Code ? rl.MeasureTextLine(FONT_MONO, 11, fmt.tprintf("%d", strings.count(block.text, "\n") + 1), 0).x + 10 : 0
					lines := wrapped_lines(
						text,
						max(f32(1), width - 20 - gutter),
						13,
						fonts = fonts,
					)
					used = len(lines)
					number, scanned := 1, 0
					for line in lines[:min(used, remaining)] {
						for scanned < line.start {
							if block.text[scanned] == '\n' {number += 1}
							scanned += 1
						}
						if clay.UI()({layout = {sizing = {height = clay.SizingFixed(13)}}}) {
							if block.kind == .Code {
								if clay.UI()(
								{
									layout = {
										sizing = {width = clay.SizingFixed(gutter)},
										padding = {right = 10},
										childAlignment = {x = .Right},
									},
								},
								) {
									if line.start == 0 ||
									   block.text[line.start - 1] ==
										   '\n' {clay.Text(fmt.tprintf("%d", number), {fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO})}
								}
							}
							md_code_text(
								block.text[line.start:line.end],
								text_fonts(block.code_kinds, line.start, line.end),
								13,
								text_fonts(block.fonts, line.start, line.end),
							)
						}
					}
				}
			case .List_Item:
				marker := block.text[:block.marker_len]
				task := marker == "[ ] " || marker == "[x] "
				marker_w := max(f32(12), rl.MeasureTextLine(FONT_BODY, BODY_FS, marker, 0).x)
				if task {marker_w = 18}
				if clay.UI(clay.ID("MsgListItem", block_id))(
				{
					layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 12}},
					backgroundColor = md_hover(quote_level + block.indent / 24),
					cornerRadius = rr(3),
				},
				) {
					if clay.UI(clay.ID("MsgListMarker", block_id))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(marker_w),
								height = clay.SizingFixed(f32(BODY_FS)),
							},
							childAlignment = {y = .Center},
						},
					},
					) {
						if task {
							if clay.UI(clay.ID("MdTask", block_id))(
							{
								layout = {
									sizing = {
										width = clay.SizingFixed(12),
										height = clay.SizingFixed(12),
									},
									childAlignment = {x = .Center, y = .Center},
								},
								border = {
									color = marker == "[x] " ? ACCENT : TEXT_DIM,
									width = {1, 1, 1, 1, 0},
								},
								backgroundColor = marker == "[x] " ? SELECTED : {},
								cornerRadius = rr(2),
							},
							) {
								if marker ==
								   "[x] " {clay.Text(ICON_CHECK, {fontId = FONT_ICON, fontSize = 12, textColor = ACCENT})}
							}
						} else {clay.Text(
								marker,
								{fontId = FONT_BODY, fontSize = BODY_FS, textColor = TEXT},
							)}
					}
					if clay.UI(clay.ID("MsgListBody", block_id))(
					{layout = {layoutDirection = .TopToBottom}},
					) {
						used = body_text(
							block_id + 2,
							block.text[block.marker_len:],
							BODY_FS,
							TEXT,
							selectable,
							width > 0 ? max(f32(1), width - 12 - marker_w) : 0,
							remaining,
							text_fonts(block.fonts, block.marker_len, len(block.text)),
							links = block.links[:],
							link_offset = block.marker_len,
						)
					}
				}
			case .Image:
				image_link(block_id, block.text, 11, min(width > 0 ? width : att_w(), att_w()))
			case .Rule:
				if clay.UI(clay.ID("MsgRule", block_id))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(width), height = clay.SizingFixed(1)},
					},
					backgroundColor = TEXT_DIM,
				},
				) {}
			case .Table:
				used = len(block.cells)
				md_table(
					block_id,
					block.cells[:min(used, remaining)],
					block.cell_fonts,
					block.alignments,
					width,
					quote_level + block.indent / 24,
					block.cell_links,
				)
			}
		}
		cropped := used > remaining
		remaining -= min(used, remaining)
		if cropped {return true}
	}
	return false
}

// One body_line per physical line. `selectable` registers the lines
// with bodysel.odin, which needs each line's byte range inside `text`;
// the walk therefore slices `text` itself instead of split_lines, whose
// copies carry no offsets. Selectable bodies are also wrapped here
// rather than by clay: a selection highlight splits a line into three
// spans, and clay only wraps a whole Text element. Break points come
// from measured widths.
// `wrap_w` forces wrapping at that width for non-selectable bodies
// whose container clay can't wrap into (reply previews, edit history).
body_text :: proc(
	id: u32,
	text: string,
	font_size: u16,
	color: clay.Color,
	selectable := false,
	wrap_w: f32 = 0,
	max_lines: int = max(int),
	fonts: string = "",
	emoji := Emoji_Scale.Inline,
	links: []Inline_Link = nil,
	link_offset: int = 0,
) -> int {
	wrap := wrap_w > 0 ? wrap_w : (selectable ? body_wrap_w() : 0)
	tile_px := body_tile_size(text, font_size, emoji)
	mode: Wrap_Mode = link_cards_enabled() ? .Cards : .Text
	lines := wrapped_lines(text, wrap, font_size, mode, fonts, tile_px)
	count := len(lines)
	lines = lines[:min(len(lines), max_lines)]
	// Parse destinations before wrapping: every visible fragment keeps
	// the original URL, including a fragment without an http prefix.
	runs := make([dynamic]Inline_Link, context.temp_allocator)
	visible_end := len(lines) > 0 ? lines[len(lines) - 1].end : 0
	link_index := 0
	for at := 0; at < visible_end; {
		for link_index < len(links) && links[link_index].end <= at + link_offset {link_index += 1}
		if link_index < len(links) && links[link_index].start <= at + link_offset {
			link := links[link_index]
			append(&runs, Inline_Link{link.start - link_offset, link.end - link_offset, link.url})
			at = link.end - link_offset
			continue
		}
		end :=
			link_index < len(links) ? min(len(text), links[link_index].start - link_offset) : len(text)
		if text_literal(fonts, at) {at += 1; continue}
		if end, url, ok := url_at(text[:end], at); ok {
			append(&runs, Inline_Link{at, end, url})
			at = end
		} else {at += 1}
	}
	first := 0
	for line in lines {
		for first < len(runs) && runs[first].end <= line.start {first += 1}
		last := first
		for last < len(runs) && runs[last].start < line.end {last += 1}
		line_id := id * 8 + line.index
		if selectable {
			sel_register(
				line_id,
				id,
				line.start,
				text[line.start:line.end],
				text,
				font_size,
				tile_px,
				text_fonts(fonts, line.start, line.end),
			)
			body_line(
				line_id,
				text[line.start:line.end],
				font_size,
				color,
				sel_range(id, line.start, line.end - line.start),
				true,
				tile_px,
				text_fonts(fonts, line.start, line.end),
				runs[first:last],
				line.start,
			)
		} else {
			body_line(
				line_id,
				text[line.start:line.end],
				font_size,
				color,
				tile_px = tile_px,
				fonts = text_fonts(fonts, line.start, line.end),
				links = runs[first:last],
				offset = line.start,
			)
		}
	}
	return count
}

@(private)
DEFAULT_MESSAGE_LINES :: 6

@(private)
EXCERPT_DURATION :: 100 * time.Millisecond

@(private)
Excerpt :: struct {
	expanded:                   bool,
	changed:                    time.Tick,
	from_height, closed_height: f32,
}

@(private)
Excerpt_Source :: enum {
	Message,
	Embed,
}

@(private)
message_line_limit :: proc() -> int {
	if g_prefs == nil {return DEFAULT_MESSAGE_LINES}
	return g_prefs.message_lines > 0 ? g_prefs.message_lines : max(int)
}

@(private)
excerpt_toggle :: proc(state: ^Excerpt, id: u32) {
	state.from_height = clay.GetElementData(clay.ID("ExcerptClip", id)).boundingBox.height
	if !state.expanded &&
	   (state.changed == {} || time.tick_since(state.changed) >= EXCERPT_DURATION) {
		state.closed_height = state.from_height
	}
	state.expanded = !state.expanded
	state.changed = time.tick_now()
}

@(private)
excerpt_body :: proc(
	id: u32,
	text: string,
	blocks: []Md_Block_Ui,
	state: Excerpt,
	width: f32,
	color: clay.Color,
	source: Excerpt_Source = .Message,
	emoji := Emoji_Scale.Inline,
) -> bool {
	if len(text) == 0 && len(blocks) == 0 {return false}
	threshold := message_line_limit()
	progress :=
		state.changed == {} || !motion_on() ? f32(1) : clamp(f32(time.tick_since(state.changed)) / f32(EXCERPT_DURATION), 0, 1)
	moving := threshold < max(int) && progress < 1
	limit := state.expanded || moving ? max(int) : threshold
	height := clay.SizingFit()
	if moving {
		full := clay.GetElementData(clay.ID("ExcerptBody", id)).boundingBox.height
		target := state.expanded ? full : state.closed_height
		eased := progress * progress * (3 - 2 * progress)
		height = clay.SizingFixed(state.from_height + (target - state.from_height) * eased)
		anim_moving += 1
	}
	more := state.expanded || moving
	if clay.UI(clay.ID("ExcerptClip", id))(
	{
		layout = {sizing = {width = clay.SizingFixed(width), height = height}},
		clip = {vertical = moving},
	},
	) {
		if clay.UI(clay.ID("ExcerptBody", id))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingFixed(width)},
				childGap = 3,
			},
		},
		) {
			if len(blocks) > 0 {
				lines: int
				more =
					md_blocks(
						blocks,
						id,
						source == .Message,
						width,
						limit,
						lines_used = &lines,
						emoji = emoji,
					) ||
					more
				more ||= lines > threshold
			} else {
				more =
					body_text(
						id,
						text,
						BODY_FS,
						color,
						source == .Message,
						width,
						limit,
						emoji = emoji,
					) >
						threshold ||
					more
			}
		}
	}
	return threshold < max(int) && more
}

// Plain fallback for pending messages and records without parsed blocks.
@(private)
message_excerpt :: proc(id: u32, text: string, color: clay.Color, state: Excerpt = {}) -> bool {
	threshold := message_line_limit()
	if threshold == max(int) ||
	   len(wrapped_lines(text, body_wrap_w(), BODY_FS)) <= threshold {return false}
	cards := gh_cards_on
	gh_cards_on = false
	excerpt_body(id, text, nil, state, body_wrap_w(), color)
	gh_cards_on = cards
	message_more(id, state)
	return true
}

@(private)
message_more :: proc(id: u32, state: Excerpt = {}) {
	if message_line_limit() == max(int) {return}
	if clay.UI(clay.ID("MessageMore", id))(
	{
		layout = {padding = {top = 4, bottom = 4}},
		backgroundColor = hovered() ? HOVER : {},
		cornerRadius = rr(4),
	},
	) {
		clay.Text(
			state.expanded ? tr("Show less") : tr("Read more"),
			{fontId = FONT_BODY, fontSize = 12, textColor = ACCENT},
		)
	}
}

// Text width available to a message body: the timeline column from the
// previous frame, minus the row padding, the avatar and its gap. The
// pre-layout default is a readable measure, corrected on frame two.
// The box is capped by what the window can hold: it is one frame
// behind and inflated by its own over-long lines, so after a shrink
// the rewrap otherwise crawls toward the new width a word per frame.
body_wrap_w :: proc() -> f32 {
	MSG_ROW_CHROME :: f32(16 + 16 + 28 + 10 + 8) // paddings, avatar, gap, slack
	tl := clay.GetElementData(clay.ID("Timeline"))
	if !tl.found {
		return 480
	}
	avail := page_w(g_ui)
	if g_ui.issues_open {avail = tl.boundingBox.width - (page_w(g_ui) < 720 ? 40 : 64)}
	return max(min(tl.boundingBox.width, avail) - MSG_ROW_CHROME, 120)
}

// Widest an attachment tile draws: its design width, or the message
// column when that is narrower. A 320px tile in a 300px column is the
// same clipped edge a fixed-width modal gives a narrow window.
att_w :: proc(w: f32 = 320) -> f32 {
	return min(w, body_wrap_w())
}

// How a body of at most six emoji and nothing else draws them. Inline
// (quotes, previews, rows) uses 28px tiles; Jumbo (a message body)
// uses the art's native EMOJI_SIDE physical pixels, ~85 logical at 1.5x.
@(private)
Emoji_Scale :: enum {
	Inline,
	Jumbo,
}

// Pick emoji size for the whole body, so a short wrapped tail does
// not grow larger than the tiles used to measure its line.
@(private)
body_tile_size :: proc(text: string, font_size: u16, scale := Emoji_Scale.Inline) -> f32 {
	text_px := f32(font_size) + 4
	tiles := 0
	it := utf8.decode_grapheme_iterator_make(text)
	for cluster, _ in rl.grapheme_iterate(&it) {
		if text_emoji(cluster) != nil {
			tiles += 1
			if tiles > 6 {return text_px}
		} else if len(strings.trim_space(cluster)) > 0 {
			return text_px
		}
	}
	if tiles == 0 {
		return text_px
	}
	return scale == .Jumbo ? f32(EMOJI_SIDE) / UI_SCALE : 28
}

// Greedy break at whole words, or whole graphemes in an over-long word.
wrap_break :: proc(
	text: string,
	at, end: int,
	width: f32,
	font_size: u16,
	mode: Wrap_Mode = .Text,
	tile_px: f32 = 0,
	fonts: string = "",
) -> int {
	// Only measure the current line. Measuring the whole next word
	// rescans a long unbroken suffix once per line (quadratic work).
	fit := rune_fit(text, at, end, width, font_size, mode, tile_px, fonts)
	if fit == end || text[fit] == ' ' {
		return fit
	}
	cut := fit
	for cut > at && text[cut - 1] != ' ' {
		cut -= 1
	}
	for cut > at && text[cut - 1] == ' ' {
		cut -= 1
	}
	if cut > at {
		if mode == .Compose {
			for cut < fit && text[cut] == ' ' {cut += 1}
		}
		return cut
	}
	// An event token stays whole because its card replaces the text.
	word := at
	for word < fit && text[word] == ' ' {
		word += 1
	}
	if mode != .Compose && !text_literal(fonts, word) {
		if tok_end, _, _, is_event := nevent_at(text, word);
		   is_event && tok_end <= end {return tok_end}
	}
	return fit
}

// Longest prefix of [at, end) that fits `width`, keeping emoji
// graphemes intact and returning at least one cluster.
rune_fit :: proc(
	text: string,
	at, end: int,
	width: f32,
	font_size: u16,
	mode: Wrap_Mode = .Text,
	tile_px: f32 = 0,
	fonts: string = "",
) -> int {
	pen: f32 = 0
	previous_emoji := false
	skip := at
	it := utf8.decode_grapheme_iterator_make(text[at:end])
	for cluster, grapheme in rl.grapheme_iterate(&it) {
		i := at + grapheme.byte_index
		if i < skip {continue}
		literal := text_literal(fonts, i)
		// Chips are atoms; composer segments sit flush, bodies 2px apart.
		next, atom_width := 0, f32(0)
		switch {
		case literal:
		case mode == .Compose:
			next, atom_width = compose_atom(text[:end], i)
		case:
			next, atom_width = body_atom(text[:end], i, font_size)
			if i > at {atom_width += 2}
		}
		if next > i {
			if i > at && pen + atom_width > width {return i}
			pen += atom_width
			skip, previous_emoji = next, true
			continue
		}
		adv := rl.MeasureTextLine(text_font(fonts, i), font_size, cluster, 0).x
		emoji := !literal && text_emoji(cluster) != nil
		if emoji {adv = mode == .Compose ? 18 : (tile_px > 0 ? tile_px : f32(font_size) + 4)}
		// Body segments have a 2px gap; plain graphemes share one run.
		if mode != .Compose && i > at && (emoji || previous_emoji) {adv += 2}
		if i > at && pen + adv > width {
			return i
		}
		pen += adv
		previous_emoji = emoji
	}
	return end
}
