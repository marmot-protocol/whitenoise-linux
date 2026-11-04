package main

import "nendo"
import rl "sdlrl"

@(private)
whip_dock_owner :: proc(ui: ^Ui_State) -> u32 {
	for item in ui.whip_attachments {
		if item.group_id != "" && whip_attach_visible(ui, item) {return item.pane}
	}
	return 0
}

@(private)
whip_dock_limit :: proc(size, span, dock_min, chat_min: f32) -> f32 {
	usable := max(span - WHIP_GUTTER, 0)
	minimum := min(dock_min, usable * 0.4)
	maximum := usable - min(chat_min, usable * 0.6)
	return clamp(size, minimum, maximum)
}

@(private)
whip_dock_end :: proc(ui: ^Ui_State) {
	// A relayout can remove the grip while the pointer is still held.
	// Keep its release away from the newly exposed chat or terminal.
	if ui.whip_dock_drag {ui.whip_dock_release = true}
	ui.whip_dock_drag = false
	ui.whip_dock_pane = 0
}

@(private)
whip_dock_divider :: proc(ui: ^Ui_State) {
	wide := ui.whip_dock_wide
	active := ui.whip_dock_drag || nendo.pointer_over(nendo.id("WhipDockDivider"))
	if nendo.box(nendo.id("WhipDockDivider"))(
	{
		width = wide ? nendo.fixed(WHIP_GUTTER) : nendo.grow(),
		height = wide ? nendo.grow() : nendo.fixed(WHIP_GUTTER),
		align = {x = .Center, y = .Center},
	},
	) {
		if active {cursor_raise(wide ? .ResizeEW : .ResizeNS)}
		if nendo.box(nendo.id_local("GutterLine"))(
		{
			width = nendo.fixed(wide ? 2 : 40),
			height = nendo.fixed(wide ? 40 : 2),
			color = active ? ACCENT : FIELD_BORDER,
			radius = rr(1),
		},
		) {}
	}
}

@(private)
whip_dock_input :: proc(ui: ^Ui_State) -> bool {
	owner := whip_dock_owner(ui)
	data := nendo.element(nendo.id("WhipDockLayout"))
	box := data.rect
	wide := ui.whip_dock_wide
	if ui.whip_dock_drag &&
	   (owner == 0 ||
			   owner != ui.whip_dock_pane ||
			   !data.found ||
			   box != ui.whip_dock_bounds) {whip_dock_end(ui)}
	if ui.whip_dock_release {
		if !rl.IsMouseButtonDown(.LEFT) {ui.whip_dock_release = false}
		return true
	}
	if owner == 0 || !data.found {return false}
	point := rl.GetMousePosition()
	point.x /= UI_ZOOM; point.y /= UI_ZOOM
	if !ui.whip_dock_drag &&
	   rl.IsMouseButtonPressed(.LEFT) &&
	   ui.whip_attach_drag == 0 &&
	   ui.whip_attach_resize == 0 &&
	   nendo.pointer_over(nendo.id("WhipDockDivider")) {
		divider := nendo.element(nendo.id("WhipDockDivider")).rect
		ui.whip_dock_drag = true
		ui.whip_dock_pane = owner
		ui.whip_dock_wide = wide
		ui.whip_dock_bounds = box
		ui.whip_dock_offset = wide ? point.x - divider.x : point.y - divider.y
		whip_attach_release_focus(ui)
	}
	if !ui.whip_dock_drag {return false}
	cursor_raise(wide ? .ResizeEW : .ResizeNS)
	if wide {
		ui.whip_dock_width = whip_dock_limit(
			box.x + box.width - point.x + ui.whip_dock_offset - WHIP_GUTTER,
			box.width,
			240,
			PAGE_W_MIN,
		)
	} else {
		ui.whip_dock_height = whip_dock_limit(
			box.y + box.height - point.y + ui.whip_dock_offset - WHIP_GUTTER,
			box.height,
			120,
			200,
		)
	}
	if !rl.IsMouseButtonDown(.LEFT) {
		ui.whip_dock_drag = false
		ui.whip_dock_pane = 0
	}
	return true
}
