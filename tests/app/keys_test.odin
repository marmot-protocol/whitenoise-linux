// Keys page: package row layout and the two-step danger confirm.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:testing"
import rl "sdlrl"

@(test)
keys_package_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "keys_package_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 700, "Key package locations")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes(); apply_theme(0, 0)
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui := Ui_State {
		page          = .Settings,
		selected      = -1,
		kp_fetched    = true,
		audit_scanned = true,
	}
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	ui.account_ref = "offline"
	append(&ui.accounts, "Offline fixture")
	append(&ui.account_ids, "offline")
	append(&ui.account_signing, Account_Signing{local = true})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs = nil, nil
		delete(ui.kp_list); delete(ui.accounts); delete(ui.account_ids); delete(ui.account_signing)
		set_locale("en")
	}
	append(
		&ui.kp_list,
		Kp_Row {
			id = "0123456789abcdef",
			at = "2026-10-28",
			local = true,
			relay = true,
			relay_urls = {"wss://a", "wss://b"},
		},
	)
	settings_open(&ui, nil, .Keys, 1, level = .Sheet)
	for locale in ([]string{"en", "it", "de", "ja"}) {
		set_locale(locale)
		for _ in 0 ..< 3 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
		commands := build_layout(&ui, 0)
		row := clay.GetElementData(clay.ID("KpRow", 0))
		testing.expect(t, row.found && row.boundingBox.height > 0, "package has a visible row")
		testing.expect(
			t,
			!clay.GetElementData(clay.ID("KpRow", 1)).found,
			"overlapping locations do not add a package row",
		)
		box := row.boundingBox
		text_count := 0
		for command in commands.internalArray[:commands.length] {
			b := command.boundingBox
			if command.commandType != .Text ||
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
