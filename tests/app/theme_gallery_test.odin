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
	if !test_isolated("theme_gallery_interactions") {return}
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
	append(&ui.compose, "PRIVATE_DRAFT")
	append(&ui.messages, Msg_Ui{body = "PRIVATE_MESSAGE"})
	defer {delete(ui.compose); delete(ui.messages)}
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
	for locale in ([]string{"en", "de", "it", "ja", "ko"}) {
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
	gallery_open_from_appearance(t, &ui)
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
	if system_theme_index >= 0 {
		box := nendo.element(nendo.id("ThemeOpt", u32(system_theme_index))).rect
		testing.expect(t, box.y < native_box.y, "System must precede the source collections")
	}
	gallery_check_preview(t, &ui, custom_box)
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
	gallery_open_from_appearance(t, &ui)
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
	settings_open(&ui, nil, .Language, anchor = "RowLang")
	settings_theme_preview_guard(&ui)
	testing.expect(
		t,
		!ui.theme_preview_active && ui.theme == native,
		"Navigation must not retain a hover palette",
	)
	gallery_open_from_appearance(t, &ui)
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
	gallery_return_to_appearance(t, &ui)
	testing.expect(
		t,
		nendo.element(nendo.id("ThemeShareBtn")).found &&
		nendo.element(nendo.id("ThemeEditBtn")).found,
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
	gallery_click(&ui, nendo.id("BrowseThemes"))
	gallery_hover(&ui, native)
	testing.expect(
		t,
		nendo.element(nendo.id("ThemeSourceNotice")).found,
		"A native hover must not hide the committed source credit",
	)
	gallery_click(&ui, nendo.id("ThemeOpt", u32(custom_index)))
	testing.expect_value(t, ui.theme, custom_index)
	testing.expect(t, !nendo.element(nendo.id("ThemeSourceNotice")).found)
	gallery_return_to_appearance(t, &ui)
	testing.expect(t, nendo.element(nendo.id("ThemeDeleteBtn")).found)
	gallery_click(&ui, nendo.id("BrowseThemes"))
	testing.expect(t, !nendo.element(nendo.id("ThemeDeleteBtn")).found)
	gallery_click(&ui, nendo.id("ThemeOpt", u32(native)))
	testing.expect(t, !nendo.element(nendo.id("ThemeSourceNotice")).found)
	if system_theme_index >= 0 {
		ui.theme_tone = theme_packs[system_theme_index].tone == .Light ? .Dark : .Light
		gallery_frames(&ui)
		gallery_click(&ui, nendo.id("ThemeOpt", u32(system_theme_index)))
		testing.expect_value(t, ui.theme, system_theme_index)
		testing.expect(t, !nendo.element(nendo.id("ThemeSourceNotice")).found)
	}
	gallery_click(&ui, nendo.id("ThemeToneLight"))
	gallery_click(&ui, nendo.id("ThemeOpt", u32(light)))
	settings_open(&ui, nil, .Language, anchor = "RowLang")
	gallery_open_from_appearance(t, &ui)
	testing.expect(
		t,
		nendo.element(nendo.id("ThemeOpt", u32(light))).found &&
		!nendo.element(nendo.id("ThemeOpt", u32(native))).found,
		"Reopening the gallery must browse the committed theme's tone",
	)
	gallery_return_to_appearance(t, &ui)
	gallery_check_appearance_tab_order(t, &ui)
	gallery_click(&ui, nendo.id("BrowseThemes"))
	ui.theme_tone = custom.tone
	gallery_frames(&ui)
	nendo.set_pointer({-10, -10}, .Up)
	kb_focus = ""
	last_focus := fmt.tprintf("ThemeOpt%d", custom_index)
	control_focus := []string{"SettingsBack", "ThemeToneDark", "ThemeToneLight"}
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
		testing.expectf(t, visited[i], "Tab must reach %s in the gallery", key)
	}
	testing.expect(t, kb_focus == last_focus, "Tab must reach the final custom tile")
	focused := nendo.element(nendo.id("ThemeOpt", u32(custom_index))).rect
	focus_page := nendo.element(nendo.id("SettingsPage")).rect
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
		}{{390, 360, 1}, {390, 390, 390.0 / 360}, {1024, 700, 1.5}, {1024, 700, 3}, {740, 500, 1}, {1440, 1000, 1.5}, {2560, 1080, 1}, {3440, 1440, 1}, {2560, 1080, 2}, {1440, 1000, 2}, {2560, 480, 1}}) {
		rl.SetWindowSize(size.w, size.h)
		UI_ZOOM = size.zoom
		viewport := nendo.Dimensions{f32(size.w) / UI_ZOOM, f32(size.h) / UI_ZOOM}
		nendo.set_dimensions(viewport)
		ui.theme = native
		apply_theme(ui.theme, ui.accent)
		gallery_open_from_appearance(t, &ui)
		ui.theme_tone = custom.tone
		gallery_frames(&ui)
		page := nendo.element(nendo.id("SettingsPage")).rect
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
			if box.y >= page.y - 0.1 && box.y + box.height <= page.y + page.height + 0.1 {break}
			wanted := clamp(box.y, page.y, max(page.y, page.y + page.height - box.height))
			settings_test_frame(&ui, {0, (wanted - box.y) / NENDO_SCROLL_PIXELS})
			gallery_frames(&ui)
		}
		tile := nendo.element(nendo.id("ThemeOpt", u32(custom_index)))
		box := tile.rect
		testing.expect(
			t,
			tile.found &&
			box.x >= page.x - 0.1 &&
			box.x + box.width <= page.x + page.width + 0.1 &&
			box.y >= page.y - 0.1 &&
			box.y + box.height <= page.y + page.height + 0.1,
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
		if settings_wide() {
			ui.theme = native
			apply_theme(ui.theme, ui.accent)
			gallery_open_from_appearance(t, &ui)
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
			gallery_clip := nendo.element(nendo.id("SettingsPage")).rect
			testing.expect(
				t,
				kb_focus == last_focus &&
				focused_tile.y >= gallery_clip.y - 0.1 &&
				focused_tile.y + focused_tile.height <= gallery_clip.y + gallery_clip.height + 0.1,
				"Wide keyboard traversal must reveal the final tile inside SettingsPage",
			)
			rl.PushKey(.ENTER, true)
			handle_settings(&ui, nil)
			rl.PushKey(.ENTER, false)
			gallery_frames(&ui)
			testing.expect(
				t,
				ui.theme == custom_index,
				"Enter must commit the final tile in the wide gallery",
			)
			kb_focus = ""
		}
	}
	gallery_check_modal_preview(t)
}

