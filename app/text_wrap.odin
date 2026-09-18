package main

import "core:strings"
import "base:runtime"

@(private)
Wrap_Key :: struct { text: string, width: f32, scale: f32, size: u16, mode: Wrap_Mode }
@(private)
Wrap_Mode :: enum { Text, Cards, Compose }
@(private)
Wrap_Line :: struct { start, end: int, index: u32 }
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
		delete(lines)
	}
	clear(&wrap_cache)
	wrap_bytes = 0
	wrap_flush = false
}

@(private)
wrapped_lines :: proc(text: string, width: f32, size: u16, mode: Wrap_Mode = .Text) -> []Wrap_Line {
	key := Wrap_Key{text, width, UI_SCALE, size, mode}
	if lines, hit := wrap_cache[key]; hit { return lines }
	tile_px := mode == .Compose ? f32(18) : body_tile_size(text, size)
	lines := make([dynamic]Wrap_Line, context.temp_allocator)
	start := 0
	i: u32
	for {
		end := len(text)
		if nl := strings.index_byte(text[start:], '\n'); nl >= 0 { end = start + nl }
		at := start
		if at == end { append(&lines, Wrap_Line{at, at, i}) }
		for at < end {
			// Cards occupy a whole row, even when their URL is wider
			// than the column. Keep source offsets for selection/copy.
			card_at, card_end := end, end
			if mode == .Cards {
				for scan := at; scan < end; scan += 1 {
					if text[scan] != 'h' { continue }
					if next, url, ok := url_at(text[:end], scan); ok {
						if _, card := gh_ref(url); card {
							card_at, card_end = scan, next
							break
						}
						scan = next - 1
					}
				}
			}
			for at < card_at {
				cut := width > 0 ? wrap_break(text, at, card_at, width, size, mode, tile_px) : card_at
				append(&lines, Wrap_Line{at, cut, i})
				i += 1
				at = cut
				if at < card_at && text[at] == ' ' { at += 1 }
			}
			if card_at < end {
				append(&lines, Wrap_Line{card_at, card_end, i})
				i += 1
				at = card_end
			}
			if at < end && text[at] == ' ' { at += 1 }
		}
		if end == len(text) { break }
		start = end + 1
		i += 1
	}
	bytes := len(text) + len(lines) * size_of(Wrap_Line)
	if bytes > WRAP_CACHE_BYTES { return lines[:] }
	// Evict between frames: a nested link card may still be reading an
	// outer paragraph's spans. Large misses use this frame's scratch space.
	// ponytail: bounded wholesale eviction; use LRU if mixed long bodies churn.
	if wrap_bytes + bytes > WRAP_CACHE_BYTES || len(wrap_cache) >= 1024 {
		wrap_flush = true
		return lines[:]
	}
	context.allocator = runtime.default_context().allocator
	key.text = strings.clone(text)
	owned := make([]Wrap_Line, len(lines))
	copy(owned, lines[:])
	wrap_cache[key] = owned
	wrap_bytes += bytes
	return owned
}
