package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:text/edit"
import "nendo"
import rl "sdlrl"

// Runs in its own headless process through scripts/build.sh test.
@(test)
settings_viewport :: proc(t: ^testing.T) {
	if !test_isolated("settings_viewport") {return}
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-settings-viewport", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	previous_config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", home)
	defer {
		if previous_config == "" {os.unset_env("XDG_CONFIG_HOME")} else {
			os.set_env("XDG_CONFIG_HOME", previous_config)
		}
	}
	rl.InitWindow(740, 500, "Settings viewport")
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
		selected      = -1,
		audit_scanned = true,
		cache_scanned = true,
	}
	append(
		&ui.accounts,
		Account_Row_Ui{id_hex = "viewport-local", local = true},
		Account_Row_Ui{id_hex = "viewport-remote", external = true},
	)
	ui.account_ref = "viewport-local"
	defer delete(ui.accounts)
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	append(&ui.client_input, ..transmute([]u8)ui.prefs.event_client)
	defer {delete(ui.client_input); delete(ui.gm_input)}
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; kb_focus = ""}
	settings_test_appearance_reflow(t, &ui)
	settings_test_search_routes(t, &ui)
	settings_test_notification_gate(t, &ui)
	settings_test_emoji_previews(t, &ui)
	settings_test_event_client_navigation(t, &ui)
	for size in ([]struct {
			w, h: i32,
			zoom: f32,
		}{{740, 500, 1}, {390, 360, 1}, {1440, 1000, 1.5}, {1568, 1001, 1}, {1568, 733, 1}, {2102, 1342, 1.5}, {2872, 1342, 1.5}, {2560, 1080, 1}, {3440, 1440, 1}, {2560, 1080, 2}, {1440, 1000, 2}, {2560, 480, 1}}) {
		rl.SetWindowSize(size.w, size.h)
		UI_ZOOM = size.zoom
		viewport := nendo.Dimensions{f32(size.w) / UI_ZOOM, f32(size.h) / UI_ZOOM}
		nendo.set_dimensions(viewport)
		for target in ([]struct {
				section: Settings_Section,
				anchor:  string,
				id:      string,
			}{{.Home, "", "SettingsSearchBox"}, {.Appearance, "", "RowZoom"}, {.Notifications, "", "NotifyTest"}, {.Chats, "", "SettingsFolderNew"}, {.Language, "", "RowLang"}, {.Account, "", "RowEditProfile"}, {.Privacy, "", "RowTelemetry"}, {.Connection, "", "AddRelayRow"}, {.Advanced, "", "RowAudit"}, {.Help, "", "SupportChat"}, {.Language, "RowLang", "RowLang"}, {.Connection, "AddRelayRow", "AddRelayRow"}, {.Connection, "AddFetchRow", "AddFetchRow"}, {.Connection, "ClientBox", "ClientBox"}, {.Account, "NpubRow", "NpubRow"}, {.Account, "RowVaultPw", "RowVaultPw"}, {.Account, "RowReveal", "RowReveal"}, {.Account, "KpStatus", "KpStatus"}, {.Account, "RowRotate", "RowRotate"}, {.Privacy, "RowTelemetry", "RowTelemetry"}, {.Advanced, "RowAudit", "RowAudit"}, {.Advanced, "RowDevMode", "RowDevMode"}, {.Help, "SupportChat", "SupportChat"}, {.Help, "RowShortcuts", "RowShortcuts"}, {.Help, "AboutCredits", "AboutCredits"}}) {
			if target.id == "RowShortcuts" && tap_size() {continue}
			settings_open(&ui, nil, target.section, anchor = target.anchor)
			for _ in 0 ..< 3 {settings_test_frame(&ui)}
			root := nendo.element(nendo.id("SettingsRoot"))
			box := root.rect
			testing.expect(
				t,
				root.found && box.width > 0 && box.x >= 0 && box.x + box.width <= viewport.width,
				"Translated settings must not expand the page beyond the window",
			)
			testing.expectf(
				t,
				nendo.element(nendo.id(target.id)).found,
				"%v with anchor %q must show %s without another navigation step",
				target.section,
				target.anchor,
				target.id,
			)
			testing.expect(
				t,
				!nendo.element(nendo.id("SettingsPageIcon", 0)).found &&
				!nendo.element(nendo.id("SettingsTabs")).found,
				"Settings must not show an intermediate category menu or legacy tabs",
			)
			if target.section == .Help && target.anchor != "" {
				page := nendo.element(nendo.id("SettingsPage")).rect
				control := nendo.element(nendo.id(target.anchor)).rect
				testing.expectf(
					t,
					control.y >= page.y - 0.1 && control.y < page.y + page.height,
					"Help deep link must scroll %s into SettingsPage",
					target.anchor,
				)
			}
			if target.section == .Account && target.anchor == "" {
				for id in ([]string{"NpubRow", "RowReveal", "RowExport", "RowVaultPw", "RowLinkedDevices"}) {
					testing.expectf(
						t,
						nendo.element(nendo.id(id)).found,
						"Account must show %s",
						id,
					)
				}
			}
			if target.section == .Language {
				page := nendo.element(nendo.id("SettingsSheet")).rect
				group := nendo.element(nendo.id("LanguageGroup"))
				left := group.rect.x - page.x
				right := page.x + page.width - group.rect.x - group.rect.width
				testing.expect(
					t,
					group.found && left > right - 1 && left < right + 1,
					"Language must have equal side gutters inside its settings page",
				)
			}
		}

		for anchor in SETTINGS_TEST_APPEARANCE_ANCHORS {
			settings_open(&ui, nil, .Appearance, anchor = anchor)
			for _ in 0 ..< 3 {settings_test_frame(&ui)}
			if anchor == "RowScroll" && tap_size() {
				testing.expect(
					t,
					!nendo.element(nendo.id(anchor)).found,
					"Touch Appearance must omit mouse-wheel speed controls",
				)
				continue
			}
			clip := nendo.element(nendo.id("SettingsPage")).rect
			destination := nendo.element(nendo.id(anchor)).rect
			testing.expectf(
				t,
				destination.y >= clip.y - 0.1 && destination.y < clip.y + clip.height,
				"An Appearance deep link must reveal %s inside SettingsPage",
				anchor,
			)
			for other in SETTINGS_TEST_APPEARANCE_ANCHORS {
				if other == "RowScroll" && tap_size() {continue}
				testing.expectf(
					t,
					nendo.element(nendo.id(other)).found,
					"Opening %s must leave %s on Appearance",
					anchor,
					other,
				)
			}
		}
		settings_open(&ui, nil, .Appearance)
		for _ in 0 ..< 3 {settings_test_frame(&ui)}
		settings_test_appearance_rows(t)
		commands := settings_test_frame(&ui)
		rl.BeginDrawing()
		rl.DrawRectangleRec(0, 0, f32(size.w), f32(size.h), nendo_color(BG))
		rl.BeginMode2D({zoom = UI_ZOOM})
		render_nendo(commands)
		rl.EndMode2D()
		rl.TakeScreenshot(
			fmt.ctprintf("/tmp/wn-appearance-%dx%d-%v.png", size.w, size.h, size.zoom),
		)
		rl.EndDrawing()
		page := nendo.element(nendo.id("SettingsPage"))
		b := page.rect
		// nendo's f32 size distribution can accumulate subpixel boundary error.
		if !testing.expectf(
			t,
			page.found &&
			b.width > 0 &&
			b.height > 0 &&
			b.x >= 0 &&
			b.y >= 0 &&
			b.x + b.width <= viewport.width + 0.1 &&
			b.y + b.height <= viewport.height + 0.1,
			"The Appearance viewport %v must fit %v (root %v, main %v)",
			b,
			viewport,
			nendo.element(nendo.id("SettingsRoot")).rect,
			nendo.element(nendo.id("SettingsMain")).rect,
		) {return}
		mobile_settings_reveal(t, &ui, "SettingsPage", nendo.id("RowCropShape"))
		ui.account_ref = "viewport-remote"
		settings_open(&ui, nil, .Account, anchor = "RowVaultPw")
		for _ in 0 ..< 3 {settings_test_frame(&ui)}
		testing.expect(
			t,
			nendo.element(nendo.id("RowVaultPw")).found &&
			!nendo.element(nendo.id("RowExport")).found &&
			!nendo.element(nendo.id("RowReveal")).found,
			"A remote account keeps device vault controls but never offers its private key",
		)
		ui.account_ref = "viewport-local"
		when TRANSLATION_AVAILABLE {
			ui.prefs.translation_enabled = true
			settings_open(&ui, nil, .Language, anchor = "RowTranslationTarget")
			settings_translation_action(&ui, "TranslationTarget")
			for _ in 0 ..< 3 {settings_test_frame(&ui)}
			dropdown_page := nendo.element(nendo.id("SettingsPage")).rect
			list := nendo.element(nendo.id("TranslationLanguageList"))
			testing.expectf(
				t,
				list.found &&
				list.rect.y >= dropdown_page.y &&
				list.rect.y + list.rect.height <= dropdown_page.y + dropdown_page.height + 1,
				"The open translation language list must fit its viewport: page=%v list=%v",
				dropdown_page,
				list.rect,
			)
			settings_translation_close(&ui, 2)
			for _ in 0 ..< 3 {settings_test_frame(&ui)}
			field := nendo.element(nendo.id("TranslationTarget")).rect
			testing.expect(
				t,
				field.y >= dropdown_page.y &&
				field.y + field.height <= dropdown_page.y + dropdown_page.height,
				"Closing the language list must keep the selected language visible",
			)
		}
	}
	// A font preview must change real measurements, not just token names,
	// and cancellation must restore both nendo and paragraph-wrap geometry.
	ui.theme, ui.accent = 0, 0
	apply_theme(ui.theme, ui.accent)
	SAMPLE :: "Morning trains depart at seven"
	title_width :: proc() -> f32 {
		nendo.begin()
		if nendo.box(nendo.id("ThemeFontGeometry"))({}) {
			nendo.text(SAMPLE, {font = FONT_TITLE, size = 24, wrap = .None})
		}
		nendo.end(0)
		return nendo.element(nendo.id("ThemeFontGeometry")).rect.width
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
			"nendo must measure the selected font rather than reuse the previous face",
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
	"RowContrast",
	"RowCentered",
	"RowMessageLines",
	"RowAvatarShape",
	"RowCropShape",
}

