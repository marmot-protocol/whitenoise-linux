package main

import "core:fmt"
import "core:strings"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
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
	{.Appearance, N_("Centre the conversation"), "RowCentered", "layout width centred", false},
	{
		.Appearance,
		N_("Automatically expand long messages"),
		"RowAutoExpand",
		"read more collapse event cards",
		false,
	},
	{.Appearance, N_("Share this theme"), "RowThemeShare", "edit custom theme", false},
	{.General, N_("Change the interface language"), "RowLang", "locale translation", true},
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
		N_("Get desktop notifications"),
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
	{.Network, N_("Choose where events open"), "ClientBox", "web client browser links", false},
	{.Keys, N_("Copy your public key"), "NpubRow", "identity npub", true},
	{.Keys, N_("Publish a key package"), "KpStatus", "mls invite identity", true},
	{.Keys, N_("Change your vault password"), "RowVaultPw", "security encryption secret", true},
	{.Keys, N_("Reveal your secret key"), "RowReveal", "nsec export security", true},
	{.Storage, N_("Clear cached attachments"), "RowCache", "media space disk", true},
	{.Storage, N_("Back up everything"), "RowBackup", "export data encrypted", true},
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
		{.Notifications, N_("Get desktop notifications"), "RowNotify", "", false},
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
		{.Storage, N_("Back up everything"), "RowBackup", "", false},
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
	when ODIN_OS == .OpenBSD {
		if task.anchor == "RowLaunch" {
			return false
		}
	}
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

// Folders, About and the developer pages hold a single task, so they open
// straight onto their sheet instead of a menu with one entry.
@(private)
settings_has_menu :: proc(section: Settings_Section) -> bool {
	if section == .Home {return false}
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
	if clay.UI(clay.ID("SettingsBoxMain"))(settings_pane_box()) {
		settings_pane_head(Settings_Art.Home, tr("Settings"))
		if clay.UI(clay.ID("SettingsBoxMainBody"))(settings_pane_body()) {
			if clay.UI(clay.ID("SettingsSearchBox"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(30)},
					padding = {left = 8, right = 8},
					childGap = 7,
					childAlignment = {y = .Center},
				},
				backgroundColor = ROW_BG,
				cornerRadius = rr(3),
				border = {
					color = ui.focus == .SettingsSearch ? ACCENT : FIELD_BORDER,
					width = bw(),
				},
			},
			) {
				clay.Text(ICON_SEARCH, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
				field_text(
					ui,
					"SettingsSearchBox",
					&ui.settings_search,
					tr("Find a setting..."),
					ui.focus == .SettingsSearch,
					12,
					TEXT_DIM,
				)
			}
			if len(ui.settings_search) >
			   0 {micro_button("SettingsSearchClear", tr("Clear search"))}
			if section != .Home && !settings_on_menu(ui) && settings_has_menu(section) {
				settings_pane_link(
					clay.ID("SettingsMenu"),
					.Art,
					SECTION_ART[section],
					tr(SETTINGS_SECTIONS[section].label),
				)
			}
			if section != .Home {
				settings_pane_link(clay.ID("SettingsHome"), .Art, .Home, tr("All categories"))
			}
		}
	}
}

