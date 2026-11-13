package main

import "core:fmt"
import "nendo"
import rl "sdlrl"

// Stable focus keys map the workbench's indexed chips to their nendo hit targets.
@(private)
APPEARANCE_CONTROLS := []struct {
	key, id: string,
	index:   u32,
} {
	{"ZoomMinus", "ZoomMinus", 0},
	{"ZoomPlus", "ZoomPlus", 0},
	{"ZoomReset", "ZoomReset", 0},
	{"TgHandDrawn", "TgHandDrawn", 0},
	{"TgThemeFont", "TgThemeFont", 0},
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
	if nendo.box(nendo.id("AppearanceWorkbench"))(
	{
		width = nendo.grow(),
		height = split ? nendo.grow() : nendo.fit(),
		direction = split ? .Row : .Column,
		gap = 16,
	},
	) {
		if nendo.box(nendo.id("AppearanceControls"))(
		{
			width = nendo.fixed(layout.controls),
			height = split ? nendo.grow() : nendo.fit(),
			direction = .Column,
			gap = 18,
			padding = {top = 8, bottom = 8},
			clip = {y = split, scroll = true},
		},
		) {
			settings_appearance_controls(ui)
		}
		if split {scrollbar(nendo.id("AppearanceControls"))}
		// On narrow screens the preview stays near the controls it illustrates.
		if nendo.box(nendo.id("AppearanceSamples"))(
		{
			width = nendo.grow(),
			height = split ? nendo.grow() : nendo.fit(),
			direction = layout.columns == 3 ? .Row : .Column,
			gap = 16,
		},
		) {
			for panel in 0 ..< 2 {
				preview := split ? panel == 1 : panel == 0
				if preview {
					if nendo.box(nendo.id("AppearancePreview"))(
					{
						width = nendo.fixed(layout.preview),
						height = split ? nendo.grow() : nendo.fit(),
						clip = {y = split, scroll = true},
					},
					) {
						settings_conversation_preview(ui)
					}
					if split {scrollbar(nendo.id("AppearancePreview"))}
				} else {
					if nendo.box(nendo.id("AppearanceThemes"))(
					{
						width = nendo.fixed(layout.themes),
						height = split ? nendo.grow() : nendo.fit(),
						clip = {y = split, scroll = true},
					},
					) {
						settings_theme_gallery(ui, layout.themes)
					}
					if split {scrollbar(nendo.id("AppearanceThemes"))}
				}
			}
		}
	}
}

@(private)
appearance_control_input :: proc(ui: ^Ui_State, pressed: string) -> bool {
	// A held stepper repeats without waiting for a lift. A travelling finger
	// cancels it, so the same buttons remain safe scroll starting points.
	if rl.IsMouseButtonPressed(.LEFT) {
		appearance_hold = {}
		for id in ([2]string{"MessageLinesMinus", "MessageLinesPlus"}) {
			if nendo.pointer_over(nendo.id(id)) {
				appearance_hold = {
					id  = id,
					at  = rl.GetTime() + 0.45,
					pos = rl.GetMousePosition(),
				}
			}
		}
	}
	if appearance_hold.id != "" && rl.IsMouseButtonDown(.LEFT) {
		pos := rl.GetMousePosition()
		if abs(pos.x - appearance_hold.pos.x) > LONG_PRESS_SLOP ||
		   abs(pos.y - appearance_hold.pos.y) > LONG_PRESS_SLOP {
			appearance_hold = {}
		} else if rl.GetTime() >= appearance_hold.at {
			appearance_activate(ui, nendo.id(appearance_hold.id))
			appearance_hold.at = rl.GetTime() + 0.12
			appearance_hold.repeated = true
			return true
		}
	}
	if rl.IsMouseButtonReleased(.LEFT) && appearance_hold.repeated {
		appearance_hold = {}
		return true
	}
	for entry in APPEARANCE_CONTROLS {
		control := nendo.id(entry.id, entry.index)
		if pressed != entry.key && !(mouse_released() && nendo.pointer_over(control)) {
			continue
		}
		if entry.id == "TgMotion" ||
		   entry.id == "TgCentered" ||
		   entry.id == "TgHandDrawn" ||
		   entry.id == "TgThemeFont" {
			settings_flip(ui, nil, entry.id)
		} else {
			appearance_activate(ui, control)
		}
		return true
	}
	return false
}

