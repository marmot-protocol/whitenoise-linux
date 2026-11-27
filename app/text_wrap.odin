package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"

import rl "sdlrl"

@(private)
Wrap_Key :: struct {
	text:       string,
	width:      f32,
	scale:      f32,
	size:       u16,
	mode:       Wrap_Mode,
	fonts:      string,
	tile_px:    f32, // 0 = body_tile_size's pick
	labels:     string,
	plain_font: u16,
}
@(private)
Wrap_Mode :: enum {
	Text,
	Cards,
	Links, // web cards, but event references stay wrapped text inside an event card
	Compose,
	Plain,
}
@(private)
Wrap_Line :: struct {
	start, end: int,
	index:      u32,
}

@(private)
Wrap_Label :: struct {
	start, end: int,
	inset:      int,
}

@(private)
wrap_labels :: proc(text: string, links: []Inline_Link, mode: Wrap_Mode) -> []Wrap_Label {
	if len(links) == 0 {return nil}
	labels := make([]Wrap_Label, len(links), context.temp_allocator)
	count := 0
	for link in links {
		start, end := max(0, link.start), min(len(text), link.end)
		if start >= end {continue}
		if (mode == .Cards || mode == .Links) && text[start:end] == link.url {
			// A URL that is its own label can still draw as a preview or GitHub chip.
			if _, gh := gh_ref(link.url);
			   gh || link_card(link.url, link_place(text, start, end)) {continue}
		}
		labels[count] = {start, end, link.url == "" ? 0 : LINK_INSET}
		count += 1
	}
	return labels[:count]
}

@(private)
wrap_label_at :: proc(labels: ^[]Wrap_Label, at: int) -> (label: Wrap_Label, boundary: bool) {
	for len(labels^) > 0 && labels^[0].end <= at {
		boundary = boundary || labels^[0].end == at
		labels^ = labels^[1:]
	}
	if len(labels^) > 0 {
		label = labels^[0]
		boundary = boundary || label.start == at
	}
	return
}

@(private)
wrap_cache: map[Wrap_Key][]Wrap_Line
@(private)
wrap_bytes: int
@(private)
wrap_flush: bool
@(private)
WRAP_CACHE_BYTES :: 4 * 1024 * 1024

@(private)
wrap_clear :: proc() {
	context.allocator = runtime.default_context().allocator
	compose_cache_forget()
	for key, lines in wrap_cache {
		delete(key.text)
		delete(key.fonts)
		delete(key.labels)
		delete(lines)
	}
	clear(&wrap_cache)
	wrap_bytes = 0
	wrap_flush = false
}

@(private)
wrapped_lines :: proc(
	text: string,
	width: f32,
	size: u16,
	mode: Wrap_Mode = .Text,
	fonts: string = "",
	tile_px: f32 = 0,
	labels: []Wrap_Label = nil,
	plain_font: u16 = FONT_BODY,
) -> []Wrap_Line {
	key := Wrap_Key {
		text,
		width,
		UI_SCALE,
		size,
		mode,
		fonts,
		tile_px,
		string(mem.slice_to_bytes(labels)),
		plain_font,
	}
	if lines, hit := wrap_cache[key]; hit && !wrap_flush {return lines}
	lines := make([dynamic]Wrap_Line, context.temp_allocator)
	plan_wrap_lines(&lines, text, width, size, mode, fonts, tile_px, plain_font, labels)
	bytes := len(text) + len(fonts) + len(key.labels) + len(lines) * size_of(Wrap_Line)
	if bytes > WRAP_CACHE_BYTES {return lines[:]}
	// Evict between frames: a nested link card may still be reading an
	// outer paragraph's spans. Large misses use this frame's scratch space.
	// ponytail: bounded wholesale eviction; use LRU if mixed long bodies churn.
	if wrap_flush || wrap_bytes + bytes > WRAP_CACHE_BYTES || len(wrap_cache) >= 1024 {
		wrap_flush = true
		return lines[:]
	}
	context.allocator = runtime.default_context().allocator
	key.text = strings.clone(text)
	key.fonts = strings.clone(fonts)
	key.labels = strings.clone(key.labels)
	owned := make([]Wrap_Line, len(lines))
	copy(owned, lines[:])
	wrap_cache[key] = owned
	wrap_bytes += bytes
	return owned
}

