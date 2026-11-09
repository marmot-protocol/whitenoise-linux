package main

import "core:fmt"
import "core:strings"

import marmot "../marmot"
import "nendo"
import rl "sdlrl"

// A task names one control. Search finds it, and every link to it opens the
// property sheet and scrolls the control into view; links never toggle a
// preference themselves.
@(private)
Settings_Task :: struct {
	section:  Settings_Section,
	label:    string,
	anchor:   string,
	keywords: string,
	featured: bool, // listed under "Pick a task..." on its category menu
}

@(private)
SETTINGS_TASKS := []Settings_Task {
	{
		.Agents,
		N_("Connect an AI agent"),
		"AgentConnectors",
		"hermes openclaw opencode codex claude code installation setup npub",
		true,
	},
	{.Appearance, N_("Change the theme"), "RowTheme", "appearance colors look", true},
	{.Appearance, N_("Change the message text size"), "RowBodyFont", "font accessibility", true},
	{.Appearance, N_("Choose an emoji style"), "RowEmojiSet", "noto twemoji openmoji look", true},
	{.Appearance, N_("Zoom the interface"), "RowZoom", "scale size accessibility", true},
	{.Appearance, N_("Choose the default avatar shape"), "RowAvatarShape", "photo picture", true},
	{
		.Appearance,
		N_("Choose the crop circle shape"),
		"RowCropShape",
		"identity fingerprint avatar",
		false,
	},
	{.Appearance, N_("Change the scroll speed"), "RowScroll", "mouse wheel", false},
	{.Appearance, N_("Reduce motion"), "RowMotion", "animation accessibility", false},
	{
		.Appearance,
		N_("Center the conversation"),
		"RowCentered",
		"layout width center centre centered centred",
		false,
	},
	{
		.Appearance,
		N_("Message line limit"),
		"RowMessageLines",
		"read more collapse expand event cards lines threshold",
		false,
	},
	{.Appearance, N_("Share this theme"), "RowThemeShare", "edit custom theme", false},
	{.General, N_("Change the interface language"), "RowLang", "locale translation", true},
	{
		.General,
		N_("Translate messages on your device"),
		"RowTranslation",
		"translation local offline gemma model download privacy",
		true,
	},
	{
		.General,
		N_("Translate received messages automatically"),
		"RowTranslationAuto",
		"translation automatic incoming language",
		false,
	},
	{
		.General,
		N_("Choose a translation source language"),
		"RowTranslationSource",
		"translation detect automatic from",
		false,
	},
	{
		.General,
		N_("Choose a translation target language"),
		"RowTranslationTarget",
		"translation into output",
		false,
	},
	{.General, N_("Launch at login"), "RowLaunch", "startup autostart", true},
	{.General, N_("Change the time format"), "RowTimeFmt", "clock 12 24 hour", true},
	{.General, N_("Choose one-tap reactions"), "RowQuick", "emoji messaging quick", true},
	{.General, N_("View keyboard shortcuts"), "RowShortcuts", "keys hotkeys", true},
	{.General, N_("Start minimized to tray"), "RowTray", "startup background", false},
	{.General, N_("Close to tray"), "RowMinTray", "window background", false},
	{.General, N_("Restore the last chat on launch"), "RowRestore", "startup conversation", false},
	{.General, N_("Change the date format"), "RowDateFmt", "calendar", false},
	{.General, N_("Upload custom emoji"), "RowEmoji", "emoji messaging", false},
	{.General, N_("Change your GM"), "RowGm", "good morning greeting daily", false},
	{
		.Folders,
		N_("Organize your folders"),
		"SettingsFolderActions",
		"chats create rename order delete drag rules",
		true,
	},
	{
		.Notifications,
		N_("Get message notifications"),
		"RowNotify",
		"alerts incoming messages",
		true,
	},
	{.Notifications, N_("Play a sound for new messages"), "RowSound", "audio notifications", true},
	{
		.Notifications,
		N_("Show or hide message previews"),
		"RowPreview",
		"privacy notifications",
		true,
	},
	{
		.Notifications,
		N_("Send a test notification"),
		"RowNotifyTest",
		"audio sound desktop alert",
		true,
	},
	{.Notifications, N_("Play interface sounds"), "RowUiSounds", "audio sent received", false},
	{
		.Speech,
		N_("Dictate your messages"),
		"RowStt",
		"speech to text microphone transcribe model",
		true,
	},
	{.Speech, N_("Have messages read aloud"), "RowTts", "voice audio text to speech model", true},
	{
		.Network,
		N_("Choose where you publish"),
		"AddRelayRow",
		"outbox relays nip65 nostr connection",
		true,
	},
	{
		.Network,
		N_("Choose where people reach you"),
		"AddInboxRow",
		"inbox relays receive messages nostr",
		true,
	},
	{
		.Network,
		N_("Add relays for linked events"),
		"AddFetchRow",
		"fetch links nevent nostr",
		true,
	},
	{.Network, N_("Republish your relay lists"), "RowRepublish", "sync nostr", true},
	{
		.Network,
		N_("Configure a SOCKS5 proxy"),
		"NetworkProxyGroup",
		"proxy socks socks5 tor privacy network connection",
		true,
	},
	{.Network, N_("Choose where events open"), "ClientBox", "web client browser links", false},
	{
		.Network,
		N_("Choose where git patches open"),
		"NetworkGitClientGroup",
		"ngit committish gitworkshop nostrhub patch web client links",
		false,
	},
	{.Keys, N_("Copy your public key"), "NpubRow", "identity npub", true},
	{.Keys, N_("Publish a key package"), "KpStatus", "mls invite identity", true},
	{.Keys, N_("Change your vault password"), "RowVaultPw", "security encryption secret", true},
	{.Keys, N_("Reveal your secret key"), "RowReveal", "nsec export security", true},
	{.Storage, N_("Clear cached attachments"), "RowCache", "media space disk", true},
	{.Storage, N_("Back up local data"), "RowBackup", "export data encrypted", true},
	{.Storage, N_("Import a backup"), "RowImport", "restore data encrypted", true},
	{
		.Storage,
		N_("See where your data is stored"),
		"RowLocation",
		"data folder disk location",
		false,
	},
	{.Advanced, N_("Share usage and diagnostics"), "RowTelemetry", "privacy telemetry", true},
	{.Advanced, N_("Record audit logs"), "RowAudit", "privacy security files", true},
	{.Advanced, N_("Turn on developer mode"), "RowDevMode", "debug tools", true},
	{.Advanced, N_("Choose the renderer"), "RowRenderer", "vulkan opengl cpu gpu graphics", true},
	{.About, N_("About White Noise"), "", "version license credits", true},
	{
		.Debug,
		N_("Inspect the current session"),
		"DbgTabs",
		"debug diagnostics state events timings",
		true,
	},
	{.KP, N_("Inspect key packages"), "KpMineRow", "kp mls decode", true},
}

