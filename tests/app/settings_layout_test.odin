package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:math"
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
	append(&ui.account_ids, "viewport-local", "viewport-remote")
	append(&ui.account_signing, Account_Signing{local = true}, Account_Signing{external = true})
	ui.account_ref = "viewport-local"
	defer {delete(ui.account_ids); delete(ui.account_signing)}
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
			}{{.Home, ""}, {.Keys, ""}, {.General, "RowLang"}, {.Network, "AddRelayRow"}, {.Network, "AddFetchRow"}, {.Network, "ClientBox"}, {.Keys, "NpubRow"}, {.Keys, "KpStatus"}, {.Keys, "RowRotate"}, {.Keys, "RowVaultPw"}, {.Keys, "RowReveal"}, {.Advanced, "RowTelemetry"}, {.Advanced, "RowAudit"}, {.Advanced, "RowDevMode"}, {.Appearance, "RowTheme"}}) {
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
			} else if target.section != .Home {
				testing.expect(
					t,
					clay.GetElementData(clay.ID("SettingsPageIcon", 0)).found &&
					!clay.GetElementData(clay.ID("SettingsSheet")).found,
					"A category without a deep link must open on its menu, not its sheet",
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
		for _ in 0 ..< 3 {settings_test_frame(&ui)}
		page := clay.GetElementData(clay.ID("SettingsPage"))
		b := page.boundingBox
		// Clay's f32 size distribution can accumulate subpixel boundary error.
		if !testing.expectf(
			t,
			page.found &&
			b.width > 0 &&
			b.height > 0 &&
			b.x >= 0 &&
			b.y >= 0 &&
			b.x + b.width <= viewport.width + 0.1 &&
			b.y + b.height <= viewport.height + 0.1,
			"The theme gallery viewport %v must fit %v",
			b,
			viewport,
		) {return}
		// Wheel input must reach the clipped final row, not just a correctly sized box.
		// The wheel arrives inside a frame, as in the app: a second scroll update
		// without a layout between drops containers and their offsets.
		clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
		last := -1
		for pack, i in theme_packs {
			if pack.tone == ui.theme_tone && i != system_theme_index {last = i}
		}
		if !testing.expect(t, last >= 0) {return}
		for _ in 0 ..< 128 {
			row := clay.GetElementData(clay.ID("ThemeOpt", u32(last))).boundingBox
			if row.y >= b.y && row.y + row.height <= b.y + b.height {break}
			settings_test_frame(&ui, {0, -8})
			for _ in 0 ..< 2 {settings_test_frame(&ui)}
		}
		target := clay.GetElementData(clay.ID("ThemeOpt", u32(last)))
		row := target.boundingBox
		testing.expect(
			t,
			target.found && row.y >= b.y && row.y + row.height <= b.y + b.height,
			"Scrolling must reveal the complete final theme tile",
		)
		clay.SetPointerState({row.x + row.width / 2, row.y + row.height / 2}, false)
		testing.expect(
			t,
			clay.PointerOver(clay.ID("ThemeOpt", u32(last))),
			"The final theme tile must remain clickable inside the page clip",
		)
		ui.account_ref = "viewport-remote"
		settings_open(&ui, nil, .Keys, anchor = "RowVaultPw")
		for _ in 0 ..< 3 {settings_test_frame(&ui)}
		testing.expect(
			t,
			clay.GetElementData(clay.ID("RowVaultPw")).found &&
			!clay.GetElementData(clay.ID("RowExport")).found &&
			!clay.GetElementData(clay.ID("RowReveal")).found,
			"A remote account keeps device vault controls but never offers its private key",
		)
		ui.account_ref = "viewport-local"
	}
	// A font preview must change real measurements, not just token names,
	// and cancellation must restore both Clay and paragraph-wrap geometry.
	ui.theme, ui.accent = 0, 0
	apply_theme(ui.theme, ui.accent)
	SAMPLE :: "Morning trains depart at seven"
	title_width :: proc() -> f32 {
		clay.BeginLayout()
		if clay.UI(clay.ID("ThemeFontGeometry"))({}) {
			clay.Text(SAMPLE, {fontId = FONT_TITLE, fontSize = 24, wrapMode = .None})
		}
		clay.EndLayout(0)
		return clay.GetElementData(clay.ID("ThemeFontGeometry")).boundingBox.width
	}
	body_default := rl.MeasureTextLine(FONT_BODY, 18, SAMPLE, 0).x
	body_manrope := rl.MeasureTextLine(theme_font_stack("Manrope", .Body), 18, SAMPLE, 0).x
	title_default := title_width()
	wrap_width := (body_default + body_manrope) / 2
	baseline_lines := len(wrapped_lines(SAMPLE, wrap_width, 18))
	for pack, i in theme_packs {
		if pack.font != "Manrope" {continue}
		apply_theme(i, ui.accent)
		ui.theme_preview, ui.theme_preview_active = i, true
		body_preview := rl.MeasureTextLine(FONT_BODY, 18, SAMPLE, 0).x
		title_preview := title_width()
		testing.expect(
			t,
			body_preview != body_default,
			"Preview must render Manrope rather than the default face",
		)
		testing.expect(
			t,
			title_preview != title_default,
			"Each display face must change rendered title geometry",
		)
		testing.expect(
			t,
			math.abs(title_preview - rl.MeasureTextLine(FONT_TITLE, 24, SAMPLE, 0).x) < 0.001,
			"Clay must measure the selected font rather than reuse the previous face",
		)
		testing.expect(
			t,
			len(wrapped_lines(SAMPLE, wrap_width, 18)) != baseline_lines,
			"A font switch must invalidate cached paragraph line breaks",
		)
		// Applying the same font selection should preserve the fresh wrap cache.
		cached_bytes := wrap_bytes
		apply_theme(i, ui.accent)
		testing.expect_value(t, wrap_bytes, cached_bytes)
		settings_theme_preview_reset(&ui)
		testing.expect_value(t, rl.MeasureTextLine(FONT_BODY, 18, SAMPLE, 0).x, body_default)
		testing.expect_value(t, title_width(), title_default)
		testing.expect_value(t, len(wrapped_lines(SAMPLE, wrap_width, 18)), baseline_lines)
	}
	// Sleepy Hollow's numeric patch must not steal its book lettering or
	// skip the declared Cormorant fallback when Fell lacks a character.
	hollow := theme_font_stack("Hollow Figures", .Title)
	fell := theme_font_stack("IM FELL English SC", .Title)
	cormorant := theme_font_stack("Cormorant Garamond", .Title)
	for sample in ([]struct {
			text: string,
			face: u16,
		}{{"The Hollow", fell}, {"1,820.00", cormorant}, {"ʻ′↑−", cormorant}}) {
		testing.expect(
			t,
			math.abs(
				rl.MeasureTextLine(hollow, 24, sample.text, 0).x -
				rl.MeasureTextLine(sample.face, 24, sample.text, 0).x,
			) <
			0.001,
			"Hollow titles must use Fell letters, Cormorant figures and source fallback glyphs",
		)
	}
	testing.expect(
		t,
		math.abs(
			rl.MeasureTextLine(hollow, 24, "The Hollow 1820", 0).x -
			rl.MeasureTextLine(fell, 24, "The Hollow ", 0).x -
			rl.MeasureTextLine(cormorant, 24, "1820", 0).x,
		) <
		0.001,
		"A single title must compose book lettering and lining figures without replacing either face",
	)
}

@(private)
settings_test_frame :: proc(ui: ^Ui_State, wheel: clay.Vector2 = {}) {
	anim_tick(1.0 / 60)
	clay.UpdateScrollContainers(false, wheel, 1.0 / 60)
	clay.BeginLayout()
	settings_pane(ui)
	clay.EndLayout(0)
	if settings_resolve_scroll(ui) {
		clay.BeginLayout()
		settings_pane(ui)
		clay.EndLayout(0)
	}
}
