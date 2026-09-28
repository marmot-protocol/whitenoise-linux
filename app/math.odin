// Math blocks are rendered by the isolated wn-math helper into RGBA textures.
// Failed requests cache a nil entry so the timeline draws the source text.
package main

import "core:c"
import "core:c/libc"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

foreign import math_decoder {WN_BUILD_DIR + "/libwndecoder.a"}

@(private = "file", default_calling_convention = "c")
foreign math_decoder {
	wn_math_render :: proc(helper: cstring, data: [^]u8, size: c.int, font_size: f32, argb, max_side, max_bytes: c.uint, w, h: ^c.int) -> [^]u8 ---
}

// Parse time grows with nesting (8000 bytes of braces: 42 ms); past
// MATH_MAX_SRC the source text is shown. The pixel caps bound one
// formula's surface and texture at 8 MiB, since peers choose the input.
@(private = "file")
MATH_MAX_SRC :: 4096
@(private = "file")
MATH_MAX_SIDE :: 4096
@(private = "file")
MATH_MAX_BYTES :: 8 << 20

// Cache bounds: least recently drawn entries go first once either is
// exceeded. A formula that scrolls back into view is rendered again.
@(private = "file")
MATH_CACHE_BYTES :: 64 << 20
@(private = "file")
MATH_CACHE_ENTRIES :: 256

@(private = "file")
Math_Key :: struct {
	text: string, // owned
	px:   f32, // text size in output pixels: body size * UI_SCALE
}

@(private = "file")
Math_Entry :: struct {
	tex:   ^rl.Texture2D, // nil: MicroTeX rejected it
	color: clay.Color, // TEXT when rendered; a theme switch re-renders
	bytes: int,
	used:  u32, // anim_frame at the last lookup
}

@(private = "file")
math_cache: map[Math_Key]Math_Entry
@(private = "file")
math_bytes: int

// Display size of block math, in layout units.
@(private)
math_font_size :: proc() -> f32 {
	return f32(BODY_FS) * 1.25
}

// The typeset texture for `text`, or nil to draw the source instead.
// Its layout size is tex.width / UI_SCALE by tex.height / UI_SCALE.
@(private)
math_texture :: proc(text: string) -> ^rl.Texture2D {
	if len(text) > MATH_MAX_SRC {return nil}

	key := Math_Key{text, math_font_size() * UI_SCALE}
	if entry, seen := &math_cache[key]; seen {
		entry.used = anim_frame
		if entry.tex == nil || entry.color == TEXT {return entry.tex}
		// Theme switched: drop the old ink, keep the owned key.
		for stale_key in math_cache {
			if stale_key == key {key.text = stale_key.text; break}
		}
		math_drop(key)
	} else {
		key.text = strings.clone(text)
	}

	argb := u32(TEXT.a) << 24 | u32(TEXT.r) << 16 | u32(TEXT.g) << 8 | u32(TEXT.b)
	w, h: c.int
	pixels := wn_math_render(
		strings.clone_to_cstring(helper_path("wn-math"), context.temp_allocator),
		raw_data(text),
		c.int(len(text)),
		key.px,
		argb,
		MATH_MAX_SIDE,
		MATH_MAX_BYTES,
		&w,
		&h,
	)
	entry := Math_Entry{nil, TEXT, 0, anim_frame}
	if pixels != nil {
		tex := rl.LoadTextureFromImage({data = pixels, width = i32(w), height = i32(h)})
		libc.free(pixels)
		if tex.tex != nil {
			entry.tex = new(rl.Texture2D)
			entry.tex^ = tex
			entry.bytes = int(w) * int(h) * 4
		}
	}
	math_cache[key] = entry
	math_bytes += entry.bytes

	// Evict least recently drawn. Entries drawn this frame stay even over
	// budget: clay image commands already built this frame point at them
	// and render after layout.
	for math_bytes > MATH_CACHE_BYTES || len(math_cache) > MATH_CACHE_ENTRIES {
		oldest: Math_Key
		oldest_used := anim_frame
		for k, e in math_cache {
			if e.used < oldest_used {oldest, oldest_used = k, e.used}
		}
		if oldest_used == anim_frame {break}
		math_drop(oldest)
		delete(oldest.text)
	}
	return entry.tex
}

// Remove one entry and its texture; the caller owns key.text afterwards.
@(private = "file")
math_drop :: proc(key: Math_Key) {
	entry := math_cache[key]
	if entry.tex != nil {
		rl.UnloadTexture(entry.tex^)
		free(entry.tex)
	}
	math_bytes -= entry.bytes
	delete_key(&math_cache, key)
}

@(private)
math_stop :: proc() {
	for key, entry in math_cache {
		if entry.tex != nil {
			rl.UnloadTexture(entry.tex^)
			free(entry.tex)
		}
		delete(key.text)
	}
	delete(math_cache)
	math_cache = {}
	math_bytes = 0
}
