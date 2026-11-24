package main

import "core:fmt"
import "core:strings"

import marmot "../marmot"
import "nendo"
import rl "sdlrl"

// Shared with the Android and iOS support entry points.
@(private = "file")
SUPPORT_NPUB :: "npub1zymqqmvktw8lkr5dp6zzw5xk3fkdqcynj4l3f080k3amy28ses6setzznv"

// Search results identify a control or a task-specific editor.
@(private)
Settings_Task :: struct {
	section:  Settings_Section,
	label:    string,
	anchor:   string,
	keywords: string,
}

@(private)
SETTINGS_TASKS := [?]Settings_Task {
	{
		.Agents,
		N_("Connect an AI agent"),
		"AgentConnectors",
		"hermes openclaw opencode codex claude code installation setup npub",
	},
	{.Appearance, N_("Change the theme"), "RowTheme", "appearance colors look"},
	{.Appearance, N_("Message text size"), "RowBodyFont", N_("font accessibility")},
	{.Appearance, N_("Choose an emoji style"), "RowEmojiSet", "noto twemoji openmoji look"},
	{.Appearance, N_("Interface zoom"), "RowZoom", N_("scale size accessibility")},
	{.Appearance, N_("Choose the default avatar shape"), "RowAvatarShape", "photo picture"},
	{
		.Appearance,
		N_("Choose the crop circle shape"),
		"RowCropShape",
		"identity fingerprint avatar",
	},
	{.Appearance, N_("Change the scroll speed"), "RowScroll", "mouse wheel"},
	{.Appearance, N_("Reduce motion"), "RowMotion", "animation accessibility"},
	{.Appearance, N_("Increase contrast"), "RowContrast", "accessibility text borders"},
	{
		.Appearance,
		N_("Center the conversation"),
		"RowCentered",
		"layout width center centre centered centred",
	},
	{
		.Appearance,
		N_("Message line limit"),
		"RowMessageLines",
		"read more collapse expand event cards lines threshold",
	},
	{.Appearance, N_("Share this theme"), "RowThemeShare", "edit custom theme"},
	{.Language, N_("Change the interface language"), "RowLang", "locale translation"},
	{
		.Language,
		N_("Translate messages on your device"),
		"RowTranslation",
		"translation local offline gemma model download privacy",
	},
	{
		.Language,
		N_("Translate received messages automatically"),
		"RowTranslationAuto",
		"translation automatic incoming language",
	},
	{
		.Language,
		N_("Choose a translation source language"),
		"RowTranslationSource",
		"translation detect automatic from",
	},
	{
		.Language,
		N_("Choose a translation target language"),
		"RowTranslationTarget",
		"translation into output",
	},
	{.Advanced, N_("Launch at login"), "RowLaunch", "startup autostart"},
	{.Language, N_("Change the time format"), "RowTimeFmt", "clock 12 24 hour"},
	{.Chats, N_("Choose one-tap reactions"), "RowQuick", "emoji messaging quick"},
	{
		.Composer,
		N_("Customize composer"),
		"ComposerSettings",
		"chat toolbar shortcuts reorder pin voice",
	},
	{.Help, N_("Keyboard shortcuts"), "RowShortcuts", "keys hotkeys"},
	{.Advanced, N_("Start minimized to tray"), "RowTray", "startup background"},
	{.Advanced, N_("Close to tray"), "RowMinTray", "window background"},
	{.Advanced, N_("Restore the last chat on launch"), "RowRestore", "startup conversation"},
	{.Language, N_("Change the date format"), "RowDateFmt", "calendar"},
	{.Chats, N_("Upload custom emoji"), "RowEmoji", "emoji messaging"},
	{.Chats, N_("Change your GM"), "RowGm", "good morning greeting daily"},
	{
		.Chats,
		N_("Organize your folders"),
		"SettingsFolderActions",
		"chats create rename order delete drag rules",
	},
	{.Notifications, N_("Desktop notifications"), "RowNotify", N_("alerts incoming messages")},
	{.Notifications, N_("Desktop alert sound"), "RowSound", N_("audio notifications mute")},
	{.Notifications, N_("Message previews"), "RowPreview", N_("privacy notifications")},
	{.Notifications, N_("Send a test notification"), "RowNotifyTest", "audio sound desktop alert"},
	{
		.Notifications,
		N_("Message tones"),
		"RowUiSounds",
		N_("in-app sounds audio sent received mute"),
	},
	{
		.Language,
		N_("Dictate your messages"),
		"RowStt",
		"speech to text microphone transcribe model",
	},
	{.Language, N_("Have messages read aloud"), "RowTts", "voice audio text to speech model"},
	{
		.Connection,
		N_("Choose where you publish"),
		"AddRelayRow",
		"outbox relays nip65 nostr connection",
	},
	{
		.Connection,
		N_("Choose where people reach you"),
		"AddInboxRow",
		"inbox relays receive messages nostr",
	},
	{.Connection, N_("Add relays for linked events"), "AddFetchRow", "fetch links nevent nostr"},
	{.Connection, N_("Republish your relay lists"), "RowRepublish", "sync nostr"},
	{
		.Connection,
		N_("Configure a SOCKS5 proxy"),
		"NetworkProxyGroup",
		"proxy socks socks5 tor privacy network connection",
	},
	{.Connection, N_("Choose where events open"), "ClientBox", "web client browser links"},
	{
		.Connection,
		N_("Choose where git patches open"),
		"NetworkGitClientGroup",
		"ngit committish gitworkshop nostrhub patch web client links",
	},
	{.Account, N_("Copy your public key"), "NpubRow", "identity npub"},
	{.Account, N_("Publish a key package"), "KpStatus", "mls invite identity"},
	{.Account, N_("Change your vault password"), "RowVaultPw", "security encryption secret"},
	{.Account, N_("Reveal your secret key"), "RowReveal", "nsec export security"},
	{.Devices, N_("Manage linked devices"), "DevicesRoster", "pair link roster"},
	{.Privacy, N_("Clear cached attachments"), "RowCache", "media space disk"},
	{.Privacy, N_("Back up local data"), "RowBackup", "export data encrypted"},
	{.Privacy, N_("Import a backup"), "RowImport", "restore data encrypted"},
	{.Privacy, N_("See where your data is stored"), "RowLocation", "data folder disk location"},
	{.Privacy, N_("Share usage and diagnostics"), "RowTelemetry", "privacy telemetry"},
	{.Advanced, N_("Record audit logs"), "RowAudit", "privacy security files"},
	{.Advanced, N_("Turn on developer mode"), "RowDevMode", "debug tools"},
	{.Advanced, N_("Choose the renderer"), "RowRenderer", "vulkan opengl cpu gpu graphics"},
	{.Help, N_("About White Noise"), "AboutIdentity", "version license credits"},
	{.Help, N_("Reach out to support"), "SettingsSupport", "help contact feedback bug question"},
	{
		.Debug,
		N_("Inspect the current session"),
		"DbgTabs",
		"debug diagnostics state events timings",
	},
	{.KP, N_("Inspect key packages"), "KpMineRow", "kp mls decode"},
	{
		.Account,
		N_("Edit profile"),
		"RowEditProfile",
		N_("display name username avatar picture bio"),
	},
	{.Account, N_("Export encrypted key (ncryptsec)"), "RowExport", "backup secret key"},
	{.Connection, N_("Link previews"), "RowLinkPreviews", "embed website image privacy"},
	{.Connection, N_("Location maps"), "RowMaps", "maps pictures openstreetmap"},
	{.Connection, N_("Open locations in"), "RowMapBrowser", "map browser"},
	{.Connection, N_("Trusted link sites"), "AdvancedTrustedGroup", "allowlist browser links"},
	{.Mute, N_("Mute a conversation"), "MuteHelp", N_("silence quiet chat notifications")},
}

