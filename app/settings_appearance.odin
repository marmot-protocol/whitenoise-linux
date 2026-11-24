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
	{"ThemeQuickSystem", "ThemeQuickSystem", 0},
	{"ThemeQuickLight", "ThemeQuickLight", 0},
	{"ThemeQuickDark", "ThemeQuickDark", 0},
	{"BrowseThemes", "BrowseThemes", 0},
	{"BodyFontChip0", "BodyFontChip", 0},
	{"BodyFontChip1", "BodyFontChip", 1},
	{"BodyFontChip2", "BodyFontChip", 2},
	{"ZoomMinus", "ZoomMinus", 0},
	{"ZoomPlus", "ZoomPlus", 0},
	{"ZoomReset", "ZoomReset", 0},
	{"Motion0", "Motion", 0},
	{"Motion1", "Motion", 1},
	{"Motion2", "Motion", 2},
	{"Contrast0", "Contrast", 0},
	{"Contrast1", "Contrast", 1},
	{"Contrast2", "Contrast", 2},
	{"TgHandDrawn", "TgHandDrawn", 0},
	{"TgThemeFont", "TgThemeFont", 0},
	{"EmojiSetChip0", "EmojiSetChip", 0},
	{"EmojiSetChip1", "EmojiSetChip", 1},
	{"EmojiSetChip2", "EmojiSetChip", 2},
	{"ScrollChip0", "ScrollChip", 0},
	{"ScrollChip1", "ScrollChip", 1},
	{"ScrollChip2", "ScrollChip", 2},
	{"ScrollChip3", "ScrollChip", 3},
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
}

@(private)
settings_appearance :: proc(ui: ^Ui_State) {
	if ui.settings_gallery {
		settings_theme_gallery(ui, settings_body_width(ui))
		settings_conversation_preview(ui)
		return
	}
	settings_appearance_controls(ui)
}

