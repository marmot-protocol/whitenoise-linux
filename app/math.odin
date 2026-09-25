// Math blocks ($$…$$): TeX typeset by MicroTeX through app/math_shim.cpp
// (built into build/libwnmath.a by scripts/build.sh) into a texture.
//
//   math_texture(src) -+- cache hit ---------------------------> texture
//                      +- miss: math_shim_render -> RGBA -> texture
//
// Anything MicroTeX rejects caches a nil entry, and the timeline keeps
// drawing the source on the code plate.
package main

import "core:c"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

foreign import mathlib {WN_BUILD_DIR + "/libwnmath.a", WN_BUILD_DIR + "/microtex/lib/libmicrotex.a", "system:cairo", WN_CXX_LIBRARY, "system:m"}

@(private = "file", default_calling_convention = "c")
foreign mathlib {
	math_shim_init :: proc(font: [^]u8, len: c.ulong) -> bool ---
	math_shim_render :: proc(tex: cstring, size: f32, argb: u32, max_side: c.int, max_area: c.long, w, h: ^c.int) -> [^]u8 ---
	math_shim_free :: proc(pixels: [^]u8) ---
}

// TeX Gyre DejaVu Math (the DejaVu Serif companion), pre-converted to
// MicroTeX's .clm2 by upstream (903 KB). Fira Math (271 KB) lacks
// fraktur, \ddots/\vdots, and stretchy arrows.
@(private = "file")
MATH_FONT := #load("../vendor/microtex/res/tex-gyre/texgyredejavu-math.clm2")

// Parse time grows with nesting (8000 bytes of braces: 42 ms); past
// MATH_MAX_SRC the source text is shown. The pixel caps bound one
// formula's surface and texture at 8 MiB, since peers choose the input.
@(private = "file")
MATH_MAX_SRC :: 4096
@(private = "file")
MATH_MAX_SIDE :: 4096
@(private = "file")
MATH_MAX_AREA :: 2 << 20

// Cache bounds: least recently drawn entries go first once either is
// exceeded. A formula that scrolls back into view is re-typeset (well
// under a millisecond for typical input).
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
@(private = "file")
math_ready: enum {
	Unloaded,
	Ready,
	Failed,
}

// Display size of block math, in layout units.
@(private)
math_font_size :: proc() -> f32 {
	return f32(BODY_FS) * 1.25
}

// The typeset texture for `text`, or nil to draw the source instead.
// Its layout size is tex.width / UI_SCALE by tex.height / UI_SCALE.
@(private)
math_texture :: proc(text: string) -> ^rl.Texture2D {
	if math_ready == .Unloaded {
		math_ready =
			math_shim_init(raw_data(MATH_FONT), c.ulong(len(MATH_FONT))) ? .Ready : .Failed
	}
	if math_ready == .Failed || len(text) > MATH_MAX_SRC {return nil}

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
	pixels := math_shim_render(
		strings.clone_to_cstring(text, context.temp_allocator),
		key.px,
		argb,
		MATH_MAX_SIDE,
		MATH_MAX_AREA,
		&w,
		&h,
	)
	entry := Math_Entry{nil, TEXT, 0, anim_frame}
	if pixels != nil {
		tex := rl.LoadTextureFromImage({data = pixels, width = i32(w), height = i32(h)})
		math_shim_free(pixels)
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
	// ponytail: MicroTeX itself stays up. Its release() frees the static
	// macro table without clearing it, so a module that stays mapped would
	// reuse freed entries. Cost: `just dev` leaks its heap-held macro table
	// once per reload; a release build exits instead. Upgrade path: patch
	// _free_ to clear, then release here.
	math_ready = .Unloaded
}
