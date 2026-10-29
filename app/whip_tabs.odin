package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:slice"
import "core:strings"
import rl "sdlrl"

@(private)
Whip_Tab_Drag :: struct {
	project, tab:      u32,
	from:              [2]f32,
	active, cancelled: bool,
	slot:              int,
}

// Slots are gaps between tabs, including both ends. Move whole records so
// titles and unread counts stay attached to their stable terminal IDs.
@(private)
whip_tab_move :: proc(tabs: []rl.Whip_Tab, id: u32, slot: int) -> bool {
	if slot < 0 || slot > len(tabs) {return false}
	for tab, from in tabs {
		if tab.id != id {continue}
		to := slot
		if to > from {to -= 1}
		if to == from {return false}
		if to < from {
			copy(tabs[to + 1:from + 1], tabs[to:from])
		} else {
			copy(tabs[from:to], tabs[from + 1:to + 1])
		}
		tabs[to] = tab
		return true
	}
	return false
}

@(private)
whip_tab_order :: proc(ui: ^Ui_State) {
	folder := whip_workspace_folder(ui.whip_project)
	for &saved in ui.prefs.whip_selected_tabs {
		if saved.account != ui.account_ref ||
		   saved.folder != folder ||
		   len(saved.order) == 0 {continue}
		for pane in rl.WhipPanes() {
			if pane.project != ui.whip_project || pane.session != saved.session {continue}
			slice.sort_by_with_data(rl.WhipTabs(), proc(a, b: rl.Whip_Tab, data: rawptr) -> bool {
					order := (^map[u32]int)(data)^
					ar, ak := order[a.id]
					br, bk := order[b.id]
					if ak != bk {return ak}
					if ak && ar != br {return ar < br}
					return a.id < b.id
				}, &saved.order)
			return
		}
	}
}

@(private)
whip_tab_save :: proc(ui: ^Ui_State) {
	folder := whip_workspace_folder(ui.whip_project)
	if ui.account_ref == "" || folder == "" {return}
	anchor: rl.Whip_Pane
	for pane in rl.WhipPanes() {
		if pane.project == ui.whip_project &&
		   pane.tab == ui.whip_tabs[ui.whip_project] &&
		   pane.session != ([4]u64{}) {anchor = pane; break}
	}
	if anchor.id == 0 {return}
	index := -1
	for saved, i in ui.prefs.whip_selected_tabs {
		if saved.account == ui.account_ref && saved.folder == folder {index = i; break}
	}
	if index < 0 {
		append(
			&ui.prefs.whip_selected_tabs,
			Whip_Saved_Tab {
				account = strings.clone(ui.account_ref),
				folder = strings.clone(folder),
			},
		)
		index = len(ui.prefs.whip_selected_tabs) - 1
	}
	saved := &ui.prefs.whip_selected_tabs[index]
	saved.pane, saved.tab, saved.session = anchor.id, anchor.tab, anchor.session
	clear(&saved.order)
	for tab, i in rl.WhipTabs() {saved.order[tab.id] = i}
	ui.settings_dirty = true
}

@(private)
whip_tab_input :: proc(ui: ^Ui_State) -> bool {
	drag := &ui.whip_tab_drag
	if !ui.whip_open || drag.project != 0 && drag.project != ui.whip_project {
		drag^ = {}
		return false
	}
	mouse := test_pointer_on ? test_pointer : transmute([2]f32)rl.GetMousePosition()
	mouse /= UI_ZOOM
	if drag.tab == 0 {
		if !mouse_pressed() {return false}
		for tab in rl.WhipTabs() {
			if !clay.PointerOver(clay.ID("WhipTab", tab.id)) ||
			   clay.PointerOver(clay.ID("WhipTabClose", tab.id)) {continue}
			whip_workspace_navigation(ui)
			drag^ = {
				project = ui.whip_project,
				tab     = tab.id,
				from    = mouse,
			}
			return true
		}
		return false
	}
	live := false
	for tab in rl.WhipTabs() {if tab.id == drag.tab {live = true; break}}
	if !live || rl.IsKeyPressed(.ESCAPE) || !rl.IsWindowFocused() {
		drag.cancelled, drag.active = true, false
	}
	if drag.cancelled {
		// Escape must not turn the eventual release into a close-button click.
		if mouse_released() || !rl.IsMouseButtonDown(.LEFT) && !forced_press {drag^ = {}}
		return true
	}
	if mouse_released() || !rl.IsMouseButtonDown(.LEFT) && !forced_press {
		active := drag.active
		if active && clay.PointerOver(clay.ID("WhipTabs")) {
			if whip_tab_move(rl.WhipTabs(), drag.tab, drag.slot) {whip_tab_save(ui)}
			ui.whip_scroll_pending = true
		}
		drag^ = {}
		return active
	}
	delta := mouse - drag.from
	if delta.x * delta.x + delta.y * delta.y > DRAG_MIN * DRAG_MIN {drag.active = true}
	if !drag.active {return true}
	cursor_raise(.Grabbing)
	view := clay.GetElementData(clay.ID("WhipTabs"))
	scroll := clay.GetScrollContainerData(clay.ID("WhipTabs"))
	if view.found &&
	   scroll.found &&
	   mouse.y >= view.boundingBox.y &&
	   mouse.y < view.boundingBox.y + view.boundingBox.height {
		b := view.boundingBox
		step: f32
		if mouse.x < b.x + 24 {step = 8}
		if mouse.x > b.x + b.width - 24 {step = -8}
		span := max(scroll.contentDimensions.width - scroll.scrollContainerDimensions.width, 0)
		scroll.scrollPosition.x = clamp(scroll.scrollPosition.x + step, -span, 0)
	}
	drag.slot = 0
	for tab, i in rl.WhipTabs() {
		box := clay.GetElementData(clay.ID("WhipTab", tab.id))
		if box.found && mouse.x > box.boundingBox.x + box.boundingBox.width / 2 {drag.slot = i + 1}
	}
	return true
}

@(private)
whip_tab_reveal :: proc(ui: ^Ui_State) {
	if !ui.whip_open || ui.page != .Chats {
		ui.whip_scroll_project = 0
		ui.whip_scroll_pending = true
		return
	}
	if ui.whip_tab_drag.active {return}
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