@(private)
settings_test_appearance_rows :: proc(t: ^testing.T) {
	page := nendo.id("SettingsPage")
	testing.expect(t, nendo.scroll(page).found)
	clip := nendo.element(page).rect
	previous := clip.y
	for name in ([]string{"RowTheme", "RowBodyFont", "RowZoom"}) {
		row := nendo.element(nendo.id(name))
		testing.expectf(
			t,
			row.found && row.rect.y >= previous - 0.1,
			"%s must appear in reading order",
			name,
		)
		previous = row.rect.y + row.rect.height
	}
	for target in ([][2]string{{"RowZoom", "ZoomChoices"}, {"RowZoom", "ZoomReset"}, {"RowTheme", "BrowseThemes"}}) {
		parent := nendo.element(nendo.id(target[0])).rect
		child := nendo.element(nendo.id(target[1]))
		testing.expectf(
			t,
			child.found &&
			child.rect.y >= parent.y - 0.1 &&
			child.rect.y + child.rect.height <= parent.y + parent.height + 0.1,
			"%s must be inside %s",
			target[1],
			target[0],
		)
	}
	testing.expect(
		t,
		!nendo.element(nendo.id("ThemeToneDark")).found &&
		!nendo.element(nendo.id("SettingsConversationPreview")).found &&
		nendo.element(nendo.id("SettingsAppearancePreview")).found,
		"Appearance shows one compact sample; the full preview belongs in the gallery",
	)
	for control in ([2]string{"Motion", "Contrast"}) {
		for state in 0 ..< 3 {
			testing.expect(t, nendo.element(nendo.id(control, u32(state))).found)
		}
	}
}

