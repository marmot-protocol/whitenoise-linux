#+build linux
package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import rl "sdlrl"

// Run alone: SDL and Clay own process-global state. Exercise both production
// dispatch paths with real filesystem failures, then retry and cancel.
@(test)
test_emoji_save_io_dispatch :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "test_emoji_save_io_dispatch" {return}
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp(
		os.get_env("TMPDIR", context.temp_allocator),
		"wn-emoji-io-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, err, nil) {return}
	defer testing.expect_value(t, os.remove_all(home), nil)
	previous_home, had_home := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !testing.expect_value(t, os.set_env("XDG_CONFIG_HOME", home), nil) {return}
	defer {
		if had_home {
			testing.expect_value(t, os.set_env("XDG_CONFIG_HOME", previous_home), nil)
		} else {
			testing.expect(t, os.unset_env("XDG_CONFIG_HOME"))
		}
	}
	if !testing.expect_value(
		t,
		os.make_directory(fmt.tprintf("%s/whitenoise", home)),
		nil,
	) {return}
	fixture_dir := fmt.tprintf("%s/whitenoise/emoji", home)
	// Never recursively delete a path obtained from unchecked platform config.
	if !testing.expect_value(t, emoji_dir(), fixture_dir) {return}
	rl.InitWindow(1024, 700, "Emoji save IO dispatch")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes(); apply_theme(0, 0)
	previous_layout := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {clay.SetCurrentContext(previous_layout); delete(memory)}
	ui := Ui_State {
		page          = .Settings,
		audit_scanned = true,
	}
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	set_locale(ui.prefs.locale)
	defer set_locale("en")
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; settings_stop(&ui); delete(ui.emoji_staged)
		delete(ui.emoji_name)}
	saved_names, saved_sources, saved_scanned :=
		custom_emoji_names, emoji_sources, custom_emoji_scanned
	saved_textures := custom_emoji_textures
	custom_emoji_names, emoji_sources, custom_emoji_scanned = nil, nil, true
	custom_emoji_textures = nil
	defer {
		for name, tex in custom_emoji_textures {
			if tex != nil {rl.UnloadTexture(tex^); free(tex)}
			delete(name)
		}
		delete(custom_emoji_textures); custom_emoji_textures = saved_textures
		for name in custom_emoji_names {delete(name)}
		delete(custom_emoji_names); emoji_sources_clear()
		custom_emoji_names, emoji_sources, custom_emoji_scanned =
			saved_names, saved_sources, saved_scanned
		forced_release, kb_focus = false, ""
	}
	settings_open(&ui, nil, .General, 2, level = .Sheet)
	ui.settings_anchor = "CustomEmojiGroup"
	source := fmt.tprintf("%s/party.png", home)
	destination := fmt.tprintf("%s/party.png", fixture_dir)
	for keyboard in ([]bool{false, true}) {
		for failure in 0 ..< 4 {
			// 0: source disappeared; 1: staging directory creation fails;
			// 2: destination directory blocks rename; 3: kernel rejects write.
			if !testing.expect_value(t, emoji_dir(), fixture_dir) {return}
			if os.exists(fixture_dir) &&
			   !testing.expect_value(t, os.remove_all(fixture_dir), nil) {return}
			if os.exists(source) &&
			   !testing.expect_value(t, os.remove(source), nil) {return}
			if failure != 0 &&
			   !testing.expect_value(
					   t,
					   os.write_entire_file(source, BUILTIN_EMOJI[1].png),
					   nil,
				   ) {return}
			if failure == 1 &&
			   !testing.expect_value(
					   t,
					   os.write_entire_file(fixture_dir, "blocked"),
					   nil,
				   ) {return}
			if failure >= 2 &&
			   !testing.expect_value(t, os.make_directory(fixture_dir), nil) {return}
			if failure == 2 &&
			   !testing.expect_value(t, os.make_directory(destination), nil) {return}
			old_texture: ^rl.Texture2D
			if failure == 3 {
				if !testing.expect_value(
					t,
					os.write_entire_file(destination, BUILTIN_EMOJI[0].png),
					nil,
				) {return}
				append(&custom_emoji_names, strings.clone("party.png"))
				append(
					&emoji_sources,
					Emoji_Source {
						strings.clone("party.png"),
						strings.clone("Original title"),
						strings.clone("Original author"),
						strings.clone("original-coordinate"),
					},
				)
				old_texture = custom_emoji_texture("party.png")
				if !testing.expect(t, old_texture != nil) {return}
			}
			stage_emoji(&ui, source)
			ui.client_status, ui.banner, ui.banner_seen = "", "", ""
			for attempt in 0 ..< 2 {
				if attempt == 1 {
					ui.banner = ""
					banner_tick(&ui)
					testing.expect_value(t, ui.banner, "")
				}
				for _ in 0 ..< 3 {settings_test_frame(&ui)}
				if !emoji_io_save_dispatch(t, &ui, keyboard, failure == 3) {return}
				banner_tick(&ui)
				testing.expect_value(
					t,
					ui.banner,
					tr("Couldn't save your emoji. Please try again."),
				)
				testing.expect_value(t, ui.banner_kind, Status_Kind.Error)
				if !testing.expect_value(t, ui.emoji_staged, source) {return}
				testing.expect_value(t, string(ui.emoji_name[:]), "party")
				testing.expect_value(t, ui.focus, Focus.EmojiName)
				if !testing.expect_value(
					t,
					len(custom_emoji_names),
					failure == 3 ? 1 : 0,
				) {return}
				if failure == 3 {
					bytes, read_err := os.read_entire_file(
						destination,
						context.temp_allocator,
					)
					testing.expect_value(t, read_err, nil)
					testing.expect_value(
						t,
						string(bytes),
						string(BUILTIN_EMOJI[0].png),
					)
					testing.expect_value(t, custom_emoji_names[0], "party.png")
					testing.expect_value(
						t,
						custom_emoji_textures["party.png"],
						old_texture,
					)
					if !testing.expect_value(t, len(emoji_sources), 1) {return}
					testing.expect_value(
						t,
						emoji_sources[0],
						Emoji_Source {
							"party.png",
							"Original title",
							"Original author",
							"original-coordinate",
						},
					)
				}
			}
			// Cancel after failure, then restage for recovery through the same UI.
			if failure == 3 {
				if !emoji_io_click(t, &ui, "EmojiCancel") {return}
				testing.expect_value(t, ui.emoji_staged, "")
				testing.expect_value(t, len(ui.emoji_name), 0)
				testing.expect_value(t, ui.focus, Focus.Compose)
				stage_emoji(&ui, source)
			}
			// A repaired filesystem allows both mouse and keyboard recovery.
			if !testing.expect_value(t, emoji_dir(), fixture_dir) {return}
			if failure != 3 &&
			   os.exists(fixture_dir) &&
			   !testing.expect_value(t, os.remove_all(fixture_dir), nil) {return}
			if !testing.expect_value(
				t,
				os.write_entire_file(source, BUILTIN_EMOJI[1].png),
				nil,
			) {return}
			for _ in 0 ..< 3 {settings_test_frame(&ui)}
			if !emoji_io_save_dispatch(t, &ui, keyboard, false) {return}
			bytes, read_err := os.read_entire_file(destination, context.temp_allocator)
			testing.expect_value(t, read_err, nil)
			testing.expect_value(t, string(bytes), string(BUILTIN_EMOJI[1].png))
			if failure == 3 {
				_, cached := custom_emoji_textures["party.png"]
				testing.expect(t, !cached)
				testing.expect_value(t, len(emoji_sources), 0)
			}
			testing.expect_value(t, ui.emoji_staged, "")
			testing.expect_value(t, ui.focus, Focus.Compose)
			for name in custom_emoji_names {delete(name)}
			clear(&custom_emoji_names); emoji_sources_clear()
		}
	}
	stage_emoji(&ui, source)
	rl.PushKey(.ESCAPE, true); settings_escape(&ui)
	rl.PushKey(.ESCAPE, false); rl.WindowShouldClose()
	testing.expect_value(t, ui.emoji_staged, "")
	testing.expect_value(t, len(ui.emoji_name), 0)
}

