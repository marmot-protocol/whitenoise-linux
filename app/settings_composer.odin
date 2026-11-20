package main

import "nendo"
import rl "sdlrl"

@(private)
COMPOSER_TAB :: 3

@(private = "file")
COMPOSER_SLOT_LABELS := [Composer_Slot]string {
	.Menu  = N_("+ menu"),
	.Left  = N_("Left"),
	.Right = N_("Right"),
	.Send  = N_("Send button"),
	.Off   = N_("Off"),
}

@(private)
settings_composer :: proc(ui: ^Ui_State) {
	if nendo.box(nendo.id("ComposerSettings"))(
	{width = nendo.grow(), direction = .Column, gap = 12},
	) {
		if nendo.box(nendo.id_local("ComposerHeading"))(
		{width = nendo.grow(), gap = 8, align = {y = .Center}},
		) {
			row_labels(tr("Composer preview"), "")
			if ui.composer_settings_from_chat {settings_button("ComposerBack", tr("Back to chat"))}
		}
		composer_preview(ui)
		id := nendo.id("ComposerLayoutOptions")
		if nendo.box(id)(settings_choices(id)) {
			config := composer_config(&ui.prefs)
			settings_option(
				"ComposerLayout",
				u32(Composer_Layout.Automatic),
				tr("Automatic"),
				config.layout == .Automatic,
			)
			settings_option(
				"ComposerLayout",
				u32(Composer_Layout.Expanded),
				tr("Always expanded"),
				config.layout == .Expanded,
			)
		}
		scrollbar(id)
		if nendo.box(nendo.id_local("ComposerToolsHeading"))(
		{width = nendo.grow(), gap = 8, align = {y = .Center}},
		) {
			row_labels(tr("Composer shortcuts"), "")
			settings_button("ComposerReset", tr("Restore defaults"))
		}
		nendo.text(
			tr("Drag shortcuts to move them. Select one for more options."),
			{font = FONT_BODY, size = 12, color = TEXT_DIM},
		)
		composer_trays(ui)
		composer_inspector(ui)
	}
	composer_drag_feedback(ui)
}

@(private = "file")
composer_preview :: proc(ui: ^Ui_State) {
	plan := composer_plan(ui, settings_body_width(ui) - 24, .Preview)
	inline := plan.config.layout == .Automatic && plan.inline_width >= COMPOSER_TEXT_MIN
	if nendo.box(nendo.id("ComposerPreview"))(
	{
		width = nendo.grow(),
		direction = .Column,
		padding = nendo.pad(12),
		gap = 8,
		color = PLATE,
		radius = rr(12),
		border = {color = FIELD_BORDER, width = bw()},
	},
	) {
		if !inline {composer_preview_text()}
		if nendo.box(nendo.id("ComposerPreviewRow"))(
		{width = nendo.grow(), gap = plan.gap, align = {y = .Center}},
		) {
			composer_tools(ui, plan, .Left)
			if inline {
				composer_preview_text()
			} else if nendo.box(nendo.id("ComposerPreviewGap"))({width = nendo.grow()}) {}
			composer_tools(ui, plan, .Right)
			composer_primary(ui, plan, .Preview)
		}
	}
}

@(private = "file")
composer_preview_text :: proc() {
	if nendo.box(nendo.id("ComposerPreviewDraft"))({width = nendo.grow(), clip = {x = true}}) {
		nendo.text(
			tr("Send a message..."),
			{font = FONT_BODY, size = BODY_FS, color = TEXT_LO, wrap = .None},
		)
	}
}

@(private = "file")
composer_trays :: proc(ui: ^Ui_State) {
	width := settings_body_width(ui)
	side_width := (width - 8) * 0.5
	if nendo.box(nendo.id("ComposerSides"))({width = nendo.grow(), gap = 8}) {
		composer_tray(ui, .Left, side_width)
		composer_tray(ui, .Right, side_width)
	}
	composer_tray(ui, .Menu, width)
}

