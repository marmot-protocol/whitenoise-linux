// Keys page: package row layout and the two-step danger confirm.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "base:runtime"
import "core:testing"
import "nendo"
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
		delete(ui.kp_list); delete(ui.accounts)
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
	for locale in ([]string{"en", "it", "de", "ja", "ko"}) {
		set_locale(locale)
		for _ in 0 ..< 3 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
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
