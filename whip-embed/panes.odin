package sdlrl

import "core:crypto/hash"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import sdl "vendor:sdl3"
import whip "whip:gui"
import model "whip:model"
import proto "whip:proto"

when #config(WN_WHIP, false) {
	@(private)
	whip_mounts: map[u32]^whip.SDL_UI
	@(private)
	whip_hit_bounds: map[u32]model.Rect
	@(private)
	whip_panes: [dynamic]Whip_Pane
	@(private)
	whip_nodes: [dynamic]Whip_Node
	@(private)
	whip_active_panes: map[u32]bool
	@(private)
	whip_live_panes: map[u32]bool
	@(private)
	whip_pane_info: map[u32]Whip_Pane
	@(private)
	whip_surfaces: map[u32]bool
	@(private)
	whip_surface_focus: u32
	@(private)
	whip_draw_order: [dynamic]u32
	@(private)
	whip_draw_reset: bool
	@(private)
	whip_mount_created: bool
	@(private)
	whip_root: int = -1
	@(private)
	whip_focused, whip_zoom: u32
	@(private)
	whip_nav_leaves: [dynamic]model.Leaf_Rect
	@(private)
	whip_nav_dividers: [dynamic]model.Divider

	WhipPanes :: proc() -> []Whip_Pane {return whip_panes[:]}

	// Metadata is projected from the full observer, not the selected tab.
	// Borrowed strings remain valid until the next WhipFrame.
	WhipPaneInfo :: proc(pane: u32) -> (Whip_Pane, bool) {
		info, found := whip_pane_info[pane]
		if found {
			info.focused = whip_pane_keys(pane)
			if ui := whip_mounts[pane]; ui != nil {
				info.mode = whip.mode_label(ui.view)
				info.loading =
					whip.view_status(ui.view) != .Ready ||
					ui.texture == nil ||
					ui.view.fonts_pending ||
					ui.scale_pending
			}
		}
		return info, found
	}

	@(private)
	whip_pane_visible :: proc(pane: u32) -> bool {
		if visible, detached := whip_surfaces[pane]; detached {return visible}
		return whip_visible && whip_active_panes[pane] && (whip_zoom == 0 || whip_zoom == pane)
	}

	@(private)
	whip_pane_keys :: proc(pane: u32) -> bool {
		if visible, detached := whip_surfaces[pane]; detached {
			return visible && whip_surface_focus == pane
		}
		return(
			whip_surface_focus == 0 &&
			pane == whip_focused &&
			whip_input_enabled &&
			whip_pane_visible(pane) \
		)
	}

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

	// The observer owns the split tree and titles. Mounts are independent
	// Pane targets; keeping hidden mounts retains their scroll and search state.
	@(private)
	whip_session_identity: [4]u64
	@(private)
	whip_session_checked: bool

	// Resolve once when the observer installs its complete layout. The connected
	// peer, not a socket pathname or reused pane ID, establishes shell identity.
	// Boot ID and process start ticks distinguish PID reuse, including reboot.
	@(private)
	whip_connected_identity :: proc(app: ^whip.App) -> [4]u64 {
		peer: struct {
			pid:      i32,
			uid, gid: u32,
		}
		size := posix.socklen_t(size_of(peer))
		if posix.getsockopt(
			   app.sock,
			   posix.SOL_SOCKET,
			   posix.Sock_Option(linux.Socket_Option.PEERCRED),
			   &peer,
			   &size,
		   ) !=
			   .OK ||
		   size != size_of(peer) ||
		   peer.pid <= 0 {return {}}
		boot, boot_err := os.read_entire_file(
			"/proc/sys/kernel/random/boot_id",
			context.temp_allocator,
		)
		stat, stat_err := os.read_entire_file(
			fmt.tprintf("/proc/%d/stat", peer.pid),
			context.temp_allocator,
		)
		if boot_err != nil || stat_err != nil || len(boot) == 0 {return {}}
		end := strings.last_index(string(stat), ")")
		if end < 0 {return {}}
		fields := strings.fields(string(stat[end + 1:]), context.temp_allocator)
		if len(fields) <= 19 {return {}}
		for c in fields[19] {if c < '0' || c > '9' {return {}}}
		identity := fmt.tprintf(
			"%s:%d:%d:%d:%s",
			string(boot),
			peer.pid,
			peer.uid,
			peer.gid,
			fields[19],
		)
		digest: [32]u8
		hash.hash(.SHA256, identity, digest[:])
		return transmute([4]u64)digest
	}

	@(private)
	whip_panes_sync :: proc() {
		app := whip_catalog.view
		if !whip_session_checked && app.layout_ready {
			whip_session_checked = true
			whip_session_identity = whip_connected_identity(app)
		}
		clear(&whip_active_panes)
		clear(&whip_live_panes)
		for &workspace in app.session.workspaces {
			for &tab in workspace.tabs {
				for node in tab.nodes {
					if node.kind != .Leaf {continue}
					id := u32(node.pane)
					whip_live_panes[id] = true
					info := whip_pane_info[id]
					label := whip.pane_label(app, node.pane)
					if info.name != label {delete(info.name); info.name = strings.clone(label)}
					info.id, info.project, info.tab = id, u32(workspace.id), u32(tab.id)
					info.session = whip_session_identity
					info.mode = ""
					ui := whip_mounts[id]
					if ui != nil {info.mode = whip.mode_label(ui.view)}
					info.focused = whip_pane_keys(id)
					pv := app.panes[node.pane]
					info.waiting = pv != nil && pv.attention
					info.loading =
						ui == nil ||
						ui.texture == nil ||
						whip.view_status(ui.view) != .Ready ||
						ui.view.fonts_pending ||
						ui.scale_pending
					info.restoring = pv != nil && pv.snapshot_job != nil
					whip_pane_info[id] = info
				}
			}
		}
		for id, info in whip_pane_info {
			if !whip_live_panes[id] {
				delete(info.name)
				delete_key(&whip_pane_info, id)
				new_pending, split_pending := whip_pending_new[id], whip_pending_split[id]
				whip_new_pending -= new_pending
				whip_split_pending -= split_pending
				delete_key(&whip_pending_new, id)
				delete_key(&whip_pending_split, id)
				if new_pending + split_pending > 0 && whip_new_pending + whip_split_pending == 0 {
					whip_control.work = .Complete
				}
			}
		}
		if !whip_live_panes[whip_surface_focus] {whip_surface_focus = 0}
		for id, ui in whip_mounts {
			if !whip_live_panes[id] {
				if whip_ui == ui {whip_ui = nil}
				whip.destroy_sdl(ui)
				delete_key(&whip_mounts, id)
				delete_key(&whip_hit_bounds, id)
			}
		}
		wi, ti, found := model.find_tab(&app.session, model.Id(whip_tab))
		if !found || u32(app.session.workspaces[wi].id) != whip_project {
			whip_root = -1
			clear(&whip_nodes)
			clear(&whip_panes)
			whip_ui = whip_mounts[whip_surface_focus]
			return
		}
		tab := &app.session.workspaces[wi].tabs[ti]
		whip_root = int(tab.root)
		whip_focused = u32(whip.tab_focus(app, tab))
		whip_ui = whip_mounts[whip_surface_focus != 0 ? whip_surface_focus : whip_focused]
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
			// The full-session map is the sole owner of pane title strings.
			item := whip_pane_info[id]
			item.focused = id == (whip_surface_focus != 0 ? whip_surface_focus : whip_focused)
			if count < len(whip_panes) {whip_panes[count] = item} else {append(&whip_panes, item)}
			count += 1
		}
		if !zoom_exists {whip_zoom = 0}
		resize(&whip_panes, count)
	}

	@(private)
	whip_pane_focus :: proc(pane: u32) {
		if whip_catalog == nil {return}
		loc, found := model.find_pane(&whip_catalog.view.session, proto.Pane_Id(pane))
		if !found {return}
		tab := &whip_catalog.view.session.workspaces[loc.ws].tabs[loc.tab]
		visible, detached := whip_surfaces[pane]
		if detached && !visible {return}
		if !detached && (u32(tab.id) != whip_tab || !whip_visible) {return}
		if whip_ui != nil && whip_ui != whip_mounts[pane] {whip.set_focus(whip_ui.view, .Blurred)}
		changed := whip.tab_focus(whip_catalog.view, tab) != proto.Pane_Id(pane)
		whip_catalog.view.focus_choice[tab.id] = proto.Pane_Id(pane)
		if detached {whip_surface_focus = pane} else {whip_surface_focus, whip_focused = 0, pane; whip_input_enabled = true}
		whip_ui = whip_mounts[pane]
		whip_control.focused, whip_control.pane = true, pane
		for &item in whip_panes {item.focused = item.id == pane}
		if whip_ui != nil {
			// A shortcut consumed before this focus cannot swallow a new IME commit.
			whip_ui.view.pending_key = nil
			whip_ui.view.swallow_text = false
			whip.set_focus(whip_ui.view, .Focused)
			if changed {whip.send_id(whip_ui.view, .Focus, pane)}
		}
	}

	WhipPaneAct :: proc(action: Whip_Pane_Action, pane: u32) {
		if whip_catalog == nil || !whip_live_panes[pane] {return}
		if action == .Focus {whip_pane_focus(pane); return}
		if action == .Split_Right || action == .Split_Down || action == .Zoom {
			whip_pane_focus(pane)
		}
		ui := whip_mounts[pane]
		// A close may arrive before the first draw has created its mount.
		if ui == nil && action == .Close {
			whip.send_close(whip_catalog.view, .Pane, pane)
			return
		}
		if ui == nil {return}
		switch action {
		case .Focus:
		case .Split_Right:
			whip_host_action(ui.view, .Split_Right, 0)
		case .Split_Down:
			whip_host_action(ui.view, .Split_Down, 0)
		case .Close:
			whip_host_action(ui.view, .Close_Pane, 0)
		case .Zoom:
			whip_host_action(ui.view, .Zoom, 0)
		}
	}

	WhipPaneRatio :: proc(node: int, ratio: f32) {
		if whip_ui == nil ||
		   node < 0 ||
		   node >= len(whip_nodes) ||
		   whip_nodes[node].kind != .Split {return}
		whip_pane_ratio(whip_ui.view, whip_tab, node, ratio)
	}

	@(private)
	whip_pane_ratio :: proc(app: ^whip.App, tab: u32, node: int, ratio: f32) {
		ratio := clamp(ratio, 0.05, 0.95)
		start := whip.cmd_begin(app, .Set_Ratio)
		proto.put_u32(&app.outbox, tab)
		proto.put_u32(&app.outbox, u32(node))
		proto.put_u32(&app.outbox, transmute(u32)ratio)
		whip.cmd_send(app, start)
	}

	@(private)
	whip_pane_neighbor :: proc(tab: ^model.Tab, pane: u32, direction: model.Direction) {
		whip_zoom = 0
		clear(&whip_nav_leaves); clear(&whip_nav_dividers)
		model.layout_tab(tab, {0, 0, 10000, 10000}, 0, &whip_nav_leaves, &whip_nav_dividers)
		if next, found := model.neighbor(whip_nav_leaves[:], proto.Pane_Id(pane), direction);
		   found {
			if visible, detached := whip_surfaces[u32(next)]; detached && visible {
				whip_pane_focus(u32(next))
			} else if !detached {
				whip_catalog.view.focus_choice[tab.id] = next
				if pane in whip_surfaces {
					info := whip_pane_info[pane]
					whip_control.project, whip_control.tab = info.project, info.tab
					whip_control.selection = true
				} else {whip_pane_focus(u32(next))}
			}
		}
	}

	// Host titlebars overlay the terminal without changing its rows or columns.
	// Exclude their top strip from mouse input, not from rendering geometry.
	DrawWhipPane :: proc(pane: u32, x, y, w, h: f32, input_top: f32 = 0) {
		if whip_draw_reset {
			clear(&whip_draw_order)
			whip_draw_reset = false
			whip_mount_created = false
		}
		if whip_failed ||
		   whip_catalog == nil ||
		   !whip_live_panes[pane] ||
		   !whip_pane_visible(pane) {return}
		sx, sy: f32
		sdl.GetRenderScale(state.renderer, &sx, &sy)
		bounds := model.Rect{int(x * sx), int(y * sy), int(w * sx), int(h * sy)}
		if bounds.w <= 0 || bounds.h <= 0 {return}
		// The host renderer already combines UI zoom and pixel density.
		// Reapplying window display scale would double-count DPI.
		font_scale := sy
		focused := whip_surface_focus != 0 ? whip_surface_focus : whip_focused
		focus_pending := whip_pane_visible(focused) && whip_mounts[focused] == nil
		ui := whip_mounts[pane]
		if ui == nil {
			// Creation and font refresh share one costly resource slot per frame.
			// Spend the first slot on the input owner, not its tree position.
			if pane != focused && focus_pending {return}
			if whip_mount_created {return}
			whip_mount_created = true
			ui = whip.create_sdl(
				state.window,
				state.renderer,
				"default",
				bounds,
				{kind = .Pane, pane = proto.Pane_Id(pane)},
				whip_catalog.view,
				font_scale,
			)
			if ui == nil {whip_failed = true; return}
			whip_mounts[pane] = ui
			whip.set_notice_handler(ui.view, whip_host_notice)
			whip.set_action_handler(ui.view, whip_host_action)
		}
		if whip_pane_keys(pane) || whip_surface_focus == 0 && pane == whip_focused {whip_ui = ui}
		whip.set_focus(ui.view, whip_pane_keys(pane) ? .Focused : .Blurred)
		whip.set_bounds(ui.view, bounds)
		hit := bounds
		blocked := clamp(int(input_top * sy), 0, bounds.h)
		hit.y += blocked
		hit.h -= blocked
		whip_hit_bounds[pane] = hit
		status := whip.view_status(ui.view)
		if status == .Missing || status == .Stopped {return}
		append(&whip_draw_order, pane)
		allow_font_refresh := !whip_mount_created && !focus_pending && ui.view.mouse.drag == .None
		if allow_font_refresh && (ui.view.scale != font_scale || ui.view.fonts_pending) {
			whip_mount_created = true
		}
		if !whip.render_sdl(ui, font_scale, allow_font_refresh ? .Allow : .Defer) {
			// Pane exit can arrive during preparation; only renderer failures
			// on a still-live view fail the integration.
			status = whip.view_status(ui.view)
			if status != .Missing && status != .Stopped {whip_failed = true}
		}
	}

	@(private)
	whip_panes_update :: proc() {
		for id, ui in whip_mounts {
			visible := whip_pane_visible(id)
			drawn := false
			for painted in whip_draw_order {if painted == id {drawn = true; break}}
			keys :=
				whip_pane_keys(id) ||
				whip_surface_focus == 0 &&
					id == whip_focused &&
					!(id in whip_surfaces) &&
					whip_enabled &&
					!whip_visible &&
					ui.view.mode == .Navigate
			whip.set_focus(ui.view, keys ? .Focused : .Blurred)
			if !visible || !drawn {
				whip.set_bounds(ui.view, {})
				whip_hit_bounds[id] = {}
				ui.view.mouse.drag = .None
			}
			whip.update(ui.view)
			if !ui.view.running || whip.view_status(ui.view) == .Missing {
				if whip_ui == ui {whip_ui = nil}
				whip.destroy_sdl(ui)
				delete_key(&whip_mounts, id)
				delete_key(&whip_hit_bounds, id)
			}
		}
	}

	@(private)
	whip_panes_close :: proc() {
		whip_session_identity, whip_session_checked = {}, false
		for _, ui in whip_mounts {whip.destroy_sdl(ui)}
		delete(whip_mounts); whip_mounts = nil
		delete(whip_hit_bounds); whip_hit_bounds = nil
		delete(whip_panes); whip_panes = {}
		delete(whip_nodes); whip_nodes = {}
		delete(whip_active_panes); whip_active_panes = nil
		delete(whip_live_panes); whip_live_panes = nil
		for _, info in whip_pane_info {delete(info.name)}
		delete(whip_pane_info); whip_pane_info = nil
		delete(whip_surfaces); whip_surfaces = nil
		delete(whip_draw_order); whip_draw_order = {}
		whip_draw_reset = false
		whip_mount_created = false
		whip_surface_focus = 0
		delete(whip_nav_leaves); whip_nav_leaves = {}
		delete(whip_nav_dividers); whip_nav_dividers = {}
		whip_root, whip_focused, whip_zoom, whip_ui = -1, 0, 0, nil
	}
}
