package main

import "base:runtime"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "nendo"
import rl "sdlrl"

import marmot "../marmot"

// Run alone with SDL_VIDEODRIVER=dummy and
// -define:ODIN_TEST_NAMES=test_emoji_save_dispatch (SDL/nendo process globals).
@(test)
test_emoji_save_dispatch :: proc(t: ^testing.T) {
	if !test_isolated("test_emoji_save_dispatch") {return}
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	rl.InitWindow(1024, 700, "Emoji save dispatch")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes(); apply_theme(0, 0); set_locale("en")
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {nendo.set_context(previous); delete(memory)}
	scanned := custom_emoji_scanned
	custom_emoji_scanned = true
	defer {custom_emoji_scanned = scanned; forced_release = false; kb_focus = ""}
	ui := Ui_State {
		page          = .Settings,
		audit_scanned = true,
	}
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; settings_stop(&ui); delete(ui.emoji_staged)
		delete(ui.emoji_name)}
	settings_open(&ui, nil, .Chats, "CustomEmojiGroup")
	for keyboard in ([]bool{false, true}) {
		for row in ([]struct {
				path, name: string,
			}{{"/staged/!!!.png", ""}, {"/staged/😀🎉.png", ""}, {"/staged/!!!.png", "!!!"}}) {
			stage_emoji(&ui, row.path)
			testing.expect_value(t, len(ui.emoji_name), 0)
			append(&ui.emoji_name, ..transmute([]u8)row.name)
			ui.client_status, ui.banner, ui.banner_seen = "", "", ""
			for attempt in 0 ..< 2 {
				if attempt == 1 {
					// BannerClose clears only banner in the real frame loop.
					ui.banner = ""
					banner_tick(&ui)
					testing.expect_value(t, ui.banner, "")
				}
				for _ in 0 ..< 3 {settings_test_frame(&ui)}
				if keyboard {
					rl.PushKey(.ENTER, true)
					settings_fields(&ui)
					rl.PushKey(.ENTER, false)
					rl.WindowShouldClose()
				} else {
					button := nendo.element(nendo.id("EmojiSave"))
					if !testing.expect(t, button.found) {return}
					box := button.rect
					nendo.set_pointer({box.x + box.width / 2, box.y + box.height / 2}, .Up)
					if !testing.expect(t, nendo.pointer_over(nendo.id("EmojiSave"))) {return}
					forced_release = true
					handle_settings(&ui, nil)
					forced_release = false
				}
				banner_tick(&ui)
				testing.expect_value(
					t,
					ui.banner,
					tr(
						"Couldn't save your emoji. Include at least one ASCII letter, digit, underscore, or hyphen in the name.",
					),
				)
				testing.expect_value(t, ui.banner_kind, Status_Kind.Error)
				testing.expect_value(t, ui.emoji_staged, row.path)
				testing.expect_value(t, string(ui.emoji_name[:]), row.name)
				testing.expect_value(t, ui.focus, Focus.EmojiName)
			}
		}
	}
}

// Rejected names keep the upload editable and explain how to recover.
@(test)
test_save_staged_emoji_empty_shortcode :: proc(t: ^testing.T) {
	for name in ([]string{"!!!", " \t\n", "😀🎉", "", "é日本語"}) {
		ui := Ui_State {
			emoji_staged = strings.clone("staged-image.png"),
			focus        = .EmojiName,
		}
		append(&ui.emoji_name, ..transmute([]u8)name)
		save_staged_emoji(&ui)
		testing.expect_value(
			t,
			ui.client_status,
			tr(
				"Couldn't save your emoji. Include at least one ASCII letter, digit, underscore, or hyphen in the name.",
			),
		)
		testing.expect_value(t, ui.client_status_kind, Status_Kind.Error)
		banner_tick(&ui)
		testing.expect_value(t, ui.banner, ui.client_status)
		testing.expect_value(t, ui.banner_kind, Status_Kind.Error)
		testing.expect_value(t, ui.emoji_staged, "staged-image.png")
		testing.expect_value(t, string(ui.emoji_name[:]), name)
		testing.expect_value(t, ui.focus, Focus.EmojiName)
		delete(ui.emoji_staged)
		delete(ui.emoji_name)
	}
}

