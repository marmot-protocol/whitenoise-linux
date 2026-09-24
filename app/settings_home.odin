package main

import "core:fmt"
import "core:strings"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
Settings_Task :: struct {
	section:  Settings_Section,
	label:    string,
	anchor:   string,
	keywords: string,
	featured: bool,
}

// One catalog drives the home links and search. Targets open a property
// sheet and reveal its actual control, never toggle a preference themselves.
@(private)
SETTINGS_TASKS := []Settings_Task {
	{.Appearance, N_("Theme"), "RowTheme", "appearance colors look", true},
	{.Appearance, N_("Message text size"), "RowBodyFont", "font accessibility", true},
	{.Appearance, N_("Default avatar shape"), "RowAvatarShape", "photo picture", false},
	{.Appearance, N_("Crop circle shape"), "RowCropShape", "identity fingerprint avatar", false},
	{.Appearance, N_("Interface zoom"), "RowZoom", "scale size accessibility", false},
	{.Appearance, N_("Scroll speed"), "RowScroll", "mouse wheel", false},
	{.Appearance, N_("Reduce motion"), "RowMotion", "animation accessibility", false},
	{.Appearance, N_("Centred conversation"), "RowCentered", "layout width", false},
	{.Appearance, N_("Share this theme"), "RowThemeShare", "edit custom theme", false},
	{.General, N_("Interface language"), "RowLang", "locale translation", true},
	{.General, N_("Launch at login"), "RowLaunch", "startup autostart", true},
	{.General, N_("Start minimized to tray"), "RowTray", "startup background", false},
	{.General, N_("Close to tray"), "RowMinTray", "window background", false},
	{
		.General,
		N_("Restore last selected chat on launch"),
		"RowRestore",
		"startup conversation",
		false,
	},
	{.General, N_("Time format"), "RowTimeFmt", "clock 12 24 hour", false},
	{.General, N_("Date format"), "RowDateFmt", "calendar", false},
	{.General, N_("One-tap reactions"), "RowQuick", "emoji messaging", false},
	{.General, N_("Uploaded emoji"), "RowEmoji", "custom emoji messaging", false},
	{.General, N_("Keyboard shortcuts"), "RowShortcuts", "keys hotkeys", false},
	{
		.Folders,
		N_("Organize your folders"),
		"SettingsFolderActions",
		"chats create rename order delete",
		true,
	},
	{.Notifications, N_("Desktop notifications"), "RowNotify", "alerts incoming messages", true},
	{.Notifications, N_("Play a sound"), "RowSound", "audio notifications", true},
	{.Notifications, N_("Interface sounds"), "RowUiSounds", "audio sent received", false},
	{.Notifications, N_("Show message preview"), "RowPreview", "privacy notifications", false},
	{
		.Notifications,
		N_("Send a test notification"),
		"RowNotifyTest",
		"audio sound desktop alert",
		false,
	},
	{.Speech, N_("Speech to text"), "RowStt", "dictation microphone transcribe model", true},
	{.Speech, N_("Read aloud"), "RowTts", "voice audio text to speech model", true},
	{
		.Network,
		N_("Manage your relays"),
		"AddRelayRow",
		"outbox publish nip65 nostr connection",
		true,
	},
	{.Network, N_("Inbox relays"), "AddInboxRow", "receive messages nostr", true},
	{.Network, N_("Event fetch relays"), "AddFetchRow", "links nevent nostr", false},
	{.Network, N_("Open events in"), "ClientBox", "web client browser links", false},
	{.Network, N_("Republish relay lists"), "RowRepublish", "sync nostr", false},
	{.Keys, N_("Your public key"), "NpubRow", "identity npub copy", true},
	{.Keys, N_("Change vault password"), "RowVaultPw", "security encryption secret", true},
	{.Keys, N_("Key packages"), "KpStatus", "mls publish identity", false},
	{.Keys, N_("Your secret key"), "RowReveal", "nsec reveal export security", false},
	{.Storage, N_("Cached attachments"), "RowCache", "media space disk clear", true},
	{.Storage, N_("Back up everything"), "RowBackup", "export data encrypted", true},
	{.Storage, N_("Import a backup"), "RowImport", "restore data encrypted", false},
	{.Storage, N_("Location"), "RowLocation", "data folder disk", false},
	{.Advanced, N_("Share usage and diagnostics"), "RowTelemetry", "privacy telemetry", true},
	{.Advanced, N_("Developer mode"), "RowDevMode", "debug tools", true},
	{.Advanced, N_("Audit logs"), "RowAudit", "privacy security files", false},
	{.About, N_("About White Noise"), "", "version license credits", false},
	{.Debug, N_("Debug"), "DbgTabs", "diagnostics state events timings", false},
	{.KP, N_("KP inspector"), "KpMineRow", "mls decode key packages", false},
}

