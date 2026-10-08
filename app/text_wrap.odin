package main

import "base:runtime"
import "core:fmt"
import "core:strings"

import rl "sdlrl"

@(private)
Wrap_Key :: struct {
	text:    string,
	width:   f32,
	scale:   f32,
	size:    u16,
	mode:    Wrap_Mode,
	fonts:   string,
	tile_px: f32, // 0 = body_tile_size's pick
}
@(private)
Wrap_Mode :: enum {
	Text,
	Cards,
	Links, // web cards, but event references stay wrapped text inside an event card
	Compose,
}
@(private)
Wrap_Line :: struct {
	start, end: int,
	index:      u32,
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
	delete(compose_cache.text)
	delete(compose_cache.lines)
	compose_cache = {}
	for key, lines in wrap_cache {
		delete(key.text)
		delete(key.fonts)
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
) -> []Wrap_Line {
	key := Wrap_Key{text, width, UI_SCALE, size, mode, fonts, tile_px}
	if lines, hit := wrap_cache[key]; hit && !wrap_flush {return lines}
	tile_px := tile_px > 0 ? tile_px : (mode == .Compose ? f32(18) : body_tile_size(text, size))
	lines := make([dynamic]Wrap_Line, context.temp_allocator)
	start := 0
	i: u32
	for {
		end := len(text)
		if nl := strings.index_byte(text[start:], '\n'); nl >= 0 {end = start + nl}
		at := start
		if at == end {append(&lines, Wrap_Line{at, at, i})}
		for at < end {
			// Cards occupy a whole row, even when their URL is wider
			// than the column. Keep source offsets for selection/copy.
			card_at, card_end := end, end
			if mode == .Cards || mode == .Links {
				for scan := at; scan < end; scan += 1 {
					if text_literal(fonts, scan) {continue}
					if mode == .Cards {
						if next, _, _, ok := nevent_at(text[:end], scan); ok {
							card_at, card_end = scan, next
							break
						}
					}
					if text[scan] != 'h' {continue}
					if next, url, ok := url_at(text[:end], scan); ok {
						if link_card(url) {
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
				cut :=
					width > 0 ? wrap_break(text, at, card_at, width, size, mode, tile_px, fonts) : card_at
				append(&lines, Wrap_Line{at, cut, i})
				i += 1
				at = cut
				if at < card_at && text[at] == ' ' {at += 1}
			}
			if card_at < end {
				append(&lines, Wrap_Line{card_at, card_end, i})
				i += 1
				at = card_end
			}
			if at < end && text[at] == ' ' {at += 1}
		}
		if end == len(text) {break}
		start = end + 1
		i += 1
	}
	bytes := len(text) + len(fonts) + len(lines) * size_of(Wrap_Line)
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
	owned := make([]Wrap_Line, len(lines))
	copy(owned, lines[:])
	wrap_cache[key] = owned
	wrap_bytes += bytes
	return owned
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