@(private)
settings_test_appearance_reflow :: proc(t: ^testing.T, ui: ^Ui_State) {
	resize :: proc(ui: ^Ui_State, w, h: i32) {
		rl.SetWindowSize(w, h)
		apply_zoom(ui)
		nendo.set_dimensions({f32(w) / UI_ZOOM, f32(h) / UI_ZOOM})
	}
	ui.prefs.zoom_pct = 100
	resize(ui, 1024, 700)
	ui.page = .Chats
	ui.prefs.settings_category = .Home
	settings_enter(ui, nil)
	for _ in 0 ..< 3 {settings_test_frame(ui)}
	back_id := nendo.id("SettingsBack")
	reset_id := nendo.id("ZoomReset")
	page_id := nendo.id("SettingsPage")
	testing.expect(
		t,
		ui.page == .Settings && ui.settings_section == .Appearance,
		"First wide Settings entry must land on Appearance",
	)
	testing.expect(
		t,
		!nendo.element(back_id).found,
		"Wide Appearance must not render compact Back",
	)
	search := nendo.element(nendo.id("SettingsSearchBox"))
	categories := nendo.element(nendo.id("SettingsTaskPane"))
	testing.expect(
		t,
		search.found &&
		categories.found &&
		search.rect.y + search.rect.height <= categories.rect.y,
		"Sidebar search stays outside the scrolling category list",
	)
	for _ in 0 ..< 12 {
		rl.PushKey(.TAB, true)
		handle_settings(ui, nil)
		rl.PushKey(.TAB, false)
		if kb_focus == SETTINGS_SECTIONS[.Notifications] {break}
	}
	rl.PushKey(.ENTER, true)
	handle_settings(ui, nil)
	rl.PushKey(.ENTER, false)
	testing.expect_value(t, ui.settings_section, Settings_Section.Notifications)
	settings_open(ui, nil, .Appearance)
	resize(ui, 390, 390)
	for _ in 0 ..< 3 {settings_test_frame(ui)}
	testing.expect(
		t,
		ui.settings_section == .Appearance && !ui.settings_gallery,
		"Shrinking must keep the active page",
	)
	gallery_click(ui, nendo.id("BrowseThemes"))
	testing.expect(t, ui.settings_gallery)
	resize(ui, 1024, 700)
	for _ in 0 ..< 3 {settings_test_frame(ui)}
	testing.expect(
		t,
		ui.settings_section == .Appearance && ui.settings_gallery,
		"Widening must keep the active gallery",
	)
	resize(ui, 390, 390)
	for _ in 0 ..< 3 {settings_test_frame(ui)}
	gallery_return_to_appearance(t, ui)
	commands := settings_test_frame(ui)
	back := nendo.element(back_id)
	page := nendo.element(page_id).rect
	label_found := false
	for command in commands {
		if command.kind == .Text && strings.contains(command.text.text, tr("All settings")) {
			label_found = true
		}
	}
	if testing.expect(
		t,
		back.found && back.rect.y + back.rect.height <= page.y + 0.1 && label_found,
		"Compact Appearance must keep All settings above the scroll viewport",
	) {
		settings_test_point(back_id)
		settings_test_release(ui)
		testing.expect(
			t,
			ui.page == .Settings && ui.settings_section == .Home,
			"Compact Back must open the categories",
		)
		for _ in 0 ..< 3 {settings_test_frame(ui)}
		for category in ([]Settings_Section{.Appearance, .Notifications, .Chats, .Language, .Account, .Privacy, .Connection, .Advanced, .Help}) {
			testing.expectf(
				t,
				nendo.element(nendo.id("SettingsNav", u32(category))).found,
				"Compact index shows %v",
				category,
			)
		}
		testing.expect(
			t,
			nendo.element(nendo.id("SettingsSearchBox")).found &&
			!nendo.element(nendo.id("RowZoom")).found,
		)
		account := nendo.id("SettingsNav", u32(Settings_Section.Account))
		mobile_settings_reveal(t, ui, "SettingsPage", account)
		settings_test_point(account)
		settings_test_release(ui)
		for _ in 0 ..< 3 {settings_test_frame(ui)}
		testing.expect_value(t, ui.settings_section, Settings_Section.Account)
		testing.expect(
			t,
			nendo.element(nendo.id("RowEditProfile")).found,
			"Opening Account from the compact index shows its controls",
		)
	}
	ui.prefs.zoom_pct = 200
	resize(ui, 1024, 700)
	settings_open(ui, nil, .Appearance)
	for _ in 0 ..< 3 {settings_test_frame(ui)}
	page = nendo.element(page_id).rect
	reset := nendo.element(reset_id)
	testing.expect(t, nendo.element(back_id).found, "200% zoom must use the compact header")
	if testing.expectf(
		t,
		reset.found &&
		reset.rect.y >= page.y - 0.1 &&
		reset.rect.y + reset.rect.height <= page.y + page.height + 0.1,
		"Reset %v must be visible in %v on entry at 200%%",
		reset.rect,
		page,
	) {
		settings_test_point(reset_id)
		settings_test_release(ui)
		testing.expect_value(t, ui.prefs.zoom_pct, 100)
		nendo.set_dimensions({1024 / UI_ZOOM, 700 / UI_ZOOM})
		for _ in 0 ..< 3 {settings_test_frame(ui)}
		testing.expect(
			t,
			ui.settings_section == .Appearance && !nendo.element(back_id).found,
			"Resetting zoom must reflow in place to wide Appearance",
		)
	}
	ui.prefs.zoom_pct = 100
	resize(ui, 1024, 700)
}
@(private)
settings_test_search_routes :: proc(t: ^testing.T, ui: ^Ui_State) {
	set_locale("en")
	defer set_locale("ja")
	defer settings_open(ui, nil, .Home)
	for target in ([]struct {
			query:        string,
			section:      Settings_Section,
			anchor:       string,
			control:      string,
			editor_focus: Focus,
		}{{"Mute a conversation", .Mute, "MuteHelp", "", .Compose}, {"Launch at login", .Advanced, "RowLaunch", "TgLaunch", .Compose}, {"developer mode", .Advanced, "RowDevMode", "TgDevMode", .Compose}, {"Center the conversation", .Appearance, "RowCentered", "TgCentered", .Compose}, {"Restore the last chat", .Advanced, "RowRestore", "TgRestore", .Compose}, {"Change your GM", .Chats, "RowGm", "GmBox", .Gm}, {"Choose where events open", .Connection, "ClientBox", "ClientBox", .Client}, {"vault password", .Account, "RowVaultPw", "VaultPwBtn", .Compose}}) {
		when ODIN_OS == .OpenBSD || ODIN_PLATFORM_SUBTARGET == .Android {
			if target.anchor == "RowLaunch" {continue}
		}
		settings_open(ui, nil, .Notifications)
		settings_test_frame(ui)
		ui.focus = .SettingsSearch
		for ch in target.query {rl.PushChar(ch)}
		settings_search_field(ui)
		for _ in 0 ..< 3 {settings_test_frame(ui)}
		testing.expect_value(t, ui.settings_section, Settings_Section.Notifications)
		testing.expect(
			t,
			nendo.element(nendo.id("RowNotify")).found,
			"Typing must not close the current desktop page",
		)
		matches: [len(SETTINGS_TASKS)]int
		results := settings_results(ui, matches[:])
		if !testing.expectf(t, len(results) > 0, "Search finds %q", target.query) {continue}
		index := results[0]
		result := nendo.id("SettingsTask", u32(index))
		if !testing.expectf(
			t,
			nendo.element(result).found,
			"Search renders %q",
			target.query,
		) {continue}
		testing.expect(
			t,
			nendo.element(result).rect.x < nendo.element(nendo.id("SettingsPage")).rect.x,
			"Desktop results must be in the sidebar",
		)
		rl.PushKey(.DOWN, true)
		handle_settings(ui, nil)
		rl.PushKey(.DOWN, false)
		testing.expect_value(t, ui.settings_result, index + 1)
		testing.expect_value(t, ui.settings_section, Settings_Section.Notifications)
		rl.PushKey(.ENTER, true)
		handle_settings(ui, nil)
		rl.PushKey(.ENTER, false)
		testing.expect_value(t, ui.settings_section, target.section)
		testing.expect_value(t, ui.settings_anchor, target.anchor)
		testing.expect_value(t, settings_flash_id, target.anchor)
		for _ in 0 ..< 3 {settings_test_frame(ui)}
		testing.expectf(
			t,
			nendo.element(nendo.id(target.anchor)).found,
			"Search opens %s",
			target.anchor,
		)
		testing.expect_value(t, kb_focus, target.control)
		testing.expect_value(t, ui.focus, target.editor_focus)
		if target.control != "" {
			testing.expectf(
				t,
				nendo.element(nendo.id(target.control)).found,
				"Search focus target %s is rendered",
				target.control,
			)
			if target.editor_focus == .Compose {
				order := settings_check_ids[:settings_check_count]
				if target.section == .Appearance {order = theme_control_order[:]}
				registered := false
				for id in order {registered |= id == target.control}
				testing.expectf(
					t,
					registered,
					"%s is a registered keyboard control",
					target.control,
				)
			}
		}
		if target.editor_focus == .Gm && testing.expect(t, active_buf(ui) == &ui.gm_input) {
			rl.PushChar('!')
			edit_text(ui, active_buf(ui))
			testing.expect_value(t, string(ui.gm_input[:]), "!")
			clear(&ui.gm_input)
		}
		if target.section == .Mute {
			testing.expect_value(t, ui.selected, -1)
		} else if target.anchor == "RowVaultPw" {
			testing.expect(
				t,
				!ui.vault_pw_open && ui.keys_confirm == "" && len(ui.keys_nsec) == 0,
				"Vault search must focus the control without opening it or exposing a secret",
			)
		}
		settings_back(ui)
		testing.expect_value(t, ui.settings_section, target.section)
		testing.expect_value(t, string(ui.settings_search[:]), target.query)
		testing.expect_value(t, ui.settings_result, index + 1)
		testing.expect_value(t, ui.focus, Focus.SettingsSearch)
	}
	rl.SetWindowSize(390, 700)
	apply_zoom(ui)
	nendo.set_dimensions({390 / UI_ZOOM, 700 / UI_ZOOM})
	for _ in 0 ..< 3 {settings_test_frame(ui)}
	testing.expect(
		t,
		nendo.element(nendo.id("SettingsSearchBox")).found &&
		!nendo.element(nendo.id("RowVaultPw")).found,
		"A search in progress reflows to the compact results list",
	)
	rl.PushKey(.ENTER, true)
	handle_settings(ui, nil)
	rl.PushKey(.ENTER, false)
	for _ in 0 ..< 3 {settings_test_frame(ui)}
	testing.expect(t, nendo.element(nendo.id("RowVaultPw")).found && !ui.vault_pw_open)
	settings_back(ui)
	for _ in 0 ..< 3 {settings_test_frame(ui)}
	testing.expect(
		t,
		nendo.element(nendo.id("SettingsSearchBox")).found &&
		!nendo.element(nendo.id("RowVaultPw")).found,
	)
	rl.SetWindowSize(1024, 700)
	apply_zoom(ui)
	nendo.set_dimensions({1024 / UI_ZOOM, 700 / UI_ZOOM})
	settings_open(ui, nil, .Mute)
	settings_back(ui)
	testing.expect_value(t, ui.settings_section, Settings_Section.Help)
}

