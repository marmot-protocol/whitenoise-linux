package main

import "core:strings"
import "nendo"
import rl "sdlrl"

// Placement is independent of the native split tree: returning a pane only
// removes this record and never sends the destructive native Close action.
Whip_Attachment :: struct {
	pane:              u32,
	session:           [4]u64,
	account, group_id: string,
	bounds:            nendo.Rect,
}

@(private)
whip_attach_index :: proc(ui: ^Ui_State, pane: u32) -> int {
	for item, i in ui.whip_attachments {if item.pane == pane {return i}}
	return -1
}

@(private)
whip_attach_release_focus :: proc(ui: ^Ui_State) {
	ui.whip_focus = 0
	if ui.focus == .Whip {ui.focus = .Compose}
}

@(private)
Whip_Placement_Disposition :: enum {
	Forget,
	Preserve,
}

@(private)
whip_attach_return :: proc(
	ui: ^Ui_State,
	pane: u32,
	placement: Whip_Placement_Disposition = .Forget,
) {
	i := whip_attach_index(ui, pane)
	if i < 0 {return}
	if placement ==
	   .Forget {whip_workspace_forget(ui, ui.whip_attachments[i].account, pane, ui.whip_attachments[i].session)}
	delete(ui.whip_attachments[i].account)
	delete(ui.whip_attachments[i].group_id)
	ordered_remove(&ui.whip_attachments, i)
	if ui.whip_focus == pane {whip_attach_release_focus(ui)}
	if ui.whip_attach_drag == pane {ui.whip_attach_drag = 0}
	if ui.whip_attach_resize == pane {ui.whip_attach_resize = 0}
}

@(private)
whip_attach_rejoin :: proc(ui: ^Ui_State, pane: u32) {
	info, live := rl.WhipPaneInfo(pane)
	whip_attach_return(ui, pane)
	if !live {return}
	whip_open_project(ui, info.project)
	ui.whip_tabs[info.project] = info.tab
	ui.whip_return_focus = pane
}

@(private)
whip_attach_clear :: proc(ui: ^Ui_State) {
	for len(ui.whip_attachments) >
	    0 {whip_attach_return(ui, ui.whip_attachments[0].pane, .Preserve)}
	delete(ui.whip_attachments); ui.whip_attachments = nil
	delete(ui.whip_workspace_account); ui.whip_workspace_account = ""
	ui.whip_workspace_loaded, ui.whip_workspace_pending = false, false
	whip_attach_release_focus(ui)
	ui.whip_attach_drag, ui.whip_attach_resize = 0, 0
	ui.whip_return_focus = 0
	ui.whip_chat_width = 0
	whip_dock_end(ui)
	ui.whip_dock_width, ui.whip_dock_height = 0, 0
}

@(private)
whip_attach_clamp :: proc(bounds: ^nendo.Rect) {
	w := max(f32(rl.GetScreenWidth()) / UI_ZOOM, 1)
	h := max(f32(rl.GetScreenHeight()) / UI_ZOOM - 24, 1)
	bounds.width = clamp(bounds.width, min(300, w), w)
	bounds.height = clamp(bounds.height, min(160, h), h)
	bounds.x = clamp(bounds.x, 0, max(w - bounds.width, 0))
	bounds.y = clamp(bounds.y, 0, max(h - bounds.height, 0))
}

@(private)
whip_attach_float :: proc(ui: ^Ui_State, pane: u32) {
	info, live := rl.WhipPaneInfo(pane)
	if !live || ui.account_ref == "" {return}
	i := whip_attach_index(ui, pane)
	if i >= 0 && ui.whip_attachments[i].session != info.session {
		whip_attach_return(ui, pane, .Preserve)
		i = -1
	}
	if i < 0 {
		w := f32(rl.GetScreenWidth()) / UI_ZOOM
		h := f32(rl.GetScreenHeight()) / UI_ZOOM
		offset := f32(len(ui.whip_attachments) % 6) * 24
		append(
			&ui.whip_attachments,
			Whip_Attachment {
				pane = pane,
				session = info.session,
				account = strings.clone(ui.account_ref),
				bounds = {
					max(w - 640 - offset, 0),
					64 + offset,
					min(620, w * 0.75),
					min(380, h * 0.55),
				},
			},
		)
		i = len(ui.whip_attachments) - 1
	} else {
		delete(ui.whip_attachments[i].group_id)
		ui.whip_attachments[i].group_id = ""
	}
	whip_attach_clamp(&ui.whip_attachments[i].bounds)
	ui.whip_focus, ui.focus = pane, .Whip
}