@(private = "file")
composer_tray :: proc(ui: ^Ui_State, slot: Composer_Slot, width: f32) {
	config := composer_config(&ui.prefs)
	size := tap_size() ? tap_min() : 36
	columns := max(1, int((width - 20 + 6) / (size + 6)))
	tiles: [COMPOSER_SHORTCUT_COUNT]Composer_Action
	count := 0
	for action in config.order[:COMPOSER_SHORTCUT_COUNT] {
		if config.slots[action] != slot {continue}
		tiles[count] = action
		count += 1
	}
	drag := ui.composer_editor.drag
	target := drag.active && drag.drop.valid && !drag.drop.preview && drag.drop.slot == slot
	if nendo.box(nendo.id("ComposerTray", u32(slot)))(
	{
		width = nendo.grow(),
		direction = .Column,
		gap = 6,
		padding = nendo.pad(10),
		color = target ? SELECTED : CARD,
		radius = rr(10),
		border = {color = target ? ACCENT : FIELD_BORDER, width = bw()},
	},
	) {
		nendo.text(
			tr(COMPOSER_SLOT_LABELS[slot]),
			{font = FONT_TITLE, size = 12, color = TEXT_DIM},
		)
		for first := 0; first < max(count, 1); first += columns {
			if nendo.box()(
			{width = nendo.grow(), height = nendo.fixed(size), gap = 6, align = {y = .Center}},
			) {
				for i in first ..< min(count, first + columns) {composer_tile(ui, tiles[i], size)}
				if count ==
				   0 {nendo.text(tr("Drop here"), {font = FONT_BODY, size = 11, color = TEXT_DIM})}
			}
		}
	}
}

@(private = "file")
composer_tile :: proc(ui: ^Ui_State, action: Composer_Action, size: f32) {
	editor := &ui.composer_editor
	held := editor.drag.source == action && !editor.drag.cancelled
	chosen := editor.selected == action
	if nendo.box(nendo.id("ComposerTile", u32(action)))(
	{
		width = nendo.fixed(size),
		height = nendo.fixed(size),
		align = {x = .Center, y = .Center},
		color = held ? FIELD_BORDER : chosen ? SELECTED : hovered() ? HOVER : ROW_BG,
		border = {color = chosen ? ACCENT : FIELD_BORDER, width = bw()},
		radius = rr(8),
	},
	) {
		unavailable := action == .Dictate && !ui.prefs.stt_enabled
		composer_glyph(action, chosen ? ACCENT : held || unavailable ? TEXT_DIM : TEXT)
		if nendo.hovered() &&
		   editor.drag.source == .None {tooltip(tr(COMPOSER_ACTIONS[action].name))}
	}
}

@(private = "file")
composer_glyph :: proc(action: Composer_Action, color: nendo.Color) {
	text_icon := action == .GM || action == .More
	glyph := action == .Dictate ? "\uf11c" : COMPOSER_ACTIONS[action].icon
	nendo.text(
		glyph,
		{
			font = text_icon ? FONT_TITLE : FONT_ICON,
			size = action == .More ? 22 : text_icon ? 12 : 16,
			color = color,
		},
	)
}