// Saving a usable name still normalizes case, maps hyphens, and drops other bytes.
@(test)
test_save_staged_emoji_sanitization :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-emoji-save-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(home)
	previous := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !testing.expect_value(t, os.set_env("XDG_CONFIG_HOME", home), nil) {return}
	defer {
		if previous ==
		   "" {os.unset_env("XDG_CONFIG_HOME")} else {os.set_env("XDG_CONFIG_HOME", previous)}
	}
	if !testing.expect_value(
		t,
		os.make_directory(fmt.tprintf("%s/whitenoise", home)),
		nil,
	) {return}
	saved_names := custom_emoji_names
	saved_sources := emoji_sources
	saved_scanned := custom_emoji_scanned
	custom_emoji_names = nil
	emoji_sources = nil
	defer {
		for name in custom_emoji_names {delete(name)}
		delete(custom_emoji_names)
		emoji_sources_clear()
		custom_emoji_names = saved_names
		emoji_sources = saved_sources
		custom_emoji_scanned = saved_scanned
	}
	source := fmt.tprintf("%s/source.png", home)
	if !testing.expect_value(t, os.write_entire_file(source, BUILTIN_EMOJI[0].png), nil) {return}
	for row in ([]struct {
			name, code: string,
		}{{"Party-01_OK!😀", "party_01_ok"}, {"-", "_"}, {"_", "_"}, {"AZ09", "az09"}}) {
		ui := Ui_State {
			emoji_staged = strings.clone(source),
			focus        = .EmojiName,
		}
		append(&ui.emoji_name, ..transmute([]u8)row.name)
		save_staged_emoji(&ui)
		data, read_err := os.read_entire_file(
			fmt.tprintf("%s/%s.png", emoji_dir(), row.code),
			context.temp_allocator,
		)
		testing.expect_value(t, read_err, nil)
		testing.expect_value(t, string(data), string(BUILTIN_EMOJI[0].png))
		testing.expect_value(t, ui.emoji_staged, "")
		testing.expect_value(t, len(ui.emoji_name), 0)
		testing.expect_value(t, ui.focus, Focus.Compose)
		testing.expect_value(t, ui.client_status, "")
		delete(ui.emoji_name)
	}
}

@(test)
builtin_emoji_payloads :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	expected := [13]struct {
		code, sha256: string,
	} {
		{"marmot", "e787c7deee497eb439c4515607cc8e04043a3f5ac6dc32a6d667a3d3dcfd0c82"},
		{"wn", "af8ffecb318167d4f5ebfc020ce9aba86cb7222f60a64067750e86ec61d539a2"},
		{"marmot_classic", "2eb14069ef98a307e8cde88e85f73c34aeaa191e8a033a125f41909c9368991e"},
		{"marmot_wave", "733a03c928f7fa1040a8d25306c00cdc41532eea3b1446adaa514cd9fd603284"},
		{"marmot_yes", "e91d12edd023ed6af2ec0df44a8526d8d2c1f28ab2d34d7af43728a013200bdf"},
		{"marmot_laugh", "ea7b4f760778396a63b0935653fe6ee37a5a31243b959553a90879adaac9dc61"},
		{"marmot_love", "096ee61fd705e6b6616cf5ef2f2b94f45252e91e8f94aca597b19e4d6a4daeff"},
		{"marmot_party", "9eb8e1bfc64dd96a1a873df837e77f77e4c8ea33a0c0c14e1f2e5dfec1c2c0bd"},
		{"marmot_fire", "00047e800a0a6386b628d0043e9b66cf88cbe0cf597f70e409f02e8caa6f53a1"},
		{"marmot_wow", "906c4ad53f92691fea2c06efb509adad9b48caac74a217d91761bcb6ef961bdb"},
		{"marmot_smirk", "9573a1d7a97f13c68f47294db74ef6f29a65f401d485c6f3359d40f61ab1778e"},
		{"marmot_cry", "51e57e230b8510a9b548b852ed1871dab1d88995a496d9924e08010b87c5a27d"},
		{"marmot_angry", "93b03b1590585c11b0d5036150483d92dece1012c1382a17bdeabaae0c6762a1"},
	}
	for item in expected {
		name, bytes := emoji_payload(item.code)
		defer {delete(name); delete(bytes)}
		testing.expect_value(t, name, fmt.tprintf("%s.png", item.code))
		digest := hash.hash_bytes(.SHA256, bytes, context.temp_allocator)
		testing.expect_value(t, string(hex.encode(digest, context.temp_allocator)), item.sha256)
	}
}