@(private = "file")
emoji_io_click :: proc(t: ^testing.T, ui: ^Ui_State, id: string) -> bool {
	button := clay.GetElementData(clay.ID(id))
	if !testing.expect(t, button.found) {return false}
	box := button.boundingBox
	clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
	forced_release = true
	handle_settings(ui, nil)
	forced_release = false
	return true
}

@(private = "file")
emoji_io_save_dispatch :: proc(t: ^testing.T, ui: ^Ui_State, keyboard, fail_write: bool) -> bool {
	// Scope process-global failure injection to dispatch only. Keep the hard
	// limit unchanged and restore the full signal disposition, even on return.
	if fail_write {
		previous_limit: posix.rlimit
		if !testing.expect_value(
			t,
			posix.getrlimit(.FSIZE, &previous_limit),
			posix.result.OK,
		) {return false}
		previous_signal: posix.sigaction_t
		ignore: posix.sigaction_t
		ignore.sa_handler = auto_cast posix.SIG_IGN
		if !testing.expect_value(
			t,
			posix.sigemptyset(&ignore.sa_mask),
			i32(0),
		) {return false}
		if !testing.expect_value(
			t,
			posix.sigaction(.SIGXFSZ, &ignore, &previous_signal),
			posix.result.OK,
		) {return false}
		defer testing.expect_value(
			t,
			posix.sigaction(.SIGXFSZ, &previous_signal, nil),
			posix.result.OK,
		)
		limited := previous_limit
		limited.rlim_cur = 0
		if !testing.expect_value(
			t,
			posix.setrlimit(.FSIZE, &limited),
			posix.result.OK,
		) {return false}
		defer testing.expect_value(
			t,
			posix.setrlimit(.FSIZE, &previous_limit),
			posix.result.OK,
		)
		return emoji_io_save_dispatch(t, ui, keyboard, false)
	}
	if keyboard {
		rl.PushKey(.ENTER, true); settings_fields(ui)
		rl.PushKey(.ENTER, false); rl.WindowShouldClose()
		return true
	}
	return emoji_io_click(t, ui, "EmojiSave")
}