@(private)
gallery_open_from_appearance :: proc(t: ^testing.T, ui: ^Ui_State) {
	settings_open(ui, nil, .Appearance, anchor = "RowTheme")
	gallery_frames(ui)
	testing.expect(t, !ui.settings_gallery && nendo.element(nendo.id("BrowseThemes")).found)
	gallery_click(ui, nendo.id("BrowseThemes"))
	testing.expect(t, ui.settings_section == .Appearance && ui.settings_gallery)
	testing.expect(
		t,
		nendo.element(nendo.id("SettingsBack")).found &&
		nendo.scroll(nendo.id("SettingsPage")).found,
	)
	for id in ([5]string{"RowZoom", "SettingsAppearancePreview", "ThemeShareBtn", "ThemeEditBtn", "ThemeDeleteBtn"}) {
		testing.expectf(
			t,
			!nendo.element(nendo.id(id)).found,
			"%s belongs on Appearance, not the gallery",
			id,
		)
	}
}

@(private)
gallery_return_to_appearance :: proc(t: ^testing.T, ui: ^Ui_State) {
	gallery_click(ui, nendo.id("SettingsBack"))
	testing.expect(t, ui.settings_section == .Appearance && !ui.settings_gallery)
	testing.expect_value(t, kb_focus, "BrowseThemes")
	button := nendo.element(nendo.id("BrowseThemes"))
	page := nendo.element(nendo.id("SettingsPage")).rect
	testing.expect(
		t,
		button.found &&
		button.rect.y >= page.y - 0.1 &&
		button.rect.y + button.rect.height <= page.y + page.height + 0.1,
		"Back must reveal the Browse themes button without scrolling",
	)
}

@(private)
gallery_check_preview :: proc(t: ^testing.T, ui: ^Ui_State, last_tile: nendo.Rect) {
	id := nendo.id("SettingsConversationPreview")
	preview := nendo.element(id)
	testing.expect(
		t,
		preview.found &&
		preview.rect.y >= last_tile.y + last_tile.height - 0.1 &&
		!nendo.scroll(id).found,
		"The inert sample must follow the tiles in SettingsPage",
	)
	head := nendo.id("SettingsPreviewTitle")
	gallery_point(ui, head)
	testing.expect(
		t,
		nendo.element(head).found &&
		nendo.pointer_over(nendo.id("SettingsPage")) &&
		!nendo.pointer_over(head),
		"The sample conversation must not capture SettingsPage input",
	)
	for live_id in ([]string{"ChatPane", "ChatHeader", "ChatHeadInfo", "Timeline", "MsgRow", "JumpLatest", "Composer"}) {
		testing.expectf(
			t,
			!nendo.element(nendo.id(live_id)).found,
			"The sample must not mount %s",
			live_id,
		)
	}
	for command in settings_test_frame(ui) {
		if command.kind != .Text {continue}
		testing.expect(
			t,
			command.text.text != "PRIVATE_DRAFT" && command.text.text != "PRIVATE_MESSAGE",
			"The preview must not render the live draft or chat history",
		)
	}
	testing.expect_value(t, string(ui.compose[:]), "PRIVATE_DRAFT")
	testing.expect_value(t, ui.messages[0].body, "PRIVATE_MESSAGE")
}