@(private)
SETTINGS_TROUBLESHOOTERS := [?]Settings_Task {
	{.Connection, N_("Messages aren't arriving"), "RowNetStatus", ""},
	{.Connection, N_("Peers can't find you"), "RowRepublish", ""},
	{.Account, N_("People can't invite you"), "KpStatus", ""},
	{.Notifications, N_("Notifications don't appear"), "RowNotifyTest", ""},
	{.Notifications, N_("Sounds don't play"), "RowSound", ""},
	{.Appearance, N_("Text is hard to read"), "RowBodyFont", ""},
	{.Appearance, N_("Animations are distracting"), "RowMotion", ""},
	{.Advanced, N_("White Noise doesn't open at login"), "RowLaunch", ""},
	{.Language, N_("Dictation doesn't work"), "RowStt", ""},
	{.Language, N_("Nothing is read aloud"), "RowTts", ""},
	{.Privacy, N_("Your disk is filling up"), "RowCache", ""},
	{.Advanced, N_("Collecting logs for a bug report"), "RowAudit", ""},
}

@(private)
settings_category :: proc(section: Settings_Section) -> Settings_Section {
	#partial switch section {
	case .Composer:
		return .Chats
	case .Devices:
		return .Account
	case .Agents, .Debug, .KP:
		return .Advanced
	case .Mute:
		return .Help
	}
	return section
}

@(private)
settings_available :: proc(ui: ^Ui_State, section: Settings_Section) -> bool {
	if section == .Devices {return devices_visible(ui)}
	return (section != .Debug && section != .KP) || ui.prefs.dev_mode
}

