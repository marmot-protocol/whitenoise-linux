package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
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
	append(&ui.compose, "PRIVATE_DRAFT")
	append(&ui.messages, Msg_Ui{body = "PRIVATE_MESSAGE"})
	defer {delete(ui.compose); delete(ui.messages)}
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	for size in ([]struct {
			w, h: i32,
			zoom: f32,
		}{{740, 500, 1}, {390, 360, 1}, {1440, 1000, 1.5}, {1568, 1001, 1}, {1568, 733, 1}, {2102, 1342, 1.5}, {2872, 1342, 1.5}, {2560, 1080, 1}, {3440, 1440, 1}, {2560, 1080, 2}, {1440, 1000, 2}, {2560, 480, 1}}) {
		rl.SetWindowSize(size.w, size.h)
		UI_ZOOM = size.zoom
		viewport := clay.Dimensions{f32(size.w) / UI_ZOOM, f32(size.h) / UI_ZOOM}
		clay.SetLayoutDimensions(viewport)
		for target in ([]struct {
				section: Settings_Section,
				anchor:  string,
			}{{.Home, ""}, {.Keys, ""}, {.General, "RowLang"}, {.Network, "AddRelayRow"}, {.Network, "AddFetchRow"}, {.Network, "ClientBox"}, {.Keys, "NpubRow"}, {.Keys, "KpStatus"}, {.Keys, "RowRotate"}, {.Keys, "RowVaultPw"}, {.Keys, "RowReveal"}, {.Advanced, "RowTelemetry"}, {.Advanced, "RowAudit"}, {.Advanced, "RowDevMode"}, {.Appearance, ""}}) {
			if target.section == .Appearance {ui.settings_tab = 2}
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
			} else if target.section == .Appearance {
				testing.expect_value(t, ui.settings_tab, 0)
				testing.expect(
					t,
					clay.GetElementData(clay.ID("SettingsSheet")).found &&
					!clay.GetElementData(clay.ID("SettingsPageIcon", 0)).found &&
					!clay.GetElementData(clay.ID("SettingsTabs")).found,
					"Opening Appearance must show its workbench directly, without a category menu or tabs",
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
		for anchor in SETTINGS_TEST_APPEARANCE_ANCHORS {
			settings_open(&ui, nil, .Appearance, anchor = anchor)
			for _ in 0 ..< 3 {settings_test_frame(&ui)}
			testing.expect_value(t, ui.settings_tab, 0)
			if anchor == "RowScroll" && tap_size() {
				testing.expect(
					t,
					!clay.GetElementData(clay.ID(anchor)).found,
					"Touch Appearance must omit mouse-wheel speed controls",
				)
				continue
			}
			scroll_id := clay.ID("SettingsPage")
			if settings_test_appearance_wide() {
				scroll_id = clay.ID(
					anchor == "RowTheme" ? "AppearanceThemes" : "AppearanceControls",
				)
			}
			clip := clay.GetElementData(scroll_id).boundingBox
			destination := clay.GetElementData(clay.ID(anchor)).boundingBox
			testing.expectf(
				t,
				destination.y >= clip.y - 0.1 && destination.y < clip.y + clip.height,
				"An Appearance deep link must reveal %s inside its own scroll viewport",
				anchor,
			)
			for other in SETTINGS_TEST_APPEARANCE_ANCHORS {
				if other == "RowScroll" && tap_size() {continue}
				testing.expectf(
					t,
					clay.GetElementData(clay.ID(other)).found,
					"Opening %s must leave %s in the same Appearance workbench",
					anchor,
					other,
				)
			}
		}
		settings_open(&ui, nil, .Appearance)
		for _ in 0 ..< 3 {settings_test_frame(&ui)}
		settings_test_appearance_panels(t)
		commands := settings_test_frame(&ui)
		for command in commands.internalArray[:commands.length] {
			if command.commandType != .Text {continue}
			text := command.renderData.text.stringContents
			shown := string(text.chars[:text.length])
			testing.expect(
				t,
				shown != "PRIVATE_DRAFT" && shown != "PRIVATE_MESSAGE",
				"Appearance must never render your live draft or message history",
			)
		}
		testing.expect_value(t, string(ui.compose[:]), "PRIVATE_DRAFT")
		testing.expect_value(t, ui.messages[0].body, "PRIVATE_MESSAGE")
		rl.BeginDrawing()
		rl.DrawRectangleRec(0, 0, f32(size.w), f32(size.h), clay_color(BG))
		rl.BeginMode2D({zoom = UI_ZOOM})
		clay_raylib_render(&commands)
		rl.EndMode2D()
		rl.TakeScreenshot(
			fmt.ctprintf("/tmp/wn-appearance-%dx%d-%v.png", size.w, size.h, size.zoom),
		)
		rl.EndDrawing()
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
			"The Appearance workbench viewport %v must fit %v",
			b,
			viewport,
		) {return}
		// Wheel input must reach the clipped final row, not just a correctly sized box.
		// The wheel arrives inside a frame, as in the app: a second scroll update
		// without a layout between drops containers and their offsets.
		b = clay.GetElementData(settings_test_gallery_scroll_id()).boundingBox
		clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
		last := -1
		bottom: f32 = -1
		for pack, i in theme_packs {
			if pack.tone != ui.theme_tone || i == system_theme_index {continue}
			tile := clay.GetElementData(clay.ID("ThemeOpt", u32(i)))
			if tile.found && tile.boundingBox.y + tile.boundingBox.height > bottom {
				last, bottom = i, tile.boundingBox.y + tile.boundingBox.height
			}
		}
		if !testing.expect(t, last >= 0) {return}
		if settings_test_appearance_wide() {
			settings_test_scroll_panel(t, &ui, "AppearanceThemes", clay.ID("ThemeOpt", u32(last)))
			settings_test_scroll_panel(t, &ui, "AppearanceControls", clay.ID("RowCropShape"))
			settings_test_scroll_panel(t, &ui, "AppearancePreview", clay.ID("Composer"))
			clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
		}
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
			"The final theme tile must remain clickable inside its scroll viewport",
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
		when TRANSLATION_AVAILABLE {
			ui.prefs.translation_enabled = true
			settings_open(&ui, nil, .General, anchor = "RowTranslationTarget")
			settings_translation_action(&ui, "TranslationTarget")
			for _ in 0 ..< 3 {settings_test_frame(&ui)}
			dropdown_page := clay.GetElementData(clay.ID("SettingsPage")).boundingBox
			list := clay.GetElementData(clay.ID("TranslationLanguageList"))
			testing.expectf(
				t,
				list.found &&
				list.boundingBox.y >= dropdown_page.y &&
				list.boundingBox.y + list.boundingBox.height <=
					dropdown_page.y + dropdown_page.height + 1,
				"The open translation language list must fit its viewport: page=%v list=%v",
				dropdown_page,
				list.boundingBox,
			)
			settings_translation_close(&ui, 2)
			for _ in 0 ..< 3 {settings_test_frame(&ui)}
			field := clay.GetElementData(clay.ID("TranslationTarget")).boundingBox
			testing.expect(
				t,
				field.y >= dropdown_page.y &&
				field.y + field.height <= dropdown_page.y + dropdown_page.height,
				"Closing the language list must keep the selected language visible",
			)
		}
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
SETTINGS_TEST_APPEARANCE_ANCHORS := []string {
	"RowTheme",
	"RowAccent",
	"RowThemeShare",
	"RowZoom",
	"RowBodyFont",
	"RowEmojiSet",
	"RowScroll",
	"RowMotion",
	"RowCentered",
	"RowMessageLines",
	"RowAvatarShape",
	"RowCropShape",
}

@(private)
settings_test_appearance_panels :: proc(t: ^testing.T) {
	page := clay.GetElementData(clay.ID("SettingsPage")).boundingBox
	for id in ([]string{"AppearanceControls", "AppearanceThemes", "AppearancePreview"}) {
		panel := clay.GetElementData(clay.ID(id))
		box := panel.boundingBox
		testing.expectf(
			t,
			panel.found &&
			box.width > 0 &&
			box.height > 0 &&
			box.x >= page.x - 0.1 &&
			box.x + box.width <= page.x + page.width + 0.1,
			"The %s panel must fit the Appearance viewport horizontally",
			id,
		)
		if settings_test_appearance_wide() {
			testing.expectf(
				t,
				box.y >= page.y - 0.1 &&
				box.y + box.height <= page.y + page.height + 0.1 &&
				clay.GetScrollContainerData(clay.ID(id)).found,
				"Wide %s %v must be a vertically bounded independent scroll viewport inside %v",
				id,
				box,
				page,
			)
		}
	}
	controls := clay.GetElementData(clay.ID("AppearanceControls")).boundingBox
	themes := clay.GetElementData(clay.ID("AppearanceThemes")).boundingBox
	preview := clay.GetElementData(clay.ID("AppearancePreview")).boundingBox
	if themes.x + themes.width <= preview.x + 0.1 {
		testing.expect(
			t,
			controls.x + controls.width <= themes.x + 0.1 &&
			themes.x + themes.width <= preview.x + 0.1 &&
			math.abs(controls.y - themes.y) <= 0.1 &&
			math.abs(themes.y - preview.y) <= 0.1,
			"Wide Appearance must place controls, themes and live preview side by side",
		)
	} else if settings_test_appearance_wide() {
		testing.expect(
			t,
			controls.x + controls.width <= themes.x + 0.1 &&
			themes.y + themes.height <= preview.y + 0.1 &&
			math.abs(themes.x - preview.x) <= 0.1 &&
			math.abs(controls.y - themes.y) <= 0.1,
			"Intermediate Appearance must split controls from independently scrolling themes and preview",
		)
	} else {
		testing.expect(
			t,
			controls.y + controls.height <= preview.y + 0.1 &&
			preview.y + preview.height <= themes.y + 0.1 &&
			math.abs(controls.x - preview.x) <= 0.1 &&
			math.abs(preview.x - themes.x) <= 0.1,
			"Narrow Appearance must stack controls, live preview and themes without overlap",
		)
	}
}

@(private)
settings_test_appearance_wide :: proc() -> bool {
	return clay.GetScrollContainerData(clay.ID("AppearanceControls")).found
}

@(private)
settings_test_gallery_scroll_id :: proc() -> clay.ElementId {
	return clay.ID(settings_test_appearance_wide() ? "AppearanceThemes" : "SettingsPage")
}

@(private)
settings_test_scroll_panel :: proc(
	t: ^testing.T,
	ui: ^Ui_State,
	panel_id: string,
	destination: clay.ElementId,
) {
	ids := [4]string{"AppearanceControls", "AppearanceThemes", "AppearancePreview", "SettingsPage"}
	offsets: [4]clay.Vector2
	boxes: [4]clay.BoundingBox
	tracked: [4]bool
	for id, i in ids {
		data := clay.GetScrollContainerData(clay.ID(id))
		tracked[i] = data.found
		if data.found {offsets[i] = data.scrollPosition^}
		boxes[i] = clay.GetElementData(clay.ID(id)).boundingBox
	}
	panel := clay.GetElementData(clay.ID(panel_id)).boundingBox
	data := clay.GetScrollContainerData(clay.ID(panel_id))
	if !testing.expect(
		t,
		data.found,
		"Every wide Appearance panel must scroll independently",
	) {return}
	clay.SetPointerState({panel.x + panel.width / 2, panel.y + panel.height / 2}, false)
	for _ in 0 ..< 128 {
		box := clay.GetElementData(destination).boundingBox
		if box.y >= panel.y && box.y + box.height <= panel.y + panel.height {break}
		wanted := clamp(box.y, panel.y, panel.y + panel.height - box.height)
		settings_test_frame(ui, {0, (wanted - box.y) / CLAY_SCROLL_PIXELS})
		for _ in 0 ..< 2 {settings_test_frame(ui)}
	}
	target := clay.GetElementData(destination)
	box := target.boundingBox
	testing.expectf(
		t,
		target.found && box.y >= panel.y && box.y + box.height <= panel.y + panel.height,
		"Scrolling %s must reveal final content %v within %v (window %dx%d)",
		panel_id,
		box,
		panel,
		rl.GetScreenWidth(),
		rl.GetScreenHeight(),
	)
	for id, i in ids {
		if id == panel_id {continue}
		if tracked[i] {
			other := clay.GetScrollContainerData(clay.ID(id))
			testing.expectf(
				t,
				other.found && other.scrollPosition^ == offsets[i],
				"Scrolling %s must preserve %s's scroll offset",
				panel_id,
				id,
			)
		}
		testing.expectf(
			t,
			clay.GetElementData(clay.ID(id)).boundingBox == boxes[i],
			"Scrolling %s must not move %s",
			panel_id,
			id,
		)
	}
}

@(private)
settings_test_frame :: proc(
	ui: ^Ui_State,
	wheel: clay.Vector2 = {},
) -> clay.ClayArray(clay.RenderCommand) {
	anim_tick(1.0 / 60)
	clay.UpdateScrollContainers(false, wheel, 1.0 / 60)
	clay.BeginLayout()
	settings_pane(ui)
	if open_now(clay.ID("ExportModal"), ui.export_open) {export_modal(ui)}
	commands := clay.EndLayout(0)
	if settings_resolve_scroll(ui) {
		clay.BeginLayout()
		settings_pane(ui)
		if open_now(clay.ID("ExportModal"), ui.export_open) {export_modal(ui)}
		commands = clay.EndLayout(0)
	}
	return commands
}