@(private)
appearance_hold: struct {
	id:       string,
	at:       f64,
	pos:      rl.Vector2,
	repeated: bool,
}

// Deep links and keyboard focus scroll their own column, never its neighbours.
@(private)
appearance_scroll :: proc(ui: ^Ui_State, field: nendo.Id) -> nendo.Id {
	if appearance_layout(ui).columns == 1 {return nendo.id("SettingsPage")}
	box := nendo.element(field).rect
	for id in ([2]string{"AppearanceThemes", "AppearancePreview"}) {
		panel := nendo.element(nendo.id(id)).rect
		if box.x >= panel.x && box.x < panel.x + panel.width {
			return nendo.id(id)
		}
	}
	return nendo.id("AppearanceControls")
}

@(private)
appearance_activate :: proc(ui: ^Ui_State, control: nendo.Id) {
	if control == nendo.id("MessageLinesMinus") ||
	   control == nendo.id("MessageLinesPlus") ||
	   control == nendo.id("MessageLinesReset") {
		lines := ui.prefs.message_lines
		if control == nendo.id("MessageLinesMinus") {lines = max(lines - 1, 0)}
		if control == nendo.id("MessageLinesPlus") && lines < max(int) {lines += 1}
		if control == nendo.id("MessageLinesReset") {lines = DEFAULT_MESSAGE_LINES}
		ui.prefs.message_lines = lines
		for &msg in ui.messages {msg.excerpt = {}; msg.row_height = 0}
		for &pending in ui.pending {pending.excerpt = {}}
		for _, &card in nev_cards {card.excerpt = {}}
		save_settings(ui)
		return
	}
	for _, shape in AVATAR_SHAPE_NAMES {
		if control == nendo.id("AvatarShapeChip", u32(shape)) {
			ui.prefs.avatar_shape = shape
			save_settings(ui)
			return
		}
	}
	for _, shape in CROP_SHAPE_NAMES {
		if control == nendo.id("CropShapeChip", u32(shape)) {
			ui.prefs.crop_avatar_shape = shape
			save_settings(ui)
			return
		}
	}
	for _, i in BODY_FONT_DELTAS {
		if control == nendo.id("BodyFontChip", u32(i)) {
			ui.prefs.body_font = BODY_FONT_DELTAS[i]
			apply_zoom(ui)
			save_settings(ui)
			return
		}
	}
	for _, i in SCROLL_SPEEDS {
		if control == nendo.id("ScrollChip", u32(i)) {
			ui.prefs.scroll_speed = SCROLL_SPEEDS[i]
			save_settings(ui)
			return
		}
	}
	for _, set in EMOJI_SET_NAMES {
		if control == nendo.id("EmojiSetChip", u32(set)) {
			ui.prefs.emoji_set = set
			emoji_set_load(set)
			save_settings(ui)
			return
		}
	}
	if control == nendo.id("ZoomMinus") {
		ui.prefs.zoom_pct -= 10
	} else if control == nendo.id("ZoomPlus") {
		ui.prefs.zoom_pct += 10
	} else if control == nendo.id("ZoomReset") {
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

	if ui.theme != system_theme_index && has_accent_choices {
		if nendo.box(nendo.id("ThemeGroup"))(settings_box()) {
			settings_group(tr("Theme"))
			if ui.theme != system_theme_index && has_accent_choices {
				if nendo.box(nendo.id("RowAccent"))(settings_row(true)) {
					row_labels(tr("Accent color"), "")
					nendo.text(
						theme_packs[preview_theme].accent_names[ui.accent],
						{font = FONT_BODY, size = 12, color = TEXT_DIM},
					)
					if nendo.box(nendo.id("AccentChoices"))({gap = single_pane() ? 4 : 10}) {
						for name, i in theme_packs[preview_theme].accent_names {
							append(&theme_control_order, THEME_ACCENT_KEYS[i])
							if nendo.box(nendo.id("AccentDot", u32(i)))(
							{
								width = nendo.fixed(settings_tap_size(18)),
								height = nendo.fixed(settings_tap_size(18)),
								color = len(theme_packs) > 0 ? theme_packs[preview_theme].accent_base[i] : default_pack().accent_base[i],
								radius = rr(2),
								border = kb_focus == THEME_ACCENT_KEYS[i] || ui.accent == i ? nendo.Border{color = TEXT, width = {2, 2, 2, 2, 0}} : {},
							},
							) {
								if hovered() {tooltip(name)}
							}
						}
					}
				}
			}

		}
	}
	if nendo.box(nendo.id("InterfaceGroup"))(settings_box()) {
		settings_group(tr("Interface"))
		if len(theme_packs) > 0 && theme_packs[preview_theme].chalk_drawn {
			if nendo.box(nendo.id("RowHandDrawn"))(settings_row()) {
				settings_check(
					"TgHandDrawn",
					!ui.prefs.hand_drawn_disabled,
					tr("Hand-drawn filter"),
					tr("Textured strokes and sketched avatars. Shapes stay fixed."),
				)
			}
		}
		// The committed theme decides, so hovering a gallery tile never
		// inserts the row and pushes the tile out from under the pointer.
		if len(theme_packs) > 0 && pack_ships_face(&theme_packs[active_theme(ui)]) {
			if nendo.box(nendo.id("RowThemeFont"))(settings_row()) {
				settings_check(
					"TgThemeFont",
					!ui.prefs.theme_font_disabled,
					tr("Theme font"),
					tr("Text uses the typeface this theme ships with."),
				)
			}
		}
		if nendo.box(nendo.id("RowZoom"))(settings_row(true)) {
			row_labels(
				tr("Interface zoom"),
				tap_size() ? tr("Make everything larger or smaller.") : tr("Ctrl + + to zoom in, Ctrl + - to zoom out, Ctrl + 0 to reset."),
			)
			zoom_choices := settings_choices(nendo.id("ZoomChoices"))
			zoom_choices.direction = .Row
			zoom_choices.gap = 4
			zoom_choices.clip = {}
			if nendo.box(nendo.id("ZoomChoices"))(zoom_choices) {
				nendo.text(
					fmt.tprintf("%d%%", ui.prefs.zoom_pct),
					{font = FONT_BODY, size = 12, color = TEXT_DIM},
				)
				settings_button("ZoomMinus", "-")
				settings_button("ZoomPlus", "+")
				if !single_pane() {settings_button("ZoomReset", tr("Reset"))}
			}
			if single_pane() {settings_button("ZoomReset", tr("Reset"))}
		}
		if nendo.box(nendo.id("RowBodyFont"))(settings_row(true)) {
			row_labels(tr("Message text size"), tr("Applies to message bodies and the composer."))
			if nendo.box(nendo.id("BodyFontChoices"))(
				settings_choices(nendo.id("BodyFontChoices")),
			) {
				for label, i in BODY_FONT_LABELS {
					settings_option(
						"BodyFontChip",
						u32(i),
						tr(label),
						ui.prefs.body_font == BODY_FONT_DELTAS[i],
					)
				}
			}
			if single_pane() {
				nendo.text(
					tr("A message at this size."),
					{font = FONT_BODY, size = BODY_FS, color = TEXT},
				)
			}
		}
		if nendo.box(nendo.id("RowEmojiSet"))(settings_row(true)) {
			row_labels(
				tr("Emoji style"),
				tr("Applies to the picker, reactions and emoji in messages."),
			)
			if nendo.box(nendo.id("EmojiSetChoices"))(
				settings_choices(nendo.id("EmojiSetChoices")),
			) {
				for name, set in EMOJI_SET_NAMES {
					settings_option("EmojiSetChip", u32(set), name, ui.prefs.emoji_set == set)
				}
			}
			if single_pane() {
				if nendo.box(nendo.id("EmojiStyleSample"))({gap = 12}) {
					for emoji, i in ([3]string{"😀", "❤️", "🥕"}) {
						if tex := emoji_tex(emoji); tex != nil {
							if nendo.box(nendo.id("EmojiStyleSampleImg", u32(i)))(
							{width = nendo.fixed(24), height = nendo.fixed(24), image = tex},
							) {}
						}
					}
				}
			}
		}
		if !tap_size() {
			if nendo.box(nendo.id("RowScroll"))(settings_row(true)) {
				row_labels(tr("Scroll speed"), tr("How far the mouse wheel moves the view."))
				if nendo.box(nendo.id("ScrollChoices"))(
					settings_choices(nendo.id("ScrollChoices")),
				) {
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
	}

	if nendo.box(nendo.id("LayoutGroup"))(settings_box()) {
		settings_group(tr("Layout"))
		if nendo.box(nendo.id("RowMotion"))(settings_row()) {
			settings_check(
				"TgMotion",
				ui.prefs.reduce_motion,
				tr("Reduce motion"),
				tr(
					"Turn off animated transitions, flights and effects. State still changes, nothing moves.",
				),
			)
		}
		if nendo.box(nendo.id("RowCentered"))(settings_row()) {
			settings_check(
				"TgCentered",
				ui.prefs.centered_chat,
				tr("Center the conversation"),
				tr(
					"Keep the open conversation on a comfortable reading measure instead of filling the width.",
				),
			)
		}
		if nendo.box(nendo.id("RowMessageLines"))(settings_row(true)) {
			row_labels(
				tr("Message line limit"),
				tr(
					"Collapse messages and event cards after this many lines. Set to 0 to never collapse.",
				),
			)
			if nendo.box(nendo.id("MessageLinesChoices"))({gap = 12, align = {y = .Center}}) {
				if nendo.box(nendo.id("MessageLinesStepper"))(
				{
					padding = nendo.pad(2),
					align = {y = .Center},
					color = CARD,
					border = {color = FIELD_BORDER, width = bw()},
					radius = rr(7),
				},
				) {
					for id, i in ([3]string{"MessageLinesMinus", "MessageLinesValue", "MessageLinesPlus"}) {
						action := i == 2 || i == 0 && ui.prefs.message_lines > 0
						if nendo.box(nendo.id(id))(
						{
							width = nendo.fit(min = settings_tap_size(i == 1 ? 44 : 28)),
							height = nendo.fixed(settings_tap_size(28)),
							padding = {
								left = 6,
								right = 6,
								top = action ? press_down(nendo.id(id)) : 0,
							},
							align = {x = .Center, y = .Center},
							color = action && hovered() ? HOVER : {},
							radius = rr(4),
						},
						) {
							label :=
								i == 1 ? (ui.prefs.message_lines == 0 ? tr("Never") : fmt.tprintf("%d", ui.prefs.message_lines)) : i == 0 ? "-" : "+"
							nendo.text(
								label,
								{
									font = FONT_BODY,
									size = i == 1 ? 13 : 16,
									color = i == 1 ? TEXT : action ? TEXT_DIM : TEXT_LO,
								},
							)
						}
					}
				}
				settings_button("MessageLinesReset", tr("Reset"))
			}
		}
	}
	settings_avatar_choices(ui)
	for control in APPEARANCE_CONTROLS {
		if control.id == "TgHandDrawn" &&
		   (len(theme_packs) == 0 || !theme_packs[preview_theme].chalk_drawn) {continue}
		if control.id == "TgThemeFont" &&
		   (len(theme_packs) == 0 || !pack_ships_face(&theme_packs[active_theme(ui)])) {continue}
		append(&theme_control_order, control.key)
	}
	if nendo.box(nendo.id("ThemeActionsGroup"))(settings_box()) {
		settings_group(tr("Sharing"))
		if nendo.box(nendo.id("RowThemeShare"))(settings_row(true)) {
			row_labels(
				tr("Share this theme"),
				tr("Pick a chat to send it to. They choose whether to use it."),
			)
			if nendo.box(nendo.id("ThemeShareActions"))(
				settings_choices(nendo.id("ThemeShareActions")),
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