@(private)
settings_task_matches :: proc(ui: ^Ui_State, task: Settings_Task, query: string) -> bool {
	when !TRANSLATION_AVAILABLE {
		if strings.has_prefix(task.anchor, "RowTranslation") {return false}
	}
	when ODIN_OS == .OpenBSD || ODIN_PLATFORM_SUBTARGET == .Android {
		if task.anchor == "RowLaunch" {return false}
	}
	when ODIN_OS == .OpenBSD {
		if task.anchor == "AdvancedTrustedGroup" {return false}
	}
	if (task.anchor == "RowReveal" || task.anchor == "RowExport") &&
	   !account_local(ui) {return false}
	if task.anchor == "RowEditProfile" && ui.account_ref == "" {return false}
	if !settings_available(ui, task.section) {return false}
	if tap_size() && settings_desktop_only(task.anchor) {return false}
	if query == "" {return true}
	category := SETTINGS_SECTIONS[settings_category(task.section)]
	text := fmt.tprintf(
		"%s %s %s %s %s %s",
		tr(task.label),
		task.label,
		tr(category),
		category,
		task.keywords,
		tr(task.keywords),
	)
	if task.anchor == "RowTheme" {
		names := strings.builder_make(context.temp_allocator)
		strings.write_string(&names, text)
		strings.write_byte(&names, ' ')
		strings.write_string(&names, tr("Color mode"))
		for pack in theme_packs {
			strings.write_byte(&names, ' ')
			strings.write_string(&names, pack.custom ? pack.name : tr(pack.name))
		}
		text = strings.to_string(names)
	}
	text = strings.to_lower(text, context.temp_allocator)
	for word in strings.fields(query) {
		if !strings.contains(text, word) {return false}
	}
	return true
}

// Rows that only mean something with a mouse, keyboard or tray: touch
// screens hide them and every link to them.
@(private)
settings_desktop_only :: proc(anchor: string) -> bool {
	switch anchor {
	case "RowShortcuts", "RowTray", "RowMinTray", "RowScroll":
		return true
	}
	return false
}

@(private)
SETTINGS_CATEGORY_GROUPS := [][]Settings_Section {
	{.Account},
	{.Appearance, .Notifications, .Chats, .Language},
	{.Privacy, .Connection},
	{.Advanced, .Help},
}

@(private)
SETTINGS_CATEGORY_ICONS := #partial [Settings_Section]struct {
	glyph: string,
	tone:  int,
} {
	.Account       = {ICON_PROFILE, 0},
	.Appearance    = {ICON_BRUSH, 3},
	.Notifications = {ICON_BELL, 4},
	.Chats         = {ICON_CHATS, 1},
	.Language      = {ICON_MIC, 3},
	.Privacy       = {ICON_LOCK, 0},
	.Connection    = {ICON_GLOBE, 2},
	.Advanced      = {ICON_SETTINGS, -1},
	.Help          = {ICON_INFO, 1},
}

@(private)
settings_register_nav :: proc(ui: ^Ui_State, id: string) {
	if ui.settings_section == .Appearance {
		append(&theme_control_order, id)
	} else {
		settings_register(id)
	}
}

@(private)
settings_nav_box :: proc(ui: ^Ui_State) {
	settings_register_nav(ui, "SettingsExit")
	label := settings_modal(ui) ? tr("Close") : fmt.tprintf("‹ %s", tr("Back to White Noise"))
	settings_button("SettingsExit", label)
	settings_register_nav(ui, "SettingsSearchBox")
	if nendo.box(nendo.id("SettingsSearchBox"))(
	{
		width = nendo.grow(),
		height = nendo.fixed(settings_tap_size(30)),
		padding = {left = 9, right = 5},
		gap = 7,
		align = {y = .Center},
		color = ROW_BG,
		radius = rr(7),
		border = {color = ui.focus == .SettingsSearch ? ACCENT : FIELD_BORDER, width = bw()},
	},
	) {
		nendo.text(ICON_SEARCH, {font = FONT_ICON, size = 12, color = TEXT_DIM})
		field_text(
			ui,
			"SettingsSearchBox",
			&ui.settings_search,
			tr("Search settings"),
			ui.focus == .SettingsSearch,
			12,
			TEXT_DIM,
		)
		if len(ui.settings_search) > 0 {
			if nendo.box(nendo.id("SettingsSearchClear"))(
			{
				width = nendo.fixed(settings_tap_size(21)),
				height = nendo.grow(),
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : {},
				radius = rr(5),
			},
			) {
				if hovered() {tooltip(tr("Clear search"))}
				nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 11, color = TEXT_DIM})
			}
		}
	}
}

