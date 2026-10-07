package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import rl "sdlrl"

// Run separately with SDL_VIDEODRIVER=dummy and
// -define:ODIN_TEST_NAMES=theme_gallery_interactions, like settings_viewport.
@(test)
theme_gallery_interactions :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "theme_gallery_interactions" {return}
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-theme-gallery", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	previous_config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", home)
	defer {
		if previous_config == "" {os.unset_env("XDG_CONFIG_HOME")} else {
			os.set_env("XDG_CONFIG_HOME", previous_config)
		}
	}
	rl.InitWindow(740, 500, "Theme gallery interactions")
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
	defer settings_stop(&ui)
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	custom_emoji_scanned = true
	defer {custom_emoji_scanned = false; forced_release = false; kb_focus = ""
		delete(ui.link_url)}
	native, sidecar, light := -1, -1, -1
	for pack, i in theme_packs {
		if i == system_theme_index || pack.custom {continue}
		if pack.tone == .Light && light < 0 {light = i}
		if pack.tone != .Dark {continue}
		if pack.collection == .White_Noise && native < 0 {native = i}
		if pack.collection == .Sidecar && sidecar < 0 {sidecar = i}
	}
	if !testing.expect(t, native >= 0 && sidecar >= 0 && light >= 0) {return}
	// Inheriting a source palette must not turn a custom theme into a source credit.
	custom := theme_packs[sidecar]
	custom.name, custom.custom = "Gallery custom", true
	custom_index := len(theme_packs)
	append(&theme_packs, custom)
	defer resize(&theme_packs, custom_index)
	ui.theme = native
	apply_theme(ui.theme, ui.accent)
	settings_open(&ui, nil, .Appearance, anchor = "RowTheme")
	gallery_frames(&ui)
	testing.expect(t, !clay.GetElementData(clay.ID("ThemeSourceNotice")).found)
	gallery_filter_check(t, &ui)
	native_box := clay.GetElementData(clay.ID("ThemeOpt", u32(native))).boundingBox
	sidecar_box := clay.GetElementData(clay.ID("ThemeOpt", u32(sidecar))).boundingBox
	custom_box := clay.GetElementData(clay.ID("ThemeOpt", u32(custom_index))).boundingBox
	testing.expect(
		t,
		native_box.y < sidecar_box.y && sidecar_box.y < custom_box.y,
		"Source groups must preserve the real indices and put custom themes last",
	)
	if system_theme_index >= 0 && theme_packs[system_theme_index].tone == ui.theme_tone {
		box := clay.GetElementData(clay.ID("ThemeOpt", u32(system_theme_index))).boundingBox
		testing.expect(t, box.y < native_box.y, "System must precede the source collections")
	}
	gallery_point(&ui, clay.ID("ThemeOpt", u32(sidecar)))
	before := clay.GetElementData(clay.ID("ThemeOpt", u32(sidecar))).boundingBox
	ui.theme_candidate, ui.theme_candidate_since = sidecar, rl.GetTime() - 1
	handle_settings(&ui, nil)
	gallery_frames(&ui)
	testing.expect(t, ui.theme_preview_active && ui.theme_preview == sidecar && ui.theme == native)
	testing.expect(
		t,
		!clay.GetElementData(clay.ID("ThemeSourceNotice")).found &&
		!clay.GetElementData(clay.ID("ThemeTileNotice", u32(sidecar))).found,
		"Hovering a source theme must not credit an uncommitted selection",
	)
	after := clay.GetElementData(clay.ID("ThemeOpt", u32(sidecar))).boundingBox
	testing.expect(t, after == before, "A palette/font preview must not move its pointer target")
	header := clay.ID("ThemeCollection", u32(Theme_Collection.Sidecar))
	gallery_point(&ui, header)
	handle_settings(&ui, nil)
	testing.expect(
		t,
		!ui.theme_preview_active && ui.theme_candidate == -1 && ui.theme == native,
		"Crossing from a tile to its heading must restore the committed theme",
	)
	forced_release = true
	handle_settings(&ui, nil)
	forced_release = false
	testing.expect(
		t,
		!ui.link_open && ui.theme == native,
		"Collection headings must remain passive on activation",
	)
	gallery_hover(&ui, sidecar)
	clay.SetPointerState({-10, -10}, false)
	handle_settings(&ui, nil)
	testing.expect(
		t,
		!ui.theme_preview_active && ui.theme == native,
		"Leaving the gallery must cancel hover preview",
	)
	gallery_hover(&ui, sidecar)
	rl.PushKey(.ESCAPE, true)
	handle_settings(&ui, nil)
	rl.PushKey(.ESCAPE, false)
	testing.expect(
		t,
		!ui.theme_preview_active && ui.theme == native,
		"Escape must restore the committed palette without selecting a tile",
	)
	settings_open(&ui, nil, .Appearance, anchor = "RowTheme")
	gallery_frames(&ui)
	gallery_hover(&ui, sidecar)
	gallery_click(&ui, clay.ID("ThemeToneLight"))
	testing.expect(
		t,
		ui.theme_tone == .Light && ui.theme == native && !ui.theme_preview_active,
		"Tone filters browse without committing and restore the current palette",
	)
	testing.expect(
		t,
		clay.PointerOver(clay.ID("ThemeToneLight")),
		"Switching tone must keep the clicked filter under the pointer",
	)
	gallery_filter_check(t, &ui)
	gallery_click(&ui, clay.ID("ThemeToneDark"))
	gallery_filter_check(t, &ui)
	gallery_hover(&ui, sidecar)
	settings_open(&ui, nil, .General, anchor = "RowLang")
	settings_theme_preview_guard(&ui)
	testing.expect(
		t,
		!ui.theme_preview_active && ui.theme == native,
		"Navigation must not retain a hover palette",
	)
	settings_open(&ui, nil, .Appearance, anchor = "RowTheme")
	gallery_frames(&ui)
	gallery_hover(&ui, sidecar)
	ui.add_account_open = true
	settings_theme_preview_guard(&ui)
	testing.expect(
		t,
		!ui.theme_preview_active && ui.theme == native,
		"Opening a modal must restore the committed palette",
	)
	ui.add_account_open = false
	gallery_click(&ui, clay.ID("ThemeOpt", u32(sidecar)))
	testing.expect_value(t, ui.theme, sidecar)
	testing.expect(t, !ui.theme_preview_active)
	testing.expect(
		t,
		clay.GetElementData(clay.ID("ThemeOptCheck", u32(sidecar))).found,
		"The committed tile must show its selected marker",
	)
	testing.expect(
		t,
		clay.GetElementData(clay.ID("ThemeSourceNotice")).found &&
		clay.GetElementData(clay.ID("ThemeTileNotice", u32(sidecar))).found,
		"A selected Sidecar tile must show credit without scrolling back to the page header",
	)
	settings_stop(&ui)
	data, read_err := os.read_entire_file(settings_path(), context.temp_allocator)
	if !testing.expect(t, read_err == nil) {return}
	saved: Settings
	if !testing.expect(
		t,
		json.unmarshal(data, &saved, allocator = context.temp_allocator) == nil,
	) {return}
	testing.expect(t, saved.theme == sidecar, "Tile selection must persist the real index")
	gallery_hover(&ui, native)
	testing.expect(
		t,
		clay.GetElementData(clay.ID("ThemeSourceNotice")).found,
		"A native hover must not hide the committed source credit",
	)
	gallery_click(&ui, clay.ID("ThemeOpt", u32(custom_index)))
	testing.expect_value(t, ui.theme, custom_index)
	testing.expect(t, !clay.GetElementData(clay.ID("ThemeSourceNotice")).found)
	gallery_click(&ui, clay.ID("ThemeOpt", u32(native)))
	testing.expect(t, !clay.GetElementData(clay.ID("ThemeSourceNotice")).found)
	if system_theme_index >= 0 {
		ui.theme_tone = theme_packs[system_theme_index].tone
		gallery_frames(&ui)
		gallery_click(&ui, clay.ID("ThemeOpt", u32(system_theme_index)))
		testing.expect_value(t, ui.theme, system_theme_index)
		testing.expect(t, !clay.GetElementData(clay.ID("ThemeSourceNotice")).found)
	}
	gallery_click(&ui, clay.ID("ThemeToneLight"))
	gallery_click(&ui, clay.ID("ThemeOpt", u32(light)))
	settings_open(&ui, nil, .General, anchor = "RowLang")
	settings_open(&ui, nil, .Appearance, anchor = "RowTheme")
	gallery_frames(&ui)
	testing.expect(
		t,
		clay.GetElementData(clay.ID("ThemeOpt", u32(light))).found &&
		!clay.GetElementData(clay.ID("ThemeOpt", u32(native))).found,
		"Reopening the gallery must browse the committed theme's tone",
	)
	settings_open(&ui, nil, .Appearance, anchor = "RowTheme")
	ui.theme_tone = custom.tone
	gallery_frames(&ui)
	clay.SetPointerState({-10, -10}, false)
	kb_focus = ""
	last_focus := fmt.tprintf("ThemeOpt%d", custom_index)
	for _ in 0 ..< len(theme_packs) + 20 {
		rl.PushKey(.TAB, true)
		handle_settings(&ui, nil)
		rl.PushKey(.TAB, false)
		gallery_frames(&ui)
		if kb_focus == last_focus {break}
	}
	testing.expect(t, kb_focus == last_focus, "Tab must reach the final custom tile")
	focused := clay.GetElementData(clay.ID("ThemeOpt", u32(custom_index))).boundingBox
	focus_page := clay.GetElementData(clay.ID("SettingsPage")).boundingBox
	testing.expect(
		t,
		focused.y >= focus_page.y &&
		focused.y + focused.height <= focus_page.y + focus_page.height,
		"Keyboard traversal must reveal the focused tile inside the page",
	)
	rl.PushKey(.ENTER, true)
	handle_settings(&ui, nil)
	rl.PushKey(.ENTER, false)
	gallery_frames(&ui)
	testing.expect(t, ui.theme == custom_index, "Enter must commit the keyboard-focused tile")
	kb_focus = ""
	for size in ([]struct {
			w, h: i32,
			zoom: f32,
		}{{390, 360, 1}, {740, 500, 1}, {1440, 1000, 1.5}}) {
		rl.SetWindowSize(size.w, size.h)
		UI_ZOOM = size.zoom
		viewport := clay.Dimensions{f32(size.w) / UI_ZOOM, f32(size.h) / UI_ZOOM}
		clay.SetLayoutDimensions(viewport)
		settings_open(&ui, nil, .Appearance, anchor = "RowTheme")
		ui.theme_tone = custom.tone
		gallery_frames(&ui)
		page := clay.GetElementData(clay.ID("SettingsPage")).boundingBox
		for pack, i in theme_packs {
			if pack.tone != ui.theme_tone {continue}
			box := clay.GetElementData(clay.ID("ThemeOpt", u32(i))).boundingBox
			testing.expect(
				t,
				box.width > 0 && box.x >= page.x && box.x + box.width <= page.x + page.width,
				"Responsive gallery rows must keep every tile inside the available sheet width",
			)
		}
		clay.SetPointerState({page.x + page.width / 2, page.y + page.height / 2}, false)
		for _ in 0 ..< 128 {
			box := clay.GetElementData(clay.ID("ThemeOpt", u32(custom_index))).boundingBox
			if box.y >= page.y && box.y + box.height <= page.y + page.height {break}
			settings_test_frame(&ui, {0, -8})
			gallery_frames(&ui)
		}
		tile := clay.GetElementData(clay.ID("ThemeOpt", u32(custom_index)))
		box := tile.boundingBox
		testing.expect(
			t,
			tile.found &&
			box.x >= page.x &&
			box.x + box.width <= page.x + page.width &&
			box.y >= page.y &&
			box.y + box.height <= page.y + page.height,
			"Wheel scrolling must expose the complete final tile at narrow, short and zoomed sizes",
		)
		clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
		testing.expect(
			t,
			clay.PointerOver(clay.ID("ThemeOpt", u32(custom_index))),
			"The final tile must remain reachable through the page clip",
		)
	}
}