@(test)
test_inline_custom_emoji :: proc(t: ^testing.T) {
	if !test_isolated("test_inline_custom_emoji") {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(640, 128, "Inline custom emoji")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes(); apply_theme(0, 0)
	memory: []u8
	init_layout(&memory, 2048, {640, 128})
	defer delete(memory)

	// A received image can use the same name as a bundled emoji.
	image := custom_emoji_image("marmot_classic")
	received := rl.LoadTextureFromImage(image)
	rl.UnloadImage(image)
	if !testing.expect(t, received.tex != nil) {return}
	defer rl.UnloadTexture(received)
	defer {
		delete(remote_emoji_tex)
		remote_emoji_tex = nil
		for &tex in builtin_emoji_tex {
			if tex != nil {rl.UnloadTexture(tex^); free(tex); tex = nil}
		}
	}
	text := strings.builder_make(context.temp_allocator)
	for asset in BUILTIN_EMOJI {
		remote_emoji_tex[asset.code] = &received
		fmt.sbprintf(&text, ":%s:", asset.code)
	}
	remote_emoji_tex["received_emoji"] = &received
	strings.write_string(&text, ":received_emoji: :undefined_emoji:")

	nendo.begin()
	body_line(42, strings.to_string(text), 16, TEXT)
	commands := nendo.end(0)
	images := 0
	unknown_visible := false
	for cmd in commands {
		if cmd.kind == .Text && strings.contains(cmd.text.text, ":undefined_emoji:") {
			unknown_visible = true
		}
		if cmd.kind != .Image {continue}
		expected :=
			images < len(BUILTIN_EMOJI) ? builtin_tex_by_code(BUILTIN_EMOJI[images].code) : &received
		testing.expect(t, expected != nil && expected.tex != nil)
		testing.expect_value(t, cmd.image.image, rawptr(expected))
		images += 1
	}
	testing.expect_value(t, images, len(BUILTIN_EMOJI) + 1)
	testing.expect(t, unknown_visible)
	if path := os.get_env("WN_INLINE_EMOJI_CAPTURE", context.temp_allocator); path != "" {
		rl.BeginDrawing()
		render_nendo(commands)
		rl.TakeScreenshot(strings.clone_to_cstring(path, context.temp_allocator))
		rl.EndDrawing()
	}
}

// A body's shortcodes are found once each; unknown codes are skipped.
@(test)
test_emoji_codes_in :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	append(&custom_emoji_names, "party.png", "cat.gif")
	defer clear(&custom_emoji_names)

	// custom_tex_by_code loads real files, so drive the pure half:
	// emoji_file_for is what gates a code onto the wire.
	testing.expect_value(t, emoji_file_for("party"), "party.png")
	testing.expect_value(t, emoji_file_for("cat"), "cat.gif")
	testing.expect_value(t, emoji_file_for("nope"), "")
}

// A NIP-30 emoji tag claims the attachment whose locator is its url;
// other attachments and malformed tags stay ordinary.
@(test)
test_emoji_tag_code :: proc(t: ^testing.T) {
	party := [3]cstring{"emoji", "party", "https://b.example/aa"}
	short := [2]cstring{"emoji", "cat"}
	other := [3]cstring{"t", "cat", "https://b.example/bb"}
	tags := [3]marmot.Message_Tag {
		{raw_data(party[:]), 3},
		{raw_data(short[:]), 2},
		{raw_data(other[:]), 3},
	}

	loc_a := [2]marmot.Media_Locator {
		{"blossom", "https://mirror.example/aa"},
		{"blossom", "https://b.example/aa"},
	}
	loc_b := [1]marmot.Media_Locator{{"blossom", "https://b.example/bb"}}
	ref_a := marmot.Media_Attachment_Reference {
		locators     = raw_data(loc_a[:]),
		locators_len = 2,
	}
	ref_b := marmot.Media_Attachment_Reference {
		locators     = raw_data(loc_b[:]),
		locators_len = 1,
	}

	testing.expect_value(t, emoji_tag_code(tags[:], &ref_a), "party")
	testing.expect_value(t, emoji_tag_code(tags[:], &ref_b), "")
}