@(private)
whip_attach_chat :: proc(ui: ^Ui_State) -> string {
	if ui.page != .Chats ||
	   ui.whip_open ||
	   ui.selected < 0 ||
	   ui.selected >= len(ui.chats) ||
	   ui.show_members ||
	   ui.group_files_open ||
	   ui.new_chat_open {return ""}
	return ui.chats[ui.selected].group_id
}

@(private)
whip_attach_dock :: proc(ui: ^Ui_State, pane: u32) {
	i := whip_attach_index(ui, pane)
	group := whip_attach_chat(ui)
	if i < 0 || group == "" || ui.whip_attachments[i].account != ui.account_ref {return}
	delete(ui.whip_attachments[i].group_id)
	ui.whip_attachments[i].group_id = strings.clone(group)
	ui.whip_focus, ui.focus = pane, .Whip
}

@(private)
whip_attach_allowed :: proc(ui: ^Ui_State) -> bool {
	return(
		rl.WhipAvailable() &&
		len(ui.accounts) > 0 &&
		ui.account_ref != "" &&
		!ui.add_account_open &&
		!ui.new_chat_open &&
		!modal_open(ui) &&
		!ui.picker_open &&
		!ui.poll_open &&
		ui.row_menu < 0 &&
		!ui.folder_menu_open \
	)
}

@(private)
whip_attach_visible :: proc(ui: ^Ui_State, item: Whip_Attachment) -> bool {
	if !whip_attach_allowed(ui) || item.account != ui.account_ref {return false}
	return(
		item.group_id == "" ||
		(item.group_id == whip_attach_chat(ui) && (!single_pane() || phone_detail(ui))) \
	)
}

@(private)
whip_attach_validate :: proc(ui: ^Ui_State) {
	if state := rl.WhipState(); state == .Ready || state == .Missing {
		for i := len(ui.whip_attachments) - 1; i >= 0; i -= 1 {
			item := ui.whip_attachments[i]
			info, live := rl.WhipPaneInfo(item.pane)
			if !live || info.session != item.session {
				whip_attach_return(
					ui,
					item.pane,
					!live || info.session != ([4]u64{}) ? .Forget : .Preserve,
				)
			}
		}
	}
}

@(private)
whip_attach_prune :: proc(ui: ^Ui_State) {
	whip_workspace_prepare(ui)
	ui.whip_chat_width = 0
	whip_attach_validate(ui)
	for &item in ui.whip_attachments {whip_attach_clamp(&item.bounds)}
	if ui.focus == .Whip && whip_attach_focused(ui) == 0 {whip_attach_release_focus(ui)}
}

@(private)
whip_attach_surfaces :: proc(ui: ^Ui_State) -> []rl.Whip_Surface {
	surfaces := make([]rl.Whip_Surface, len(ui.whip_attachments), context.temp_allocator)
	for item, i in ui.whip_attachments {surfaces[i] = {
			pane    = item.pane,
			visible = whip_attach_visible(ui, item),
		}}
	return surfaces
}

@(private)
whip_attach_focused :: proc(ui: ^Ui_State) -> u32 {
	if ui.focus != .Whip {return 0}
	i := whip_attach_index(ui, ui.whip_focus)
	if i >= 0 && whip_attach_visible(ui, ui.whip_attachments[i]) {return ui.whip_focus}
	return 0
}