@(private)
settings_test_event_client_navigation :: proc(t: ^testing.T, ui: ^Ui_State) {
	defer settings_open(ui, nil, .Home)
	for exit in ([2]bool{false, true}) {
		settings_open(ui, nil, .Connection, anchor = "ClientBox")
		for _ in 0 ..< 3 {settings_test_frame(ui)}
		ui.focus = .Client
		ui.settings_dirty = false
		handle_settings(ui, nil)
		testing.expect(t, !ui.settings_dirty, "Unchanged event client does not queue a save")

		value := exit ? "https://example.org/{id}" : "https://example.net/{id}"
		ed_set(ui, &ui.client_input, "")
		for ch in value {rl.PushChar(ch)}
		edit_text(ui, active_buf(ui))
		destination := nendo.id("SettingsNav", u32(Settings_Section.Appearance))
		if exit {destination = nendo.id("SettingsExit")}
		if !testing.expect(t, nendo.element(destination).found) {continue}
		settings_test_point(destination)
		if exit {
			settings_test_release(ui)
			testing.expect_value(t, ui.page, Page.Chats)
		} else {
			forced_release = true
			testing.expect(t, settings_category_click(ui, nil))
			forced_release = false
			testing.expect_value(t, ui.settings_section, Settings_Section.Appearance)
		}
		testing.expect_value(t, ui.prefs.event_client, value)
		testing.expect(t, ui.settings_dirty, "Leaving Connection with an edit queues a save")
	}
}