@(private)
settings_categories :: proc(ui: ^Ui_State) {
	current := settings_category(ui.settings_section)
	for group, i in SETTINGS_CATEGORY_GROUPS {
		if nendo.box(nendo.id("SettingsCategoryGroup", u32(i)))(
		{width = nendo.grow(), direction = .Column, gap = 2},
		) {
			for section in group {
				label := SETTINGS_SECTIONS[section]
				selected := current == section
				settings_register_nav(ui, label)
				if nendo.box(nendo.id("SettingsNav", u32(section)))(
				{
					width = nendo.grow(),
					height = nendo.fit(min = settings_tap_size(29)),
					padding = {left = 8, right = 6, top = 4, bottom = 4},
					align = {y = .Center},
					gap = 8,
					color = selected ? SELECTED : hovered() ? HOVER : {},
					border = kb_focus == label ? kb_ring(ACCENT) : {},
					radius = rr(7),
				},
				) {
					if section == .Account && ui.account_ref != "" {
						name :=
							ui.profile.name != "" ? ui.profile.name : profile_label(nil, ui.account_ref)
						avatar(
							"SettingsAccountAvatar",
							0,
							ui.account_ref,
							name,
							32,
							url_pic(ui.my_pic_url),
						)
						row_labels(name, tr(label))
					} else {
						icon := SETTINGS_CATEGORY_ICONS[section]
						fill, ink := CONTROL, TEXT
						if icon.tone >= 0 && len(theme_packs) > 0 {
							pack := &theme_packs[active_theme(ui)]
							fill, ink = pack.accent_base[icon.tone], pack.on_accent[icon.tone]
						}
						if nendo.box(nendo.id_local("CategoryIcon"))(
						{
							width = nendo.fixed(21),
							height = nendo.fixed(21),
							align = {x = .Center, y = .Center},
							color = fill,
							radius = rr(5),
						},
						) {
							nendo.text(icon.glyph, {font = FONT_ICON, size = 12, color = ink})
						}
						nendo.text(
							tr(label),
							{font = selected ? FONT_TITLE : FONT_BODY, size = 13, color = TEXT},
						)
					}
				}
			}
		}
	}
}

@(private)
settings_query :: proc(ui: ^Ui_State) -> string {
	return strings.trim_space(string(ui.settings_search[:]))
}

@(private)
settings_index :: proc(ui: ^Ui_State) -> bool {
	return(
		ui.settings_section == .Home ||
		(!settings_wide() && settings_query(ui) != "" && ui.settings_search_return == nil) \
	)
}

@(private)
settings_results :: proc(ui: ^Ui_State, matches: []int) -> []int {
	query := strings.to_lower(settings_query(ui), context.temp_allocator)
	if query == "" {return matches[:0]}
	count, direct := 0, 0
	for task, i in SETTINGS_TASKS {
		if !settings_task_matches(ui, task, query) {continue}
		if strings.contains(strings.to_lower(tr(task.label), context.temp_allocator), query) {
			copy(matches[direct + 1:count + 1], matches[direct:count])
			matches[direct] = i
			direct += 1
		} else {
			matches[count] = i
		}
		count += 1
	}
	return matches[:count]
}

@(private)
settings_result_list :: proc(ui: ^Ui_State) {
	settings_group(tr("Search results"))
	matches: [len(SETTINGS_TASKS)]int
	results := settings_results(ui, matches[:])
	if len(results) == 0 {
		nendo.text(
			fmt.tprintf(tr("No settings match ‘%s’."), settings_query(ui)),
			{font = FONT_TITLE, size = 13, color = TEXT},
		)
		return
	}
	for index in results {
		task := SETTINGS_TASKS[index]
		category := settings_category(task.section)
		if nendo.box(nendo.id("SettingsTask", u32(index)))(
		{
			width = nendo.grow(),
			height = nendo.fit(min = settings_tap_size(34)),
			padding = {top = 5, bottom = 5, left = 8, right = 6},
			gap = 8,
			align = {y = .Center},
			color = ui.settings_result == index + 1 ? SELECTED : hovered() ? HOVER : {},
			radius = rr(6),
		},
		) {
			nendo.text(
				SETTINGS_CATEGORY_ICONS[category].glyph,
				{font = FONT_ICON, size = 13, color = TEXT_DIM},
			)
			row_labels(tr(task.label), tr(SETTINGS_SECTIONS[category]))
		}
	}
}

@(private)
open_support_chat :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if ui.account_ref == "" || client == nil {return}
	start_dm(ui, client, Contact_Ui{id_hex = deeplink_hex(SUPPORT_NPUB)})
}

@(private)
Settings_Jump :: enum {
	Replace,
	Keep_Search,
}

