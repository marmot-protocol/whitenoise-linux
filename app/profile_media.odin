package main

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private = "file")
Profile_Font :: struct {
	url, path:    string,
	done, loaded: bool,
	id:           u16,
}

@(private = "file")
profile_fonts: map[string]^Profile_Font

@(private = "file")
profile_font_mutex: sync.Mutex

@(private)
profile_font :: proc(url: string) -> u16 {
	if url == "" {return 0}
	font, found := profile_fonts[url]
	if !found {
		// ponytail: retain up to 64 custom fonts per session; evict stacks if this ceiling becomes visible.
		if len(profile_fonts) >= 64 || !profile_asset_url(url) {return 0}
		font = new(Profile_Font)
		font.url, font.id = strings.clone(url), u16(32 + len(profile_fonts))
		profile_fonts[font.url] = font
		append(&send_threads, thread.create_and_start_with_poly_data(font, profile_font_worker))
	}
	sync.lock(&profile_font_mutex)
	ready := font.done
	sync.unlock(&profile_font_mutex)
	if !ready || font.path == "" {return 0}
	if !font.loaded {
		paths := make([dynamic]cstring, context.temp_allocator)
		append(
			&paths,
			strings.clone_to_cstring(font.path, context.temp_allocator),
			res_font("LiberationSans-Regular.ttf"),
		)
		append(&paths, ..CJK_CANDIDATES)
		rl.LoadFontStack(font.id, paths[:], text_emoji)
		font.loaded = true
	}
	return font.id
}

@(private = "file")
profile_font_worker :: proc(font: ^Profile_Font) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	defer {
		sync.lock(&profile_font_mutex)
		font.done = true
		sync.unlock(&profile_font_mutex)
	}
	digest := hash.hash_string(.SHA256, font.url, context.temp_allocator)
	key := string(hex.encode(digest, context.temp_allocator))
	dir := fmt.tprintf("%s/events/fonts", data_home)
	path := fmt.tprintf("%s/%s.ttf", dir, key)
	if !os.exists(path) {
		os.make_directory(fmt.tprintf("%s/events", data_home))
		os.make_directory(dir)
		tmp := fmt.tprintf("%s.download", path)
		defer os.remove(tmp)
		state, _, _, err := os.process_exec(
			{
				command = {
					curl_path(),
					"-sfL",
					"--proto",
					"=http,https",
					"--proto-redir",
					"=http,https",
					"--max-time",
					"15",
					"--max-filesize",
					"8388608",
					"-o",
					tmp,
					"--",
					font.url,
				},
			},
			context.temp_allocator,
		)
		if err != nil || state.exit_code != 0 {return}
		helper := helper_path("wn-font")
		decoded, data, _, decode_err := os.process_exec(
			{command = {helper, tmp}},
			context.temp_allocator,
		)
		if decode_err != nil || decoded.exit_code != 0 || len(data) < 12 {return}
		if os.write_entire_file(tmp, data) != nil || os.rename(tmp, path) != nil {return}
	}
	font.path = strings.clone(path)
}

@(private)
Profile_Background :: struct {
	kind: Model_Kind,
	tex:  ^rl.Texture2D,
	tile: bool,
	base: clay.Color,
}

@(private)
profile_background :: proc(style: Profile_Style) -> clay.CustomElementConfig {
	if style.background == "" {return {}}
	tex := nev_img(style.background)
	if tex == nil {return {}}
	view := new(Profile_Background, context.temp_allocator)
	view^ = {.Profile_Background, tex, style.tile, BG}
	return {customData = view}
}

@(private)
profile_background_draw :: proc(
	view: ^Profile_Background,
	bounds: clay.BoundingBox,
	tint: rl.Color,
) {
	tint := tint
	tex := view.tex
	if tex.width <= 0 || tex.height <= 0 {return}
	base := clay_color(view.base)
	base.a = u8(u32(base.a) * u32(tint.a) / 255)
	rl.DrawRectangleRec(bounds.x, bounds.y, bounds.width, bounds.height, base)
	// Leave the theme's background color behind text, even with a bright photo.
	tint.a = u8(u32(tint.a) * 48 / 255)
	rl.BeginScissorMode(i32(bounds.x), i32(bounds.y), i32(bounds.width), i32(bounds.height))
	defer rl.EndScissorMode()
	if !view.tile {
		scale := max(bounds.width / f32(tex.width), bounds.height / f32(tex.height))
		w, h := f32(tex.width) * scale, f32(tex.height) * scale
		rl.DrawTextureRect(
			tex,
			bounds.x + (bounds.width - w) / 2,
			bounds.y + (bounds.height - h) / 2,
			w,
			h,
			tint,
		)
		return
	}
	// Tiny remote tiles must not turn a profile into millions of draw calls.
	scale := max(
		f32(1),
		max(bounds.width / 64 / f32(tex.width), bounds.height / 64 / f32(tex.height)),
	)
	w, h := f32(tex.width) * scale, f32(tex.height) * scale
	for y: f32 = 0; y < bounds.height; y += h {
		for x: f32 = 0; x < bounds.width; x += w {
			rl.DrawTextureRect(tex, bounds.x + x, bounds.y + y, w, h, tint)
		}
	}
}