@(private)
settings_related_boxes :: proc(ui: ^Ui_State) {
	section := ui.settings_section
	settings_link_box(ui, "SettingsSeeAlso", tr("See also"), SETTINGS_SEE_ALSO[section], .Art)
	settings_link_box(
		ui,
		"SettingsTrouble",
		tr("Troubleshooters"),
		SETTINGS_TROUBLESHOOTERS[section],
		.Help,
	)

	// Developer pages stay out of everyone else's way: shown only in
	// developer mode, and only beside home and the developer settings.
	if !ui.prefs.dev_mode {return}
	if section != .Home && section != .Advanced && section != .Debug && section != .KP {return}
	if clay.UI(clay.ID("SettingsDevBox"))(settings_pane_box()) {
		settings_pane_head(Settings_Art.Advanced, tr("Developer tools"))
		if clay.UI(clay.ID("SettingsDevBody"))(settings_pane_body()) {
			for dev in ([2]Settings_Section{.Debug, .KP}) {
				if dev == section {continue}
				settings_pane_link(
					clay.ID("SettingsNav", u32(dev)),
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
	if clay.UI(clay.ID(fmt.tprintf("%sBox", id)))(settings_pane_box()) {
		settings_pane_head(nil, title)
		if clay.UI(clay.ID_LOCAL("Body"))(settings_pane_body()) {
			for link, i in links {
				if !settings_task_matches(ui, link, "") {continue}
				settings_pane_link(
					clay.ID(id, u32(i)),
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
settings_pane_box :: proc() -> clay.ElementDeclaration {
	return {
		layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom},
		backgroundColor = CARD,
		cornerRadius = {topLeft = 5 * R_SCALE, topRight = 5 * R_SCALE},
		border = {color = CARD_BORDER, width = bw()},
	}
}

@(private)
settings_pane_body :: proc() -> clay.ElementDeclaration {
	return {
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {left = 10, right = 10, top = 10, bottom = 10},
			childGap = 6,
		},
	}
}

@(private)
settings_pane_head :: proc(art: Maybe(Settings_Art), title: string) {
	if clay.UI(clay.ID_LOCAL("Head"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(30)},
			padding = {left = 10, right = 10},
			childGap = 8,
			childAlignment = {y = .Center},
		},
		backgroundColor = ROW_BG,
		cornerRadius = {topLeft = 5 * R_SCALE, topRight = 5 * R_SCALE},
		border = {color = DIVIDER, width = {bottom = 1}},
	},
	) {
		if which, ok := art.?; ok {settings_illustration("SettingsPaneArt", which, 22)}
		clay.Text(title, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
	}
}

@(private)
settings_pane_link :: proc(
	id: clay.ElementId,
	mark: Settings_Mark,
	art: Settings_Art,
	label: string,
) {
	if clay.UI(id)(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {top = 2, bottom = 2},
			childGap = 8,
			childAlignment = {y = .Center},
		},
	},
	) {
		switch mark {
		case .Art:
			settings_illustration(fmt.tprintf("SettingsLinkArt%d", id.id), art, 20)
		case .Help:
			if clay.UI(clay.ID_LOCAL("Help"))(
			{
				layout = {
					sizing = {clay.SizingFixed(20), clay.SizingFixed(20)},
					childAlignment = {x = .Center, y = .Center},
				},
			},
			) {
				clay.Text(ICON_QUESTION, {fontId = FONT_ICON, fontSize = 15, textColor = ACCENT})
			}
		}
		clay.Text(
			label,
			{fontId = FONT_BODY, fontSize = 12, textColor = hovered() ? ACCENT : TEXT_DIM},
		)
	}
}

// Faded headline over each block of choices, like "Pick a category".
@(private)
settings_pick_heading :: proc(text: string) {
	if clay.UI(clay.ID_LOCAL(text))({layout = {padding = {top = 6, bottom = 14}}}) {
		clay.Text(text, {fontId = FONT_TITLE, fontSize = 28, textColor = TEXT_LO})
	}
}

// The category banner: the category art and name on an accent strip,
// over both the category menu and its sheet.
@(private)
settings_banner :: proc(ui: ^Ui_State) {
	section := ui.settings_section
	if clay.UI(clay.ID("SettingsHead"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {left = 24, right = 24, top = 8, bottom = 8},
			childGap = 12,
			childAlignment = {y = .Center},
		},
		backgroundColor = ACCENT,
	},
	) {
		settings_illustration("SettingsHeadArt", SECTION_ART[section], 34)
		if clay.UI(clay.ID("SettingsHeadCol"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				childGap = 2,
			},
		},
		) {
			clay.Text(
				tr(SETTINGS_SECTIONS[section].label),
				{fontId = FONT_TITLE, fontSize = 16, textColor = ON_ACCENT},
			)
			clay.Text(
				tr(settings_description(section)),
				{fontId = FONT_BODY, fontSize = 11, textColor = ON_ACCENT},
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
	if clay.UI(clay.ID("SettingsTaskList"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {left = 8, bottom = 24},
			childGap = 6,
		},
	},
	) {
		for task, i in SETTINGS_TASKS {
			if task.section != section ||
			   !task.featured ||
			   !settings_task_matches(ui, task, "") {continue}
			if clay.UI(clay.ID("SettingsTask", u32(i)))(
			{
				layout = {
					padding = {top = 4, bottom = 4},
					childGap = 10,
					childAlignment = {y = .Center},
				},
			},
			) {
				if clay.UI(clay.ID_LOCAL("Arrow"))(
				{
					layout = {
						sizing = {clay.SizingFixed(18), clay.SizingFixed(18)},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = ACCENT,
					cornerRadius = rr(3),
				},
				) {
					clay.Text(
						ICON_RIGHT,
						{fontId = FONT_ICON, fontSize = 11, textColor = ON_ACCENT},
					)
				}
				clay.Text(
					tr(task.label),
					{fontId = FONT_TITLE, fontSize = 14, textColor = hovered() ? ACCENT : TEXT},
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
	if clay.UI(clay.ID("SettingsPageIcons"))(
	{layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 8}, childGap = 24}},
	) {
		for col in 0 ..< columns {
			if clay.UI(clay.ID("SettingsPageCol", u32(col)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					childGap = 10,
				},
			},
			) {
				for row in 0 ..< rows {
					at := row * columns + col
					if at >= len(pages) {break}
					if clay.UI(clay.ID("SettingsPageIcon", u32(at)))(
					{
						layout = {
							padding = {top = 4, bottom = 4},
							childGap = 12,
							childAlignment = {y = .Center},
						},
					},
					) {
						settings_illustration(
							fmt.tprintf("SettingsPageArt%d", at),
							pages[at].art,
							40,
						)
						clay.Text(
							tr(pages[at].label),
							{
								fontId = FONT_TITLE,
								fontSize = 14,
								textColor = hovered() ? ACCENT : TEXT,
							},
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
				settings_illustration(
					fmt.tprintf("SettingsResultArt%d", i),
					SECTION_ART[task.section],
					36,
				)
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

	// Icon and name only; the summary moves to a tooltip.
	settings_pick_heading(tr("Pick a category"))
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
	columns := settings_main_w(ui) >= 600 ? 2 : 1
	rows := (len(categories) + columns - 1) / columns
	if clay.UI(clay.ID("SettingsCategories"))(
	{layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 8}, childGap = 24}},
	) {
		for col in 0 ..< columns {
			if clay.UI(clay.ID("SettingsCategoryCol", u32(col)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					childGap = 10,
				},
			},
			) {
				for row in 0 ..< rows {
					at := row * columns + col
					if at >= len(categories) {break}
					section := categories[at]
					if clay.UI(clay.ID("SettingsNav", u32(section)))(
					{
						layout = {
							padding = {top = 6, bottom = 6},
							childGap = 14,
							childAlignment = {y = .Center},
						},
					},
					) {
						if hovered() {tooltip(tr(SETTINGS_SUMMARIES[section]))}
						settings_illustration(
							fmt.tprintf("SettingsCategoryArt%d", u32(section)),
							SECTION_ART[section],
							48,
						)
						clay.Text(
							tr(SETTINGS_SECTIONS[section].label),
							{
								fontId = FONT_TITLE,
								fontSize = 15,
								textColor = hovered() ? ACCENT : TEXT,
							},
						)
					}
				}
			}
		}
	}
}

// A task link (anchor set) or a single-task section lands on the sheet;
// a bare category opens on its menu.
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
	level := level
	if anchor != "" || !settings_has_menu(section) {level = .Sheet}
	target_tab := anchor == "" ? tab : settings_target_tab(section, anchor)
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

// Step back one level: sheet -> its category menu -> All categories ->
// the chat list. Sections without a menu go straight to All categories.
@(private)
settings_back :: proc(ui: ^Ui_State) {
	switch {
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
	if ui.lang_open || ui.shortcuts_open || ui.theme_menu_open || ui.export_open {return}
	if field_mouse(ui, &ui.settings_search, "SettingsSearchBox", 12) {ui.focus = .SettingsSearch}
	if ui.focus != .SettingsSearch {return}
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
	if clicked("SettingsHome") || clay.PointerOver(clay.ID("Nav", u32(Page.Settings))) {
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
		if clay.PointerOver(clay.ID("SettingsTask", u32(i))) {
			settings_open(ui, client, task.section, anchor = task.anchor)
			return true
		}
	}
	for link, i in SETTINGS_SEE_ALSO[section] {
		if clay.PointerOver(clay.ID("SettingsSeeAlso", u32(i))) {
			settings_open(ui, client, link.section, anchor = link.anchor)
			return true
		}
	}
	for link, i in SETTINGS_TROUBLESHOOTERS[section] {
		if clay.PointerOver(clay.ID("SettingsTrouble", u32(i))) {
			settings_open(ui, client, link.section, anchor = link.anchor)
			return true
		}
	}
	if settings_on_menu(ui) {
		for i in 0 ..< max(1, len(settings_tabs(section))) {
			if clay.PointerOver(clay.ID("SettingsPageIcon", u32(i))) {
				settings_open(ui, client, section, tab = i, level = .Sheet)
				return true
			}
		}
	}
	for target in Settings_Section {
		if clay.PointerOver(clay.ID("SettingsNav", u32(target))) {
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