// The "See also" box: a few related settings in other categories, chosen
// for each page rather than listing every category again.
@(private)
SETTINGS_SEE_ALSO := [Settings_Section][]Settings_Task {
	.Home          = []Settings_Task {
		{.About, N_("About White Noise"), "", "", false},
		{.General, N_("View keyboard shortcuts"), "RowShortcuts", "", false},
	},
	.Appearance    = []Settings_Task {
		{.General, N_("Change the interface language"), "RowLang", "", false},
		{.Notifications, N_("Play interface sounds"), "RowUiSounds", "", false},
		{.Speech, N_("Have messages read aloud"), "RowTts", "", false},
	},
	.General       = []Settings_Task {
		{.Appearance, N_("Zoom the interface"), "RowZoom", "", false},
		{.Notifications, N_("Get message notifications"), "RowNotify", "", false},
		{.Folders, N_("Organize your folders"), "SettingsFolderActions", "", false},
	},
	.Folders       = []Settings_Task {
		{.General, N_("Restore the last chat on launch"), "RowRestore", "", false},
	},
	.Notifications = []Settings_Task {
		{.Speech, N_("Have messages read aloud"), "RowTts", "", false},
		{.General, N_("Start minimized to tray"), "RowTray", "", false},
		{.Appearance, N_("Reduce motion"), "RowMotion", "", false},
	},
	.Speech        = []Settings_Task {
		{.Notifications, N_("Play a sound for new messages"), "RowSound", "", false},
		{.General, N_("Change the interface language"), "RowLang", "", false},
	},
	.Network       = []Settings_Task {
		{.Keys, N_("Publish a key package"), "KpStatus", "", false},
		{.Keys, N_("Copy your public key"), "NpubRow", "", false},
		{.Advanced, N_("Record audit logs"), "RowAudit", "", false},
	},
	.Keys          = []Settings_Task {
		{.Storage, N_("Back up local data"), "RowBackup", "", false},
		{.Network, N_("Choose where people reach you"), "AddInboxRow", "", false},
	},
	.Storage       = []Settings_Task {
		{.Keys, N_("Change your vault password"), "RowVaultPw", "", false},
		{.Advanced, N_("Record audit logs"), "RowAudit", "", false},
	},
	.Advanced      = []Settings_Task {
		{.Storage, N_("See where your data is stored"), "RowLocation", "", false},
		{.Network, N_("Republish your relay lists"), "RowRepublish", "", false},
	},
	.About         = []Settings_Task {
		{.Advanced, N_("Share usage and diagnostics"), "RowTelemetry", "", false},
	},
	.Debug         = []Settings_Task{{.Advanced, N_("Record audit logs"), "RowAudit", "", false}},
	.KP            = []Settings_Task{{.Keys, N_("Publish a key package"), "KpStatus", "", false}},
	.Agents        = []Settings_Task {
		{.Keys, N_("Copy your public key"), "NpubRow", "", false},
		{.Network, N_("Choose where people reach you"), "AddInboxRow", "", false},
	},
}

