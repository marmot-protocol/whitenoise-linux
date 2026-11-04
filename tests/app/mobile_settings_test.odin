package main

import "base:runtime"
import "core:strings"
import "core:testing"

import "nendo"
import rl "sdlrl"

// Kept isolated like settings_viewport: fonts and nendo own process-global state.
@(test)
mobile_settings_viewport :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "mobile_settings_viewport" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(320, 480, "Mobile settings")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	set_locale("de")
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {320, 480})
	defer {nendo.set_context(previous); delete(memory)}
	ui := Ui_State {
		page          = .Settings,
		audit_scanned = true,
		cache_scanned = true,
	}
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	ui.prefs.stt_enabled, ui.prefs.tts_enabled = true, true
	ui.profile.username = strings.repeat("long-account-name", 8, context.temp_allocator)
	ui.profile.nip05 = strings.repeat("long-address@example.com", 8, context.temp_allocator)
	npub := hex_npub(strings.repeat("01", 32, context.temp_allocator))
	defer delete(npub)
	append(
		&ui.accounts,
		Account_Row_Ui{id_hex = "mobile-settings-local", npub = npub, local = true},
	)
	defer delete(ui.accounts)
	ui.account_ref = "mobile-settings-local"
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}

	for size in ([][2]i32{{320, 480}, {360, 320}, {390, 240}, {430, 360}, {740, 240}, {1100, 760}}) {
		rl.SetWindowSize(size[0], size[1])
		viewport := nendo.Dimensions{f32(size[0]), f32(size[1])}
		nendo.set_dimensions(viewport)
		for target in ([]struct {
				section: Settings_Section,
				tab:     int,
				id:      string,
			}{{.General, 0, "TgRestore"}, {.General, 1, "DateFmtCol"}, {.General, 2, "QuickReset"}, {.Folders, 0, "SettingsFolderNew"}, {.Speech, 0, "SttModel"}, {.Speech, 1, "TtsPreview0"}, {.Network, 0, "AddInboxBtn"}, {.Network, 1, "GitClientChoices"}, {.Keys, 0, "SettingsCopyNpub"}, {.Keys, 1, "KpRefresh"}, {.Keys, 2, "VaultPwBtn"}, {.Appearance, 0, "ThemeEditBtn"}, {.Notifications, 0, "NotifyTest"}, {.Storage, 0, "ImportBtn"}, {.Advanced, 0, "MapBrowserChoices"}, {.Advanced, 1, "AuditRefresh"}, {.Advanced, 2, "TgDevMode"}, {.About, 0, "AboutCredits"}, {.Agents, 0, "AgentDocs"}}) {
			ui.settings_section, ui.settings_tab, ui.settings_level =
				target.section, target.tab, .Sheet
			for _ in 0 ..< 3 {settings_test_frame(&ui)}
			mobile_settings_inside(t, nendo.id("SettingsRoot"), viewport)
			mobile_settings_inside(t, nendo.id("SettingsSheet"), viewport, .Width)
			id := target.id == "SttModel" ? nendo.id(target.id, 0) : nendo.id(target.id)
			mobile_settings_inside(t, id, viewport, .Width)
			if single_pane() &&
			   target.section != .About &&
			   target.id != "DateFmtCol" &&
			   target.id != "GitClientChoices" &&
			   target.id != "MapBrowserChoices" {
				testing.expectf(
					t,
					nendo.element(id).rect.height >= 44,
					"%s must have a touch-height target",
					target.id,
				)
			}
			panel :=
				target.section == .Appearance && appearance_layout(&ui).columns > 1 ? "AppearanceControls" : "SettingsPage"
			mobile_settings_reveal(t, &ui, panel, id)
		}

		ui.settings_section, ui.settings_level = .Agents, .Sheet
		ui.agent_connector = 1
		for _ in 0 ..< 3 {settings_test_frame(&ui)}
		mobile_settings_inside(t, nendo.id("AgentCopyPrompt"), viewport, .Width)
		mobile_settings_inside(t, nendo.id("AgentCopyKey"), viewport, .Width)
		ui.agent_connector = 0

		ui.settings_section, ui.settings_level = .Storage, .Sheet
		ui.lang_open = true
		for _ in 0 ..< 3 {settings_test_frame(&ui)}
		mobile_settings_inside(t, nendo.id("LangModal"), viewport)
		ui.lang_open = false
		ui.shortcuts_open = true
		for _ in 0 ..< 3 {settings_test_frame(&ui)}
		mobile_settings_inside(t, nendo.id("ShortModal"), viewport)
		last_shortcut := len(SHORTCUTS) - (rl.HasTouch() ? 2 : 1)
		mobile_settings_reveal(t, &ui, "ShortList", nendo.id("ShortRow", u32(last_shortcut)))
		ui.shortcuts_open = false
		for creating in ([]bool{true, false}) {
			ui.backup_mode = creating ? .Create : .Import
			for _ in 0 ..< 3 {settings_test_frame(&ui)}
			mobile_settings_inside(t, nendo.id("BackupModal"), viewport)
			mobile_settings_inside(t, nendo.id("BackupGo"), viewport, .Width)
			mobile_settings_reveal(t, &ui, "BackupModal", nendo.id("BackupGo"))
		}
		ui.backup_mode = .None
		ui.export_open = true
		for sealed in ([]bool{false, true}) {
			ui.export_result =
				sealed ? strings.repeat("ncryptsec1234567890", 12, context.temp_allocator) : ""
			for _ in 0 ..< 3 {settings_test_frame(&ui)}
			mobile_settings_inside(t, nendo.id("ExportModal"), viewport)
			mobile_settings_reveal(
				t,
				&ui,
				"ExportModal",
				nendo.id(sealed ? "ExportDone" : "ExportGo"),
			)
		}
		ui.export_open, ui.export_result = false, ""

		theme_edit_open(&ui)
		for _ in 0 ..< 3 {settings_test_frame(&ui)}
		mobile_settings_inside(t, nendo.id("ThemeEdit"), viewport)
		mobile_settings_inside(t, nendo.id("ThemeSeedBox0"), viewport, .Width)
		mobile_settings_inside(t, nendo.id("ThemeEditSave"), viewport, .Width)
		theme_edit_close(&ui, .Discard)

		ui.profile.editing = true
		for _ in 0 ..< 3 {mobile_settings_profile_frame(&ui)}
		mobile_settings_inside(t, nendo.id("ProfilePage"), viewport)
		mobile_settings_inside(t, nendo.id("NameBox"), viewport, .Width)
		mobile_settings_inside(t, nendo.id("PublishProfileBtn"), viewport, .Width)
		if single_pane() {
			label := nendo.element(nendo.id("ProfileFormLabel", 0)).rect
			field := nendo.element(nendo.id("NameBox")).rect
			testing.expect(
				t,
				field.y >= label.y + label.height,
				"Phone profile labels must sit above their fields",
			)
		}
		ui.profile.editing = false
		for _ in 0 ..< 3 {mobile_settings_profile_frame(&ui)}
		mobile_settings_inside(t, nendo.id("ProfileKvValue", 0), viewport, .Width)
		mobile_settings_inside(t, nendo.id("SignOutBtn"), viewport, .Width)
		if single_pane() {
			value := nendo.scroll(nendo.id("ProfileKvValue", 0))
			testing.expect(
				t,
				value.found && value.content.width > value.viewport.width,
				"Long public profile values must remain reachable through horizontal scrolling",
			)
		}
	}
}

