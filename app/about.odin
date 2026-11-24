package main

import "nendo"

@(private)
settings_help :: proc(ui: ^Ui_State) {
	settings_group(tr("Support"))
	if nendo.box(nendo.id("SettingsSupport"))(settings_box()) {
		support_detail := tr(
			"Ask a question, report a problem, or share a suggestion in a private chat with White Noise support.",
		)
		if ui.account_ref != "" {
			settings_nav_row("SupportChat", tr("Reach out to support"), support_detail)
		} else {
			nendo.text(support_detail, {font = FONT_BODY, size = 12, color = TEXT_DIM})
			settings_nav_button("SupportChat", tr("Reach out to support"), .Disabled)
		}
		if !tap_size() {
			settings_divider()
			if nendo.box(nendo.id("RowShortcuts"))({width = nendo.grow()}) {
				settings_nav_row("ShortcutsView", tr("Keyboard shortcuts"), "")
			}
		}
	}
	settings_group(tr("Troubleshooting"))
	if nendo.box(nendo.id("SettingsTroubleshooting"))(settings_box()) {
		settings_nav_row("SettingsMuteHelp", tr("Mute a conversation"), "")
		for link in SETTINGS_TROUBLESHOOTERS {
			if !settings_task_matches(ui, link, "") {continue}
			settings_divider()
			settings_nav_row(link.label, tr(link.label), "")
		}
	}
	if nendo.box(nendo.id("AboutIdentity"))(settings_box()) {
		if nendo.box(nendo.id("AboutBrand"))(
		{width = nendo.grow(), gap = 16, align = {y = .Center}},
		) {
			if nendo.box(nendo.id("AboutLogo"))(
			{
				width = nendo.fixed(64),
				height = nendo.fixed(64),
				align = {x = .Center, y = .Center},
				color = fade(ACCENT, 0.08),
				radius = rr(16),
			},
			) {logo_mark()}
			if nendo.box(nendo.id("AboutName"))(
			{width = nendo.grow(), direction = .Column, gap = 6},
			) {
				nendo.text("White Noise", {font = FONT_TITLE, size = 26, color = TEXT})
				nendo.text(APP_VERSION, {font = FONT_MONO, size = 12, color = TEXT_DIM})
			}
		}
		nendo.text(
			tr("Private group chat over Nostr"),
			{font = FONT_TITLE, size = 16, color = TEXT},
		)
		nendo.text(
			tr(
				"A client for private group chat. Messages are sealed with MLS on this device, handed to Nostr relays as opaque blobs, and opened again only inside the group.",
			),
			{font = FONT_BODY, size = 13, color = TEXT_DIM},
		)
		nendo.text("GNU AGPLv3", {font = FONT_BODY, size = 12, color = TEXT_DIM})
	}

	update_settings_row()

	settings_group(tr("Built with"))
	if nendo.box(nendo.id("AboutCredits"))(settings_box()) {
		nendo.text("Marmot · MLS · Nostr", {font = FONT_BODY, size = 13, color = TEXT_DIM})
		nendo.text(
			"Odin · nendo · SDL3 · stb · mpv",
			{font = FONT_BODY, size = 13, color = TEXT_DIM},
		)
		nendo.text(
			"Noto Emoji · Twemoji · OpenMoji",
			{font = FONT_BODY, size = 13, color = TEXT_DIM},
		)
	}
}

@(private)
settings_mute :: proc() {
	if nendo.box(nendo.id("MuteHelp"))(settings_box()) {
		nendo.text(
			tr(
				"Right-click or press and hold a conversation in Chats, then select Mute. To turn its alerts back on, open the same menu and select Unmute.",
			),
			{font = FONT_BODY, size = 13, color = TEXT},
		)
	}
}