// The "Troubleshooters" box: a symptom in the user's words, linked to the
// control that diagnoses or fixes it. Pages without a common failure have none.
@(private)
SETTINGS_TROUBLESHOOTERS := #partial [Settings_Section][]Settings_Task {
	.Home          = []Settings_Task {
		{.Network, N_("Messages aren't arriving"), "RowNetStatus", "", false},
		{.Keys, N_("People can't invite you"), "KpStatus", "", false},
		{.Notifications, N_("Notifications don't appear"), "RowNotifyTest", "", false},
	},
	.Appearance    = []Settings_Task {
		{.Appearance, N_("Text is hard to read"), "RowBodyFont", "", false},
		{.Appearance, N_("Animations are distracting"), "RowMotion", "", false},
	},
	.General       = []Settings_Task {
		{.General, N_("White Noise doesn't open at login"), "RowLaunch", "", false},
	},
	.Notifications = []Settings_Task {
		{.Notifications, N_("Notifications don't appear"), "RowNotifyTest", "", false},
		{.Notifications, N_("Sounds don't play"), "RowSound", "", false},
	},
	.Speech        = []Settings_Task {
		{.Speech, N_("Dictation doesn't work"), "RowStt", "", false},
		{.Speech, N_("Nothing is read aloud"), "RowTts", "", false},
	},
	.Network       = []Settings_Task {
		{.Network, N_("Messages aren't arriving"), "RowNetStatus", "", false},
		{.Network, N_("Peers can't find you"), "RowRepublish", "", false},
	},
	.Keys          = []Settings_Task {
		{.Keys, N_("People can't invite you"), "KpStatus", "", false},
	},
	.Storage       = []Settings_Task {
		{.Storage, N_("Your disk is filling up"), "RowCache", "", false},
	},
	.Advanced      = []Settings_Task {
		{.Advanced, N_("Collecting logs for a bug report"), "RowAudit", "", false},
	},
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
	.Agents        = N_("Setup prompts for connecting an AI agent to White Noise."),
}

// How a pane link is marked: the target category's art, or a help mark.
@(private)
Settings_Mark :: enum {
	Art,
	Help,
}

@(private)
settings_available :: proc(ui: ^Ui_State, section: Settings_Section) -> bool {
	return (section != .Debug && section != .KP) || ui.prefs.dev_mode
}