@(private = "file")
composer_inspector :: proc(ui: ^Ui_State) {
	config := composer_config(&ui.prefs)
	action := ui.composer_editor.selected
	voice_slot := config.slots[.Voice]
	voice_outside := voice_slot == .Send || voice_slot == .Off
	if action == .None && !voice_outside {return}
	if nendo.box(nendo.id("ComposerInspector"))(
	{
		width = nendo.grow(),
		direction = .Column,
		gap = 8,
		padding = nendo.pad(10),
		color = CARD,
		radius = rr(10),
		border = {color = FIELD_BORDER, width = bw()},
	},
	) {
		if voice_outside && action != .Voice {
			if nendo.box()({width = nendo.grow(), gap = 10, align = {y = .Center}}) {
				composer_tile(ui, .Voice, tap_size() ? tap_min() : 36)
				row_labels(tr(COMPOSER_ACTIONS[.Voice].name), tr(COMPOSER_SLOT_LABELS[voice_slot]))
			}
		}
		if action == .None {return}
		if nendo.box()({width = nendo.grow(), gap = 8, align = {y = .Center}}) {
			if voice_outside && action == .Voice {
				composer_tile(ui, .Voice, tap_size() ? tap_min() : 36)
			} else {
				composer_glyph(action, ACCENT)
			}
			row_labels(
				tr(COMPOSER_ACTIONS[action].name),
				action == .Dictate && !ui.prefs.stt_enabled ? tr("Enable dictation in Speech to use this shortcut.") : "",
			)
		}
		id := nendo.id("ComposerPlacement")
		if nendo.box(id)(settings_choices(id)) {
			allowed := composer_slots(action)
			for slot in Composer_Slot {
				if slot not_in allowed {continue}
				settings_option(
					"ComposerPlace",
					u32(slot),
					tr(COMPOSER_SLOT_LABELS[slot]),
					config.slots[action] == slot,
				)
			}
		}
		scrollbar(id)
		before, after := composer_neighbors(config, action)
		if before != .None || after != .None {
			id := nendo.id("ComposerOrderOptions")
			if nendo.box(id)(settings_choices(id)) {
				if before != .None {settings_button("ComposerEarlier", tr("Move earlier"))}
				if after != .None {settings_button("ComposerLater", tr("Move later"))}
			}
			scrollbar(id)
		}
	}
}

@(private)
Composer_Editor :: struct {
	selected: Composer_Action,
	drag:     Composer_Drag,
	reveal:   bool,
}

@(private = "file")
Composer_Drag :: struct {
	source:            Composer_Action,
	from:              nendo.Vector2,
	active, cancelled: bool,
	drop:              Composer_Drop,
}

@(private = "file")
Composer_Drop :: struct {
	slot:           Composer_Slot,
	before:         Composer_Action,
	mark:           nendo.Id,
	valid, preview: bool,
}

@(private = "file")
composer_tile_id :: proc(action: Composer_Action) -> nendo.Id {
	return nendo.id("ComposerTile", u32(action))
}

@(private = "file")
composer_hit :: proc(ui: ^Ui_State) -> Composer_Action {
	for action in composer_config(&ui.prefs).order[:COMPOSER_SHORTCUT_COUNT] {
		if nendo.pointer_over(composer_tile_id(action)) ||
		   nendo.pointer_over(nendo.id(COMPOSER_ACTIONS[action].id)) {
			return action
		}
	}
	return .None
}

@(private = "file")
composer_drop_at :: proc(ui: ^Ui_State, point: nendo.Vector2) -> Composer_Drop {
	drop: Composer_Drop
	for slot in ([3]Composer_Slot{.Left, .Right, .Menu}) {
		if !nendo.pointer_over(nendo.id("ComposerTray", u32(slot))) {continue}
		drop.slot, drop.valid = slot, true
		break
	}
	if !drop.valid && nendo.pointer_over(nendo.id("ComposerPreviewRow")) {
		row := nendo.element(nendo.id("ComposerPreviewRow")).rect
		drop.slot = point.x < row.x + row.width * 0.5 ? .Left : .Right
		if hit := composer_hit(ui); hit != .None {
			slot := composer_config(&ui.prefs).slots[hit]
			if slot == .Left || slot == .Right {drop.slot = slot}
		}
		drop.valid, drop.preview = true, true
	}
	source := ui.composer_editor.drag.source
	if !drop.valid || drop.slot not_in composer_slots(source) {return {}}
	config := composer_config(&ui.prefs)
	for action in config.order[:COMPOSER_SHORTCUT_COUNT] {
		if action == source || config.slots[action] != drop.slot {continue}
		id := drop.preview ? nendo.id(COMPOSER_ACTIONS[action].id) : composer_tile_id(action)
		box := nendo.element(id)
		if !box.found {continue}
		r := box.rect
		if point.y < r.y - 3 || (point.y < r.y + r.height + 3 && point.x < r.x + r.width * 0.5) {
			drop.before, drop.mark = action, id
			break
		}
		drop.mark = id
	}
	return drop
}