@(private)
whip_attach_button :: proc(id: string, pane: u32, label: string) {
	if nendo.box(nendo.id(id, pane))(
	{
		width = nendo.fit(min = tap_size() ? tap_min() : 0),
		height = nendo.fixed(tap_size() ? tap_min() : 20),
		padding = {left = 5, right = 5},
		align = {y = .Center},
		color = hovered() ? HOVER : PLATE,
		radius = rr(3),
	},
	) {
		nendo.text(label, {font = FONT_BODY, size = 10, color = TEXT_DIM, wrap = .None})
		if hovered() {cursor_raise(.Pointer); tooltip(label)}
	}
}

@(private)
whip_attached_pane :: proc(ui: ^Ui_State, item: Whip_Attachment) {
	pane, live := rl.WhipPaneInfo(item.pane)
	if !live {return}
	floating := item.group_id == ""
	root := nendo.id(floating ? "WhipFloat" : "WhipDockPane", pane.id)
	show_header := floating || whip_header_open(root, nendo.id("WhipAttachHead", pane.id))
	payload := new(Whip_Payload, context.temp_allocator)
	payload^ = {
		.Whip,
		pane.id,
		floating ? 0 : (show_header ? (tap_size() ? tap_min() : WHIP_HEADER_H) : WHIP_REVEAL_H),
	}
	if nendo.box(root)(
	{
		width = floating ? nendo.fixed(item.bounds.width) : nendo.grow(),
		height = floating ? nendo.fixed(item.bounds.height) : nendo.grow(),
		direction = .Column,
		padding = nendo.pad(1),
		floating = floating ? nendo.Floating{attach_to = .Root, z = 8, offset = {item.bounds.x, item.bounds.y}, attach = {element = .Left_Top, parent = .Left_Top}} : {},
		color = PANEL,
		radius = rr(5),
		border = {
			color = ui.whip_focus == pane.id && ui.focus == .Whip ? ACCENT_DIM : FIELD_BORDER,
			width = nendo.outline(1),
		},
		clip = {x = true, y = true},
	},
	) {
		if show_header {
			if nendo.box(nendo.id("WhipAttachHead", pane.id))(
			{
				width = floating ? nendo.percent(1) : nendo.fixed(max(nendo.element(root).rect.width - 2, 0)),
				height = nendo.fixed(tap_size() ? tap_min() : WHIP_HEADER_H),
				gap = 3,
				padding = {left = 5, right = 3},
				align = {y = .Center},
				floating = floating ? nendo.Floating{} : nendo.Floating{attach_to = .Parent, clip_to = .Parent, z = 7, offset = {1, 1}, attach = {element = .Left_Top, parent = .Left_Top}},
				color = ui.whip_focus == pane.id ? SELECTED : PANEL,
				border = {color = DIVIDER, width = {bottom = 1}},
			},
			) {
				if hovered() {cursor_raise(floating ? .Grabbing : .Pointer)}
				if nendo.box(nendo.id("WhipAttachTitle", pane.id))(
				{width = nendo.grow(), clip = {x = true}},
				) {
					nendo.text(
						pane.name,
						{font = FONT_MONO, size = 10, color = TEXT_DIM, wrap = .None},
					)
					if hovered() {tooltip(pane.name)}
				}
				if floating {
					if whip_attach_chat(ui) !=
					   "" {whip_attach_button("WhipAttachDock", pane.id, tr("Dock to chat"))}
				} else {whip_attach_button("WhipAttachFloat", pane.id, tr("Float"))}
				whip_attach_button("WhipAttachReturn", pane.id, tr("Return to project"))
			}
		}
		if nendo.box(nendo.id("WhipAttachContent", pane.id))(
		{
			width = nendo.percent(1),
			height = nendo.grow(),
			clip = {x = true, y = true},
			custom = payload,
		},
		) {whip_pane_progress(pane)}
		if floating {
			if nendo.box(nendo.id("WhipAttachFoot", pane.id))(
			{
				width = nendo.percent(1),
				height = nendo.fixed(tap_size() ? tap_min() : 12),
				align = {x = .Right},
			},
			) {
				if nendo.box(nendo.id("WhipAttachResize", pane.id))(
				{
					width = nendo.fixed(tap_size() ? tap_min() : 24),
					height = nendo.fixed(tap_size() ? tap_min() : 12),
					align = {x = .Center, y = .Center},
					color = hovered() ? ACCENT_GLOW : PLATE,
					radius = rr(2),
				},
				) {
					nendo.text("◢", {font = FONT_BODY, size = 11, color = TEXT_DIM})
					if hovered() {cursor_raise(.Grabbing); tooltip(tr("Resize terminal"))}
				}
			}
		}
	}
}