@(private)
settings_task_matches :: proc(ui: ^Ui_State, task: Settings_Task, query: string) -> bool {
	when !TRANSLATION_AVAILABLE {
		if strings.has_prefix(task.anchor, "RowTranslation") {return false}
	}
	when ODIN_OS == .OpenBSD {
		if task.anchor == "RowLaunch" {
			return false
		}
	}
	if !settings_available(ui, task.section) {return false}
	if tap_size() && settings_desktop_only(task.anchor) {return false}
	if query == "" {return true}
	text := fmt.tprintf(
		"%s %s %s %s %s",
		tr(task.label),
		task.label,
		tr(SETTINGS_SECTIONS[task.section].label),
		SETTINGS_SECTIONS[task.section].label,
		task.keywords,
	)
	if task.anchor == "RowTheme" {
		names := strings.builder_make(context.temp_allocator)
		strings.write_string(&names, text)
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

// Folders, About and the developer pages hold a single task, and
// Notifications a single page, so they open straight onto their sheet
// instead of a menu that offers no choice.
@(private)
settings_has_menu :: proc(section: Settings_Section) -> bool {
	if section == .Home || section == .Appearance || section == .Speech {return false}
	if len(settings_tabs(section)) <= 1 {return false}
	count := 0
	for task in SETTINGS_TASKS {
		if task.section == section {count += 1}
	}
	return count > 1
}

@(private)
settings_on_menu :: proc(ui: ^Ui_State) -> bool {
	return ui.settings_level == .Menu && settings_has_menu(ui.settings_section)
}

// Control panel layout. Every level shares the task pane on the
// left; the right side is the category grid, a category menu, or a sheet.
//
//   home               category menu              property sheet
//   +------+--------+  +------+---------------+  +------+-------------+
//   |Search| Pick a |  |Search| [art] Network |  |Search| [art] Network|
//   |      | category  |< All |---------------|  |< Net |-------------|
//   |See   | [] []  |  |See   | Pick a task...|  |See   | [tab][tab]  |
//   |also  | [] []  |  |also  |  -> Choose ...|  |also  | sheet       |
//   |Trbl  |        |  |Trbl  | or pick a page|  |Trbl  |             |
//   +------+--------+  +------+  [icon] [icon]|  +------+-------------+
//
// Narrow windows put the search box above the page and the related boxes
// below it, inside the page's scroll.
@(private)
settings_nav_box :: proc(ui: ^Ui_State) {
	section := ui.settings_section
	if nendo.box(nendo.id("SettingsBoxMain"))(settings_pane_box()) {
		// A phone already says Settings in its nav bar; the strip only costs height.
		if !single_pane() {settings_pane_head(Settings_Art.Home, tr("SETTINGS"))}
		if nendo.box(nendo.id("SettingsBoxMainBody"))(settings_pane_body()) {
			if nendo.box(nendo.id("SettingsSearchBox"))(
			{
				width = nendo.grow(),
				height = nendo.fixed(settings_tap_size(30)),
				padding = {left = 8, right = 8},
				gap = 7,
				align = {y = .Center},
				color = ROW_BG,
				radius = rr(3),
				border = {
					color = ui.focus == .SettingsSearch ? ACCENT : FIELD_BORDER,
					width = bw(),
				},
			},
			) {
				nendo.text(ICON_SEARCH, {font = FONT_ICON, size = 12, color = TEXT_DIM})
				field_text(
					ui,
					"SettingsSearchBox",
					&ui.settings_search,
					tr("Find a setting..."),
					ui.focus == .SettingsSearch,
					12,
					TEXT_DIM,
				)
				// Clearing sits inside the box so typing never moves the page.
				if len(ui.settings_search) > 0 {
					if nendo.box(nendo.id("SettingsSearchClear"))(
					{
						width = nendo.fixed(settings_tap_size(22)),
						height = nendo.fixed(settings_tap_size(22)),
						align = {x = .Center, y = .Center},
						color = hovered() ? HOVER : {},
						radius = rr(3),
					},
					) {
						if hovered() {tooltip(tr("Clear search"))}
						nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 12, color = TEXT_DIM})
					}
				}
			}
			if section != .Home && !settings_on_menu(ui) && settings_has_menu(section) {
				settings_pane_link(
					nendo.id("SettingsMenu"),
					.Art,
					SECTION_ART[section],
					tr(SETTINGS_SECTIONS[section].label),
				)
			}
			if section != .Home {
				settings_pane_link(nendo.id("SettingsHome"), .Art, .Home, tr("All categories"))
			}
		}
	}
}

@(private)
settings_related_boxes :: proc(ui: ^Ui_State) {
	section := ui.settings_section
	settings_link_box(ui, "SettingsSeeAlso", tr("SEE ALSO"), SETTINGS_SEE_ALSO[section], .Art)
	settings_link_box(
		ui,
		"SettingsTrouble",
		tr("TROUBLESHOOTERS"),
		SETTINGS_TROUBLESHOOTERS[section],
		.Help,
	)

	// Developer pages stay out of everyone else's way: shown only in
	// developer mode, and only beside home and the developer settings.
	if !ui.prefs.dev_mode {return}
	if section != .Home && section != .Advanced && section != .Debug && section != .KP {return}
	if nendo.box(nendo.id("SettingsDevBox"))(settings_pane_box()) {
		settings_pane_head(Settings_Art.Advanced, tr("DEVELOPER TOOLS"))
		if nendo.box(nendo.id("SettingsDevBody"))(settings_pane_body()) {
			for dev in ([2]Settings_Section{.Debug, .KP}) {
				if dev == section {continue}
				settings_pane_link(
					nendo.id("SettingsNav", u32(dev)),
					.Art,
					SECTION_ART[dev],
					tr(SETTINGS_SECTIONS[dev].label),
				)
			}
		}
	}
}

// A titled box of task links; hidden when none apply on this platform or mode.
@(private)
settings_link_box :: proc(
	ui: ^Ui_State,
	id: string,
	title: string,
	links: []Settings_Task,
	mark: Settings_Mark,
) {
	shown := 0
	for link in links {
		if settings_task_matches(ui, link, "") {shown += 1}
	}
	if shown == 0 {return}
	if nendo.box(nendo.id(fmt.tprintf("%sBox", id)))(settings_pane_box()) {
		settings_pane_head(nil, title)
		if nendo.box(nendo.id_local("Body"))(settings_pane_body()) {
			for link, i in links {
				if !settings_task_matches(ui, link, "") {continue}
				settings_pane_link(
					nendo.id(id, u32(i)),
					mark,
					SECTION_ART[link.section],
					tr(link.label),
				)
			}
		}
	}
}

