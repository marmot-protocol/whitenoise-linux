package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:fmt"

// Stable focus keys map the workbench's indexed chips to their Clay hit targets.
@(private)
APPEARANCE_CONTROLS := []struct {
	key, id: string,
	index:   u32,
} {
	{"ZoomMinus", "ZoomMinus", 0},
	{"ZoomPlus", "ZoomPlus", 0},
	{"ZoomReset", "ZoomReset", 0},
	{"TgHandDrawn", "TgHandDrawn", 0},
	{"BodyFontChip0", "BodyFontChip", 0},
	{"BodyFontChip1", "BodyFontChip", 1},
	{"BodyFontChip2", "BodyFontChip", 2},
	{"EmojiSetChip0", "EmojiSetChip", 0},
	{"EmojiSetChip1", "EmojiSetChip", 1},
	{"EmojiSetChip2", "EmojiSetChip", 2},
	{"ScrollChip0", "ScrollChip", 0},
	{"ScrollChip1", "ScrollChip", 1},
	{"ScrollChip2", "ScrollChip", 2},
	{"ScrollChip3", "ScrollChip", 3},
	{"TgMotion", "TgMotion", 0},
	{"TgCentered", "TgCentered", 0},
	{"MessageLinesMinus", "MessageLinesMinus", 0},
	{"MessageLinesPlus", "MessageLinesPlus", 0},
	{"MessageLinesReset", "MessageLinesReset", 0},
	{"AvatarShapeChip0", "AvatarShapeChip", 0},
	{"AvatarShapeChip1", "AvatarShapeChip", 1},
	{"AvatarShapeChip2", "AvatarShapeChip", 2},
	{"CropShapeChip0", "CropShapeChip", 0},
	{"CropShapeChip1", "CropShapeChip", 1},
	{"CropShapeChip2", "CropShapeChip", 2},
	{"CropShapeChip3", "CropShapeChip", 3},
}

@(private)
Appearance_Layout :: struct {
	controls, themes, preview: f32,
	columns:                   int,
}

// Measure in logical pixels so zoom follows the same breakpoints as resizing.
@(private)
appearance_layout :: proc(ui: ^Ui_State) -> Appearance_Layout {
	width := max(120, settings_content_width(ui) - (settings_main_w(ui) < 560 ? 16 : 32))
	if width < 720 {
		return {width, width, width, 1}
	}
	if width < 1180 {
		controls := clamp(width * 0.4, 300, 420)
		remaining := width - controls - 16
		return {controls, remaining, remaining, 2}
	}
	controls := clamp(width * 0.22, 340, 420)
	remaining := width - controls - 32
	return {controls, remaining * 0.5, remaining * 0.5, 3}
}

@(private)
settings_appearance :: proc(ui: ^Ui_State) {
	layout := appearance_layout(ui)
	split := layout.columns > 1
	clear(&theme_control_order)
	if clay.UI(clay.ID("AppearanceWorkbench"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), split ? clay.SizingGrow() : clay.SizingFit()},
			layoutDirection = split ? .LeftToRight : .TopToBottom,
			childGap = 16,
		},
	},
	) {
		if clay.UI(clay.ID("AppearanceControls"))(
		{
			layout = {
				sizing = {
					clay.SizingFixed(layout.controls),
					split ? clay.SizingGrow() : clay.SizingFit(),
				},
				layoutDirection = .TopToBottom,
				childGap = 18,
				padding = {top = 8, bottom = 8},
			},
			clip = {vertical = split, childOffset = clay.GetScrollOffset()},
		},
		) {
			settings_appearance_controls(ui)
		}
		if split {scrollbar(clay.ID("AppearanceControls"))}
		// On narrow screens the preview stays near the controls it illustrates.
		if clay.UI(clay.ID("AppearanceSamples"))(
		{
			layout = {
				sizing = {clay.SizingGrow(), split ? clay.SizingGrow() : clay.SizingFit()},
				layoutDirection = layout.columns == 3 ? .LeftToRight : .TopToBottom,
				childGap = 16,
			},
		},
		) {
			for panel in 0 ..< 2 {
				preview := split ? panel == 1 : panel == 0
				if preview {
					if clay.UI(clay.ID("AppearancePreview"))(
					{
						layout = {
							sizing = {
								clay.SizingFixed(layout.preview),
								split ? clay.SizingGrow() : clay.SizingFit(),
							},
						},
						clip = {vertical = split, childOffset = clay.GetScrollOffset()},
					},
					) {
						settings_conversation_preview(ui)
					}
					if split {scrollbar(clay.ID("AppearancePreview"))}
				} else {
					if clay.UI(clay.ID("AppearanceThemes"))(
					{
						layout = {
							sizing = {
								clay.SizingFixed(layout.themes),
								split ? clay.SizingGrow() : clay.SizingFit(),
							},
						},
						clip = {vertical = split, childOffset = clay.GetScrollOffset()},
					},
					) {
						settings_theme_gallery(ui, layout.themes)
					}
					if split {scrollbar(clay.ID("AppearanceThemes"))}
				}
			}
		}
	}
}

