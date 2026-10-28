package main

import "base:runtime"
import "core:strings"
import "core:testing"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Kept isolated like settings_viewport: fonts and Clay own process-global state.
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
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {320, 480})
	defer {clay.SetCurrentContext(previous); delete(memory)}
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
	append(&ui.account_ids, "mobile-settings-local")
	append(&ui.account_signing, Account_Signing{local = true})
	npub := hex_npub(strings.repeat("01", 32, context.temp_allocator))
	defer delete(npub)
	append(&ui.account_npubs, npub)
	defer delete(ui.account_npubs)
	ui.account_ref = "mobile-settings-local"
	defer {delete(ui.account_ids); delete(ui.account_signing)}
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}

	for size in ([][2]i32{{320, 480}, {360, 320}, {390, 240}, {430, 360}, {740, 240}, {1100, 760}}) {
		rl.SetWindowSize(size[0], size[1])
		viewport := clay.Dimensions{f32(size[0]), f32(size[1])}
		clay.SetLayoutDimensions(viewport)
		for target in ([]struct {
				section: Settings_Section,
				tab:     int,
				id:      string,
			}{{.General, 0, "TgRestore"}, {.General, 1, "DateFmtCol"}, {.General, 2, "QuickReset"}, {.Folders, 0, "SettingsFolderNew"}, {.Speech, 0, "SttModel"}, {.Speech, 1, "TtsPreview0"}, {.Network, 0, "AddInboxBtn"}, {.Network, 1, "GitClientChoices"}, {.Keys, 0, "SettingsCopyNpub"}, {.Keys, 1, "KpRefresh"}, {.Keys, 2, "VaultPwBtn"}, {.Appearance, 0, "ThemeEditBtn"}, {.Notifications, 0, "NotifyTest"}, {.Storage, 0, "ImportBtn"}, {.Advanced, 0, "MapBrowserChoices"}, {.Advanced, 1, "AuditRefresh"}, {.Advanced, 2, "TgDevMode"}, {.About, 0, "AboutCredits"}, {.Agents, 0, "AgentDocs"}}) {
			ui.settings_section, ui.settings_tab, ui.settings_level =
				target.section, target.tab, .Sheet
			for _ in 0 ..< 3 {settings_test_frame(&ui)}
			mobile_settings_inside(t, clay.ID("SettingsRoot"), viewport)
			mobile_settings_inside(t, clay.ID("SettingsSheet"), viewport, .Width)
			id := target.id == "SttModel" ? clay.ID(target.id, 0) : clay.ID(target.id)
			mobile_settings_inside(t, id, viewport, .Width)
			if single_pane() &&
			   target.section != .About &&
			   target.id != "DateFmtCol" &&
			   target.id != "GitClientChoices" &&
			   target.id != "MapBrowserChoices" {
				testing.expectf(
					t,
					clay.GetElementData(id).boundingBox.height >= 44,
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
		mobile_settings_inside(t, clay.ID("AgentCopyPrompt"), viewport, .Width)
		mobile_settings_inside(t, clay.ID("AgentCopyKey"), viewport, .Width)
		ui.agent_connector = 0

		ui.settings_section, ui.settings_level = .Storage, .Sheet
		ui.lang_open = true
		for _ in 0 ..< 3 {settings_test_frame(&ui)}
		mobile_settings_inside(t, clay.ID("LangModal"), viewport)
		ui.lang_open = false
		ui.shortcuts_open = true
		for _ in 0 ..< 3 {settings_test_frame(&ui)}
		mobile_settings_inside(t, clay.ID("ShortModal"), viewport)
		mobile_settings_reveal(t, &ui, "ShortModal", clay.ID("ShortRow", u32(len(SHORTCUTS) - 1)))
		ui.shortcuts_open = false
		for creating in ([]bool{true, false}) {
			ui.backup_mode = creating ? .Create : .Import
			for _ in 0 ..< 3 {settings_test_frame(&ui)}
			mobile_settings_inside(t, clay.ID("BackupModal"), viewport)
			mobile_settings_inside(t, clay.ID("BackupGo"), viewport, .Width)
			mobile_settings_reveal(t, &ui, "BackupModal", clay.ID("BackupGo"))
		}
		ui.backup_mode = .None
		ui.export_open = true
		for sealed in ([]bool{false, true}) {
			ui.export_result =
				sealed ? strings.repeat("ncryptsec1234567890", 12, context.temp_allocator) : ""
			for _ in 0 ..< 3 {settings_test_frame(&ui)}
			mobile_settings_inside(t, clay.ID("ExportModal"), viewport)
			mobile_settings_reveal(
				t,
				&ui,
				"ExportModal",
				clay.ID(sealed ? "ExportDone" : "ExportGo"),
			)
		}
		ui.export_open, ui.export_result = false, ""

		theme_edit_open(&ui)
		for _ in 0 ..< 3 {settings_test_frame(&ui)}
		mobile_settings_inside(t, clay.ID("ThemeEdit"), viewport)
		mobile_settings_inside(t, clay.ID("ThemeSeedBox0"), viewport, .Width)
		mobile_settings_inside(t, clay.ID("ThemeEditSave"), viewport, .Width)
		theme_edit_close(&ui, .Discard)

		ui.profile.editing = true
		for _ in 0 ..< 3 {mobile_settings_profile_frame(&ui)}
		mobile_settings_inside(t, clay.ID("ProfilePage"), viewport)
		mobile_settings_inside(t, clay.ID("NameBox"), viewport, .Width)
		mobile_settings_inside(t, clay.ID("PublishProfileBtn"), viewport, .Width)
		if single_pane() {
			label := clay.GetElementData(clay.ID("ProfileFormLabel", 0)).boundingBox
			field := clay.GetElementData(clay.ID("NameBox")).boundingBox
			testing.expect(
				t,
				field.y >= label.y + label.height,
				"Phone profile labels must sit above their fields",
			)
		}
		ui.profile.editing = false
		for _ in 0 ..< 3 {mobile_settings_profile_frame(&ui)}
		mobile_settings_inside(t, clay.ID("ProfileKvValue", 0), viewport, .Width)
		mobile_settings_inside(t, clay.ID("SignOutBtn"), viewport, .Width)
		if single_pane() {
			value := clay.GetScrollContainerData(clay.ID("ProfileKvValue", 0))
			testing.expect(
				t,
				value.found &&
				value.contentDimensions.width > value.scrollContainerDimensions.width,
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
	id: clay.ElementId,
	viewport: clay.Dimensions,
	extent: Mobile_Bounds = .Viewport,
) {
	element := clay.GetElementData(id)
	box := element.boundingBox
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
mobile_settings_reveal :: proc(
	t: ^testing.T,
	ui: ^Ui_State,
	panel_id: string,
	id: clay.ElementId,
) {
	panel := clay.GetElementData(clay.ID(panel_id)).boundingBox
	data := clay.GetScrollContainerData(clay.ID(panel_id))
	if !testing.expect(t, data.found, "Settings content must register a scroll viewport") {return}
	data.scrollPosition^ = {}
	settings_test_frame(ui)
	clay.SetPointerState({panel.x + panel.width / 2, panel.y + panel.height / 2}, false)
	for _ in 0 ..< 128 {
		box := clay.GetElementData(id).boundingBox
		if box.y >= panel.y - 0.1 &&
		   box.y < panel.y + panel.height &&
		   (box.height > panel.height ||
				   box.y + box.height <= panel.y + panel.height + 0.1) {break}
		wanted :=
			box.height > panel.height ? panel.y : clamp(box.y, panel.y, panel.y + panel.height - box.height)
		settings_test_frame(ui, {0, (wanted - box.y) / CLAY_SCROLL_PIXELS})
	}
	box := clay.GetElementData(id).boundingBox
	testing.expectf(
		t,
		box.y >= panel.y - 0.1 && box.y < panel.y + panel.height,
		"Scrolling %s must reveal %s, control=%v panel=%v window=%dx%d",
		panel_id,
		string(id.stringId.chars[:id.stringId.length]),
		box,
		panel,
		rl.GetScreenWidth(),
		rl.GetScreenHeight(),
	)
}

@(private)
mobile_settings_profile_frame :: proc(ui: ^Ui_State) {
	anim_tick(1.0 / 60)
	clay.UpdateScrollContainers(false, {}, 1.0 / 60)
	clay.BeginLayout()
	profile_pane(ui)
	clay.EndLayout(0)
}