// One task-pane box: a light title strip over a tinted body.
@(private)
settings_pane_box :: proc() -> nendo.Box {
	return {
		width = nendo.grow(),
		direction = .Column,
		color = CARD,
		radius = {top_left = 5 * R_SCALE, top_right = 5 * R_SCALE},
		border = {color = CARD_BORDER, width = bw()},
	}
}

@(private)
settings_pane_body :: proc() -> nendo.Box {
	return {
		width = nendo.grow(),
		direction = .Column,
		padding = {left = 10, right = 10, top = 10, bottom = 10},
		gap = 6,
	}
}

@(private)
settings_pane_head :: proc(art: Maybe(Settings_Art), title: string) {
	if nendo.box(nendo.id_local("Head"))(
	{
		width = nendo.grow(),
		height = nendo.fixed(30),
		padding = {left = 10, right = 10},
		gap = 8,
		align = {y = .Center},
		color = ROW_BG,
		radius = {top_left = 5 * R_SCALE, top_right = 5 * R_SCALE},
		border = {color = DIVIDER, width = {bottom = 1}},
	},
	) {
		// Keyed by art: Home and Developer tools heads can share a frame.
		if which, ok := art.?; ok {
			settings_illustration(fmt.tprintf("SettingsPaneArt%d", int(which)), which, 22)
		}
		// Box captions follow the eyebrow rung of the casing ladder.
		nendo.text(title, {font = FONT_TITLE, size = 12, color = TEXT, spacing = 1})
	}
}

@(private)
settings_pane_link :: proc(id: nendo.Id, mark: Settings_Mark, art: Settings_Art, label: string) {
	gallery :=
		g_ui != nil &&
		g_ui.settings_section == .Appearance &&
		!settings_on_menu(g_ui) &&
		g_ui.settings_tab == 0
	if nendo.box(id)(
	{
		width = nendo.grow(),
		height = nendo.fit(min = settings_tap_size(24)),
		padding = {top = 2, bottom = 2},
		gap = 8,
		align = {y = .Center},
	},
	) {
		switch mark {
		case .Art:
			settings_illustration(fmt.tprintf("SettingsLinkArt%d", id.id), art, 20)
		case .Help:
			if nendo.box(nendo.id_local("Help"))(
			{
				width = nendo.fixed(20),
				height = nendo.fixed(20),
				align = {x = .Center, y = .Center},
			},
			) {
				nendo.text(ICON_QUESTION, {font = FONT_ICON, size = 15, color = ACCENT})
			}
		}
		nendo.text(
			label,
			{
				font = gallery ? gallery_font(g_ui, FONT_GALLERY_TITLE) : FONT_BODY,
				size = 12,
				color = hovered() ? ACCENT : TEXT_DIM,
			},
		)
	}
}

// Faded headline over each block of choices, like "Pick a category".
@(private)
settings_pick_heading :: proc(text: string) {
	if nendo.box(nendo.id_local(text))({padding = {top = 6, bottom = 14}}) {
		nendo.text(text, {font = FONT_TITLE, size = 28, color = TEXT_LO})
	}
}

// The category banner: the category art and name on an accent strip,
// over both the category menu and its sheet.
@(private)
settings_banner :: proc(ui: ^Ui_State) {
	section := ui.settings_section
	gallery := section == .Appearance && !settings_on_menu(ui) && ui.settings_tab == 0
	phone := single_pane()
	if nendo.box(nendo.id("SettingsHead"))(
	{
		width = nendo.grow(),
		padding = {left = phone ? 0 : 24, right = 24, top = phone ? 3 : 8, bottom = phone ? 3 : 8},
		gap = phone ? 6 : 12,
		align = {y = .Center},
		color = ACCENT,
		user_data = rawptr(TITLE_BAND),
	},
	) {
		// Phones go back from the banner itself instead of a separate bar
		// above it; the shell's PhoneBack handler runs it.
		if phone {if nendo.box(nendo.id("PhoneBack"))({width = nendo.fixed(44), height = nendo.fixed(44), align = {x = .Center, y = .Center}}) {
				nendo.text("\uf053", {font = FONT_ICON, size = 18, color = ON_ACCENT})
				if hovered() {cursor_raise(.Pointer); tooltip(tr("Back"))}
			}}
		settings_illustration("SettingsHeadArt", SECTION_ART[section], 34)
		if nendo.box(nendo.id("SettingsHeadCol"))(
		{width = nendo.grow(), direction = .Column, gap = 2},
		) {
			nendo.text(
				tr(SETTINGS_SECTIONS[section].label),
				{
					font = gallery ? gallery_font(ui, FONT_GALLERY_BOLD) : FONT_TITLE,
					size = 16,
					color = ON_ACCENT,
				},
			)
			nendo.text(
				tr(settings_description(section)),
				{
					font = gallery ? gallery_font(ui, FONT_GALLERY_TITLE) : FONT_BODY,
					size = 11,
					color = ON_ACCENT,
				},
			)
		}
	}
}

