package main

// Custom :shortcode: emoji. PNGs live under <config>/emoji/, one file
// per emoji; the filename stem is the shortcode, so the directory IS
// the persisted shortcode → image map. A message using one ships the
// image alongside it, so it renders for the group too; see
// EMOJI_ATT_PREFIX below.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import rl "sdlrl"

custom_emoji_names: [dynamic]string // filenames under emoji_dir()
custom_emoji_scanned: bool
custom_emoji_textures: map[string]^rl.Texture2D

// Built-in shortcodes shipped in the binary, always available and not
// removable. A user file with the same code takes precedence.
BUILTIN_EMOJI := [2]struct {
	code: string,
	png:  []u8,
} {
	{"marmot", #load("assets/marmot.png")},
	// The logomark on its dark tile, so it reads on light themes too.
	{"wn", #load("assets/wn.png")},
}
builtin_emoji_tex: [len(BUILTIN_EMOJI)]^rl.Texture2D

emoji_dir :: proc(allocator := context.temp_allocator) -> string {
	path := settings_path(allocator)
	return fmt.aprintf("%s/emoji", path[:len(path) - len("/settings.json")], allocator = allocator)
}

// Shortcode of a stored file: the filename stem ("party.png" → "party").
emoji_code :: proc(name: string) -> string {
	if dot := strings.last_index_byte(name, '.'); dot > 0 {
		return name[:dot]
	}
	return name
}

custom_emoji_scan :: proc() {
	custom_emoji_scanned = true
	for name in custom_emoji_names {
		delete(name)
	}
	clear(&custom_emoji_names)

	dir, err := os.open(emoji_dir())
	if err != nil {
		return
	}
	defer os.close(dir)
	entries, read_err := os.read_dir(dir, -1, context.temp_allocator)
	if read_err != nil {
		return
	}
	for entry in entries {
		if entry.type != .Directory {
			append(&custom_emoji_names, strings.clone(entry.name))
		}
	}
}

custom_emoji_texture :: proc(name: string) -> ^rl.Texture2D {
	if tex, ok := custom_emoji_textures[name]; ok {
		return tex
	}
	tex: ^rl.Texture2D
	path := strings.clone_to_cstring(fmt.tprintf("%s/%s", emoji_dir(), name), context.temp_allocator)
	image := rl.LoadImage(path)
	if image.data != nil {
		tex = new(rl.Texture2D)
		tex^ = rl.LoadTextureFromImage(image)
		rl.UnloadImage(image)
		rl.SetTextureFilter(tex^, .BILINEAR)
	}
	custom_emoji_textures[strings.clone(name)] = tex // nil marks a bad file
	return tex
}

// Texture for a shortcode, nil when undefined.
// ponytail: linear scan; index it if the emoji set ever grows large.
custom_tex_by_code :: proc(code: string) -> ^rl.Texture2D {
	for name in custom_emoji_names {
		if emoji_code(name) == code {
			return custom_emoji_texture(name)
		}
	}

	if tex, ok := remote_emoji_tex[code]; ok && tex != nil {
		return tex
	}

	for b, i in BUILTIN_EMOJI {
		if b.code != code {
			continue
		}
		if builtin_emoji_tex[i] == nil {
			img := rl.LoadImageFromMemory(".png", raw_data(b.png), i32(len(b.png)))
			if img.data == nil {
				return nil
			}
			tex := new(rl.Texture2D)
			tex^ = rl.LoadTextureFromImage(img)
			rl.UnloadImage(img)
			rl.SetTextureFilter(tex^, .BILINEAR)
			builtin_emoji_tex[i] = tex
		}
		return builtin_emoji_tex[i]
	}
	return nil
}

// Parse a :shortcode: starting at text[i] (text[i] == ':'). Returns
// the index past the closing ':' and the texture; nil = not a known
// shortcode, render literally.
shortcode_at :: proc(text: string, i: int) -> (end: int, tex: ^rl.Texture2D) {
	j := i + 1
	for j < len(text) && j - i <= 64 {
		c := text[j]
		if c == ':' {
			break
		}
		alnum := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		if !alnum && c != '_' && c != '-' {
			return 0, nil
		}
		j += 1
	}
	if j >= len(text) || text[j] != ':' || j == i + 1 {
		return 0, nil
	}
	return j + 1, custom_tex_by_code(text[i + 1:j])
}

// Shortcodes matching the picker search box: the user's files, then
// the builtins (deduped, so a user override shows once).
picker_custom :: proc(ui: ^Ui_State) -> [dynamic]string {
	codes := make([dynamic]string, context.temp_allocator)
	filter := strings.to_lower(string(ui.picker_filter[:]), context.temp_allocator)

	add :: proc(codes: ^[dynamic]string, code, filter: string) {
		lower := strings.to_lower(code, context.temp_allocator)
		if len(filter) > 0 && !strings.contains(lower, filter) {
			return
		}
		if !slice.contains(codes[:], code) {
			append(codes, code)
		}
	}

	for name in custom_emoji_names {
		if custom_emoji_texture(name) == nil {
			continue
		}
		add(&codes, emoji_code(name), filter)
	}
	for b in BUILTIN_EMOJI {
		add(&codes, b.code, filter)
	}
	return codes
}

// A picked file waits here until the user names its shortcode.
stage_emoji :: proc(ui: ^Ui_State, path: string) {
	delete(ui.emoji_staged)
	ui.emoji_staged = strings.clone(path)

	// Prefill the shortcode box with the sanitized filename stem.
	base := path
	if slash := strings.last_index_byte(path, '/'); slash >= 0 {
		base = path[slash + 1:]
	}
	clear(&ui.emoji_name)
	for c in transmute([]u8)emoji_code(base) {
		switch {
		case c >= 'A' && c <= 'Z':
			append(&ui.emoji_name, c + ('a' - 'A'))
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-':
			append(&ui.emoji_name, c)
		}
	}
	ui.focus = .EmojiName
}

cancel_staged_emoji :: proc(ui: ^Ui_State) {
	delete(ui.emoji_staged)
	ui.emoji_staged = ""
	clear(&ui.emoji_name)
	ui.focus = .Compose
}

// Copy the staged image into the emoji dir as <code>.<ext>. The code
// is sanitized to [a-z0-9_-] so it is safe as a filename.
save_staged_emoji :: proc(ui: ^Ui_State) {
	code := strings.builder_make(context.temp_allocator)
	for c in ui.emoji_name {
		switch {
		case c >= 'A' && c <= 'Z':
			strings.write_byte(&code, c + ('a' - 'A'))
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-':
			strings.write_byte(&code, c)
		}
	}
	if strings.builder_len(code) == 0 {
		return
	}
	data, read_err := os.read_entire_file(ui.emoji_staged, context.temp_allocator)
	if read_err != nil {
		cancel_staged_emoji(ui)
		return
	}

	ext := ".png"
	if dot := strings.last_index_byte(ui.emoji_staged, '.'); dot > strings.last_index_byte(ui.emoji_staged, '/') {
		ext = ui.emoji_staged[dot:]
	}
	name := fmt.tprintf("%s%s", strings.to_string(code), ext)
	os.make_directory(emoji_dir())
	_ = os.write_entire_file(fmt.tprintf("%s/%s", emoji_dir(), name), data)

	// Drop a stale texture when redefining an existing shortcode.
	if old, ok := custom_emoji_textures[name]; ok {
		if old != nil {
			rl.UnloadTexture(old^)
			free(old)
		}
		key, _ := delete_key(&custom_emoji_textures, name)
		delete(key)
	}

	custom_emoji_scan()
	cancel_staged_emoji(ui)
}

// ── Custom emoji over the wire ──────────────────────────────────────
//
// Kind 9 is reserved (marmot rejects a hand-built one) and send_text
// carries no tags, so NIP-30's ["emoji", code, url] tag has nowhere to
// ride. The attachment path is the one public channel a chat message
// has: a body containing :code: ships the PNG alongside it, named
// wn-emoji-<code>.<ext>. Receivers decode that into the cache below
// and draw it inline; clients that don't know the convention still see
// the image as an ordinary attachment.
EMOJI_ATT_PREFIX :: "wn-emoji-"

// Shortcode → texture, filled from received attachments. Session-only:
// every timeline load walks the records again, and media_load caches
// the blob on disk, so a reload costs no network.
remote_emoji_tex: map[string]^rl.Texture2D

// The stored file backing a shortcode, "" when only a builtin (or
// nothing) defines it. Builtins ship in every binary, so they need no
// wire copy.
emoji_file_for :: proc(code: string) -> string {
	for name in custom_emoji_names {
		if emoji_code(name) == code {
			return name
		}
	}
	return ""
}

// Distinct shortcodes in a body that this device has a file for.
emoji_codes_in :: proc(body: string) -> [dynamic]string {
	codes := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(body); i += 1 {
		if body[i] != ':' {
			continue
		}
		end, tex := shortcode_at(body, i)
		if tex == nil {
			continue
		}
		code := body[i + 1:end - 1]
		if !slice.contains(codes[:], code) && emoji_file_for(code) != "" {
			append(&codes, code)
		}
		i = end - 1
	}
	return codes
}

// Decode a received wn-emoji-<code>.<ext> attachment into the cache.
remote_emoji_add :: proc(att_name: string, data: []u8) {
	code := emoji_code(att_name[len(EMOJI_ATT_PREFIX):])
	if len(code) == 0 || code in remote_emoji_tex {
		return
	}
	ext := strings.clone_to_cstring(att_name[strings.last_index_byte(att_name, '.'):], context.temp_allocator)
	img := rl.LoadImageFromMemory(ext, raw_data(data), i32(len(data)))
	if img.data == nil {
		remote_emoji_tex[strings.clone(code)] = nil // bad file, don't retry
		return
	}
	tex := new(rl.Texture2D)
	tex^ = rl.LoadTextureFromImage(img)
	rl.UnloadImage(img)
	rl.SetTextureFilter(tex^, .BILINEAR)
	remote_emoji_tex[strings.clone(code)] = tex
}
