// Account key package rows, public-key disclosure, and two-step confirmation.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "nendo"
import rl "sdlrl"
import sdl "vendor:sdl3"

@(test)
keys_package_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "keys_package_layout" {return}
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-keys-layout", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(home)
	previous_config, had_config := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !testing.expect_value(t, os.set_env("XDG_CONFIG_HOME", home), nil) {return}
	defer {
		if had_config {
			os.set_env("XDG_CONFIG_HOME", previous_config)
		} else {
			os.unset_env("XDG_CONFIG_HOME")
		}
	}
	rl.InitWindow(1024, 700, "Key package locations")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes(); apply_theme(0, 0)
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {nendo.set_context(previous); delete(memory)}
	ui := Ui_State {
		page          = .Settings,
		selected      = -1,
		kp_fetched    = true,
		audit_scanned = true,
	}
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	ui.account_ref = "offline"
	append(
		&ui.accounts,
		Account_Row_Ui{id_hex = "offline", name = "Offline fixture", local = true},
	)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs = nil, nil
		kp_rows_free(&ui.kp_list)
		delete(ui.kp_list); delete(ui.accounts)
		set_locale("en")
	}
	relays := make([]string, 2)
	relays[0], relays[1] = strings.clone("wss://a"), strings.clone("wss://b")
	append(
		&ui.kp_list,
		Kp_Row {
			id = strings.clone("0123456789abcdef"),
			at = strings.clone("2026-10-28"),
			local = true,
			relay = true,
			relay_urls = relays,
		},
	)
	settings_open(&ui, nil, .Account, "KpStatus")
	for locale in ([]string{"en", "it", "de", "ja", "ko"}) {
		set_locale(locale)
		for _ in 0 ..< 3 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
		settings_resolve_scroll(&ui)
		commands := build_layout(&ui, 0)
		row := nendo.element(nendo.id("KpRow", 0))
		testing.expect(t, row.found && row.rect.height > 0, "package has a visible row")
		testing.expect(
			t,
			!nendo.element(nendo.id("KpRow", 1)).found,
			"overlapping locations do not add a package row",
		)
		box := row.rect
		text_count := 0
		for command in commands {
			b := command.rect
			if command.kind != .Text ||
			   b.x < box.x ||
			   b.y < box.y ||
			   b.y >= box.y + box.height {continue}
			text_count += 1
			testing.expect(
				t,
				b.x >= box.x && b.x + b.width <= box.x + box.width + 0.1,
				"row text fits horizontally",
			)
			testing.expect(
				t,
				b.y + b.height <= box.y + box.height + 0.1,
				"row text fits vertically",
			)
		}
		testing.expect(t, text_count > 0, "package row renders text")
	}
	keys_public_layout(t, &ui)
}

@(private = "file")
keys_public_layout :: proc(t: ^testing.T, ui: ^Ui_State) {
	NPUB :: "npub1d6qfwzfzzexwg39v98msg2nv3v7ey8jpwr4dv5fy9hd3pucusmpqasx9s6"
	SECRET :: "nsec1-fixture"
	clipboard := sdl.GetClipboardText()
	defer {
		if clipboard != nil {sdl.SetClipboardText(cstring(clipboard))}
		sdl.free(clipboard)
		keys_forget(ui)
		delete(ui.toast)
		delete(ui.settings_search)
	}
	set_locale("en")
	ui.profile.npub = NPUB
	settings_open(ui, nil, .Account, "NpubRow")
	keys_expect_public_layout(t, ui, false)

	settings_open(ui, nil, .Home)
	append(&ui.settings_search, "Copy your public key")
	ui.focus = .SettingsSearch
	settings_test_frame(ui)
	rl.PushKey(.ENTER, true)
	handle_settings(ui, nil)
	rl.PushKey(.ENTER, false)
	testing.expect_value(t, ui.settings_section, Settings_Section.Account)
	keys_expect_public_layout(t, ui, false)
	testing.expect_value(t, kb_focus, "SettingsCopyNpub")

	sdl.SetClipboardText("before public key copy")
	settings_test_point(nendo.id("SettingsCopyNpub"))
	settings_test_release(ui)
	keys_expect_clipboard(t, NPUB)
	keys_expect_public_layout(t, ui, false)

	ui.keys_nsec = strings.clone(SECRET)
	rl.PushKey(.TAB, true)
	handle_settings(ui, nil)
	rl.PushKey(.TAB, false)
	testing.expect_value(t, kb_focus, "SettingsShowNpub")
	rl.PushKey(.SPACE, true)
	handle_settings(ui, nil)
	rl.PushKey(.SPACE, false)
	keys_expect_public_layout(t, ui, true)
	testing.expect_value(t, ui.keys_nsec, SECRET)
	testing.expect(t, !ui.keys_nsec_show && !nendo.element(nendo.id("NsecValue")).found)

	sdl.SetClipboardText("long press copies the public key")
	settings_test_point(nendo.id("NpubInset"))
	long_pressed = true
	keys_fields(ui)
	long_pressed = false
	keys_expect_clipboard(t, NPUB)

	settings_test_point(nendo.id("SettingsShowNpub"))
	settings_test_release(ui)
	keys_expect_public_layout(t, ui, false)
	settings_test_point(nendo.id("SettingsShowNpub"))
	settings_test_release(ui)
	testing.expect(t, ui.keys_npub_show)
	settings_back(ui)
	testing.expect(t, !ui.keys_npub_show, "Leaving Account must hide the public key")

	settings_open(ui, nil, .Account)
	settings_flip(ui, nil, "SettingsShowNpub")
	ui.account_ref = strings.clone(ui.account_ref)
	finish_account_switch(ui, nil, "second-account")
	defer {
		devices_stop(ui)
		delete(ui.account_ref)
		delete(ui.gs_account)
		delete(ui.prefs.last_account)
	}
	testing.expect_value(t, ui.account_ref, "second-account")
	testing.expect(t, !ui.keys_npub_show, "Switching accounts must hide the public key")
}

@(private = "file")
keys_expect_public_layout :: proc(t: ^testing.T, ui: ^Ui_State, shown: bool) {
	commands := settings_test_frame(ui)
	testing.expect_value(t, nendo.element(nendo.id("NpubInset")).found, shown)
	key_rendered, label_rendered := false, false
	label := shown ? tr("Hide key") : tr("Show key")
	for command in commands {
		if command.kind != .Text {continue}
		if strings.has_prefix(command.text.text, "npub1") {key_rendered = true}
		if command.text.text == label {label_rendered = true}
	}
	testing.expect_value(t, key_rendered, shown)
	testing.expect(t, label_rendered)
}

@(private = "file")
keys_expect_clipboard :: proc(t: ^testing.T, expected: string) {
	clipboard := sdl.GetClipboardText()
	defer sdl.free(clipboard)
	testing.expect_value(t, string(cstring(clipboard)), expected)
}

@(test)
keys_confirm_arms :: proc(t: ^testing.T) {
	ui: Ui_State

	// First click arms, second acts; a different button steals the arm.
	testing.expect(t, !armed(&ui, "RotateBtn"))
	testing.expect_value(t, ui.keys_confirm, "RotateBtn")
	testing.expect(t, armed(&ui, "RotateBtn"))
	testing.expect_value(t, ui.keys_confirm, "")

	testing.expect(t, !armed(&ui, "RotateBtn"))
	testing.expect(t, !armed(&ui, "RevealNsecBtn"))
	testing.expect_value(t, ui.keys_confirm, "RevealNsecBtn")
}