// The category's front page, "Pick a task... or pick a page": its common
// tasks as arrow links, then one icon per sheet page.
@(private)
settings_category_menu :: proc(ui: ^Ui_State) {
	section := ui.settings_section
	settings_pick_heading(tr("Pick a task..."))
	if nendo.box(nendo.id("SettingsTaskList"))(
	{width = nendo.grow(), direction = .Column, padding = {left = 8, bottom = 24}, gap = 6},
	) {
		for task, i in SETTINGS_TASKS {
			if task.section != section ||
			   !task.featured ||
			   !settings_task_matches(ui, task, "") {continue}
			if nendo.box(nendo.id("SettingsTask", u32(i)))(
			{
				width = nendo.grow(),
				height = nendo.fit(min = settings_tap_size(26)),
				padding = {top = 4, bottom = 4},
				gap = 10,
				align = {y = .Center},
			},
			) {
				if nendo.box(nendo.id_local("Arrow"))(
				{
					width = nendo.fixed(18),
					height = nendo.fixed(18),
					align = {x = .Center, y = .Center},
					color = ACCENT,
					radius = rr(3),
				},
				) {
					nendo.text(ICON_RIGHT, {font = FONT_ICON, size = 11, color = ON_ACCENT})
				}
				nendo.text(
					tr(task.label),
					{font = FONT_TITLE, size = 14, color = hovered() ? ACCENT : TEXT},
				)
			}
		}
	}

	settings_pick_heading(tr("or pick a page"))
	single := [1]Settings_Page{{SETTINGS_SECTIONS[section].label, SECTION_ART[section]}}
	pages := settings_tabs(section)
	if len(pages) == 0 {pages = single[:]}
	columns := settings_body_width(ui) >= 480 ? 2 : 1
	rows := (len(pages) + columns - 1) / columns
	if nendo.box(nendo.id("SettingsPageIcons"))(
	{width = nendo.grow(), padding = {left = 8}, gap = 24},
	) {
		for col in 0 ..< columns {
			if nendo.box(nendo.id("SettingsPageCol", u32(col)))(
			{width = nendo.grow(), direction = .Column, gap = 10},
			) {
				for row in 0 ..< rows {
					at := row * columns + col
					if at >= len(pages) {break}
					if nendo.box(nendo.id("SettingsPageIcon", u32(at)))(
					{
						width = nendo.grow(),
						padding = {top = 4, bottom = 4},
						gap = 12,
						align = {y = .Center},
					},
					) {
						settings_illustration(
							fmt.tprintf("SettingsPageArt%d", at),
							pages[at].art,
							40,
						)
						nendo.text(
							tr(pages[at].label),
							{font = FONT_TITLE, size = 14, color = hovered() ? ACCENT : TEXT},
						)
					}
				}
			}
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
		settings_pick_heading(tr("Search results"))
		count := 0
		for task, i in SETTINGS_TASKS {
			if !settings_task_matches(ui, task, query) {continue}
			count += 1
			if nendo.box(nendo.id("SettingsTask", u32(i)))(
			{
				width = nendo.grow(),
				padding = {top = 12, bottom = 12, left = 10, right = 10},
				gap = 12,
				align = {y = .Center},
				color = hovered() ? HOVER : {},
				border = {color = DIVIDER, width = {bottom = 1}},
			},
			) {
				settings_illustration(
					fmt.tprintf("SettingsResultArt%d", i),
					SECTION_ART[task.section],
					36,
				)
				if nendo.box(nendo.id("SettingsResultText", u32(i)))(
				{width = nendo.grow(), direction = .Column, gap = 4},
				) {
					nendo.text(tr(task.label), {font = FONT_TITLE, size = 14, color = TEXT})
					nendo.text(
						tr(SETTINGS_SECTIONS[task.section].label),
						{font = FONT_BODY, size = 12, color = TEXT_DIM},
					)
				}
				nendo.text("›", {font = FONT_TITLE, size = 18, color = ACCENT})
			}
		}
		if count == 0 {
			nendo.text(tr("No matching settings."), {font = FONT_TITLE, size = 16, color = TEXT})
			nendo.text(
				tr("Try a different search."),
				{font = FONT_BODY, size = 13, color = TEXT_DIM},
			)
		}
		return
	}

	// Icon and name only; the summary moves to a tooltip.
	settings_pick_heading(tr("Pick a category"))
	categories := [10]Settings_Section {
		.Appearance,
		.General,
		.Folders,
		.Notifications,
		.Speech,
		.Network,
		.Keys,
		.Storage,
		.Advanced,
		.Agents,
	}
	columns := settings_main_w(ui) >= 600 ? 2 : 1
	rows := (len(categories) + columns - 1) / columns
	if nendo.box(nendo.id("SettingsCategories"))(
	{width = nendo.grow(), padding = {left = 8}, gap = 24},
	) {
		for col in 0 ..< columns {
			if nendo.box(nendo.id("SettingsCategoryCol", u32(col)))(
			{width = nendo.grow(), direction = .Column, gap = 10},
			) {
				for row in 0 ..< rows {
					at := row * columns + col
					if at >= len(categories) {break}
					section := categories[at]
					if nendo.box(nendo.id("SettingsNav", u32(section)))(
					{
						width = nendo.grow(),
						padding = {top = 6, bottom = 6},
						gap = 14,
						align = {y = .Center},
					},
					) {
						if hovered() {tooltip(tr(SETTINGS_SUMMARIES[section]))}
						settings_illustration(
							fmt.tprintf("SettingsCategoryArt%d", u32(section)),
							SECTION_ART[section],
							48,
						)
						nendo.text(
							tr(SETTINGS_SECTIONS[section].label),
							{font = FONT_TITLE, size = 15, color = hovered() ? ACCENT : TEXT},
						)
					}
				}
			}
		}
	}
}

// Task links, single-task sections and the Appearance workbench open directly;
// other bare categories open on their menu.
@(private)
settings_open :: proc(
	ui: ^Ui_State,
	client: ^marmot.Client,
	section: Settings_Section,
	tab: int = 0,
	anchor: string = "",
	level: Settings_Level = .Menu,
) {
	if !settings_available(ui, section) {return}
	settings_theme_preview_reset(ui)
	ui.translation.language_menu = 0
	ui.agent_connector = 0
	level := level
	if anchor != "" || !settings_has_menu(section) {level = .Sheet}
	target_tab :=
		section == .Appearance ? 0 : (anchor == "" ? tab : settings_target_tab(section, anchor))
	if section != .General || target_tab != 2 {
		ui.emoji_sets_open = false
		ui.emoji_sets_selected = -1
	}
	if section == .Appearance && level == .Sheet && target_tab == 0 && len(theme_packs) > 0 {
		ui.theme_tone = theme_packs[active_theme(ui)].tone
	}
	if section != .Keys ||
	   ui.settings_section != .Keys ||
	   target_tab != ui.settings_tab ||
	   level != ui.settings_level {
		keys_forget(ui)
	}
	ui.page = .Settings
	ui.settings_section = section
	ui.settings_level = level
	ui.settings_tab = target_tab
	ui.settings_anchor = anchor
	ui.settings_scroll_pending = true
	settings_flash_id = anchor
	settings_flash_until = anchor != "" ? rl.GetTime() + 1.5 : 0
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
restore_workspace :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	ui.page = ui.prefs.page
	if ui.page < .Chats || ui.page > max(Page) {ui.page = .Chats}
	ui.settings_section = ui.prefs.settings_section
	ui.settings_tab = ui.prefs.settings_tab
	ui.settings_level = ui.prefs.settings_level
	ui.chat_filter = ui.prefs.chat_filter
	if ui.page == .Settings {
		settings_open(
			ui,
			client,
			ui.settings_section,
			tab = ui.settings_tab,
			level = ui.settings_level,
		)
		return
	}
	if client == nil {return}
	#partial switch ui.page {
	case .Contacts:
		load_contacts(client, ui, .Details)
	case .Archived:
		load_archived(client, ui)
	case .Profile:
		load_profile(client, ui)
	}
}