@(private)
settings_gallery_open :: proc(ui: ^Ui_State) {
	settings_theme_preview_reset(ui)
	ui.theme_tone = active_pack(ui).tone
	ui.settings_gallery = true
	ui.settings_anchor = ""
	ui.settings_scroll_pending = true
	kb_focus = ""
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
		if entry.id == "TgCentered" || entry.id == "TgHandDrawn" || entry.id == "TgThemeFont" {
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

@(private)
appearance_activate :: proc(ui: ^Ui_State, control: nendo.Id) {
	if control == nendo.id("BrowseThemes") {
		settings_gallery_open(ui)
		return
	}
	for id, i in THEME_QUICK_IDS {
		if control != nendo.id(id) {continue}
		index := [3]int{system_theme_index, 1, 0}[i]
		if index >= 0 && index < len(theme_packs) {theme_switch(ui, index, ui.accent)}
		return
	}
	for i in 0 ..< 3 {
		if control == nendo.id("Motion", u32(i)) {
			ui.prefs.motion_override, ui.prefs.reduce_motion = i != 0, i == 1
			if reduce_motion_enabled(&ui.prefs) {anim_snap_all()}
			save_settings(ui)
			return
		}
		if control == nendo.id("Contrast", u32(i)) {
			ui.prefs.contrast_override, ui.prefs.high_contrast = i != 0, i == 1
			settings_theme_preview_reset(ui)
			apply_theme(ui.theme, ui.accent)
			save_settings(ui)
			return
		}
	}
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
	for crop, index in CROP_SHAPE_CHOICES {
		if control == nendo.id("CropShapeChip", u32(index)) {
			ui.prefs.crop_avatar_shape = crop
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
	// Resolve against the resized page, including a switch to the compact header.
	ui.settings_anchor = "ZoomChoices"
	ui.settings_scroll_pending = true
	ui.settings_dirty = true
}

@(private)
THEME_QUICK_IDS :: [3]string{"ThemeQuickSystem", "ThemeQuickLight", "ThemeQuickDark"}

@(private)
appearance_row :: proc(wide: bool) -> nendo.Box {
	row := settings_row(true)
	row.direction = wide ? .Row : .Column
	row.gap = 8
	return row
}

@(private)
appearance_segments :: proc() -> nendo.Box {
	return {
		padding = nendo.pad(2),
		gap = 2,
		align = {y = .Center},
		color = CARD,
		border = {color = FIELD_BORDER, width = bw()},
		radius = rr(7),
	}
}

@(private)
appearance_size_choices :: proc(
	available: f32,
	wide: bool,
) -> (
	group: nendo.Box,
	cell: nendo.Size,
) {
	group = appearance_segments()
	if wide {
		cell = nendo.fit(min = 60)
	} else {
		group.width = nendo.grow()
		if available < 3 * settings_tap_size(30) + 8 {group.direction = .Column}
		cell = nendo.grow(min = settings_tap_size(30))
	}
	return
}

@(private)
appearance_segment :: proc(
	id: nendo.Id,
	label: string,
	width: nendo.Size,
	focused, selected: bool,
) {
	if nendo.box(id)(
	{
		width = width,
		height = nendo.fit(min = settings_tap_size(30)),
		padding = {left = 4, right = 4, top = 4, bottom = 4},
		align = {x = .Center, y = .Center},
		color = selected ? SELECTED : hovered() ? HOVER : {},
		border = focused ? kb_ring(ACCENT) : selected ? nendo.Border{color = ACCENT, width = bw()} : {},
		radius = rr(5),
	},
	) {
		ink := TEXT
		if MESSAGE_SURFACE_TEXT {
			fill := selected ? SELECTED : hovered() ? HOVER : CARD
			ink = readable_ink(
				CARD_TEXT,
				mix_color(PLATE, fill, fill.a / 255),
				high_contrast_enabled(g_prefs) ? 7 : 4.5,
			)
		}
		nendo.text(label, {font = FONT_BODY, size = 12, color = ink, align = .Center})
	}
}

@(private)
settings_quick_themes :: proc(
	ui: ^Ui_State,
	body_width: f32,
	wide: bool,
	choices: nendo.Box,
	cell: nendo.Size,
) {
	settings_group(tr("Theme"))
	if nendo.box(nendo.id("RowTheme"))(settings_box()) {
		indices := [3]int{system_theme_index, 1, 0}
		labels := [3]string{tr("System"), tr("Light"), tr("Dark")}
		if nendo.box(nendo.id("ThemeModeRow"))(appearance_row(wide)) {
			name := ""
			if ui.theme != indices[0] && ui.theme != indices[1] && ui.theme != indices[2] {
				pack := active_pack(ui)
				name = fmt.tprintf(tr("Active theme: %s"), pack.custom ? pack.name : tr(pack.name))
			}
			row_labels(tr("Color mode"), name)
			if nendo.box(nendo.id("ThemeQuickChoices"))(choices) {
				for id, i in THEME_QUICK_IDS {
					index := indices[i]
					if index < 0 || index >= len(theme_packs) {continue}
					appearance_segment(
						nendo.id(id),
						labels[i],
						cell,
						kb_focus == id,
						ui.theme == index,
					)
				}
			}
		}
		settings_appearance_preview(body_width)
		settings_divider()
		settings_nav_row("BrowseThemes", tr("Browse themes"), "")
	}
}

@(private)
settings_appearance_controls :: proc(ui: ^Ui_State) {
	body_width := settings_body_width(ui)
	available := body_width - 20
	wide := available >= 416
	choices, cell := appearance_size_choices(available, wide)
	settings_quick_themes(ui, body_width, wide, choices, cell)
	settings_group(tr("Text & size"))
	if nendo.box(nendo.id("TextSizeGroup"))(settings_box()) {
		if nendo.box(nendo.id("RowBodyFont"))(appearance_row(wide)) {
			row_labels(tr("Message text size"), tr("Applies to message bodies and the composer."))
			if nendo.box(nendo.id("BodyFontChoices"))(choices) {
				for label, i in BODY_FONT_LABELS {
					appearance_segment(
						nendo.id("BodyFontChip", u32(i)),
						tr(label),
						cell,
						kb_focus == fmt.tprintf("BodyFontChip%d", i),
						ui.prefs.body_font == BODY_FONT_DELTAS[i],
					)
				}
			}
		}
		settings_divider()
		if nendo.box(nendo.id("RowZoom"))(appearance_row(wide)) {
			row_labels(tr("Interface zoom"), tr("Changes the whole app."))
			if nendo.box(nendo.id("ZoomChoices"))(
			{direction = available < 220 ? .Column : .Row, gap = 8, align = {y = .Center}},
			) {
				if nendo.box(nendo.id("ZoomStepper"))(appearance_segments()) {
					step := nendo.fit(min = settings_tap_size(30))
					appearance_segment(
						nendo.id("ZoomMinus"),
						"−",
						step,
						kb_focus == "ZoomMinus",
						false,
					)
					if nendo.box()({width = nendo.fit(min = 42), align = {x = .Center}}) {
						nendo.text(
							fmt.tprintf("%d%%", ui.prefs.zoom_pct),
							{font = FONT_BODY, size = 12, color = TEXT},
						)
					}
					appearance_segment(
						nendo.id("ZoomPlus"),
						"+",
						step,
						kb_focus == "ZoomPlus",
						false,
					)
				}
				settings_button("ZoomReset", tr("Reset"))
			}
		}
	}
	settings_accessibility(ui)

	preview_theme := active_theme(ui)
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
		settings_group(tr("Accent color"))
		if nendo.box(nendo.id("ThemeGroup"))(settings_box()) {
			if nendo.box(nendo.id("RowAccent"))(settings_row(true)) {
				nendo.text(
					theme_packs[preview_theme].accent_names[ui.accent],
					{font = FONT_BODY, size = 12, color = TEXT_DIM},
				)
				accent_id := nendo.id("AccentChoices")
				accents := settings_choices(accent_id)
				accents.gap = single_pane() ? 4 : 10
				if nendo.box(accent_id)(accents) {
					for name, i in theme_packs[preview_theme].accent_names {
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
	settings_group(tr("Interface"))
	if nendo.box(nendo.id("InterfaceGroup"))(settings_box()) {
		if len(theme_packs) > 0 && theme_packs[preview_theme].chalk_drawn {
			if nendo.box(nendo.id("RowHandDrawn"))({width = nendo.grow()}) {
				settings_check(
					"TgHandDrawn",
					!ui.prefs.hand_drawn_disabled,
					tr("Hand-drawn filter"),
					tr("Textured strokes and sketched avatars. Shapes stay fixed."),
				)
			}
			settings_divider()
		}
		// The committed theme decides, so hovering a gallery tile never
		// inserts the row and pushes the tile out from under the pointer.
		if len(theme_packs) > 0 && pack_ships_face(&theme_packs[active_theme(ui)]) {
			if nendo.box(nendo.id("RowThemeFont"))({width = nendo.grow()}) {
				settings_check(
					"TgThemeFont",
					!ui.prefs.theme_font_disabled,
					tr("Theme font"),
					tr("Text uses the typeface this theme ships with."),
				)
			}
			settings_divider()
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
			settings_divider()
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

	settings_group(tr("Layout"))
	if nendo.box(nendo.id("LayoutGroup"))(settings_box()) {
		if nendo.box(nendo.id("RowCentered"))({width = nendo.grow()}) {
			settings_check(
				"TgCentered",
				ui.prefs.centered_chat,
				tr("Center the conversation"),
				tr(
					"Keep the open conversation on a comfortable reading measure instead of filling the width.",
				),
			)
		}
		settings_divider()
		if nendo.box(nendo.id("RowMessageLines"))(settings_row(true)) {
			row_labels(
				tr("Message line limit"),
				tr(
					"Collapse messages and event cards after this many lines. Set to 0 to never collapse.",
				),
			)
			if nendo.box(nendo.id("MessageLinesChoices"))(
			{
				direction = settings_body_width(ui) < 270 ? .Column : .Row,
				gap = 12,
				align = {y = .Center},
			},
			) {
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
		if control.id == "ThemeQuickSystem" && system_theme_index < 0 {continue}
		if tap_size() && control.id == "ScrollChip" {continue}
		if control.id == "TgHandDrawn" &&
		   (len(theme_packs) == 0 || !theme_packs[preview_theme].chalk_drawn) {continue}
		if control.id == "TgThemeFont" &&
		   (len(theme_packs) == 0 || !pack_ships_face(&theme_packs[active_theme(ui)])) {continue}
		append(&theme_control_order, control.key)
		if control.id == "Contrast" &&
		   control.index == 2 &&
		   ui.theme != system_theme_index &&
		   has_accent_choices {
			append(&theme_control_order, ..THEME_ACCENT_KEYS[:])
		}
	}
	settings_group(tr("Sharing"))
	if nendo.box(nendo.id("ThemeActionsGroup"))(settings_box()) {
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

@(private)
settings_accessibility :: proc(ui: ^Ui_State) {
	settings_group(tr("Accessibility"))
	if nendo.box(nendo.id("AccessibilityGroup"))(settings_box()) {
		for motion in ([2]bool{true, false}) {
			if !motion {settings_divider()}
			if nendo.box(nendo.id(motion ? "RowMotion" : "RowContrast"))(settings_row(true)) {
				row_labels(
					motion ? tr("Reduce motion") : tr("Increase contrast"),
					motion ? tr("Turn off animated transitions, flights and effects. State still changes, nothing moves.") : tr("Make text and borders easier to see."),
				)
				using_system :=
					motion ? !ui.prefs.motion_override && !ui.prefs.reduce_motion : !ui.prefs.contrast_override
				on := motion ? reduce_motion_enabled(&ui.prefs) : high_contrast_enabled(&ui.prefs)
				system_on := motion ? reduce_motion_enabled(nil) : high_contrast_enabled(nil)
				choices := nendo.id(motion ? "MotionChoices" : "ContrastChoices")
				if nendo.box(choices)(settings_choices(choices)) {
					selected := using_system ? 0 : on ? 1 : 2
					for label, i in ([3]string{system_on ? tr("System (on)") : tr("System (off)"), tr("On"), tr("Off")}) {
						settings_option(
							motion ? "Motion" : "Contrast",
							u32(i),
							label,
							selected == i,
						)
					}
				}
			}
		}
	}
}