@(private)
settings_open :: proc(
	ui: ^Ui_State,
	client: ^marmot.Client,
	section: Settings_Section,
	anchor: string = "",
	jump: Settings_Jump = .Replace,
) {
	if !settings_available(ui, section) {return}
	if ui.page != .Settings && !ui.settings_profile_return {
		ui.settings_return_page = ui.page
		ui.settings_return_focus = ui.new_chat_open ? .Compose : ui.focus
	}
	keys_forget(ui)
	settings_theme_preview_reset(ui)
	ui.settings_gallery = false
	if jump == .Replace {
		ui.settings_search_return = nil
		clear(&ui.settings_search)
		ui.settings_result = 0
	}
	ui.settings_target_focus = ""
	ui.settings_profile_return = false
	ui.composer_settings_from_chat = false
	ui.translation.language_menu = 0
	ui.agent_connector = 0
	if section != .Chats {
		ui.emoji_sets_open = false
		ui.emoji_sets_selected = -1
	}
	ui.page = .Settings
	ui.settings_section = section
	ui.settings_anchor = anchor
	if anchor == "" &&
	   section == .Appearance &&
	   UI_ZOOM >= 2 * zoom_for_width(rl.GetScreenWidth()) &&
	   f32(rl.GetScreenHeight()) / UI_ZOOM < 300 {
		ui.settings_anchor = "ZoomReset"
	}
	ui.settings_scroll_pending = true
	settings_flash_id = anchor
	settings_flash_until = anchor != "" ? rl.GetTime() + 1.5 : 0
	ui.focus = .Compose
	kb_focus = ""
	if section == .Devices {devices_refresh_open(ui)}
	if client == nil {return}
	#partial switch section {
	case .Connection, .Account:
		load_profile(client, ui)
		if section == .Account {fetch_key_packages(ui, client)}
	case .Debug:
		compose_debug_json(ui, client)
	case .Advanced, .Privacy:
		load_advanced(ui, client)
	}
}

@(private)
settings_enter :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	section := Settings_Section.Home
	if settings_wide() {
		section = ui.prefs.settings_category
		if section == .Home || !settings_available(ui, section) {section = .Appearance}
	}
	settings_open(ui, client, section)
}

@(private)
restore_workspace :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	ui.page = ui.prefs.page
	if ui.page < .Chats || ui.page > max(Page) {ui.page = .Chats}
	ui.chat_filter = ui.prefs.chat_filter
	if ui.page == .Settings {
		section := ui.prefs.settings_category
		if section == .Home && settings_wide() {section = .Appearance}
		settings_open(ui, ui.account_ref == "" ? nil : client, section)
		return
	}
	if client == nil || ui.account_ref == "" {return}
	#partial switch ui.page {
	case .Contacts:
		load_contacts(client, ui, .Details)
	case .Archived:
		load_archived(client, ui)
	case .Profile:
		load_profile(client, ui)
	}
}

@(private)
settings_leave :: proc(ui: ^Ui_State) {
	keys_forget(ui)
	settings_theme_preview_reset(ui)
	page, found := ui.settings_return_page.?
	ui.page = found ? page : .Chats
	ui.focus = found ? ui.settings_return_focus : .Compose
	ui.settings_return_page = nil
	ui.composer_settings_from_chat = false
	kb_focus = ""
}

@(private)
settings_return_results :: proc(ui: ^Ui_State) {
	ui.settings_search_return = nil
	ui.focus = .SettingsSearch
	kb_focus = "SettingsSearchBox"
	ui.settings_target_focus = ""
	settings_flash_id = ""
	if settings_wide() {
		settings_reveal_result(ui)
	} else {
		ui.settings_scroll_pending = true
	}
}

@(private)
settings_back :: proc(ui: ^Ui_State) {
	if ui.composer_settings_from_chat {
		settings_leave(ui)
		return
	}
	if ui.settings_gallery {
		settings_theme_preview_reset(ui)
		ui.settings_gallery = false
		ui.settings_anchor = "BrowseThemes"
		ui.settings_target_focus = "BrowseThemes"
		ui.settings_scroll_pending = true
		return
	}
	if ui.settings_section == .Agents && ui.agent_connector > 0 {
		ui.agent_connector = 0
		kb_focus = ""
		ui.settings_scroll_pending = true
		return
	}
	if ui.settings_section == .Chats && ui.emoji_sets_open {
		if ui.emoji_sets_selected >= 0 {
			ui.emoji_sets_selected = -1
		} else {
			ui.emoji_sets_open = false
		}
		ui.focus = .Compose
		ui.settings_anchor = "EmojiSetsBrowse"
		ui.settings_scroll_pending = true
		return
	}
	if ui.settings_search_return == ui.settings_section {
		keys_forget(ui)
		settings_return_results(ui)
		return
	}
	if settings_index(ui) {settings_leave(ui); return}
	section := ui.settings_section
	parent := settings_category(section)
	if parent == section {
		if settings_modal(ui) {settings_leave(ui); return}
		settings_open(ui, nil, .Home)
		kb_focus = SETTINGS_SECTIONS[section]
		return
	}
	control: string
	#partial switch section {
	case .Composer:
		control = "SettingsComposer"
	case .Devices:
		control = "SettingsLinkedDevices"
	case .Agents:
		control = "SettingsAgents"
	case .Debug:
		control = "SettingsDebug"
	case .KP:
		control = "SettingsKP"
	case .Mute:
		control = "SettingsMuteHelp"
	}
	settings_open(ui, nil, parent, anchor = control, jump = .Keep_Search)
	ui.settings_target_focus = control
}

