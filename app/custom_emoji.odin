package main

// Custom :shortcode: emoji. PNGs live under <config>/emoji/, one file
// per emoji; the filename stem is the shortcode, so the directory IS
// the persisted shortcode → image map. A message using one ships the
// image alongside it with a NIP-30 emoji tag, so it renders for the
// group too; see emoji_tags in workers.odin.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import rl "sdlrl"

import marmot "../marmot"

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

// First click arms this file. The second removes it. The arm is the
// filename, so a rescan that reorders the chips cannot confirm another.
emoji_remove :: proc(ui: ^Ui_State, name: string) {
	if !owned_arm(ui, fmt.tprintf("EmojiDelete:%s", name)) {
		return
	}
	os.remove(fmt.tprintf("%s/%s", emoji_dir(), name))
	if old, ok := custom_emoji_textures[name]; ok {
		if old != nil {
			rl.UnloadTexture(old^)
			free(old)
		}
		key, _ := delete_key(&custom_emoji_textures, name)
		delete(key)
	}
	custom_emoji_scan()
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
	path := strings.clone_to_cstring(
		fmt.tprintf("%s/%s", emoji_dir(), name),
		context.temp_allocator,
	)
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

	return builtin_tex_by_code(code)
}

// Built-in artwork stays independent of user shortcode overrides.
@(private)
builtin_tex_by_code :: proc(code: string) -> ^rl.Texture2D {
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

// Decoded pixels for a shortcode, the same precedence as
// custom_tex_by_code minus received-only codes (those exist only as
// textures). data == nil when undefined; the caller unloads it.
@(private)
custom_emoji_image :: proc(code: string) -> rl.Image {
	if name := emoji_file_for(code); len(name) > 0 {
		path := fmt.tprintf("%s/%s", emoji_dir(), name)
		return rl.LoadImage(strings.clone_to_cstring(path, context.temp_allocator))
	}
	for b in BUILTIN_EMOJI {
		if b.code == code {
			return rl.LoadImageFromMemory(".png", raw_data(b.png), i32(len(b.png)))
		}
	}
	return {}
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

// Shortcodes containing `query` (the picker search box, or a composer
// ":token"): the user's files, then the builtins (deduped, so a user
// override shows once).
picker_custom :: proc(query: string) -> [dynamic]string {
	codes := make([dynamic]string, context.temp_allocator)
	filter := strings.to_lower(query, context.temp_allocator)

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
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_':
			append(&ui.emoji_name, c)
		case c == '-':
			append(&ui.emoji_name, '_')
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
// is sanitized to [a-z0-9_], NIP-30's shortcode alphabet, which is
// also safe as a filename.
save_staged_emoji :: proc(ui: ^Ui_State) {
	code := strings.builder_make(context.temp_allocator)
	for c in ui.emoji_name {
		switch {
		case c >= 'A' && c <= 'Z':
			strings.write_byte(&code, c + ('a' - 'A'))
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_':
			strings.write_byte(&code, c)
		case c == '-':
			strings.write_byte(&code, '_')
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
	if dot := strings.last_index_byte(ui.emoji_staged, '.');
	   dot > strings.last_index_byte(ui.emoji_staged, '/') {
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
// NIP-30: a body containing :code: uploads the image as an encrypted
// attachment and tags the message ["emoji", code, url], url being that
// attachment's Blossom locator. The group key encrypts the blob, so the
// url alone reveals nothing; a receiver matches it against the
// message's imeta locators, decrypts that attachment, and draws it
// inline instead of as a file.
// A :code: reaction does the same on its kind-7 (react_custom_emoji);
// receivers find that event for an unknown chip (reaction_emoji_ref).

// Shortcode → texture, filled from received attachments. Session-only:
// every timeline load walks the records again, and media_load caches
// the blob on disk, so a reload costs no network.
remote_emoji_tex: map[string]^rl.Texture2D

// Reaction shortcodes whose kind-7 carried no usable image, so a chip
// is not re-resolved every timeline apply. Kept apart from
// remote_emoji_tex so a later message can still supply the image.
remote_emoji_missed: map[string]bool

// The shortcode inside a ":code:" reaction or recent, ok = false for a
// plain emoji.
emoji_shortcode :: proc(emoji: string) -> (code: string, ok: bool) {
	if len(emoji) > 2 && emoji[0] == ':' && emoji[len(emoji) - 1] == ':' {
		return emoji[1:len(emoji) - 1], true
	}
	return "", false
}

// The stored file backing a shortcode, "" when only a builtin (or
// nothing) defines it.
emoji_file_for :: proc(code: string) -> string {
	for name in custom_emoji_names {
		if emoji_code(name) == code {
			return name
		}
	}
	return ""
}

// Distinct shortcodes in a body that this device can ship an image
// for: a user file or a builtin. Received-only codes have no bytes.
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
		i = end - 1
		local := emoji_file_for(code) != ""
		for b in BUILTIN_EMOJI {
			local ||= b.code == code
		}
		if local && !slice.contains(codes[:], code) {
			append(&codes, code)
		}
	}
	return codes
}

// Attachment name and bytes for a shortcode, the same precedence as
// custom_tex_by_code. Both owned by the caller; data == nil when this
// device has no image for the code.
emoji_payload :: proc(code: string) -> (name: string, data: []u8) {
	if file := emoji_file_for(code); file != "" {
		bytes, err := os.read_entire_file(
			fmt.tprintf("%s/%s", emoji_dir(), file),
			context.allocator,
		)
		if err != nil {
			return "", nil
		}
		return strings.clone(file), bytes
	}
	for b in BUILTIN_EMOJI {
		if b.code == code {
			return fmt.aprintf("%s.png", code), slice.clone(b.png)
		}
	}
	return "", nil
}

// The NIP-30 shortcode an attachment defines: the emoji tag whose url
// is one of the reference's locators. "" = an ordinary attachment.
emoji_tag_code :: proc(
	tags: []marmot.Message_Tag,
	ref: ^marmot.Media_Attachment_Reference,
) -> string {
	for tag in tags {
		if tag.values_len < 3 || string(tag.values[0]) != "emoji" {
			continue
		}
		url := string(tag.values[2])
		for locator in ref.locators[:ref.locators_len] {
			if string(locator.value) == url {
				return string(tag.values[1])
			}
		}
	}
	return ""
}
