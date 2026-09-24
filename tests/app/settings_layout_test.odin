package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:testing"
import rl "sdlrl"

// Runs in its own headless process through scripts/build.sh test.
@(test)
settings_viewport :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "settings_viewport" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(740, 500, "Settings viewport")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	set_locale("ja")
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {740, 500})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui := Ui_State {
		page          = .Settings,
		audit_scanned = true,
	}
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	for size in ([]struct {
			w, h: i32,
			zoom: f32,
		}{{740, 500, 1}, {390, 360, 1}, {1440, 1000, 1.5}}) {
		rl.SetWindowSize(size.w, size.h)
		UI_ZOOM = size.zoom
		viewport := clay.Dimensions{f32(size.w) / UI_ZOOM, f32(size.h) / UI_ZOOM}
		clay.SetLayoutDimensions(viewport)
		for target in ([]struct {
				section: Settings_Section,
				anchor:  string,
			}{{.Home, ""}, {.General, "RowLang"}, {.Network, "AddRelayRow"}, {.Network, "AddFetchRow"}, {.Network, "ClientBox"}, {.Keys, "NpubRow"}, {.Keys, "KpStatus"}, {.Keys, "RowRotate"}, {.Keys, "RowVaultPw"}, {.Keys, "RowReveal"}, {.Advanced, "RowTelemetry"}, {.Advanced, "RowAudit"}, {.Advanced, "RowDevMode"}, {.Appearance, "RowTheme"}}) {
			settings_open(&ui, nil, target.section, anchor = target.anchor)
			for _ in 0 ..< 3 {settings_test_frame(&ui)}
			root := clay.GetElementData(clay.ID("SettingsRoot"))
			box := root.boundingBox
			testing.expect(
				t,
				root.found && box.width > 0 && box.x >= 0 && box.x + box.width <= viewport.width,
				"Translated settings must not expand the page beyond the window",
			)
			if target.anchor != "" {
				testing.expect(
					t,
					clay.GetElementData(clay.ID(target.anchor)).found,
					"A settings deep link must render its destination control",
				)
			}
			if target.section == .General {
				sheet := clay.GetElementData(clay.ID("SettingsSheet")).boundingBox
				group := clay.GetElementData(clay.ID("LanguageGroup")).boundingBox
				left := group.x - sheet.x
				right := sheet.x + sheet.width - group.x - group.width
				testing.expect(
					t,
					left > right - 1 && left < right + 1,
					"The Language fieldset must have equal side gutters inside its tab panel",
				)
			}
		}
		ui.theme_menu_open = true
		for _ in 0 ..< 3 {settings_test_frame(&ui)}
		menu := clay.GetElementData(clay.ID("ThemeMenu"))
		b := menu.boundingBox
		if !testing.expect(
			t,
			menu.found &&
			b.width > 0 &&
			b.height > 0 &&
			b.x >= 0 &&
			b.y >= 0 &&
			b.x + b.width <= viewport.width &&
			b.y + b.height <= viewport.height,
			"The open theme picker must fit narrow and short windows",
		) {return}
		// Wheel input must reach the clipped final row, not just a correctly sized box.
		clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
		clay.UpdateScrollContainers(false, {0, -10000}, 1.0 / 60)
		for _ in 0 ..< 3 {settings_test_frame(&ui)}
		last := len(theme_packs) - 1
		if last == system_theme_index {last -= 1}
		target := clay.GetElementData(clay.ID("ThemeOpt", u32(last)))
		row := target.boundingBox
		testing.expect(
			t,
			target.found && row.y >= b.y && row.y + row.height <= b.y + b.height,
			"Scrolling must reveal the complete final theme option",
		)
		clay.SetPointerState({row.x + row.width / 2, row.y + row.height / 2}, false)
		testing.expect(
			t,
			clay.PointerOver(clay.ID("ThemeOpt", u32(last))),
			"The final theme option must remain clickable inside the menu clip",
		)
		ui.theme_menu_open = false
	}
}

@(private)
settings_test_frame :: proc(ui: ^Ui_State) {
	anim_tick(1.0 / 60)
	clay.UpdateScrollContainers(false, {}, 0)
	clay.BeginLayout()
	settings_pane(ui)
	clay.EndLayout(0)
	if settings_resolve_scroll(ui) {
		clay.BeginLayout()
		settings_pane(ui)
		clay.EndLayout(0)
	}
}
