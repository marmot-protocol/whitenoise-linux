package main

import "base:runtime"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

import marmot "../marmot"

// Run alone with SDL_VIDEODRIVER=dummy and
// -define:ODIN_TEST_NAMES=test_emoji_save_dispatch (SDL/Clay process globals).
@(test)
test_emoji_save_dispatch :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "test_emoji_save_dispatch" {return}
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	rl.InitWindow(1024, 700, "Emoji save dispatch")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes(); apply_theme(0, 0); set_locale("en")
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	scanned := custom_emoji_scanned
	custom_emoji_scanned = true
	defer {custom_emoji_scanned = scanned; forced_release = false; kb_focus = ""}
	ui := Ui_State{page = .Settings, audit_scanned = true}
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; settings_stop(&ui); delete(ui.emoji_staged); delete(ui.emoji_name)}
	settings_open(&ui, nil, .General, 2, level = .Sheet)
	ui.settings_anchor = "CustomEmojiGroup"
	for keyboard in ([]bool{false, true}) {
		for row in ([]struct{path, name: string}{
			{"/staged/!!!.png", ""},
			{"/staged/😀🎉.png", ""},
			{"/staged/!!!.png", "!!!"},
		}) {
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
					button := clay.GetElementData(clay.ID("EmojiSave"))
					if !testing.expect(t, button.found) {return}
					box := button.boundingBox
					clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
					if !testing.expect(t, clay.PointerOver(clay.ID("EmojiSave"))) {return}
					forced_release = true
					handle_settings(&ui, nil)
					forced_release = false
				}
				banner_tick(&ui)
				testing.expect_value(t, ui.banner, tr("Couldn't save your emoji. Include at least one ASCII letter, digit, underscore, or hyphen in the name."))
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
		ui := Ui_State{emoji_staged = strings.clone("staged-image.png"), focus = .EmojiName}
		append(&ui.emoji_name, ..transmute([]u8)name)
		save_staged_emoji(&ui)
		testing.expect_value(t, ui.client_status, tr("Couldn't save your emoji. Include at least one ASCII letter, digit, underscore, or hyphen in the name."))
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
		if previous == "" {os.unset_env("XDG_CONFIG_HOME")} else {os.set_env("XDG_CONFIG_HOME", previous)}
	}
	if !testing.expect_value(t, os.make_directory(fmt.tprintf("%s/whitenoise", home)), nil) {return}
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
	for row in ([]struct{name, code: string}{
		{"Party-01_OK!😀", "party_01_ok"},
		{"-", "_"},
		{"_", "_"},
		{"AZ09", "az09"},
	}) {
		ui := Ui_State{emoji_staged = strings.clone(source), focus = .EmojiName}
		append(&ui.emoji_name, ..transmute([]u8)row.name)
		save_staged_emoji(&ui)
		data, read_err := os.read_entire_file(fmt.tprintf("%s/%s.png", emoji_dir(), row.code), context.temp_allocator)
		testing.expect_value(t, read_err, nil)
		testing.expect_value(t, string(data), string(BUILTIN_EMOJI[0].png))
		testing.expect_value(t, ui.emoji_staged, "")
		testing.expect_value(t, len(ui.emoji_name), 0)
		testing.expect_value(t, ui.focus, Focus.Compose)
		testing.expect_value(t, ui.client_status, "")
		delete(ui.emoji_name)
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