// Standalone custom emoji detection and sizing rules.
@(test)
test_standalone_custom_emoji_rules :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	saved_scale := UI_SCALE
	saved_remote := remote_emoji_tex
	UI_SCALE = 1
	remote_emoji_tex = nil
	defer {
		delete(remote_emoji_tex)
		remote_emoji_tex = saved_remote
		UI_SCALE = saved_scale
	}

	party_tex := rl.Texture2D {
		width  = 128,
		height = 128,
	}
	wave_tex := rl.Texture2D {
		width  = 256,
		height = 128,
	}
	tall_tex := rl.Texture2D {
		width  = 128,
		height = 256,
	}
	remote_emoji_tex["party"] = &party_tex
	remote_emoji_tex["wave"] = &wave_tex

	// Lone resolvable shortcode enlarges in Jumbo, stays inline in Inline.
	testing.expect_value(t, standalone_custom_emoji(":party:"), &party_tex)
	testing.expect_value(t, standalone_custom_emoji("  :wave:\n"), &wave_tex)
	testing.expect_value(t, body_tile_size(":party:", 14, .Jumbo), jumbo_emoji_size())
	testing.expect_value(t, body_tile_size("  :wave:\n", 14, .Jumbo), jumbo_emoji_size())
	testing.expect_value(t, body_tile_size(":party:", 14, .Inline), f32(18))

	// Text, multiple custom emoji, or unresolved shortcodes stay inline.
	for text in ([]string{":unknown:", ":party: hi", "hi :party:", ":party::party:", ":party: :wave:", "party", "::", "", "   "}) {
		testing.expect_value(t, standalone_custom_emoji(text), nil)
		testing.expect_value(t, body_tile_size(text, 14, .Jumbo), f32(18))
	}

	// Literal inline code and markdown links never enlarge.
	code_font := [1]u8{FONT_MONO | TEXT_CODE}
	code_fonts := strings.repeat(string(code_font[:]), len(":party:"), context.temp_allocator)
	testing.expect_value(t, standalone_custom_emoji(":party:", code_fonts), nil)
	testing.expect_value(t, body_tile_size(":party:", 14, .Jumbo, code_fonts), f32(18))

	links := [1]Inline_Link{{start = 0, end = len(":party:"), url = "https://example.com"}}
	testing.expect_value(t, standalone_custom_emoji(":party:", "", links[:]), nil)
	testing.expect_value(t, body_tile_size(":party:", 14, .Jumbo, "", links[:]), f32(18))

	// Aspect ratio stays bounded by tile_px on both axes.
	w_sq, r_sq := emoji_tile_w(&party_tex, 128)
	testing.expect_value(t, w_sq, f32(128))
	testing.expect_value(t, r_sq, f32(1))
	w_wide, r_wide := emoji_tile_w(&wave_tex, 128)
	testing.expect_value(t, w_wide, f32(128))
	testing.expect_value(t, r_wide, f32(2))
	w_tall, r_tall := emoji_tile_w(&tall_tex, 128)
	testing.expect_value(t, w_tall, f32(64))
	testing.expect_value(t, r_tall, f32(0.5))
}