@(private)
gallery_frames :: proc(ui: ^Ui_State) {
	for _ in 0 ..< 3 {settings_test_frame(ui)}
}

@(private)
gallery_point :: proc(ui: ^Ui_State, id: clay.ElementId) {
	scroll_into_view(clay.ID("SettingsPage"), id)
	gallery_frames(ui)
	box := clay.GetElementData(id).boundingBox
	clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
}

@(private)
gallery_click :: proc(ui: ^Ui_State, id: clay.ElementId) {
	gallery_point(ui, id)
	forced_release = true
	handle_settings(ui, nil)
	forced_release = false
	gallery_frames(ui)
}

@(private)
gallery_hover :: proc(ui: ^Ui_State, index: int) {
	gallery_point(ui, clay.ID("ThemeOpt", u32(index)))
	ui.theme_candidate, ui.theme_candidate_since = index, rl.GetTime() - 1
	handle_settings(ui, nil)
	gallery_frames(ui)
}

@(private)
gallery_filter_check :: proc(t: ^testing.T, ui: ^Ui_State) {
	for pack, i in theme_packs {
		tile := clay.GetElementData(clay.ID("ThemeOpt", u32(i)))
		testing.expect(
			t,
			tile.found == (pack.tone == ui.theme_tone),
			"The gallery must expose exactly the tiles in its active tone filter",
		)
	}
}