// Move one action without changing the relative order of any other shortcut.
@(private = "file")
composer_move :: proc(
	config: ^Composer_Config,
	action: Composer_Action,
	slot: Composer_Slot,
	before: Composer_Action = .None,
) {
	from, to := 0, -1
	for other, i in config.order[:COMPOSER_SHORTCUT_COUNT] {
		if other == action {from = i; continue}
		if before != .None {
			if other == before {to = i}
		} else if config.slots[other] == slot {
			to = i + 1
		}
	}
	if to >= 0 {
		if to > from {to -= 1}
		for i := from; i < to; i += 1 {config.order[i] = config.order[i + 1]}
		for i := from; i > to; i -= 1 {config.order[i] = config.order[i - 1]}
		config.order[to] = action
	}
	config.slots[action] = slot
}

@(private = "file")
composer_neighbors :: proc(
	config: ^Composer_Config,
	action: Composer_Action,
) -> (
	before, after: Composer_Action,
) {
	slot := config.slots[action]
	if slot == .Off || slot == .Send {return}
	found := false
	for other in config.order[:COMPOSER_SHORTCUT_COUNT] {
		if other == action {found = true; continue}
		if config.slots[other] != slot {continue}
		if found {after = other; break}
		before = other
	}
	return
}

@(private = "file")
composer_save :: proc(ui: ^Ui_State, config: Composer_Config) {
	if config == composer_config(&ui.prefs)^ {return}
	ui.prefs.composer = config
	save_settings(ui, background = true)
}

@(private)
handle_settings_composer :: proc(ui: ^Ui_State) {
	if clicked("ComposerBack") {settings_back(ui); return}
	if clicked("ComposerReset") {
		ui.composer_editor = {}
		ui.prefs.composer = {}
		save_settings(ui, background = true)
		return
	}
	config := composer_config(&ui.prefs)^
	for layout in Composer_Layout {
		if clicked_indexed("ComposerLayout", u32(layout)) {
			config.layout = layout
			composer_save(ui, config)
			return
		}
	}
	action := ui.composer_editor.selected
	if action == .None {return}
	for slot in Composer_Slot {
		if slot != config.slots[action] && clicked_indexed("ComposerPlace", u32(slot)) {
			composer_move(&config, action, slot)
			composer_save(ui, config)
			return
		}
	}
	before, after := composer_neighbors(&config, action)
	if before != .None && clicked("ComposerEarlier") {
		composer_move(&config, action, config.slots[action], before)
	} else if after != .None && clicked("ComposerLater") {
		_, next := composer_neighbors(&config, after)
		composer_move(&config, action, config.slots[action], next)
	}
	composer_save(ui, config)
}

