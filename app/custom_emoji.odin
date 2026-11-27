package main

// Custom :shortcode: emoji live under <config>/emoji/, with imported
// sets in manifest-tracked subdirectories. The basename stem is the
// shortcode. A message using one ships the
// image alongside it with a NIP-30 emoji tag, so it renders for the
// group too; see emoji_tags in workers.odin.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:thread"

import "nendo"
import rl "sdlrl"

import marmot "../marmot"

custom_emoji_names: [dynamic]string // filenames under emoji_dir()
custom_emoji_scanned: bool
custom_emoji_textures: map[string]^rl.Texture2D

@(private)
picker_pack_icons: map[string]^rl.Texture2D

@(private)
Picker_Art :: struct {
	tex:     ^rl.Texture2D,
	pending: bool,
}

@(private)
Emoji_Preview_Kind :: enum {
	File,
	Pack_Icon,
	Builtin,
	Other_Set,
}

@(private = "file")
emoji_preview: struct {
	worker:    ^thread.Thread,
	directory: string,
	revision:  u64,
	set:       Emoji_Set,
	count:     int,
	items:     [2]struct {
		kind:    Emoji_Preview_Kind,
		key:     string,
		builtin: int,
		image:   rl.Image,
	},
}
@(private = "file")
emoji_revision: u64

@(private)
MARMOT_EMOJI :: "marmot"