@(private)
settings_test_notification_gate :: proc(t: ^testing.T, ui: ^Ui_State) {
	ui.prefs.notify_desktop, ui.prefs.notify_sound, ui.prefs.notify_preview = true, true, true
	settings_open(ui, nil, .Notifications)
	for _ in 0 ..< 3 {settings_test_frame(ui)}
	testing.expect(
		t,
		notify_test_enabled(ui),
		"The test action must be enabled while desktop alerts are on",
	)
	settings_test_point(nendo.id("TgNotify"))
	settings_test_release(ui)
	for _ in 0 ..< 3 {settings_test_frame(ui)}
	testing.expect(
		t,
		!ui.prefs.notify_desktop && ui.prefs.notify_sound && ui.prefs.notify_preview,
		"Turning off desktop alerts must preserve sound and preview choices",
	)
	testing.expect(
		t,
		!notify_test_enabled(ui) && nendo.element(nendo.id("NotifyTest")).found,
		"The test action stays visible but disabled while desktop alerts are off",
	)
	in_app_enabled := false
	for registered in settings_check_ids[:settings_check_count] {
		if registered == "TgUiSounds" {in_app_enabled = true}
	}
	testing.expect(
		t,
		in_app_enabled,
		"In-app sounds must stay enabled independently of desktop alerts",
	)
	for dependent in ([2]string{"TgSound", "TgPreview"}) {
		id := nendo.id(dependent)
		testing.expect(t, nendo.element(id).found)
		for registered in settings_check_ids[:settings_check_count] {
			testing.expect(
				t,
				registered != dependent,
				"A disabled control must not enter the switch action order",
			)
		}
		scroll_into_view(nendo.id("SettingsPage"), id)
		for _ in 0 ..< 3 {settings_test_frame(ui)}
		settings_test_point(id)
		settings_test_release(ui)
	}
	testing.expect(
		t,
		ui.prefs.notify_sound && ui.prefs.notify_preview,
		"Disabled controls must ignore clicks",
	)
	scroll_into_view(nendo.id("SettingsPage"), nendo.id("TgNotify"))
	for _ in 0 ..< 3 {settings_test_frame(ui)}
	settings_test_point(nendo.id("TgNotify"))
	settings_test_release(ui)
	testing.expect(
		t,
		notify_test_enabled(ui) && ui.prefs.notify_sound && ui.prefs.notify_preview,
		"Re-enabling desktop alerts must restore their existing options",
	)
}

