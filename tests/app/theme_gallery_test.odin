package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "nendo"
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
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {740, 500})
	defer {nendo.set_context(previous); delete(memory)}
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
	for locale in ([]string{"en", "de", "it", "ja"}) {
		set_locale(locale)
		for pack in theme_packs {
			name := pack.custom ? pack.name : tr(pack.name)
			query := strings.to_lower(name, context.temp_allocator)
			matches := 0
			for task in SETTINGS_TASKS {
				if task.anchor == "RowTheme" {
					testing.expectf(
						t,
						settings_task_matches(&ui, task, query),
						"The theme picker must match its displayed name %s in %s",
						name,
						locale,
					)
				}
				if settings_task_matches(&ui, task, "gallery custom") {
					matches += 1
					testing.expect_value(t, task.anchor, "RowTheme")
				}
			}
			testing.expect_value(t, matches, 1)
		}
	}
	set_locale("ja")
	for task in SETTINGS_TASKS {
		if task.anchor != "RowTheme" {continue}
		testing.expect(t, settings_task_matches(&ui, task, "jazz"))
		testing.expect(t, settings_task_matches(&ui, task, "theme gallery custom"))
		testing.expect(t, !settings_task_matches(&ui, task, "absent-theme-name"))
	}
	testing.expect_value(t, ui.theme, native)
	testing.expect(t, !ui.theme_preview_active, "Matching must not select or preview a theme")
	apply_theme(ui.theme, ui.accent)
	settings_open(&ui, nil, .Appearance, anchor = "RowTheme")
	gallery_frames(&ui)
	testing.expect(t, !nendo.element(nendo.id("ThemeSourceNotice")).found)
	gallery_filter_check(t, &ui)
	native_box := nendo.element(nendo.id("ThemeOpt", u32(native))).rect
	sidecar_box := nendo.element(nendo.id("ThemeOpt", u32(sidecar))).rect
	custom_box := nendo.element(nendo.id("ThemeOpt", u32(custom_index))).rect
	testing.expect(
		t,
		native_box.y < sidecar_box.y && sidecar_box.y < custom_box.y,
		"Source groups must preserve the real indices and put custom themes last",
	)
	if system_theme_index >= 0 && theme_packs[system_theme_index].tone == ui.theme_tone {
		box := nendo.element(nendo.id("ThemeOpt", u32(system_theme_index))).rect
		testing.expect(t, box.y < native_box.y, "System must precede the source collections")
	}
	gallery_point(&ui, nendo.id("ThemeOpt", u32(sidecar)))
	before := nendo.element(nendo.id("ThemeOpt", u32(sidecar))).rect
	ui.theme_candidate, ui.theme_candidate_since = sidecar, rl.GetTime() - 1
	handle_settings(&ui, nil)
	gallery_frames(&ui)
	testing.expect(t, ui.theme_preview_active && ui.theme_preview == sidecar && ui.theme == native)
	testing.expect(
		t,
		!nendo.element(nendo.id("ThemeSourceNotice")).found &&
		!nendo.element(nendo.id("ThemeTileNotice", u32(sidecar))).found,
		"Hovering a source theme must not credit an uncommitted selection",
	)
	after := nendo.element(nendo.id("ThemeOpt", u32(sidecar))).rect
	testing.expect(t, after == before, "A palette/font preview must not move its pointer target")
	header := nendo.id("ThemeCollection", u32(Theme_Collection.Sidecar))
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
	nendo.set_pointer({-10, -10}, .Up)
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
	gallery_click(&ui, nendo.id("ThemeToneLight"))
	testing.expect(
		t,
		ui.theme_tone == .Light && ui.theme == native && !ui.theme_preview_active,
		"Tone filters browse without committing and restore the current palette",
	)
	testing.expect(
		t,
		nendo.pointer_over(nendo.id("ThemeToneLight")),
		"Switching tone must keep the clicked filter under the pointer",
	)
	gallery_filter_check(t, &ui)
	gallery_click(&ui, nendo.id("ThemeToneDark"))
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
	gallery_click(&ui, nendo.id("ThemeOpt", u32(sidecar)))
	testing.expect_value(t, ui.theme, sidecar)
	testing.expect(t, !ui.theme_preview_active)
	testing.expect(
		t,
		nendo.element(nendo.id("ThemeOptCheck", u32(sidecar))).found,
		"The committed tile must show its selected marker",
	)
	testing.expect(
		t,
		nendo.element(nendo.id("ThemeSourceNotice")).found &&
		nendo.element(nendo.id("ThemeTileNotice", u32(sidecar))).found,
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
		nendo.element(nendo.id("ThemeSourceNotice")).found,
		"A native hover must not hide the committed source credit",
	)
	gallery_click(&ui, nendo.id("ThemeOpt", u32(custom_index)))
	testing.expect_value(t, ui.theme, custom_index)
	testing.expect(t, !nendo.element(nendo.id("ThemeSourceNotice")).found)
	gallery_click(&ui, nendo.id("ThemeOpt", u32(native)))
	testing.expect(t, !nendo.element(nendo.id("ThemeSourceNotice")).found)
	if system_theme_index >= 0 {
		ui.theme_tone = theme_packs[system_theme_index].tone
		gallery_frames(&ui)
		gallery_click(&ui, nendo.id("ThemeOpt", u32(system_theme_index)))
		testing.expect_value(t, ui.theme, system_theme_index)
		testing.expect(t, !nendo.element(nendo.id("ThemeSourceNotice")).found)
	}
	gallery_click(&ui, nendo.id("ThemeToneLight"))
	gallery_click(&ui, nendo.id("ThemeOpt", u32(light)))
	settings_open(&ui, nil, .General, anchor = "RowLang")
	settings_open(&ui, nil, .Appearance, anchor = "RowTheme")
	gallery_frames(&ui)
	testing.expect(
		t,
		nendo.element(nendo.id("ThemeOpt", u32(light))).found &&
		!nendo.element(nendo.id("ThemeOpt", u32(native))).found,
		"Reopening the gallery must browse the committed theme's tone",
	)
	settings_open(&ui, nil, .Appearance, anchor = "RowTheme")
	ui.theme_tone = custom.tone
	gallery_frames(&ui)
	nendo.set_pointer({-10, -10}, .Up)
	kb_focus = ""
	last_focus := fmt.tprintf("ThemeOpt%d", custom_index)
	control_focus := []string {
		"ZoomPlus",
		"BodyFontChip0",
		"EmojiSetChip0",
		"ScrollChip0",
		"TgMotion",
		"TgCentered",
		"MessageLinesPlus",
		"AvatarShapeChip0",
		"CropShapeChip0",
		"ThemeShareBtn",
		"ThemeToneDark",
		"ThemeToneLight",
	}
	visited := make([]bool, len(control_focus), context.temp_allocator)
	for _ in 0 ..< 256 {
		rl.PushKey(.TAB, true)
		handle_settings(&ui, nil)
		rl.PushKey(.TAB, false)
		gallery_frames(&ui)
		for key, i in control_focus {
			if kb_focus == key {visited[i] = true}
		}
		all_controls := true
		for seen in visited {all_controls = all_controls && seen}
		if kb_focus == last_focus && all_controls {break}
	}
	for key, i in control_focus {
		testing.expectf(
			t,
			visited[i],
			"Tab must reach %s in the same Appearance workbench as the gallery",
			key,
		)
	}
	testing.expect(t, kb_focus == last_focus, "Tab must reach the final custom tile")
	focused := nendo.element(nendo.id("ThemeOpt", u32(custom_index))).rect
	focus_page := nendo.element(settings_test_gallery_scroll_id()).rect
	testing.expectf(
		t,
		focused.y >= focus_page.y - 0.1 &&
		focused.y + focused.height <= focus_page.y + focus_page.height + 0.1,
		"Keyboard traversal must reveal the focused tile %v inside its gallery scroll viewport %v",
		focused,
		focus_page,
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
		}{{390, 360, 1}, {740, 500, 1}, {1440, 1000, 1.5}, {2560, 1080, 1}, {3440, 1440, 1}, {2560, 1080, 2}, {1440, 1000, 2}, {2560, 480, 1}}) {
		rl.SetWindowSize(size.w, size.h)
		UI_ZOOM = size.zoom
		viewport := nendo.Dimensions{f32(size.w) / UI_ZOOM, f32(size.h) / UI_ZOOM}
		nendo.set_dimensions(viewport)
		ui.theme = native
		apply_theme(ui.theme, ui.accent)
		settings_open(&ui, nil, .Appearance)
		ui.theme_tone = custom.tone
		gallery_frames(&ui)
		settings_test_appearance_panels(t)
		page := nendo.element(settings_test_gallery_scroll_id()).rect
		for pack, i in theme_packs {
			if pack.tone != ui.theme_tone {continue}
			box := nendo.element(nendo.id("ThemeOpt", u32(i))).rect
			testing.expect(
				t,
				box.width > 0 &&
				box.x >= page.x - 0.1 &&
				box.x + box.width <= page.x + page.width + 0.1,
				"Responsive gallery rows must keep every tile inside the available sheet width",
			)
		}
		nendo.set_pointer({page.x + page.width / 2, page.y + page.height / 2}, .Up)
		for _ in 0 ..< 128 {
			box := nendo.element(nendo.id("ThemeOpt", u32(custom_index))).rect
			if box.y >= page.y && box.y + box.height <= page.y + page.height {break}
			settings_test_frame(&ui, {0, -8})
			gallery_frames(&ui)
		}
		tile := nendo.element(nendo.id("ThemeOpt", u32(custom_index)))
		box := tile.rect
		testing.expect(
			t,
			tile.found &&
			box.x >= page.x - 0.1 &&
			box.x + box.width <= page.x + page.width + 0.1 &&
			box.y >= page.y &&
			box.y + box.height <= page.y + page.height,
			"Wheel scrolling must expose the complete final tile at narrow, short and zoomed sizes",
		)
		nendo.set_pointer({box.x + box.width / 2, box.y + box.height / 2}, .Up)
		testing.expect(
			t,
			nendo.pointer_over(nendo.id("ThemeOpt", u32(custom_index))),
			"The final tile must remain reachable through its gallery viewport clip",
		)
		forced_release = true
		handle_settings(&ui, nil)
		forced_release = false
		gallery_frames(&ui)
		testing.expect(
			t,
			ui.theme == custom_index &&
			!ui.theme_preview_active &&
			nendo.element(nendo.id("ThemeOptCheck", u32(custom_index))).found,
			"Clicking the wheel-revealed final tile must commit it at every viewport size",
		)
		if settings_test_appearance_wide() {
			ui.theme = native
			apply_theme(ui.theme, ui.accent)
			settings_open(&ui, nil, .Appearance)
			ui.theme_tone = custom.tone
			gallery_frames(&ui)
			nendo.set_pointer({-10, -10}, .Up)
			kb_focus = ""
			for _ in 0 ..< 256 {
				rl.PushKey(.TAB, true)
				handle_settings(&ui, nil)
				rl.PushKey(.TAB, false)
				gallery_frames(&ui)
				if kb_focus == last_focus {break}
			}
			focused_tile := nendo.element(nendo.id("ThemeOpt", u32(custom_index))).rect
			gallery_clip := nendo.element(settings_test_gallery_scroll_id()).rect
			testing.expect(
				t,
				kb_focus == last_focus &&
				focused_tile.y >= gallery_clip.y &&
				focused_tile.y + focused_tile.height <= gallery_clip.y + gallery_clip.height,
				"Wide keyboard traversal must reveal the final tile inside the independently scrolling gallery",
			)
			rl.PushKey(.ENTER, true)
			handle_settings(&ui, nil)
			rl.PushKey(.ENTER, false)
			gallery_frames(&ui)
			testing.expect(
				t,
				ui.theme == custom_index,
				"Enter must commit the final tile in the wide workbench",
			)
			kb_focus = ""
		}
	}
}