// Run alone with SDL_VIDEODRIVER=dummy and
// -define:ODIN_TEST_NAMES=test_standalone_custom_emoji.
@(test)
test_standalone_custom_emoji :: proc(t: ^testing.T) {
	if !test_isolated("test_standalone_custom_emoji") {return}
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	rl.InitWindow(1024, 700, "Standalone custom emoji")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	BODY_FS = 14
	init_fonts()
	load_themes(); apply_theme(0, 0); set_locale("en")
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 65536, {1024, 700})
	defer {nendo.set_context(previous); delete(memory)}

	ui := Ui_State{}
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs = nil, nil
		wrap_clear()
		delete(sel_lines); sel_lines = nil
		delete(remote_emoji_tex); remote_emoji_tex = nil
		for &tex in builtin_emoji_tex {
			if tex != nil {rl.UnloadTexture(tex^); free(tex); tex = nil}
		}
	}

	// Build a 256x128 non-square remote custom emoji texture.
	pixels := make([]u8, 256 * 128 * 4, context.temp_allocator)
	for i := 0; i < len(pixels); i += 4 {
		pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3] = 200, 120, 40, 255
	}
	wide_tex := rl.LoadTextureFromImage(
		rl.Image{data = raw_data(pixels), width = 256, height = 128},
	)
	if !testing.expect(t, wide_tex.tex != nil) {return}
	defer rl.UnloadTexture(wide_tex)
	remote_emoji_tex["wide_marmot"] = &wide_tex

	first_image_box :: proc(
		commands: []nendo.Render_Command,
		target: rawptr,
	) -> (
		nendo.Rect,
		bool,
	) {
		for cmd in commands {
			if cmd.kind == .Image && cmd.image.image == target {
				return cmd.rect, true
			}
		}
		return {}, false
	}

	marmot_tex := builtin_tex_by_code("marmot")
	if !testing.expect(t, marmot_tex != nil) {return}
	inline_px := f32(BODY_FS) + 4

	// 1. Standalone builtin custom emoji with a NIP-30 .Emoji attachment slot enlarges.
	solo_msg := Msg_Ui {
		id     = "m1",
		sender = "Alice",
		body   = ":marmot:",
	}
	append(&solo_msg.blocks, Md_Block_Ui{kind = .Para, text = ":marmot:"})
	append(
		&solo_msg.attachments,
		Att_Slot{name = "marmot.png", key = "abc", kind = .Emoji, state = .Ready},
	)
	defer {delete(solo_msg.blocks); delete(solo_msg.attachments)}

	nendo.begin()
	if nendo.box(nendo.id("Timeline"))({direction = .Column, width = nendo.fixed(640)}) {
		message_row(1, solo_msg)
	}
	cmds := nendo.end(0)
	if box, ok := first_image_box(cmds, rawptr(marmot_tex)); testing.expect(t, ok) {
		testing.expect_value(t, box.width, f32(128))
		testing.expect_value(t, box.height, f32(128))
	}

	// 2. Non-square standalone custom emoji preserves aspect ratio within 128x128.
	wide_msg := Msg_Ui {
		id     = "m2",
		sender = "Alice",
		body   = "  :wide_marmot:\n",
	}
	nendo.begin()
	if nendo.box(nendo.id("Timeline"))({direction = .Column, width = nendo.fixed(640)}) {
		message_row(2, wide_msg)
	}
	cmds = nendo.end(0)
	if box, ok := first_image_box(cmds, rawptr(&wide_tex)); testing.expect(t, ok) {
		testing.expect_value(t, box.width, f32(128))
		testing.expect_value(t, box.height, f32(64))
	}

	// 3. Inline with text stays normal size.
	text_msg := Msg_Ui {
		id     = "m3",
		sender = "Alice",
		body   = "hello :marmot:",
	}
	append(&text_msg.blocks, Md_Block_Ui{kind = .Para, text = "hello :marmot:"})
	defer delete(text_msg.blocks)

	nendo.begin()
	if nendo.box(nendo.id("Timeline"))({direction = .Column, width = nendo.fixed(640)}) {
		message_row(3, text_msg)
	}
	cmds = nendo.end(0)
	if box, ok := first_image_box(cmds, rawptr(marmot_tex)); testing.expect(t, ok) {
		testing.expect_value(t, box.width, inline_px)
		testing.expect_value(t, box.height, inline_px)
	}

	// 4. Two custom emoji stay normal inline size.
	pair_msg := Msg_Ui {
		id     = "m4",
		sender = "Alice",
		body   = ":marmot: :marmot:",
	}
	append(&pair_msg.blocks, Md_Block_Ui{kind = .Para, text = ":marmot: :marmot:"})
	defer delete(pair_msg.blocks)

	nendo.begin()
	if nendo.box(nendo.id("Timeline"))({direction = .Column, width = nendo.fixed(640)}) {
		message_row(4, pair_msg)
	}
	cmds = nendo.end(0)
	if box, ok := first_image_box(cmds, rawptr(marmot_tex)); testing.expect(t, ok) {
		testing.expect_value(t, box.width, inline_px)
		testing.expect_value(t, box.height, inline_px)
	}

	// 5. Custom emoji paired with a non-emoji attachment, quote, multi-block, or poll stays inline.
	att_msg := Msg_Ui {
		id     = "m5",
		sender = "Alice",
		body   = ":marmot:",
	}
	append(&att_msg.blocks, Md_Block_Ui{kind = .Para, text = ":marmot:"})
	append(
		&att_msg.attachments,
		Att_Slot{name = "photo.png", key = "img", kind = .Image, state = .Ready, view = &wide_tex},
	)
	defer {delete(att_msg.blocks); delete(att_msg.attachments)}

	nendo.begin()
	if nendo.box(nendo.id("Timeline"))({direction = .Column, width = nendo.fixed(640)}) {
		message_row(5, att_msg)
	}
	cmds = nendo.end(0)
	if box, ok := first_image_box(cmds, rawptr(marmot_tex)); testing.expect(t, ok) {
		testing.expect_value(t, box.width, inline_px)
		testing.expect_value(t, box.height, inline_px)
	}

	quote_msg := Msg_Ui {
		id     = "m6",
		sender = "Alice",
		body   = "> :marmot:",
	}
	append(&quote_msg.blocks, Md_Block_Ui{kind = .Quote, text = ":marmot:"})
	defer delete(quote_msg.blocks)

	nendo.begin()
	if nendo.box(nendo.id("Timeline"))({direction = .Column, width = nendo.fixed(640)}) {
		message_row(6, quote_msg)
	}
	cmds = nendo.end(0)
	if box, ok := first_image_box(cmds, rawptr(marmot_tex)); testing.expect(t, ok) {
		testing.expect_value(t, box.width, inline_px)
		testing.expect_value(t, box.height, inline_px)
	}

	multi_msg := Msg_Ui {
		id     = "m7",
		sender = "Alice",
		body   = ":marmot:\n\nhi",
	}
	append(&multi_msg.blocks, Md_Block_Ui{kind = .Para, text = ":marmot:"})
	append(&multi_msg.blocks, Md_Block_Ui{kind = .Para, text = "hi"})
	defer delete(multi_msg.blocks)

	nendo.begin()
	if nendo.box(nendo.id("Timeline"))({direction = .Column, width = nendo.fixed(640)}) {
		message_row(7, multi_msg)
	}
	cmds = nendo.end(0)
	if box, ok := first_image_box(cmds, rawptr(marmot_tex)); testing.expect(t, ok) {
		testing.expect_value(t, box.width, inline_px)
		testing.expect_value(t, box.height, inline_px)
	}

	poll_msg := Msg_Ui {
		id     = "m8",
		sender = "Alice",
		body   = ":marmot:",
	}
	append(&poll_msg.blocks, Md_Block_Ui{kind = .Para, text = ":marmot:"})
	append(&poll_msg.poll_opts, Poll_Opt_Ui{id = "a", label = "Yes"})
	defer {delete(poll_msg.blocks); delete(poll_msg.poll_opts)}

	nendo.begin()
	if nendo.box(nendo.id("Timeline"))({direction = .Column, width = nendo.fixed(640)}) {
		message_row(8, poll_msg)
	}
	cmds = nendo.end(0)
	if box, ok := first_image_box(cmds, rawptr(marmot_tex)); testing.expect(t, ok) {
		testing.expect_value(t, box.width, inline_px)
		testing.expect_value(t, box.height, inline_px)
	}

	// 6. Pending send with only custom emoji enlarges immediately; with a file stays inline.
	solo_pending := Pending_Send {
		sender = "Alice",
		body   = ":marmot:",
	}
	append(&solo_pending.atts, Pending_Att{name = "marmot.png", emoji = "marmot"})
	defer delete(solo_pending.atts)

	nendo.begin()
	if nendo.box(nendo.id("Timeline"))({direction = .Column, width = nendo.fixed(640)}) {
		pending_row(1, &ui, solo_pending)
	}
	cmds = nendo.end(0)
	if box, ok := first_image_box(cmds, rawptr(marmot_tex)); testing.expect(t, ok) {
		testing.expect_value(t, box.width, f32(128))
		testing.expect_value(t, box.height, f32(128))
	}

	file_pending := Pending_Send {
		sender = "Alice",
		body   = ":marmot:",
	}
	append(&file_pending.atts, Pending_Att{name = "photo.png", tex = &wide_tex})
	defer delete(file_pending.atts)

	nendo.begin()
	if nendo.box(nendo.id("Timeline"))({direction = .Column, width = nendo.fixed(640)}) {
		pending_row(2, &ui, file_pending)
	}
	cmds = nendo.end(0)
	if box, ok := first_image_box(cmds, rawptr(marmot_tex)); testing.expect(t, ok) {
		testing.expect_value(t, box.width, inline_px)
		testing.expect_value(t, box.height, inline_px)
	}

	// 7. HiDPI scaling and narrow (single-pane) cap match standalone Unicode emoji.
	UI_SCALE = 1.5
	testing.expect_value(t, body_tile_size(":marmot:", BODY_FS, .Jumbo), f32(EMOJI_SIDE) / 1.5)
	UI_SCALE = 1
	rl.SetWindowSize(480, 700)
	testing.expect(t, single_pane())
	testing.expect_value(t, body_tile_size(":marmot:", BODY_FS, .Jumbo), f32(64))

	// 8. Selection hit-testing treats a standalone custom emoji as one whole atom.
	testing.expect_value(t, hit_plain(":marmot:", 20, BODY_FS, 128), 0)
	testing.expect_value(t, hit_plain(":marmot:", 96, BODY_FS, 128), len(":marmot:"))
}