@(private)
SETTINGS_SUMMARIES := [Settings_Section]string {
	.Home          = N_("Choose what you'd like to change."),
	.Appearance    = N_("Themes, text size, and the look of your conversations."),
	.General       = N_("Language, startup, and everyday preferences."),
	.Folders       = N_("Keep your conversations in order."),
	.Notifications = N_("Choose what gets your attention."),
	.Speech        = N_("Dictate messages and listen to them aloud."),
	.Network       = N_("Connect with the relays you choose."),
	.Keys          = N_("Your identity and the secrets on this device."),
	.Storage       = N_("Local files, cached media, and encrypted backups."),
	.Advanced      = N_("Privacy, diagnostics, and developer tools."),
	.About         = N_("Learn about White Noise."),
	.Debug         = N_("Inspect the current session."),
	.KP            = N_("Inspect MLS key packages."),
}

@(private)
settings_available :: proc(ui: ^Ui_State, section: Settings_Section) -> bool {
	return (section != .Debug && section != .KP) || ui.prefs.dev_mode
}

@(private)
settings_task_matches :: proc(ui: ^Ui_State, task: Settings_Task, query: string) -> bool {
	if !settings_available(ui, task.section) {return false}
	if query == "" {return true}
	text := strings.to_lower(
		fmt.tprintf(
			"%s %s %s %s %s",
			tr(task.label),
			task.label,
			tr(SETTINGS_SECTIONS[task.section].label),
			SETTINGS_SECTIONS[task.section].label,
			task.keywords,
		),
		context.temp_allocator,
	)
	for word in strings.fields(query) {
		if !strings.contains(text, word) {return false}
	}
	return true
}

