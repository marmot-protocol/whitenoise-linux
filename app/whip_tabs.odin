package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
whip_tab_reveal :: proc(ui: ^Ui_State) {
	if !ui.whip_open || ui.page != .Chats {
		ui.whip_scroll_project = 0
		ui.whip_scroll_pending = true
		return
	}
	tab := ui.whip_tabs[ui.whip_project]
	container := clay.ID("WhipTabs")
	view := clay.GetElementData(container)
	scroll := clay.GetScrollContainerData(container)
	if !view.found || !scroll.found {return}
	if ui.whip_scroll_project != ui.whip_project ||
	   ui.whip_scroll_tab != tab ||
	   ui.whip_scroll_width != view.boundingBox.width {
		ui.whip_scroll_pending = true
	}
	ui.whip_scroll_project, ui.whip_scroll_tab = ui.whip_project, tab
	ui.whip_scroll_width = view.boundingBox.width
	if !ui.whip_scroll_pending {return}
	active := clay.GetElementData(clay.ID("WhipTab", tab))
	if !active.found {return}

	viewport, bounds := view.boundingBox, active.boundingBox
	offset := scroll.scrollPosition.x
	if bounds.x < viewport.x {offset += viewport.x - bounds.x}
	if bounds.x + bounds.width > viewport.x + viewport.width {
		offset -= bounds.x + bounds.width - viewport.x - viewport.width
	}
	overflow := max(scroll.contentDimensions.width - scroll.scrollContainerDimensions.width, 0)
	offset = clamp(offset, -overflow, 0)
	if scroll.scrollPosition.x != offset {
		scroll.scrollPosition.x = offset
		anim_moving += 1
	}
	ui.whip_scroll_pending = false
}

@(private)
whip_tab_wheel :: proc(ui: ^Ui_State, wheel: ^rl.Vector2) {
	if !ui.whip_open || ui.page != .Chats || !clay.PointerOver(clay.ID("WhipTabs")) {return}
	wheel.x += wheel.y
	wheel.y = 0
}