@(private)
settings_reset_results :: proc(ui: ^Ui_State) {
	if ui.settings_search_return != nil {settings_flash_id = ""}
	ui.settings_search_return = nil
	ui.settings_result = 0
	owner := settings_wide() ? "SettingsTaskPane" : "SettingsPage"
	if scroll := nendo.scroll(nendo.id(owner)); scroll.found {scroll.position.y = 0}
}

@(private)
settings_escape :: proc(ui: ^Ui_State) -> bool {
	if !rl.IsKeyPressed(.ESCAPE) {return false}
	if ui.settings_section == .Language && ui.translation.language_menu != 0 {
		settings_translation_close(ui, ui.translation.language_menu)
		return true
	}
	settings_theme_preview_reset(ui)
	#partial switch ui.focus {
	case .Compose:
		settings_back(ui)
		return true
	case .SettingsSearch:
		clear(&ui.settings_search)
		settings_reset_results(ui)
	case .EmojiName:
		cancel_staged_emoji(ui)
	}
	ui.focus = .Compose
	return true
}

@(private)
settings_search_field :: proc(ui: ^Ui_State) {
	if ui.lang_open || ui.shortcuts_open || ui.export_open {return}
	if !nendo.element(nendo.id("SettingsSearchBox")).found {return}
	if field_mouse(ui, &ui.settings_search, "SettingsSearchBox", 12) {
		ui.focus = .SettingsSearch
		kb_focus = "SettingsSearchBox"
	} else if ui.focus == .SettingsSearch &&
	   rl.IsMouseButtonPressed(.LEFT) &&
	   !nendo.pointer_over(nendo.id("SettingsSearchBox")) {
		ui.focus = .Compose
	}
	if ui.focus != .SettingsSearch {return}
	settings_theme_preview_reset(ui)
	before := avatar_hash(string(ui.settings_search[:]))
	edit_text(ui, &ui.settings_search)
	if before != avatar_hash(string(ui.settings_search[:])) {
		settings_reset_results(ui)
		if settings_index(ui) {keys_forget(ui)}
	}
}