@(private)
settings_navigation :: proc(ui: ^Ui_State) {
	home := ui.settings_section == .Home
	compact := page_w(ui) < 620
	if clay.UI(clay.ID("SettingsNavigation"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {left = 24, right = 24, top = 18, bottom = 16},
			layoutDirection = home && compact ? .TopToBottom : .LeftToRight,
			childGap = 14,
			childAlignment = {y = .Center},
		},
		backgroundColor = PANEL,
		border = {color = DIVIDER, width = {bottom = 1}},
	},
	) {
		if home {
			if clay.UI(clay.ID("SettingsTitle"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					childGap = 10,
					childAlignment = {y = .Center},
				},
			},
			) {
				settings_illustration("SettingsHomeArt", .Home, 32)
				clay.Text(tr("Settings"), {fontId = FONT_TITLE, fontSize = 24, textColor = TEXT})
			}
			if clay.UI(clay.ID("SettingsSearchLine"))(
			{
				layout = {
					sizing = {width = compact ? clay.SizingGrow() : clay.SizingFixed(300)},
					childGap = 8,
					childAlignment = {y = .Center},
				},
			},
			) {
				if clay.UI(clay.ID("SettingsSearchBox"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(36)},
						padding = {left = 10, right = 10},
						childGap = 8,
						childAlignment = {y = .Center},
					},
					backgroundColor = CARD,
					cornerRadius = rr(4),
					border = {
						color = ui.focus == .SettingsSearch ? ACCENT : FIELD_BORDER,
						width = bw(),
					},
				},
				) {
					clay.Text(
						ICON_SEARCH,
						{fontId = FONT_ICON, fontSize = 13, textColor = TEXT_DIM},
					)
					field_text(
						ui,
						"SettingsSearchBox",
						&ui.settings_search,
						tr("Find a setting..."),
						ui.focus == .SettingsSearch,
						13,
						TEXT_DIM,
					)
				}
				if len(ui.settings_search) >
				   0 {micro_button("SettingsSearchClear", "Clear search")}
			}
		} else {
			if clay.UI(clay.ID("SettingsHome"))(
			{
				layout = {
					padding = {top = 6, bottom = 6},
					childGap = 7,
					childAlignment = {y = .Center},
				},
			},
			) {
				clay.Text("‹", {fontId = FONT_TITLE, fontSize = 21, textColor = ACCENT})
				clay.Text(
					tr("Settings"),
					{fontId = FONT_TITLE, fontSize = 14, textColor = hovered() ? TEXT : ACCENT},
				)
			}
			clay.Text("/", {fontId = FONT_BODY, fontSize = 14, textColor = TEXT_LO})
			if clay.UI(clay.ID("SettingsBreadcrumb"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {
				clay.Text(
					tr(SETTINGS_SECTIONS[ui.settings_section].label),
					{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
				)
			}
			if !compact {micro_button("SettingsSearchOpen", "Find a setting")}
		}
	}
}

@(private)
settings_home :: proc(ui: ^Ui_State) {
	query := strings.to_lower(
		strings.trim_space(string(ui.settings_search[:])),
		context.temp_allocator,
	)
	if query != "" {
		clay.Text(tr("Search results"), {fontId = FONT_TITLE, fontSize = 21, textColor = TEXT})
		count := 0
		for task, i in SETTINGS_TASKS {
			if !settings_task_matches(ui, task, query) {continue}
			count += 1
			if clay.UI(clay.ID("SettingsTask", u32(i)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					padding = {top = 12, bottom = 12, left = 10, right = 10},
					childGap = 12,
					childAlignment = {y = .Center},
				},
				backgroundColor = hovered() ? HOVER : {},
				border = {color = DIVIDER, width = {bottom = 1}},
			},
			) {
				settings_illustration(fmt.tprintf("SettingsResultArt%d", i), task.section, 36)
				if clay.UI(clay.ID("SettingsResultText", u32(i)))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						layoutDirection = .TopToBottom,
						childGap = 4,
					},
				},
				) {
					clay.Text(
						tr(task.label),
						{fontId = FONT_TITLE, fontSize = 14, textColor = TEXT},
					)
					clay.Text(
						tr(SETTINGS_SECTIONS[task.section].label),
						{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
					)
				}
				clay.Text("›", {fontId = FONT_TITLE, fontSize = 18, textColor = ACCENT})
			}
		}
		if count == 0 {
			clay.Text(
				tr("No matching settings."),
				{fontId = FONT_TITLE, fontSize = 16, textColor = TEXT},
			)
			clay.Text(
				tr("Try a different search."),
				{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
			)
		}
		return
	}
	clay.Text(
		tr("Choose what you'd like to change."),
		{fontId = FONT_TITLE, fontSize = 21, textColor = TEXT},
	)
	categories := [9]Settings_Section {
		.Appearance,
		.General,
		.Folders,
		.Notifications,
		.Speech,
		.Network,
		.Keys,
		.Storage,
		.Advanced,
	}
	columns := page_w(ui) >= 680 ? 2 : 1
	for row := 0; row < (len(categories) + columns - 1) / columns; row += 1 {
		if clay.UI(clay.ID("SettingsCategoryRow", u32(row)))(
		{layout = {sizing = {width = clay.SizingGrow()}, childGap = 28}},
		) {
			for col in 0 ..< columns {
				i := row * columns + col
				if i >= len(categories) {
					if clay.UI(clay.ID("SettingsEmptyCategory"))(
					{layout = {sizing = {width = clay.SizingGrow()}}},
					) {}
					continue
				}
				section := categories[i]
				if clay.UI(clay.ID("SettingsNav", u32(section)))(
				{
					layout = {
						sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()},
						padding = {top = 20, bottom = 20},
						childGap = 16,
					},
					border = {color = DIVIDER, width = {bottom = 1}},
				},
				) {
					_ = hovered()
					settings_illustration(
						fmt.tprintf("SettingsCategoryArt%d", u32(section)),
						section,
						56,
					)
					if clay.UI(clay.ID("SettingsCategoryText", u32(section)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							layoutDirection = .TopToBottom,
							childGap = 6,
						},
					},
					) {
						clay.Text(
							tr(SETTINGS_SECTIONS[section].label),
							{
								fontId = FONT_TITLE,
								fontSize = 17,
								textColor = hovered() ? TEXT : ACCENT,
							},
						)
						clay.Text(
							tr(SETTINGS_SUMMARIES[section]),
							{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
						)
						for task, index in SETTINGS_TASKS {
							if task.section != section || !task.featured {continue}
							if clay.UI(clay.ID("SettingsTask", u32(index)))(
							{layout = {padding = {top = 3, bottom = 3}}},
							) {
								clay.Text(
									tr(task.label),
									{
										fontId = FONT_BODY,
										fontSize = 13,
										textColor = hovered() ? ACCENT : TEXT,
									},
								)
							}
						}
					}
				}
			}
		}
	}
	if clay.UI(clay.ID("SettingsUtilities"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {top = 10},
			layoutDirection = page_w(ui) < 620 ? .TopToBottom : .LeftToRight,
			childGap = 20,
		},
	},
	) {
		for section in ([3]Settings_Section{.About, .Debug, .KP}) {
			if !settings_available(ui, section) {continue}
			if clay.UI(clay.ID("SettingsNav", u32(section)))(
			{
				layout = {
					padding = {top = 6, bottom = 6},
					childGap = 8,
					childAlignment = {y = .Center},
				},
			},
			) {
				if hovered() {tooltip(tr(SETTINGS_SUMMARIES[section]))}
				settings_illustration(
					fmt.tprintf("SettingsUtilityArt%d", u32(section)),
					section,
					24,
				)
				clay.Text(
					tr(SETTINGS_SECTIONS[section].label),
					{fontId = FONT_BODY, fontSize = 13, textColor = hovered() ? TEXT : ACCENT},
				)
			}
		}
	}
}