@(private)
handle_composer_drag :: proc(ui: ^Ui_State) -> bool {
	editor := &ui.composer_editor
	drag := &editor.drag
	if ui.page != .Settings ||
	   ui.settings_section != .General ||
	   ui.settings_tab != COMPOSER_TAB ||
	   settings_on_menu(ui) ||
	   modal_open(ui) ||
	   ui.add_account_open {
		drag^ = {}
		return false
	}
	if drag.source == .None {
		if !mouse_pressed() {return false}
		source := composer_hit(ui)
		if source == .None {return false}
		drag^ = {
			source = source,
			from   = nendo.pointer().position,
		}
		anim_moving += 1
		return true
	}
	if rl.IsKeyPressed(.ESCAPE) || !rl.IsWindowFocused() {
		drag.cancelled, drag.active = true, false
	}
	point := nendo.pointer().position
	if !drag.cancelled {
		delta := point - drag.from
		threshold := rl.TouchActive() ? LONG_PRESS_SLOP : DRAG_MIN
		if max(abs(delta.x), abs(delta.y)) > threshold {drag.active = true}
	}
	released := rl.IsMouseButtonReleased(.LEFT) || forced_release
	if released || !rl.IsMouseButtonDown(.LEFT) && !forced_press {
		if released && !drag.cancelled {
			if drag.active {
				drop := composer_drop_at(ui, point)
				if drop.valid {
					config := composer_config(&ui.prefs)^
					composer_move(&config, drag.source, drop.slot, drop.before)
					composer_save(ui, config)
				}
			} else if composer_hit(ui) == drag.source {
				editor.selected = editor.selected == drag.source ? .None : drag.source
				editor.reveal = editor.selected != .None
			}
		}
		drag^ = {}
		anim_moving += 1
		return true
	}
	if drag.active {
		composer_drag_scroll(point)
		drag.drop = composer_drop_at(ui, point)
		cursor_raise(.Grabbing)
		anim_moving += 1
	}
	return true
}

@(private)
composer_reveal_inspector :: proc(ui: ^Ui_State) -> bool {
	if !ui.composer_editor.reveal {return false}
	ui.composer_editor.reveal = false
	id := nendo.id("ComposerInspector")
	if !nendo.element(id).found {return false}
	page := nendo.id("SettingsPage")
	scroll := nendo.scroll(page)
	if !scroll.found {return false}
	before := scroll.position.y
	scroll_into_view(page, id)
	return scroll.position.y != before
}

@(private = "file")
composer_drag_scroll :: proc(point: nendo.Vector2) {
	id := nendo.id("SettingsPage")
	view := nendo.element(id).rect
	if point.x < view.x || point.x >= view.x + view.width {return}
	scroll := nendo.scroll(id)
	if !scroll.found {return}
	step := min(rl.GetFrameTime(), 0.05) * 300
	delta: f32
	if point.y >= view.y && point.y < view.y + 24 {delta = step}
	bottom := view.y + view.height
	if point.y >= bottom - 24 && point.y < bottom {delta = -step}
	span := max(0, scroll.content.height - scroll.viewport.height)
	scroll.position.y = clamp(scroll.position.y + delta, -span, 0)
}

@(private = "file")
composer_drag_feedback :: proc(ui: ^Ui_State) {
	drag := &ui.composer_editor.drag
	if !drag.active {return}
	point := nendo.pointer().position
	if drag.drop.valid {
		r, found := element_box(drag.drop.mark)
		if !found && drag.drop.preview {
			r = nendo.element(nendo.id("ComposerPreviewRow")).rect
			r.width =
				drag.drop.slot == .Right ? max(0, r.width - (tap_size() ? tap_min() : 28)) : 0
			found = true
		}
		if found {
			x := drag.drop.before != .None ? r.x - 3 : r.x + r.width + 1
			page := nendo.element(nendo.id("SettingsPage")).rect
			top := max(r.y, page.y)
			height := max(0, min(r.y + r.height, page.y + page.height) - top)
			if nendo.box(nendo.id("ComposerInsertion"))(
			{
				width = nendo.fixed(2),
				height = nendo.fixed(height),
				color = ACCENT,
				radius = rr(1),
				floating = {attach_to = .Root, offset = {x, top}, z = 18, pointer = .Passthrough},
			},
			) {}
		}
	}
	size :: 40
	x, y := panel_pos(point.x + 10, point.y - 28, size + 8, size + 8)
	if nendo.box(nendo.id("ComposerGhost"))(
	{
		width = nendo.fixed(size),
		height = nendo.fixed(size),
		align = {x = .Center, y = .Center},
		floating = {attach_to = .Root, offset = {x, y}, z = 20, pointer = .Passthrough},
		color = CARD,
		border = {color = ACCENT, width = bw()},
		radius = rr(8),
	},
	) {composer_glyph(drag.source, ACCENT)}
}