@(private)
whip_attach_overlays :: proc(ui: ^Ui_State) {
	for item in ui.whip_attachments {
		if item.group_id == "" && whip_attach_visible(ui, item) {whip_attached_pane(ui, item)}
	}
}

@(private)
whip_chat_pane :: proc(ui: ^Ui_State) {
	count := 0
	for item in ui.whip_attachments {if item.group_id != "" && whip_attach_visible(ui, item) {count += 1}}
	if count == 0 {whip_dock_end(ui); chat_pane(ui, ui.chats[ui.selected], ui.messages[:]); return}
	width := page_w(ui)
	wide := width >= 780
	if wide != ui.whip_dock_wide {whip_dock_end(ui)}
	ui.whip_dock_wide = wide
	dock_w := whip_dock_limit(
		ui.whip_dock_width > 0 ? ui.whip_dock_width : clamp(width * 0.4, 280, 460),
		width,
		240,
		PAGE_W_MIN,
	)
	height := f32(rl.GetScreenHeight()) / UI_ZOOM
	if data := nendo.element(nendo.id("WhipDockLayout")); data.found {
		height = min(data.rect.height, max(height - data.rect.y, 0))
	} else if single_pane() {
		back := nendo.element(nendo.id("PhoneBack"))
		height -= back.found ? back.rect.height : 36
	}
	dock_h := whip_dock_limit(
		ui.whip_dock_height > 0 ? ui.whip_dock_height : min(260, height * 0.36),
		height,
		120,
		200,
	)
	if wide {ui.whip_chat_width = width - dock_w - WHIP_GUTTER}
	if nendo.box(nendo.id("WhipDockLayout"))(
	{width = nendo.grow(), height = nendo.grow(), direction = wide ? .Row : .Column},
	) {
		if nendo.box(nendo.id("WhipDockChat"))(
		{
			width = nendo.grow(),
			height = nendo.grow(),
			direction = .Column,
			clip = {x = true, y = true},
		},
		) {
			chat_pane(ui, ui.chats[ui.selected], ui.messages[:])
		}
		whip_dock_divider(ui)
		if nendo.box(nendo.id("WhipDockStack"))(
		{
			width = wide ? nendo.fixed(dock_w) : nendo.grow(),
			height = wide ? nendo.grow() : nendo.fixed(dock_h),
			direction = .Column,
			gap = u16(WHIP_GUTTER),
			clip = {x = true, y = true, scroll = true},
		},
		) {
			for item in ui.whip_attachments {
				if item.group_id == "" || !whip_attach_visible(ui, item) {continue}
				if nendo.box(nendo.id("WhipDockItem", item.pane))(
				{
					width = nendo.grow(),
					height = wide ? nendo.grow() : nendo.fixed(max(120, dock_h)),
				},
				) {
					whip_attached_pane(ui, item)
				}
			}
		}
		if !wide {scrollbar(nendo.id("WhipDockStack"), 8)}
	}
}

@(private)
whip_attach_pointer :: proc(ui: ^Ui_State) -> bool {
	if ui.whip_dock_drag || ui.whip_dock_release {return true}
	if whip_dock_owner(ui) != 0 && nendo.pointer_over(nendo.id("WhipDockDivider")) {return true}
	if ui.whip_attach_drag != 0 || ui.whip_attach_resize != 0 {return true}
	for item in ui.whip_attachments {
		if whip_attach_visible(ui, item) &&
		   (nendo.pointer_over(
					   nendo.id(item.group_id == "" ? "WhipFloat" : "WhipDockPane", item.pane),
				   ) ||
				   nendo.pointer_over(nendo.id("WhipAttachHead", item.pane))) {return true}
	}
	return false
}