@(private = "file")
gallery_check_modal_preview :: proc(t: ^testing.T) {
	rl.SetWindowSize(1200, 800)
	UI_ZOOM, UI_SCALE = 1, 1
	nendo.set_dimensions({1200, 800})
	ui := Ui_State {
		page        = .Chats,
		selected    = 0,
		row_menu    = -1,
		member_menu = -1,
		account_ref = "gallery-fixture",
		prefs       = default_prefs(),
	}
	ui.prefs.reduce_motion = true
	ui.prefs.composer.slots[.Effect] = .Menu
	append(&ui.accounts, Account_Row_Ui{name = "Gallery fixture"})
	append(&ui.chats, Chat_Row_Ui{group_id = "gallery-fixture", title = "Selected conversation"})
	for i in 0 ..< 80 {
		append(
			&ui.messages,
			Msg_Ui{id = fmt.tprintf("gallery-%d", i), sender = "Alice", body = "Real message"},
		)
	}
	append(&ui.compose, "PRIVATE_DRAFT")
	previous_ui, previous_prefs := g_ui, g_prefs
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs = previous_ui, previous_prefs
		delete(ui.accounts)
		delete(ui.chats)
		delete(ui.messages)
		delete(ui.compose)
		wrap_clear()
	}
	timeline_id := nendo.id("Timeline")
	jump_id := nendo.id("JumpLatest")
	menu_id := nendo.id("ComposeMoreMenu")
	for _ in 0 ..< 3 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
	timeline := nendo.scroll(timeline_id)
	if !testing.expect(
		t,
		timeline.found && timeline.content.height >= 2 * timeline.viewport.height,
	) {return}
	timeline.position.y = 0
	ui.compose_more = true
	anim_tick(1.0 / 60)
	build_layout(&ui, 0)
	testing.expect(t, nendo.element(jump_id).found && nendo.element(menu_id).found)

	settings_open(&ui, nil, .Appearance, anchor = "RowTheme")
	for _ in 0 ..< 3 {
		anim_tick(1.0 / 60)
		build_layout(&ui, 0)
		if settings_resolve_scroll(&ui) {build_layout(&ui, 0)}
	}
	if !testing.expect(t, settings_modal(&ui)) {return}
	testing.expect(t, ui.compose_more && !nendo.element(menu_id).found)
	browse_id := nendo.id("BrowseThemes")
	scroll_into_view(nendo.id("SettingsPage"), browse_id)
	build_layout(&ui, 0)
	settings_test_point(browse_id)
	settings_test_release(&ui)
	if !testing.expect(t, ui.settings_gallery) {return}
	preview_id := nendo.id("SettingsPreviewTitle")
	build_layout(&ui, 0)
	settings_resolve_scroll(&ui)
	build_layout(&ui, 0)
	scroll_into_view(nendo.id("SettingsPage"), preview_id)
	commands := build_layout(&ui, 0)
	testing.expect(t, nendo.element(preview_id).found)
	testing.expect(t, nendo.scroll(timeline_id).found && nendo.scroll(timeline_id).position.y == 0)
	for id in ([]nendo.Id{nendo.id("ChatHeader"), jump_id}) {
		count := 0
		for command in commands {
			if command.kind == .Rectangle && command.id == id.id {count += 1}
		}
		testing.expect_value(t, count, 1)
	}
	testing.expect_value(t, string(ui.compose[:]), "PRIVATE_DRAFT")
}

@(private)
gallery_check_appearance_tab_order :: proc(t: ^testing.T, ui: ^Ui_State) {
	controls := [?]string {
		"ThemeQuickLight",
		"ThemeQuickDark",
		"BrowseThemes",
		"BodyFontChip0",
		"ZoomMinus",
		"ZoomPlus",
		"ZoomReset",
		"Motion0",
		"Contrast0",
		"EmojiSetChip0",
		"ScrollChip0",
		"TgCentered",
		"MessageLinesPlus",
		"AvatarShapeChip0",
		"CropShapeChip0",
		"CropShapeChip1",
		"CropShapeChip2",
		"ThemeShareBtn",
	}
	next := 0
	nendo.set_pointer({-10, -10}, .Up)
	kb_focus = ""
	for _ in 0 ..< 256 {
		rl.PushKey(.TAB, true)
		handle_settings(ui, nil)
		rl.PushKey(.TAB, false)
		gallery_frames(ui)
		if kb_focus ==
		   "CropShapeChip3" {testing.expect(t, false, "Tab must skip the removed crop shape")}
		if kb_focus == controls[next] {next += 1}
		if kb_focus == controls[len(controls) - 1] {break}
	}
	if next < len(controls) {
		testing.expectf(t, false, "Tab must reach %s in Appearance layout order", controls[next])
	}
}

@(private)
gallery_frames :: proc(ui: ^Ui_State) {
	for _ in 0 ..< 3 {settings_test_frame(ui)}
}

@(private)
gallery_point :: proc(ui: ^Ui_State, id: nendo.Id) {
	if id != nendo.id("SettingsBack") {
		scroll_into_view(nendo.id("SettingsPage"), id)
		gallery_frames(ui)
	}
	settings_test_point(id)
}

@(private)
gallery_click :: proc(ui: ^Ui_State, id: nendo.Id) {
	gallery_point(ui, id)
	settings_test_release(ui)
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
			tile.found == (i == system_theme_index || pack.tone == ui.theme_tone),
			"The gallery must expose exactly the tiles in its active tone filter",
		)
	}
}