// Step back one level: sheet -> its category menu -> All categories ->
// the chat list. Sections without a menu go straight to All categories.
@(private)
settings_back :: proc(ui: ^Ui_State) {
	if ui.settings_section == .General && ui.settings_tab == 2 && ui.emoji_sets_open {
		if ui.emoji_sets_selected >= 0 {
			ui.emoji_sets_selected = -1
		} else {
			ui.emoji_sets_open = false
		}
		ui.focus = .Compose
		return
	}
	switch {
	case ui.settings_section == .Agents && ui.agent_connector > 0:
		ui.agent_connector = 0
		kb_focus = ""
		ui.settings_scroll_pending = true
	case ui.settings_section == .Home:
		ui.page = .Chats
	case settings_on_menu(ui) || !settings_has_menu(ui.settings_section):
		settings_open(ui, nil, .Home)
	case:
		settings_open(ui, nil, ui.settings_section)
	}
}

// The settings page's one Escape owner, run after its modals had their
// turn. A focused box lets go first: a relay box keeps its text, the
// search box clears, a staged emoji drops. The next Escape steps back.
@(private)
settings_escape :: proc(ui: ^Ui_State) -> bool {
	if !rl.IsKeyPressed(.ESCAPE) {return false}
	if ui.settings_section == .General &&
	   ui.settings_tab == 1 &&
	   ui.translation.language_menu != 0 {
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
		ui.settings_scroll_pending = true
	case .EmojiName:
		cancel_staged_emoji(ui)
	}
	ui.focus = .Compose
	return true
}