@(private)
appearance_control_input :: proc(ui: ^Ui_State, pressed: string) -> bool {
	for entry in APPEARANCE_CONTROLS {
		control := clay.ID(entry.id, entry.index)
		if pressed != entry.key && !(mouse_released() && clay.PointerOver(control)) {
			continue
		}
		if entry.id == "TgMotion" || entry.id == "TgCentered" || entry.id == "TgHandDrawn" {
			settings_flip(ui, nil, entry.id)
		} else {
			appearance_activate(ui, control)
		}
		return true
	}
	return false
}

// Deep links and keyboard focus scroll their own column, never its neighbours.
@(private)
appearance_scroll :: proc(ui: ^Ui_State, field: clay.ElementId) -> clay.ElementId {
	if appearance_layout(ui).columns == 1 {return clay.ID("SettingsPage")}
	if field == clay.ID("Composer") {return clay.ID("AppearancePreview")}
	box := clay.GetElementData(field).boundingBox
	for id in ([2]string{"AppearanceThemes", "AppearancePreview"}) {
		panel := clay.GetElementData(clay.ID(id)).boundingBox
		if box.x >= panel.x && box.x < panel.x + panel.width {
			return clay.ID(id)
		}
	}
	return clay.ID("AppearanceControls")
}

@(private)
appearance_activate :: proc(ui: ^Ui_State, control: clay.ElementId) {
	if control == clay.ID("MessageLinesMinus") ||
	   control == clay.ID("MessageLinesPlus") ||
	   control == clay.ID("MessageLinesReset") {
		lines := ui.prefs.message_lines
		if control == clay.ID("MessageLinesMinus") {lines = max(lines - 1, 0)}
		if control == clay.ID("MessageLinesPlus") && lines < max(int) {lines += 1}
		if control == clay.ID("MessageLinesReset") {lines = DEFAULT_MESSAGE_LINES}
		ui.prefs.message_lines = lines
		for &msg in ui.messages {msg.excerpt = {}; msg.row_height = 0}
		for &pending in ui.pending {pending.excerpt = {}}
		for _, &card in nev_cards {card.excerpt = {}}
		save_settings(ui)
		return
	}
	for _, shape in AVATAR_SHAPE_NAMES {
		if control == clay.ID("AvatarShapeChip", u32(shape)) {
			ui.prefs.avatar_shape = shape
			save_settings(ui)
			return
		}
	}
	for _, shape in CROP_SHAPE_NAMES {
		if control == clay.ID("CropShapeChip", u32(shape)) {
			ui.prefs.crop_avatar_shape = shape
			save_settings(ui)
			return
		}
	}
	for _, i in BODY_FONT_DELTAS {
		if control == clay.ID("BodyFontChip", u32(i)) {
			ui.prefs.body_font = BODY_FONT_DELTAS[i]
			apply_zoom(ui)
			save_settings(ui)
			return
		}
	}
	for _, i in SCROLL_SPEEDS {
		if control == clay.ID("ScrollChip", u32(i)) {
			ui.prefs.scroll_speed = SCROLL_SPEEDS[i]
			save_settings(ui)
			return
		}
	}
	for _, set in EMOJI_SET_NAMES {
		if control == clay.ID("EmojiSetChip", u32(set)) {
			ui.prefs.emoji_set = set
			emoji_set_load(set)
			save_settings(ui)
			return
		}
	}
	if control == clay.ID("ZoomMinus") {
		ui.prefs.zoom_pct -= 10
	} else if control == clay.ID("ZoomPlus") {
		ui.prefs.zoom_pct += 10
	} else if control == clay.ID("ZoomReset") {
		ui.prefs.zoom_pct = 100
	} else {
		return
	}
	apply_zoom(ui)
	// Resolve against the resized page, including a switch between columns.
	ui.settings_anchor = "ZoomChoices"
	ui.settings_scroll_pending = true
	save_settings(ui)
}