@(private)
settings_open :: proc(
	ui: ^Ui_State,
	client: ^marmot.Client,
	section: Settings_Section,
	tab: int = 0,
	anchor: string = "",
) {
	if !settings_available(ui, section) {return}
	target_tab := anchor == "" ? tab : settings_target_tab(section, anchor)
	if section != .Keys || ui.settings_section != .Keys || target_tab != ui.settings_tab {
		keys_forget(ui)
	}
	ui.page = .Settings
	ui.settings_section = section
	ui.settings_tab = target_tab
	ui.settings_anchor = anchor
	ui.settings_scroll_pending = true
	ui.focus = .Compose
	if section == .Home {clear(&ui.settings_search)}
	if client != nil {
		#partial switch section {
		case .Network, .Keys:
			load_profile(client, ui)
			if section == .Keys {fetch_key_packages(ui, client)}
		case .Debug:
			compose_debug_json(ui, client)
		case .Advanced:
			load_advanced(ui, client)
		}
	}
}

@(private)
settings_search_field :: proc(ui: ^Ui_State) {
	if ui.settings_section != .Home ||
	   ui.lang_open ||
	   ui.shortcuts_open ||
	   ui.theme_menu_open ||
	   ui.export_open {return}
	if field_mouse(ui, &ui.settings_search, "SettingsSearchBox", 13) {ui.focus = .SettingsSearch}
	if ui.focus != .SettingsSearch {return}
	before := avatar_hash(string(ui.settings_search[:]))
	edit_text(ui, &ui.settings_search)
	if rl.IsKeyPressed(.ESCAPE) {
		clear(&ui.settings_search)
		ui.focus = .Compose
	}
	if before != avatar_hash(string(ui.settings_search[:])) {
		ui.settings_anchor = ""
		ui.settings_scroll_pending = true
	}
}

@(private)
settings_handle_navigation :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	if ui.page != .Settings {return false}
	if ui.focus == .SettingsSearch && rl.IsKeyPressed(.ENTER) {
		query := strings.to_lower(
			strings.trim_space(string(ui.settings_search[:])),
			context.temp_allocator,
		)
		if query != "" {
			for task in SETTINGS_TASKS {
				if settings_task_matches(ui, task, query) {
					settings_open(ui, client, task.section, anchor = task.anchor)
					return true
				}
			}
		}
	}
	if !mouse_released() {return false}
	if clicked("SettingsHome") || clay.PointerOver(clay.ID("Nav", u32(Page.Settings))) {
		settings_open(ui, client, .Home)
		return true
	}
	if clicked("SettingsSearchOpen") {
		settings_open(ui, client, .Home)
		ui.focus = .SettingsSearch
		return true
	}
	if clicked("SettingsSearchClear") {
		clear(&ui.settings_search)
		ui.focus = .SettingsSearch
		ui.settings_scroll_pending = true
		return true
	}
	for task, i in SETTINGS_TASKS {
		if clay.PointerOver(clay.ID("SettingsTask", u32(i))) {
			settings_open(ui, client, task.section, anchor = task.anchor)
			return true
		}
	}
	for section in Settings_Section {
		if clay.PointerOver(clay.ID("SettingsNav", u32(section))) {
			settings_open(ui, client, section)
			return true
		}
	}
	return false
}

// Resolve links after layout, when both the new section and its control exist.
// Main rebuilds once before drawing, so a deep link never flashes the old scroll.
@(private)
settings_resolve_scroll :: proc(ui: ^Ui_State) -> bool {
	if ui.page != .Settings || !ui.settings_scroll_pending {return false}
	data := clay.GetScrollContainerData(clay.ID("SettingsPage"))
	page := clay.GetElementData(clay.ID("SettingsPage"))
	if !data.found || !page.found {return false}
	target: f32
	if ui.settings_anchor != "" {
		anchor := clay.GetElementData(clay.ID(ui.settings_anchor))
		if anchor.found {target = data.scrollPosition.y - (anchor.boundingBox.y - page.boundingBox.y - 12)}
	}
	overflow := max(0, data.contentDimensions.height - data.scrollContainerDimensions.height)
	data.scrollPosition.y = clamp(target, -overflow, 0)
	ui.settings_scroll_pending = false
	return true
}