@(private)
settings_search_field :: proc(ui: ^Ui_State) {
	if ui.lang_open || ui.shortcuts_open || ui.export_open {return}
	if field_mouse(ui, &ui.settings_search, "SettingsSearchBox", 12) {ui.focus = .SettingsSearch}
	if ui.focus != .SettingsSearch {return}
	settings_theme_preview_reset(ui)
	before := avatar_hash(string(ui.settings_search[:]))
	edit_text(ui, &ui.settings_search)
	if before != avatar_hash(string(ui.settings_search[:])) {
		// The task pane searches from any page; results live on home.
		if ui.settings_section != .Home {
			keys_forget(ui)
			ui.settings_section = .Home
			ui.settings_tab = 0
		}
		ui.settings_anchor = ""
		ui.settings_scroll_pending = true
	}
}

@(private)
settings_handle_navigation :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	if ui.page != .Settings {return false}
	section := ui.settings_section
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
	if clicked("SettingsHome") || nendo.pointer_over(nendo.id("Nav", u32(Page.Settings))) {
		settings_open(ui, client, .Home)
		return true
	}
	if clicked("SettingsMenu") {
		settings_open(ui, client, section)
		return true
	}
	if clicked("SettingsSearchClear") {
		clear(&ui.settings_search)
		ui.focus = .SettingsSearch
		ui.settings_scroll_pending = true
		return true
	}
	for task, i in SETTINGS_TASKS {
		if nendo.pointer_over(nendo.id("SettingsTask", u32(i))) {
			settings_open(ui, client, task.section, anchor = task.anchor)
			return true
		}
	}
	for link, i in SETTINGS_SEE_ALSO[section] {
		if nendo.pointer_over(nendo.id("SettingsSeeAlso", u32(i))) {
			settings_open(ui, client, link.section, anchor = link.anchor)
			return true
		}
	}
	for link, i in SETTINGS_TROUBLESHOOTERS[section] {
		if nendo.pointer_over(nendo.id("SettingsTrouble", u32(i))) {
			settings_open(ui, client, link.section, anchor = link.anchor)
			return true
		}
	}
	if settings_on_menu(ui) {
		for i in 0 ..< max(1, len(settings_tabs(section))) {
			if nendo.pointer_over(nendo.id("SettingsPageIcon", u32(i))) {
				settings_open(ui, client, section, tab = i, level = .Sheet)
				return true
			}
		}
	}
	for target in Settings_Section {
		if nendo.pointer_over(nendo.id("SettingsNav", u32(target))) {
			settings_open(ui, client, target)
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
	if ui.settings_section == .Appearance && appearance_layout(ui).columns > 1 {
		container = appearance_scroll(ui, nendo.id(ui.settings_anchor))
		for id in ([4]string{"SettingsPage", "AppearanceControls", "AppearanceThemes", "AppearancePreview"}) {
			if nendo.id(id).id == container.id {continue}
			if scroll := nendo.scroll(nendo.id(id)); scroll.found {
				scroll.position^ = {}
			}
		}
	}
	data := nendo.scroll(container)
	page := nendo.element(container)
	if !data.found || !page.found {return false}
	target: f32
	if ui.settings_anchor != "" {
		anchor := nendo.element(nendo.id(ui.settings_anchor))
		if anchor.found {
			inset := min(f32(40), max(0, page.rect.height - anchor.rect.height))
			target = data.position.y - (anchor.rect.y - page.rect.y - inset)
		}
	}
	overflow := max(0, data.content.height - data.viewport.height)
	data.position.y = clamp(target, -overflow, 0)
	if ui.settings_anchor == "TranslationLanguageList" && ui.translation.language_menu != 0 {
		scroll_into_view(
			nendo.id("TranslationLanguageList"),
			nendo.id(fmt.tprintf("TranslationLanguage%d", ui.translation.language_choice)),
		)
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
settings_link_flash :: proc() {
	if settings_flash_id == "" || rl.GetTime() >= settings_flash_until {return}
	anchor := nendo.element(nendo.id(settings_flash_id))
	if !anchor.found {return}
	anim_moving += 1
	if nendo.box(nendo.id("SettingsLinkFlash"))(
	{
		width = nendo.fixed(anchor.rect.width),
		height = nendo.fixed(anchor.rect.height),
		floating = {
			attach_to = .Element,
			parent = nendo.id(settings_flash_id).id,
			clip_to = .Parent,
			pointer = .Passthrough,
			z = 4,
		},
		color = fade(ACCENT, 0.12),
		border = {color = ACCENT, width = bw()},
		radius = rr(4),
	},
	) {}
}