@(private)
plan_wrap_lines :: proc(
	lines: ^[dynamic]Wrap_Line,
	text: string,
	width: f32,
	size: u16,
	mode: Wrap_Mode,
	fonts: string = "",
	tile_px: f32 = 0,
	plain_font: u16 = FONT_BODY,
	labels: []Wrap_Label = nil,
) {
	labels := labels
	tile_px := tile_px
	if mode != .Plain && tile_px <= 0 {
		tile_px = mode == .Compose ? 18 : body_tile_size(text, size)
	}
	start := 0
	i: u32
	for {
		end := len(text)
		if nl := strings.index_byte(text[start:], '\n'); nl >= 0 {end = start + nl}
		at := start
		if at == end {append(lines, Wrap_Line{at, at, i})}
		for at < end {
			// Cards occupy a whole row, even when their URL is wider
			// than the column. Keep source offsets for selection/copy.
			card_at, card_end := end, end
			if mode == .Cards || mode == .Links {
				scan_labels := labels
				for scan := at; scan < end; scan += 1 {
					label, _ := wrap_label_at(&scan_labels, scan)
					if scan < label.end && scan >= label.start {scan = label.end - 1; continue}
					if text_literal(fonts, scan) {continue}
					limit := scan < label.start ? min(end, label.start) : end
					if mode == .Cards {
						if next, _, _, ok := nevent_at(text[:limit], scan); ok {
							card_at, card_end = scan, next
							break
						}
					}
					if text[scan] != 'h' {continue}
					if next, url, ok := url_at(text[:limit], scan); ok {
						if link_card(url, link_place(text, scan, next)) {
							card_at, card_end = scan, next
							// Android's "Location: <url>" puts its caption
							// on the card's row, where render_segs drops it.
							if strings.trim_space(text[at:scan]) == GEO_CAPTION {card_at = at}
							break
						}
						scan = next - 1
					}
				}
			}
			for at < card_at {
				for len(labels) > 0 && labels[0].end <= at {labels = labels[1:]}
				cut :=
					width > 0 ? wrap_break(text, at, card_at, width, size, mode, tile_px, fonts, plain_font, labels) : card_at
				append(lines, Wrap_Line{at, cut, i})
				i += 1
				at = cut
				if at < card_at && text[at] == ' ' {at += 1}
			}
			if card_at < end {
				append(lines, Wrap_Line{card_at, card_end, i})
				i += 1
				at = card_end
			}
			if at < end && text[at] == ' ' {at += 1}
		}
		if end == len(text) {break}
		start = end + 1
		i += 1
	}
}

// Which end of a string text_fit keeps.
@(private)
Fit_End :: enum {
	Head, // text[:cut]
	Tail, // text[cut:]
}

// Byte offset of the widest cut, on a UTF-8 rune boundary, whose kept
// end of one-font `text` is no wider than `width`. Binary search over
// byte offsets snapped back onto rune starts: log2(len) measurements
// rather than one per rune. The empty end always fits, so 0 (.Head) or
// len(text) (.Tail) is the floor.
@(private)
text_fit :: proc(text: string, width: f32, font, size: u16, keep: Fit_End) -> int {
	lo, hi := 0, len(text)
	switch keep {
	case .Head:
		for lo < hi {
			mid := (lo + hi + 1) / 2
			if rl.MeasureTextLine(font, size, text[:rune_snap(text, mid)], 0).x <= width {
				lo = mid
			} else {
				hi = mid - 1
			}
		}
	case .Tail:
		for lo < hi {
			mid := (lo + hi) / 2
			if rl.MeasureTextLine(font, size, text[rune_snap(text, mid):], 0).x <= width {
				hi = mid
			} else {
				lo = mid + 1
			}
		}
	}
	return rune_snap(text, lo)
}

// Shorten one-font text to `width` with a trailing ellipsis, so a label
// needs no clip element of its own:
//   Mountain marmot at sunrise.png  ->  Mountain marmot at su…
@(private)
text_ellipsis :: proc(text: string, width: f32, font, size: u16) -> string {
	if rl.MeasureTextLine(font, size, text, 0).x <= width {
		return text
	}
	room := max(0, width - rl.MeasureTextLine(font, size, "…", 0).x)
	return fmt.tprintf("%s…", text[:text_fit(text, room, font, size, .Head)])
}