// Built-in shortcodes shipped in the binary, always available and not
// removable. A user file with the same code takes precedence.
BUILTIN_EMOJI := [13]struct {
	code: string,
	png:  []u8,
} {
	{MARMOT_EMOJI, #load("assets/marmot.png")},
	// The logomark on its dark tile, so it reads on light themes too.
	{"wn", #load("assets/wn.png")},
	{"marmot_classic", #load("assets/marmot_classic.png")},
	{"marmot_wave", #load("assets/marmot_wave.png")},
	{"marmot_yes", #load("assets/marmot_yes.png")},
	{"marmot_laugh", #load("assets/marmot_laugh.png")},
	{"marmot_love", #load("assets/marmot_love.png")},
	{"marmot_party", #load("assets/marmot_party.png")},
	{"marmot_fire", #load("assets/marmot_fire.png")},
	{"marmot_wow", #load("assets/marmot_wow.png")},
	{"marmot_smirk", #load("assets/marmot_smirk.png")},
	{"marmot_cry", #load("assets/marmot_cry.png")},
	{"marmot_angry", #load("assets/marmot_angry.png")},
}
builtin_emoji_tex: [len(BUILTIN_EMOJI)]^rl.Texture2D
@(private = "file")
builtin_emoji_failed: [len(BUILTIN_EMOJI)]bool

emoji_dir :: proc(allocator := context.temp_allocator) -> string {
	path := settings_path(allocator)
	return fmt.aprintf("%s/emoji", path[:len(path) - len("/settings.json")], allocator = allocator)
}

// Shortcode of a stored file: the filename stem ("party.png" → "party").
emoji_code :: proc(name: string) -> string {
	name := emoji_basename(name)
	if dot := strings.last_index_byte(name, '.'); dot > 0 {
		return name[:dot]
	}
	return name
}

@(private)
emoji_basename :: proc(name: string) -> string {
	if slash := strings.last_index_byte(name, '/'); slash >= 0 {return name[slash + 1:]}
	return name
}

// First click arms this file. The second removes it. The arm is the
// filename, so a rescan that reorders the chips cannot confirm another.
emoji_remove :: proc(ui: ^Ui_State, name: string) {
	if ui.emoji_sets_job != nil && ui.emoji_sets_job.op == .Import {return}
	if !owned_arm(ui, fmt.tprintf("EmojiDelete:%s", name)) {
		return
	}
	os.remove(fmt.tprintf("%s/%s", emoji_dir(), name))
	for textures in ([2]^map[string]^rl.Texture2D{&custom_emoji_textures, &picker_pack_icons}) {
		old, ok := textures^[name]
		if !ok {continue}
		if old != nil {
			rl.UnloadTexture(old^)
			free(old)
		}
		key, _ := delete_key(textures, name)
		delete(key)
	}
	custom_emoji_scan()
}

custom_emoji_scan :: proc() {
	// The worker owns disk publication until drain; never block a frame on IO.
	if g_ui != nil && g_ui.emoji_sets_job != nil && g_ui.emoji_sets_job.op == .Import {return}
	coordinate: string
	if g_ui != nil {
		if pack := picker_pack_at(g_ui.picker_pack, g_ui.picker_pack_revision); pack != nil {
			coordinate = strings.clone(pack.coordinate, context.temp_allocator)
		}
		for &msg in g_ui.messages {
			msg.row_measure = {}
		}
	}
	emoji_revision += 1
	wrap_flush = true
	custom_emoji_scanned = true
	for name in custom_emoji_names {
		delete(name)
	}
	clear(&custom_emoji_names)
	emoji_sources_clear()
	emoji_scan_files(emoji_dir(), &custom_emoji_names, &emoji_sources, &picker_emoji_packs)
	if g_ui == nil || coordinate == "" {return}
	g_ui.picker_pack, g_ui.picker_pack_revision = 0, 0
	for pack, i in picker_emoji_packs {
		if pack.coordinate != coordinate {continue}
		g_ui.picker_pack, g_ui.picker_pack_revision = i + 1, emoji_revision
		break
	}
}

@(private = "file")
emoji_preview_worker :: proc(_: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer frame_wake()
	for &item in emoji_preview.items[:emoji_preview.count] {
		switch item.kind {
		case .File, .Pack_Icon:
			item.image = rl.LoadImage(fmt.ctprintf("%s/%s", emoji_preview.directory, item.key))
			if item.kind == .Pack_Icon {item.image = image_fit(item.image, 96)}
		case .Builtin:
			png := BUILTIN_EMOJI[item.builtin].png
			item.image = rl.LoadImageFromMemory(".png", raw_data(png), i32(len(png)))
		case .Other_Set:
			item.image = emoji_image(item.key, emoji_preview.set)
		}
		free_all(context.temp_allocator)
	}
}

@(private)
Emoji_Preview_End :: enum {
	Publish,
	Discard,
}

@(private)
emoji_preview_finish :: proc(end: Emoji_Preview_End) {
	publish := end == .Publish && emoji_preview.worker != nil
	if emoji_preview.worker != nil {
		thread.join(emoji_preview.worker)
		thread.destroy(emoji_preview.worker)
	}
	for item in emoji_preview.items[:emoji_preview.count] {
		keep_key := false
		if publish {
			switch item.kind {
			case .File, .Pack_Icon:
				textures := item.kind == .File ? &custom_emoji_textures : &picker_pack_icons
				if _, cached := textures^[item.key];
				   !cached && emoji_preview.revision == emoji_revision {
					textures^[item.key] = emoji_upload(item.image)
					keep_key = true
				}
			case .Builtin:
				if builtin_emoji_tex[item.builtin] == nil {
					tex := emoji_upload(item.image)
					builtin_emoji_tex[item.builtin] = tex
					builtin_emoji_failed[item.builtin] = tex == nil
				}
			case .Other_Set:
				if _, cached := emoji_tex_cache[item.key];
				   !cached && emoji_preview.set == emoji_set {
					emoji_tex_cache[item.key] = emoji_upload(item.image)
					keep_key = true
				}
			}
		}
		if !keep_key {delete(item.key)}
		rl.UnloadImage(item.image)
	}
	if publish {frame_wake()}
	delete(emoji_preview.directory)
	emoji_preview = {}
}

@(private)
emoji_preview_queue :: proc(kind: Emoji_Preview_Kind, key: string, builtin := 0) {
	if emoji_preview.worker != nil || emoji_preview.count == len(emoji_preview.items) {return}
	for item in emoji_preview.items[:emoji_preview.count] {
		if item.key == key &&
		   item.builtin == builtin &&
		   (item.kind == kind || (kind == .Pack_Icon && item.kind == .File)) {return}
	}
	emoji_preview.items[emoji_preview.count] = {
		kind    = kind,
		key     = strings.clone(key),
		builtin = builtin,
	}
	emoji_preview.count += 1
}

@(private)
settings_emoji_tick :: proc(ui: ^Ui_State) {
	picker_upload_tick()
	if emoji_preview.worker != nil {
		if !thread.is_done(emoji_preview.worker) {return}
		emoji_preview_finish(.Publish)
	}
	if ui.picker_open {picker_pack_queue()}
	if settings_workspace_visible(ui) && ui.settings_section == .Chats && !settings_index(ui) {
		settings_emoji_queue(ui)
	}
	if emoji_preview.count == 0 {return}
	emoji_preview.revision = emoji_revision
	emoji_preview.set = emoji_set
	emoji_preview.directory = strings.clone(emoji_dir())
	emoji_preview.worker = thread.create(emoji_preview_worker)
	thread.start(emoji_preview.worker)
}

@(private = "file")
picker_pack_queue :: proc() {
	rail := nendo.element(nendo.id("PickerCategories"))
	if !rail.found {return}
	for pack, i in picker_emoji_packs {
		if emoji_preview.count == len(emoji_preview.items) {break}
		if !picker_pack_art(pack.sample).pending {continue}
		chip := nendo.element(nendo.id("PickerCategory", u32(len(PICKER_CATEGORIES) + i)))
		b, r := chip.rect, rail.rect
		if chip.found &&
		   b.x < r.x + r.width &&
		   b.x + b.width > r.x &&
		   b.y < r.y + r.height &&
		   b.y + b.height > r.y {emoji_preview_queue(.Pack_Icon, pack.sample)}
	}
}

@(private)
picker_pack_art :: proc(sample: string) -> Picker_Art {
	if tex := custom_emoji_textures[sample]; tex != nil {return {tex = tex}}
	tex, cached := picker_pack_icons[sample]
	return {tex, !cached}
}

@(private = "file")
settings_emoji_queue :: proc(ui: ^Ui_State) {
	page := nendo.element(nendo.id("SettingsPage")).rect
	queue :: proc(name: string) {
		if name == "" {return}
		if _, cached := custom_emoji_textures[name]; cached {return}
		emoji_preview_queue(.File, name)
	}
	for emoji, i in ui.prefs.quick_reactions {
		code, custom := emoji_shortcode(emoji)
		if !custom {continue}
		chip := nendo.element(nendo.id("QuickChip", u32(i)))
		if chip.found &&
		   chip.rect.y < page.y + page.height &&
		   chip.rect.y + chip.rect.height > page.y {
			queue(emoji_file_for(code))
		}
	}
	for name, i in custom_emoji_names {
		if emoji_preview.count == len(emoji_preview.items) {break}
		row := nendo.element(nendo.id("EmojiChip", u32(i)))
		if !row.found || row.rect.y >= page.y + page.height {break}
		if row.rect.y + row.rect.height > page.y {queue(name)}
	}
}

@(private)
picker_shortcode_tex :: proc(code: string) -> Picker_Art {
	if name := emoji_file_for(code); name != "" {return picker_file_tex(name)}
	for b, i in BUILTIN_EMOJI {
		if b.code == code {return picker_builtin_tex(i)}
	}
	return {tex = remote_emoji_tex[code]}
}

@(private = "file")
picker_file_tex :: proc(name: string) -> Picker_Art {
	if tex, loaded := custom_emoji_textures[name]; loaded {return {tex = tex}}
	emoji_preview_queue(.File, name)
	return {pending = true}
}

@(private = "file")
picker_builtin_tex :: proc(i: int) -> Picker_Art {
	if tex := builtin_emoji_tex[i]; tex != nil || builtin_emoji_failed[i] {return {tex = tex}}
	emoji_preview_queue(.Builtin, "", i)
	return {pending = true}
}

@(private)
picker_custom_tex :: proc(slot: u32) -> Picker_Art {
	if int(slot) < len(custom_emoji_names) {return picker_file_tex(custom_emoji_names[slot])}
	return picker_builtin_tex(int(slot) - len(custom_emoji_names))
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
	if name := emoji_file_for(code); name != "" {
		return custom_emoji_texture(name)
	}
	if tex := builtin_tex_by_code(code); tex != nil {
		return tex
	}
	return remote_emoji_tex[code]
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
			texture := rl.LoadTextureFromImage(img)
			rl.UnloadImage(img)
			if texture.tex == nil {
				return nil
			}
			tex := new(rl.Texture2D)
			tex^ = texture
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

@(private)
Emoji_Match_Mode :: enum {
	Cache_Only,
	Check_Files,
}

@(private)
Picker_Custom :: struct {
	code: string,
	slot: u32,
}

@(private)
picker_pack_at :: proc(index: int, revision: u64) -> ^Picker_Emoji_Pack {
	if revision != emoji_revision || index <= 0 || index > len(picker_emoji_packs) {return nil}
	return &picker_emoji_packs[index - 1]
}

@(private)
picker_custom_matches :: proc(ui: ^Ui_State) -> ([]Picker_Custom, u64) {
	if query := picker_query(ui); query != "" {return picker_custom(query)}
	if pack := picker_pack_at(ui.picker_pack, ui.picker_pack_revision); pack != nil {
		matches := make([dynamic]Picker_Custom, 0, len(pack.slots), context.temp_allocator)
		for slot in pack.slots {
			name := custom_emoji_names[slot]
			if tex, loaded := custom_emoji_textures[name]; loaded && tex == nil {continue}
			append(&matches, Picker_Custom{emoji_code(name), slot})
		}
		return matches[:], emoji_revision
	}
	if ui.picker_group == .Custom {return picker_custom("")}
	if ui.picker_group == .Marmot {
		matches := make([dynamic]Picker_Custom, 0, len(BUILTIN_EMOJI), context.temp_allocator)
		for b, i in BUILTIN_EMOJI {
			if b.code != MARMOT_EMOJI && !strings.has_prefix(b.code, "marmot_") {continue}
			slot := len(custom_emoji_names) + i
			if local, found := emoji_file_slot(b.code); found {
				name := custom_emoji_names[local]
				if tex, loaded := custom_emoji_textures[name]; loaded && tex == nil {continue}
				slot = local
			}
			append(&matches, Picker_Custom{b.code, u32(slot)})
		}
		return matches[:], emoji_revision
	}
	return nil, emoji_revision
}

// Shortcodes containing `query` (the picker search box, or a composer
// ":token"): the user's files, then the builtins (deduped, so a user
// override shows once).
picker_custom :: proc(
	query: string,
	mode := Emoji_Match_Mode.Cache_Only,
) -> (
	[]Picker_Custom,
	u64,
) {
	codes := make([dynamic]Picker_Custom, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	filter := strings.to_lower(query, context.temp_allocator)
	for name, i in custom_emoji_names {
		code := emoji_code(name)
		if seen[code] ||
		   filter != "" &&
			   !strings.contains(strings.to_lower(code, context.temp_allocator), filter) {continue}
		// Claim the same file that composing and sending will resolve.
		seen[code] = true
		if tex, loaded := custom_emoji_textures[name]; loaded && tex == nil {continue}
		if mode == .Check_Files && custom_emoji_texture(name) == nil {continue}
		append(&codes, Picker_Custom{code, u32(i)})
	}
	for b, i in BUILTIN_EMOJI {
		if seen[b.code] || filter != "" && !strings.contains(b.code, filter) {continue}
		append(&codes, Picker_Custom{b.code, u32(len(custom_emoji_names) + i)})
	}
	return codes[:], emoji_revision
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
	if ui.emoji_sets_job != nil && ui.emoji_sets_job.op == .Import {return}
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
		// Each rejected save needs feedback, even after dismissing the same error.
		ui.banner_seen = ""
		set_status(
			ui,
			tr(
				"Couldn't save your emoji. Include at least one ASCII letter, digit, underscore, or hyphen in the name.",
			),
			.Error,
		)
		return
	}
	data, read_err := os.read_entire_file(ui.emoji_staged, context.temp_allocator)
	if read_err != nil {
		ui.banner_seen = ""
		set_status(ui, tr("Couldn't save your emoji. Please try again."), .Error)
		return
	}

	ext := ".png"
	if dot := strings.last_index_byte(ui.emoji_staged, '.');
	   dot > strings.last_index_byte(ui.emoji_staged, '/') {
		ext = ui.emoji_staged[dot:]
	}
	name := fmt.tprintf("%s%s", strings.to_string(code), ext)
	os.make_directory(emoji_dir())
	// Publish only a complete copy, so a failed write cannot truncate an
	// existing emoji. The private staging directory is removed on every exit.
	staging, staging_err := os.make_directory_temp(emoji_dir(), ".save-*", context.temp_allocator)
	if staging_err != nil {
		ui.banner_seen = ""
		set_status(ui, tr("Couldn't save your emoji. Please try again."), .Error)
		return
	}
	defer os.remove_all(staging)
	next := fmt.tprintf("%s/image", staging)
	if os.write_entire_file(next, data) != nil ||
	   os.rename(next, fmt.tprintf("%s/%s", emoji_dir(), name)) != nil {
		ui.banner_seen = ""
		set_status(ui, tr("Couldn't save your emoji. Please try again."), .Error)
		return
	}

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
	if slot, found := emoji_file_slot(code); found {return custom_emoji_names[slot]}
	return ""
}

@(private = "file")
emoji_file_slot :: proc(code: string) -> (int, bool) {
	for name, slot in custom_emoji_names {
		if emoji_code(name) == code {
			return slot, true
		}
	}
	return 0, false
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
		return strings.clone(emoji_basename(file)), bytes
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