@(private)
gallery_frames :: proc(ui: ^Ui_State) {
	for _ in 0 ..< 3 {settings_test_frame(ui)}
}

@(private)
gallery_point :: proc(ui: ^Ui_State, id: nendo.Id) {
	scroll_into_view(settings_test_gallery_scroll_id(), id)
	gallery_frames(ui)
	box := nendo.element(id).rect
	nendo.set_pointer({box.x + box.width / 2, box.y + box.height / 2}, .Up)
}

@(private)
gallery_click :: proc(ui: ^Ui_State, id: nendo.Id) {
	gallery_point(ui, id)
	forced_release = true
	handle_settings(ui, nil)
	forced_release = false
	gallery_frames(ui)
}

@(private)
gallery_hover :: proc(ui: ^Ui_State, index: int) {
	gallery_point(ui, nendo.id("ThemeOpt", u32(index)))
	ui.theme_candidate, ui.theme_candidate_since = index, rl.GetTime() - 1
	handle_settings(ui, nil)
	gallery_frames(ui)
}

@(private)
gallery_filter_check :: proc(t: ^testing.T, ui: ^Ui_State) {
	for pack, i in theme_packs {
		tile := nendo.element(nendo.id("ThemeOpt", u32(i)))
		testing.expect(
			t,
			tile.found == (pack.tone == ui.theme_tone),
			"The gallery must expose exactly the tiles in its active tone filter",
		)
	}
}