@(private)
settings_open_result :: proc(ui: ^Ui_State, client: ^marmot.Client, index: int) {
	task := SETTINGS_TASKS[index]
	if task.anchor == "RowEditProfile" {
		ui.settings_result = index + 1
		ui.settings_search_return = .Home
		settings_edit_profile(ui, client)
		return
	}
	if !ui.prefs.translation_enabled && strings.has_prefix(task.anchor, "RowTranslation") {
		task.anchor = "RowTranslation"
	}
	settings_open(ui, client, task.section, anchor = task.anchor, jump = .Keep_Search)
	ui.settings_search_return = task.section
	ui.settings_result = index + 1
	switch task.anchor {
	case "RowGm":
		ui.focus = .Gm
		ui.settings_target_focus = "GmBox"
	case "ClientBox":
		ui.focus = .Client
		ui.settings_target_focus = "ClientBox"
	case "AddRelayRow":
		ui.focus = .Relay
		ui.settings_target_focus = "RelayBox"
	case "AddInboxRow":
		ui.focus = .Inbox
		ui.settings_target_focus = "InboxBox"
	case "AddFetchRow":
		ui.focus = .Fetch
		ui.settings_target_focus = "FetchBox"
	case "NetworkProxyGroup":
		ui.settings_target_focus = "TgSocks5"
	case "RowLaunch":
		ui.settings_target_focus = "TgLaunch"
	case "RowTray":
		ui.settings_target_focus = "TgTray"
	case "RowMinTray":
		ui.settings_target_focus = "TgMinTray"
	case "RowRestore":
		ui.settings_target_focus = "TgRestore"
	case "RowDevMode":
		ui.settings_target_focus = "TgDevMode"
	case "RowCentered":
		ui.settings_target_focus = "TgCentered"
	case "RowEmojiSet":
		ui.settings_target_focus = "EmojiSetChip0"
	case "RowAvatarShape":
		ui.settings_target_focus = "AvatarShapeChip0"
	case "RowCropShape":
		ui.settings_target_focus = "CropShapeChip0"
	case "RowScroll":
		ui.settings_target_focus = "ScrollChip0"
	case "RowMessageLines":
		ui.settings_target_focus = "MessageLinesMinus"
	case "RowThemeShare":
		ui.settings_target_focus = "ThemeShareBtn"
	case "SettingsSupport":
		ui.settings_target_focus = "SupportChat"
	case "RowShortcuts":
		ui.settings_target_focus = "ShortcutsView"
	case "RowLang":
		ui.settings_target_focus = "LangChange"
	case "RowVaultPw":
		ui.settings_target_focus = "VaultPwBtn"
	case "NpubRow":
		ui.settings_target_focus = "SettingsCopyNpub"
	case "RowStt":
		ui.settings_target_focus = "TgStt"
	case "RowTts":
		ui.settings_target_focus = "TgTts"
	case "RowTranslation":
		ui.settings_target_focus = "TgTranslation"
	case "RowTranslationAuto":
		ui.settings_target_focus = "TgTranslationAuto"
	case "RowTranslationSource":
		ui.settings_target_focus = "TranslationSource"
	case "RowTranslationTarget":
		ui.settings_target_focus = "TranslationTarget"
	case "RowTelemetry":
		ui.settings_target_focus = "TgTelemetry"
	case "RowAudit":
		ui.settings_target_focus = "TgAudit"
	case "RowLinkPreviews":
		ui.settings_target_focus = "TgLinkPreviews"
	case "RowMaps":
		ui.settings_target_focus = "TgMaps"
	case "RowZoom":
		ui.settings_target_focus = "ZoomMinus"
	case "RowBodyFont":
		ui.settings_target_focus = "BodyFontChip0"
	case "RowTheme":
		ui.settings_target_focus = "BrowseThemes"
	case "RowMotion":
		ui.settings_target_focus = "Motion0"
	case "RowContrast":
		ui.settings_target_focus = "Contrast0"
	case "RowNotify":
		ui.settings_target_focus = "TgNotify"
	case "RowSound":
		ui.settings_target_focus = ui.prefs.notify_desktop ? "TgSound" : "TgNotify"
	case "RowPreview":
		ui.settings_target_focus = ui.prefs.notify_desktop ? "TgPreview" : "TgNotify"
	case "RowNotifyTest":
		ui.settings_target_focus = notify_test_enabled(ui) ? "NotifyTest" : "TgNotify"
	case "RowUiSounds":
		ui.settings_target_focus = "TgUiSounds"
	}
}

@(private)
settings_nav_target :: proc(id: string) -> Maybe(Settings_Section) {
	for section in Settings_Section {
		if section >= .Appearance &&
		   section <= .Help &&
		   SETTINGS_SECTIONS[section] == id {return section}
	}
	return nil
}

@(private)
settings_nav_focus :: proc(ui: ^Ui_State, id: string) -> bool {
	switch id {
	case "SettingsSearchBox":
		ui.focus = .SettingsSearch
		return true
	case "SettingsBack", "SettingsExit":
		return true
	}
	if category, ok := settings_nav_target(id).?; ok {
		owner := settings_wide() ? "SettingsTaskPane" : "SettingsPage"
		scroll_into_view(nendo.id(owner), nendo.id("SettingsNav", u32(category)))
		return true
	}
	return false
}

@(private)
settings_nav_action :: proc(ui: ^Ui_State, client: ^marmot.Client, id: string) -> bool {
	switch id {
	case "SettingsBack":
		settings_back(ui)
		return true
	case "SettingsExit":
		settings_leave(ui)
		return true
	}
	if category, ok := settings_nav_target(id).?; ok {
		if category != ui.settings_section {settings_open(ui, client, category)}
		kb_focus = id
		return true
	}
	return false
}

@(private)
settings_reveal_result :: proc(ui: ^Ui_State) {
	if ui.settings_result == 0 {return}
	owner := settings_wide() ? "SettingsTaskPane" : "SettingsPage"
	scroll_into_view(nendo.id(owner), nendo.id("SettingsTask", u32(ui.settings_result - 1)))
}