// Called before any chat or page input. A press outside an attached pane
// releases its keyboard ownership, allowing ordinary fields to take focus.
@(private)
whip_attach_input :: proc(ui: ^Ui_State) -> bool {
	if whip_dock_input(ui) {return true}
	if !whip_attach_allowed(ui) {
		ui.whip_attach_drag, ui.whip_attach_resize = 0, 0
		whip_attach_release_focus(ui)
		return false
	}
	point := rl.GetMousePosition()
	point.x /= UI_ZOOM; point.y /= UI_ZOOM
	active := ui.whip_attach_drag != 0 ? ui.whip_attach_drag : ui.whip_attach_resize
	if active != 0 {
		i := whip_attach_index(ui, active)
		if i >= 0 && whip_attach_visible(ui, ui.whip_attachments[i]) {
			bounds := ui.whip_attach_bounds
			delta := rl.Vector2 {
				point.x - ui.whip_attach_origin.x,
				point.y - ui.whip_attach_origin.y,
			}
			if ui.whip_attach_resize !=
			   0 {bounds.width += delta.x; bounds.height += delta.y} else {bounds.x += delta.x; bounds.y += delta.y}
			whip_attach_clamp(&bounds)
			ui.whip_attachments[i].bounds = bounds
		}
		if !rl.IsMouseButtonDown(.LEFT) {ui.whip_attach_drag, ui.whip_attach_resize = 0, 0}
		return true
	}
	for i := len(ui.whip_attachments) - 1; i >= 0; i -= 1 {
		item := ui.whip_attachments[i]
		if !whip_attach_visible(ui, item) {continue}
		root := nendo.id(item.group_id == "" ? "WhipFloat" : "WhipDockPane", item.pane)
		if !nendo.pointer_over(root) &&
		   !nendo.pointer_over(nendo.id("WhipAttachHead", item.pane)) {continue}
		if rl.IsMouseButtonPressed(.LEFT) ||
		   rl.IsMouseButtonPressed(.RIGHT) ||
		   rl.IsMouseButtonPressed(.MIDDLE) {
			ui.whip_focus, ui.focus = item.pane, .Whip
			if rl.IsMouseButtonPressed(.LEFT) && item.group_id == "" {
				if nendo.pointer_over(
					nendo.id("WhipAttachResize", item.pane),
				) {ui.whip_attach_resize = item.pane} else if nendo.pointer_over(nendo.id("WhipAttachHead", item.pane)) && !nendo.pointer_over(nendo.id("WhipAttachDock", item.pane)) && !nendo.pointer_over(nendo.id("WhipAttachReturn", item.pane)) {ui.whip_attach_drag = item.pane}
				ui.whip_attach_origin, ui.whip_attach_bounds = point, item.bounds
			}
		}
		if mouse_released() {
			if nendo.pointer_over(
				nendo.id("WhipAttachReturn", item.pane),
			) {whip_attach_rejoin(ui, item.pane)} else if nendo.pointer_over(nendo.id("WhipAttachFloat", item.pane)) {whip_attach_float(ui, item.pane)} else if nendo.pointer_over(nendo.id("WhipAttachDock", item.pane)) {whip_attach_dock(ui, item.pane)}
		}
		wheel := rl.GetMouseWheelMoveV()
		return(
			ui.focus == .Whip ||
			mouse_released() ||
			rl.IsMouseButtonDown(.LEFT) ||
			rl.IsMouseButtonDown(.RIGHT) ||
			rl.IsMouseButtonDown(.MIDDLE) ||
			wheel.x != 0 ||
			wheel.y != 0 \
		)
	}
	if rl.IsMouseButtonPressed(.LEFT) ||
	   rl.IsMouseButtonPressed(.RIGHT) ||
	   rl.IsMouseButtonPressed(.MIDDLE) {whip_attach_release_focus(ui)}
	if ui.focus == .Whip && whip_attach_focused(ui) == 0 {whip_attach_release_focus(ui)}
	return false
}