@(private)
settings_appearance_controls :: proc(ui: ^Ui_State) {
	preview_theme := ui.theme_preview_active ? ui.theme_preview : active_theme(ui)
	has_accent_choices := false
	if len(theme_packs) > 0 {
		accents := theme_packs[preview_theme].accent_base[:]
		for color in accents[1:] {
			if color != accents[0] {
				has_accent_choices = true
				break
			}
		}
	}

	if clay.UI(clay.ID("ThemeGroup"))(settings_box()) {
		settings_group(tr("Theme"))
		if clay.UI(clay.ID("ThemeToneFilters"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}},
		) {
			theme_tone_button(ui, .Dark, "ThemeToneDark", tr("Dark"))
			theme_tone_button(ui, .Light, "ThemeToneLight", tr("Light"))
		}
		if ui.theme != system_theme_index && has_accent_choices {
			if clay.UI(clay.ID("RowAccent"))(settings_row(true)) {
				row_labels(tr("Accent color"), "")
				clay.Text(
					theme_packs[preview_theme].accent_names[ui.accent],
					{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
				)
				if clay.UI(clay.ID("AccentChoices"))(
				{layout = {childGap = single_pane() ? 4 : 10}},
				) {
					for name, i in theme_packs[preview_theme].accent_names {
						append(&theme_control_order, THEME_ACCENT_KEYS[i])
						if clay.UI(clay.ID("AccentDot", u32(i)))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(settings_tap_size(18)),
									height = clay.SizingFixed(settings_tap_size(18)),
								},
							},
							backgroundColor = len(theme_packs) > 0 ? theme_packs[preview_theme].accent_base[i] : default_pack().accent_base[i],
							cornerRadius = rr(2),
							border = kb_focus == THEME_ACCENT_KEYS[i] || ui.accent == i ? clay.BorderElementConfig{color = TEXT, width = {2, 2, 2, 2, 0}} : {},
						},
						) {
							if hovered() {tooltip(name)}
						}
					}
				}
			}
		}

	}
	if clay.UI(clay.ID("InterfaceGroup"))(settings_box()) {
		settings_group(tr("Interface"))
		if len(theme_packs) > 0 && theme_packs[preview_theme].chalk_drawn {
			if clay.UI(clay.ID("RowHandDrawn"))(settings_row()) {
				settings_check(
					"TgHandDrawn",
					!ui.prefs.hand_drawn_disabled,
					tr("Hand-drawn filter"),
					tr("Textured strokes and sketched avatars. Shapes stay fixed."),
				)
			}
		}
		if clay.UI(clay.ID("RowZoom"))(settings_row(true)) {
			row_labels(
				tr("Interface zoom"),
				tr("Ctrl + + to zoom in, Ctrl + - to zoom out, Ctrl + 0 to reset."),
			)
			zoom_choices := settings_choices(clay.ID("ZoomChoices"))
			zoom_choices.layout.layoutDirection = .LeftToRight
			zoom_choices.layout.childGap = 4
			if clay.UI(clay.ID("ZoomChoices"))(zoom_choices) {
				clay.Text(
					fmt.tprintf("%d%%", ui.prefs.zoom_pct),
					{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
				)
				settings_button("ZoomMinus", "-")
				settings_button("ZoomPlus", "+")
				settings_button("ZoomReset", tr("Reset"))
			}
		}
		if clay.UI(clay.ID("RowBodyFont"))(settings_row(true)) {
			row_labels(tr("Message text size"), tr("Applies to message bodies and the composer."))
			if clay.UI(clay.ID("BodyFontChoices"))(settings_choices(clay.ID("BodyFontChoices"))) {
				for label, i in BODY_FONT_LABELS {
					settings_option(
						"BodyFontChip",
						u32(i),
						tr(label),
						ui.prefs.body_font == BODY_FONT_DELTAS[i],
					)
				}
			}
		}
		if clay.UI(clay.ID("RowEmojiSet"))(settings_row(true)) {
			row_labels(
				tr("Emoji style"),
				tr("Applies to the picker, reactions and emoji in messages."),
			)
			if clay.UI(clay.ID("EmojiSetChoices"))(settings_choices(clay.ID("EmojiSetChoices"))) {
				for name, set in EMOJI_SET_NAMES {
					settings_option("EmojiSetChip", u32(set), name, ui.prefs.emoji_set == set)
				}
			}
		}
		if clay.UI(clay.ID("RowScroll"))(settings_row(true)) {
			row_labels(tr("Scroll speed"), tr("How far the mouse wheel moves the view."))
			if clay.UI(clay.ID("ScrollChoices"))(settings_choices(clay.ID("ScrollChoices"))) {
				for label, i in SCROLL_SPEED_LABELS {
					settings_option(
						"ScrollChip",
						u32(i),
						label,
						ui.prefs.scroll_speed == SCROLL_SPEEDS[i],
					)
				}
			}
		}
	}

	if clay.UI(clay.ID("LayoutGroup"))(settings_box()) {
		settings_group(tr("Layout"))
		if clay.UI(clay.ID("RowMotion"))(settings_row()) {
			settings_check(
				"TgMotion",
				ui.prefs.reduce_motion,
				tr("Reduce motion"),
				tr(
					"Turn off animated transitions, flights and effects. State still changes, nothing moves.",
				),
			)
		}
		if clay.UI(clay.ID("RowCentered"))(settings_row()) {
			settings_check(
				"TgCentered",
				ui.prefs.centered_chat,
				tr("Center the conversation"),
				tr(
					"Keep the open conversation on a comfortable reading measure instead of filling the width.",
				),
			)
		}
		if clay.UI(clay.ID("RowMessageLines"))(settings_row(true)) {
			row_labels(
				tr("Message line limit"),
				tr(
					"Collapse messages and event cards after this many lines. Set to 0 to never collapse.",
				),
			)
			if clay.UI(clay.ID("MessageLinesChoices"))(
			{layout = {childGap = 12, childAlignment = {y = .Center}}},
			) {
				if clay.UI(clay.ID("MessageLinesStepper"))(
				{
					layout = {padding = clay.PaddingAll(2), childAlignment = {y = .Center}},
					backgroundColor = CARD,
					border = {color = FIELD_BORDER, width = bw()},
					cornerRadius = rr(7),
				},
				) {
					for id, i in ([3]string{"MessageLinesMinus", "MessageLinesValue", "MessageLinesPlus"}) {
						action := i == 2 || i == 0 && ui.prefs.message_lines > 0
						if clay.UI(clay.ID(id))(
						{
							layout = {
								sizing = {
									width = clay.SizingFit(
										{min = settings_tap_size(i == 1 ? 44 : 28)},
									),
									height = clay.SizingFixed(settings_tap_size(28)),
								},
								padding = {
									left = 6,
									right = 6,
									top = action ? press_down(clay.ID(id)) : 0,
								},
								childAlignment = {x = .Center, y = .Center},
							},
							backgroundColor = action && hovered() ? HOVER : {},
							cornerRadius = rr(4),
						},
						) {
							label :=
								i == 1 ? fmt.tprintf("%d", ui.prefs.message_lines) : i == 0 ? "-" : "+"
							clay.Text(
								label,
								{
									fontId = FONT_BODY,
									fontSize = i == 1 ? 13 : 16,
									textColor = i == 1 ? TEXT : action ? TEXT_DIM : TEXT_LO,
								},
							)
						}
					}
				}
				if clay.UI(clay.ID("MessageLinesReset"))(
				{
					layout = {
						padding = {left = 6, right = 6},
						sizing = {height = clay.SizingFixed(settings_tap_size(32))},
						childAlignment = {y = .Center},
					},
					backgroundColor = hovered() ? HOVER : {},
					cornerRadius = rr(4),
				},
				) {clay.Text(tr("Reset"), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})}
			}
		}
	}
	settings_avatar_choices(ui)
	for control in APPEARANCE_CONTROLS {
		if control.id == "TgHandDrawn" &&
		   (len(theme_packs) == 0 || !theme_packs[preview_theme].chalk_drawn) {continue}
		append(&theme_control_order, control.key)
	}
	if clay.UI(clay.ID("ThemeActionsGroup"))(settings_box()) {
		if clay.UI(clay.ID("RowThemeShare"))(settings_row(true)) {
			row_labels(
				tr("Share this theme"),
				tr("Pick a chat to send it to. They choose whether to use it."),
			)
			if clay.UI(clay.ID("ThemeShareActions"))(
				settings_choices(clay.ID("ThemeShareActions")),
			) {
				append(&theme_control_order, "ThemeShareBtn", "ThemeEditBtn")
				settings_button("ThemeShareBtn", tr("Share to chat"))
				settings_button("ThemeEditBtn", tr("Edit"))
				if active_pack(ui).custom {
					append(&theme_control_order, "ThemeDeleteBtn")
					settings_button("ThemeDeleteBtn", tr("Delete"), DANGER)
				}
			}
		}
	}
}
