// Settings → About: application identity, updates, credits and local storage.
package main

import "nendo"

settings_about :: proc(ui: ^Ui_State) {
	if nendo.box(nendo.id("AboutIdentity"))(
	{
		width = nendo.grow(),
		direction = .Column,
		padding = {top = 16, bottom = 28},
		gap = 20,
		border = {color = DIVIDER, width = {bottom = BORDER_W}},
	},
	) {
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

	columns := settings_body_width(ui) >= 520
	if nendo.box(nendo.id("AboutDetails"))(
	{width = nendo.grow(), direction = columns ? .Row : .Column, gap = 24},
	) {
		if nendo.box(nendo.id("AboutCredits"))(
		{width = nendo.grow(), direction = .Column, padding = {top = 6}, gap = 10},
		) {
			nendo.text(tr("Built with"), {font = FONT_TITLE, size = 14, color = TEXT})
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
		if nendo.box(nendo.id("AboutStorage"))(
		{width = nendo.grow(), direction = .Column, padding = {top = 6}, gap = 10},
		) {
			nendo.text(tr("Data folder"), {font = FONT_TITLE, size = 14, color = TEXT})
			// Break long paths at grapheme boundaries instead of widening the page.
			width := columns ? (settings_body_width(ui) - 24) / 2 : settings_body_width(ui)
			for at := 0; at < len(data_home); {
				end := wrap_break(data_home, at, len(data_home), width, 12)
				nendo.text(
					data_home[at:end],
					{font = FONT_BODY, size = 12, color = TEXT_DIM, wrap = .None},
				)
				at = end
			}
		}
	}
}