@(private)
settings_handle_navigation :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	if ui.page != .Settings {return false}
	if ui.settings_section == .Connection {network_sync_event_client(ui)}
	show_results := settings_query(ui) != "" && (settings_wide() || settings_index(ui))
	if ui.focus == .SettingsSearch && show_results {
		step := 0
		if rl.IsKeyPressed(.DOWN) {step = 1}
		if rl.IsKeyPressed(.UP) {step = -1}
		if step != 0 || rl.IsKeyPressed(.ENTER) {
			matches: [len(SETTINGS_TASKS)]int
			results := settings_results(ui, matches[:])
			if len(results) > 0 {
				at := step >= 0 ? 0 : len(results) - 1
				for index, i in results {
					if ui.settings_result == index + 1 {at = (i + step) %% len(results); break}
				}
				index := results[at]
				if step == 0 {settings_open_result(ui, client, index); return true}
				ui.settings_result = index + 1
				settings_reveal_result(ui)
				return true
			}
		}
	}
	if !mouse_released() {return false}
	for id in ([]string{"SettingsBack", "SettingsExit"}) {
		if clicked(id) {return settings_nav_action(ui, client, id)}
	}
	if clicked("SettingsSearchClear") {
		clear(&ui.settings_search)
		settings_reset_results(ui)
		kb_focus = "SettingsSearchBox"
		ui.focus = .SettingsSearch
		return true
	}
	if show_results {
		matches: [len(SETTINGS_TASKS)]int
		for i in settings_results(ui, matches[:]) {
			if nendo.pointer_over(nendo.id("SettingsTask", u32(i))) {
				settings_open_result(ui, client, i)
				return true
			}
		}
	}
	return settings_category_click(ui, client)
}

@(private)
settings_category_click :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	if !mouse_released() {return false}
	for target in Settings_Section {
		if nendo.pointer_over(nendo.id("SettingsNav", u32(target))) {
			if target != ui.settings_section {
				if ui.settings_section == .Connection {network_sync_event_client(ui)}
				settings_open(ui, client, target)
			}
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
	container := nendo.id("SettingsPage")
	data := nendo.scroll(container)
	page := nendo.element(container)
	if !data.found || !page.found {return false}
	target: f32
	if ui.settings_anchor != "" && !settings_index(ui) {
		anchor := nendo.element(nendo.id(ui.settings_anchor))
		if anchor.found {
			inset := min(f32(40), max(0, page.rect.height - anchor.rect.height))
			target = data.position.y - (anchor.rect.y - page.rect.y - inset)
		}
	} else if !settings_wide() && settings_index(ui) && ui.settings_result > 0 {
		row := nendo.element(nendo.id("SettingsTask", u32(ui.settings_result - 1)))
		if row.found {target = data.position.y - (row.rect.y - page.rect.y - 12)}
	} else if ui.settings_section == .Home && !settings_wide() && kb_focus != "" {
		for category in Settings_Section {
			if SETTINGS_SECTIONS[category] != kb_focus {continue}
			row := nendo.element(nendo.id("SettingsNav", u32(category)))
			if row.found {
				bottom := row.rect.y - data.position.y + row.rect.height
				target = min(0, page.rect.y + page.rect.height - 12 - bottom)
			}
			break
		}
	}
	overflow := max(0, data.content.height - data.viewport.height)
	data.position.y = clamp(target, -overflow, 0)
	if !settings_index(ui) &&
	   ui.settings_anchor == "TranslationLanguageList" &&
	   ui.translation.language_menu != 0 {
		scroll_into_view(
			nendo.id("TranslationLanguageList"),
			nendo.id(fmt.tprintf("TranslationLanguage%d", ui.translation.language_choice)),
		)
	}
	if ui.settings_target_focus != "" {
		kb_focus = ui.settings_target_focus
		ui.settings_target_focus = ""
	}
	ui.settings_scroll_pending = false
	return true
}

@(private)
settings_flash_id: string
@(private)
settings_flash_until: f64

// An outline identifies the setting a search result or task link opened.
@(private)
settings_link_flash :: proc(ui: ^Ui_State) {
	if settings_flash_id == "" {return}
	flashing := rl.GetTime() < settings_flash_until
	if !flashing &&
	   kb_focus != settings_flash_id &&
	   ui.settings_search_return != ui.settings_section {return}
	anchor := nendo.element(nendo.id(settings_flash_id))
	if !anchor.found {return}
	if flashing {anim_moving += 1}
	if nendo.box(nendo.id("SettingsLinkFlash"))(
	{
		width = nendo.fixed(anchor.rect.width),
		height = nendo.fixed(anchor.rect.height),
		floating = {
			attach_to = .Element,
			parent = nendo.id(settings_flash_id).id,
			clip_to = .Parent,
			pointer = .Passthrough,
			z = settings_float_z(ui, 4),
		},
		color = flashing ? fade(ACCENT, 0.12) : {},
		border = {color = ACCENT, width = bw()},
		radius = rr(4),
	},
	) {}
}