@(private)
Mobile_Bounds :: enum {
	Width,
	Viewport,
}

@(private)
mobile_settings_inside :: proc(
	t: ^testing.T,
	id: nendo.Id,
	viewport: nendo.Dimensions,
	extent: Mobile_Bounds = .Viewport,
) {
	element := nendo.element(id)
	box := element.rect
	testing.expectf(
		t,
		element.found &&
		box.width > 0 &&
		box.x >= -0.1 &&
		box.x + box.width <= viewport.width + 0.1,
		"Settings target %v must fit width %v: %v",
		id,
		viewport.width,
		box,
	)
	if extent == .Viewport {
		testing.expectf(
			t,
			box.height > 0 && box.y >= -0.1 && box.y + box.height <= viewport.height + 0.1,
			"Settings viewport %v must fit height %v: %v",
			id,
			viewport.height,
			box,
		)
	}
}

@(private)
mobile_settings_reveal :: proc(t: ^testing.T, ui: ^Ui_State, panel_id: string, id: nendo.Id) {
	panel := nendo.element(nendo.id(panel_id)).rect
	data := nendo.scroll(nendo.id(panel_id))
	if !testing.expectf(
		t,
		data.found,
		"%s must register a scroll viewport for %s",
		panel_id,
		id.label,
	) {return}
	data.position^ = {}
	settings_test_frame(ui)
	nendo.set_pointer({panel.x + panel.width / 2, panel.y + panel.height / 2}, .Up)
	for _ in 0 ..< 128 {
		box := nendo.element(id).rect
		if box.y >= panel.y - 0.1 &&
		   box.y < panel.y + panel.height &&
		   (box.height > panel.height ||
				   box.y + box.height <= panel.y + panel.height + 0.1) {break}
		wanted :=
			box.height > panel.height ? panel.y : clamp(box.y, panel.y, panel.y + panel.height - box.height)
		settings_test_frame(ui, {0, (wanted - box.y) / NENDO_SCROLL_PIXELS})
	}
	box := nendo.element(id).rect
	testing.expectf(
		t,
		box.y >= panel.y - 0.1 && box.y < panel.y + panel.height,
		"Scrolling %s must reveal %s, control=%v panel=%v window=%dx%d",
		panel_id,
		id.label,
		box,
		panel,
		rl.GetScreenWidth(),
		rl.GetScreenHeight(),
	)
}

@(private)
mobile_settings_profile_frame :: proc(ui: ^Ui_State) {
	anim_tick(1.0 / 60)
	nendo.update_scroll(.Off, {}, 1.0 / 60)
	nendo.begin()
	profile_pane(ui)
	nendo.end(0)
}