@(private)
settings_test_emoji_previews :: proc(t: ^testing.T, ui: ^Ui_State) {
	defer emoji_preview_finish(.Discard)
	defer session_textures_clear(&custom_emoji_textures)
	directory := emoji_dir()
	if !testing.expect_value(t, os.make_directory_all(directory), nil) {return}
	defer {
		os.remove_all(directory)
		custom_emoji_scan()
	}
	for i in 0 ..< 40 {
		path := fmt.tprintf("%s/item_%02d.png", directory, i)
		if !testing.expect_value(t, os.write_entire_file(path, BUILTIN_EMOJI[0].png), nil) {return}
	}
	custom_emoji_scan()
	settings_open(ui, nil, .Chats)
	settings_test_frame(ui)
	first, last := "item_00.png", "item_39.png"
	first_chip := nendo.element(nendo.id("EmojiChip", 0))
	last_chip := nendo.element(nendo.id("EmojiChip", 39))
	page := nendo.element(nendo.id("SettingsPage")).rect
	testing.expect(t, first_chip.found && first_chip.rect.y < page.y + page.height)
	testing.expect(t, last_chip.found && last_chip.rect.y >= page.y + page.height)
	_, decoded_in_layout := custom_emoji_textures[first]
	testing.expect(t, !decoded_in_layout, "The first layout must not decode custom emoji")
	settings_emoji_tick(ui)
	emoji_preview_finish(.Publish)
	testing.expect(
		t,
		custom_emoji_textures[first] != nil,
		"A visible chip receives its decoded image",
	)
	_, decoded_offscreen := custom_emoji_textures[last]
	testing.expect(t, !decoded_offscreen, "Thumbnails below the fold wait for scrolling")
}

@(private)
settings_test_point :: proc(id: nendo.Id) {
	box := nendo.element(id).rect
	nendo.set_pointer({box.x + box.width / 2, box.y + box.height / 2}, .Up)
}

@(private)
settings_test_release :: proc(ui: ^Ui_State) {
	forced_release = true
	handle_settings(ui, nil)
	forced_release = false
}

@(private)
settings_test_frame :: proc(ui: ^Ui_State, wheel: nendo.Vector2 = {}) -> []nendo.Render_Command {
	anim_tick(1.0 / 60)
	nendo.update_scroll(.Off, wheel, 1.0 / 60)
	nendo.begin()
	settings_check_count = 0
	settings_pane(ui)
	if open_now(nendo.id("ExportModal"), ui.export_open) {export_modal(ui)}
	commands := nendo.end(0)
	if settings_resolve_scroll(ui) {
		nendo.begin()
		settings_check_count = 0
		settings_pane(ui)
		if open_now(nendo.id("ExportModal"), ui.export_open) {export_modal(ui)}
		commands = nendo.end(0)
	}
	return commands
}
