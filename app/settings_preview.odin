package main

import "nendo"

@(private)
settings_appearance_preview :: proc(body_width: f32) {
	settings_chat_sample(nendo.id("SettingsAppearancePreview"), body_width, false, false)
}

@(private)
settings_conversation_preview :: proc(ui: ^Ui_State) {
	settings_chat_sample(
		nendo.id("SettingsConversationPreview"),
		settings_body_width(ui),
		true,
		ui.prefs.centered_chat,
	)
}

@(private = "file")
settings_chat_sample :: proc(id: nendo.Id, body_width: f32, gallery, centered: bool) {
	if nendo.box(id)(
	{
		width = nendo.grow(),
		direction = .Column,
		gap = 4,
		padding = nendo.pad(8),
		color = BG,
		border = {color = FIELD_BORDER, width = bw()},
		radius = rr(7),
		inert = true,
		align = {x = .Center},
	},
	) {
		question := tr("Who put a sun lounger outside the burrow?")
		answer := tr("I did. Very important marmot business.")
		if !gallery {
			limit := min(360, (body_width - 36) * 0.86)
			settings_sample_bubble(question, limit, false)
			settings_sample_bubble(answer, limit, true)
			return
		}
		if nendo.box(nendo.id("SettingsPreviewTitle"))(
		{
			width = nendo.grow(),
			padding = nendo.pad(8),
			direction = .Column,
			gap = 4,
			color = RAIL_BG,
			radius = rr(6),
		},
		) {
			nendo.text(tr("Conversation preview"), {font = FONT_BODY, size = 12, color = CARD_DIM})
			nendo.text(tr("Marmot meadow"), {font = FONT_TITLE, size = 16, color = CARD_TEXT})
		}
		column_width := centered ? min(body_width - 16, CHAT_WIDTH_MAX) : body_width - 16
		if nendo.box()(
		{
			width = nendo.grow(max = column_width),
			direction = .Column,
			gap = 4,
			custom = decor_payload(),
		},
		) {
			if nendo.box()({width = nendo.grow(), align = {x = .Center}, padding = nendo.pad(4)}) {
				nendo.text(tr("Today"), {font = FONT_BODY, size = 12, color = TEXT_DIM})
			}
			limit := min(360, (column_width - 20) * 0.86)
			settings_sample_bubble(question, limit, false, "Pip", 2)
			settings_sample_bubble(answer, limit, false, "Maple", 3)
			settings_sample_bubble(
				tr("Step one: find a warm rock. Step two: become one."),
				limit,
				false,
			)
			settings_sample_bubble(
				tr("I packed snacks for the expedition. 🥕"),
				limit,
				true,
				tr("You"),
				4,
				question,
			)
			settings_sample_bubble(
				tr("Perfect. Wake me up when it's spring."),
				limit,
				false,
				"Pip",
				5,
			)
		}
	}
}

@(private = "file")
settings_sample_bubble :: proc(
	message: string,
	limit: f32,
	mine: bool,
	sender := "",
	minute: i32 = 0,
	reply := "",
) {
	if nendo.box()({width = nendo.grow(), align = {x = mine ? .Right : .Left}}) {
		fill := mine ? mix_color(CARD, ACCENT, 0.2) : CARD
		if nendo.box()(
		{
			width = nendo.fit(max = limit),
			direction = .Column,
			gap = 3,
			padding = {left = 10, right = 10, top = 6, bottom = 6},
			color = fill,
			radius = rr(BUBBLE_R),
		},
		) {
			ink := readable_ink(
				CARD_TEXT,
				mix_color(BG, fill, fill.a / 255),
				high_contrast_enabled(g_prefs) ? 7 : 4.5,
			)
			if sender != "" {
				nendo.text(sender, {font = FONT_TITLE, size = 11, color = ink})
			}
			if reply != "" {
				if nendo.box()(
				{
					width = nendo.grow(),
					padding = nendo.pad(4),
					color = ROW_BG,
					radius = rr(4),
					direction = .Column,
					gap = 2,
				},
				) {
					nendo.text("Pip", {font = FONT_TITLE, size = 11, color = ACCENT})
					nendo.text(reply, {font = FONT_BODY, size = 11, color = TEXT_DIM})
				}
			}
			nendo.text(message, {font = FONT_BODY, size = BODY_FS, color = ink})
			if minute > 0 {
				nendo.text(
					clock_text({hour = 14, minute = minute}, .Omit, context.temp_allocator),
					{font = FONT_BODY, size = 10, color = ink},
				)
			}
		}
	}
}
