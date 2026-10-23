package sdlrl

import "core:strings"
import sdl "vendor:sdl3"
import whip "whip:gui"
import model "whip:model"
import proto "whip:proto"

when #config(WN_WHIP, false) {
	@(private)
	whip_mounts: map[u32]^whip.SDL_UI
	@(private)
	whip_panes: [dynamic]Whip_Pane
	@(private)
	whip_nodes: [dynamic]Whip_Node
	@(private)
	whip_active_panes: map[u32]bool
	@(private)
	whip_live_panes: map[u32]bool
	@(private)
	whip_root: int = -1
	@(private)
	whip_focused, whip_zoom: u32
	@(private)
	whip_nav_leaves: [dynamic]model.Leaf_Rect
	@(private)
	whip_nav_dividers: [dynamic]model.Divider

	WhipPanes :: proc() -> []Whip_Pane {return whip_panes[:]}

	WhipTree :: proc() -> ([]Whip_Node, int, u32) {
		zoom := whip_zoom
		for pane in whip_panes {
			if pane.focused {
				if ui := whip_mounts[pane.id];
				   ui != nil && (ui.view.mode == .Help || ui.view.mode == .Diff) {
					zoom = pane.id
				}
			}
		}
		return whip_nodes[:], whip_root, zoom
	}

	@(private)
	whip_panes_trim :: proc(count: int) {
		for pane in whip_panes[count:] {delete(pane.name)}
		resize(&whip_panes, count)
	}

	// The observer owns the split tree and titles. Mounts are independent
	// Pane targets; keeping hidden mounts retains their scroll and search state.
	@(private)
	whip_panes_sync :: proc() {
		app := whip_catalog.view
		clear(&whip_active_panes)
		clear(&whip_live_panes)
		for &workspace in app.session.workspaces {
			for &tab in workspace.tabs {
				for node in tab.nodes {if node.kind == .Leaf {whip_live_panes[u32(node.pane)] = true}}
			}
		}
		for id, ui in whip_mounts {
			if !whip_live_panes[id] {
				if whip_ui == ui {whip_ui = nil}
				whip.destroy_sdl(ui)
				delete_key(&whip_mounts, id)
			}
		}
		wi, ti, found := model.find_tab(&app.session, model.Id(whip_tab))
		if !found || u32(app.session.workspaces[wi].id) != whip_project {
			whip_root = -1
			clear(&whip_nodes)
			whip_panes_trim(0)
			whip_ui = nil
			return
		}
		tab := &app.session.workspaces[wi].tabs[ti]
		whip_root = int(tab.root)
		whip_focused = u32(whip.tab_focus(app, tab))
		whip_ui = whip_mounts[whip_focused]
		resize(&whip_nodes, len(tab.nodes))
		count := 0
		zoom_exists := false
		for node, i in tab.nodes {
			whip_nodes[i] = {
				kind   = Whip_Node_Kind(node.kind),
				axis   = Whip_Axis(node.axis),
				ratio  = node.ratio,
				first  = int(node.a),
				second = int(node.b),
				pane   = u32(node.pane),
				slot   = count,
			}
			if node.kind != .Leaf {continue}
			id := u32(node.pane)
			whip_active_panes[id] = true
			zoom_exists ||= id == whip_zoom
			label := whip.pane_label(app, node.pane)
			name := count < len(whip_panes) ? whip_panes[count].name : ""
			if name != label {delete(name); name = strings.clone(label)}
			mode := ""
			if ui := whip_mounts[id]; ui != nil {mode = whip.mode_label(ui.view)}
			pv := app.panes[node.pane]
			item := Whip_Pane {
				id      = id,
				name    = name,
				mode    = mode,
				focused = id == whip_focused,
				waiting = pv != nil && pv.attention,
				loading = whip_mounts[id] ==
					nil || whip.view_status(whip_mounts[id].view) != .Ready,
			}
			if count < len(whip_panes) {whip_panes[count] = item} else {append(&whip_panes, item)}
			count += 1
		}
		if !zoom_exists {whip_zoom = 0}
		whip_panes_trim(count)
	}

	@(private)
	whip_pane_focus :: proc(pane: u32) {
		if whip_catalog == nil {return}
		loc, found := model.find_pane(&whip_catalog.view.session, proto.Pane_Id(pane))
		if !found {return}
		tab := &whip_catalog.view.session.workspaces[loc.ws].tabs[loc.tab]
		if u32(tab.id) != whip_tab {return}
		if whip_ui != nil && whip_ui != whip_mounts[pane] {whip.set_focus(whip_ui.view, .Blurred)}
		whip_catalog.view.focus_choice[tab.id] = proto.Pane_Id(pane)
		whip_focused, whip_ui = pane, whip_mounts[pane]
		for &item in whip_panes {item.focused = item.id == pane}
		if whip_ui != nil {
			whip.set_focus(whip_ui.view, whip_visible ? .Focused : .Blurred)
			whip.send_id(whip_ui.view, .Focus, pane)
		}
	}

	WhipPaneAct :: proc(action: Whip_Pane_Action, pane: u32) {
		whip_pane_focus(pane)
		if whip_ui == nil {return}
		switch action {
		case .Focus:
		case .Split_Right:
			whip_host_action(whip_ui.view, .Split_Right, 0)
		case .Split_Down:
			whip_host_action(whip_ui.view, .Split_Down, 0)
		case .Close:
			whip_host_action(whip_ui.view, .Close_Pane, 0)
		case .Zoom:
			whip_host_action(whip_ui.view, .Zoom, 0)
		}
	}

	WhipPaneRatio :: proc(node: int, ratio: f32) {
		if whip_ui == nil ||
		   node < 0 ||
		   node >= len(whip_nodes) ||
		   whip_nodes[node].kind != .Split {return}
		ratio := clamp(ratio, 0.05, 0.95)
		start := whip.cmd_begin(whip_ui.view, .Set_Ratio)
		proto.put_u32(&whip_ui.view.outbox, whip_tab)
		proto.put_u32(&whip_ui.view.outbox, u32(node))
		proto.put_u32(&whip_ui.view.outbox, transmute(u32)ratio)
		whip.cmd_send(whip_ui.view, start)
	}

	@(private)
	whip_pane_neighbor :: proc(tab: ^model.Tab, direction: model.Direction) {
		whip_zoom = 0
		clear(&whip_nav_leaves); clear(&whip_nav_dividers)
		model.layout_tab(tab, {0, 0, 10000, 10000}, 0, &whip_nav_leaves, &whip_nav_dividers)
		if next, found := model.neighbor(
			whip_nav_leaves[:],
			proto.Pane_Id(whip_focused),
			direction,
		); found {whip_pane_focus(u32(next))}
	}

	// WN's header and splitter are outside these bounds. Only the pane's
	// content is composited here; no Whip tab or split chrome is drawn.
	DrawWhipPane :: proc(pane: u32, x, y, w, h: f32) {
		if whip_failed || whip_catalog == nil || whip_root < 0 {return}
		sx, sy: f32
		sdl.GetRenderScale(state.renderer, &sx, &sy)
		bounds := model.Rect{int(x * sx), int(y * sy), int(w * sx), int(h * sy)}
		if bounds.w <= 0 || bounds.h <= 0 {return}
		ui := whip_mounts[pane]
		if ui == nil {
			ui = whip.create_sdl(
				state.window,
				state.renderer,
				"default",
				bounds,
				{kind = .Pane, pane = proto.Pane_Id(pane)},
			)
			if ui == nil {whip_failed = true; return}
			whip_mounts[pane] = ui
			whip.set_notice_handler(ui.view, whip_host_notice)
			whip.set_action_handler(ui.view, whip_host_action)
		}
		if pane == whip_focused {whip_ui = ui}
		whip.set_focus(ui.view, pane == whip_focused && whip_visible ? .Focused : .Blurred)
		whip.set_bounds(ui.view, bounds)
		if !whip.render_sdl(ui) {whip_failed = true}
	}

	@(private)
	whip_panes_update :: proc() {
		for id, ui in whip_mounts {
			visible := whip_active_panes[id] && whip_visible && (whip_zoom == 0 || whip_zoom == id)
			keys := id == whip_focused && (visible || whip_enabled && ui.view.mode == .Navigate)
			whip.set_focus(ui.view, keys ? .Focused : .Blurred)
			if !visible {whip.set_bounds(ui.view, {})}
			whip.update(ui.view)
			if !ui.view.running {whip_failed = true}
		}
	}

	@(private)
	whip_panes_close :: proc() {
		for _, ui in whip_mounts {whip.destroy_sdl(ui)}
		delete(whip_mounts); whip_mounts = nil
		whip_panes_trim(0); delete(whip_panes); whip_panes = {}
		delete(whip_nodes); whip_nodes = {}
		delete(whip_active_panes); whip_active_panes = nil
		delete(whip_live_panes); whip_live_panes = nil
		delete(whip_nav_leaves); whip_nav_leaves = {}
		delete(whip_nav_dividers); whip_nav_dividers = {}
		whip_root, whip_focused, whip_zoom, whip_ui = -1, 0, 0, nil
	}
}
