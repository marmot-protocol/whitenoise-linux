package sdlrl

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import sdl "vendor:sdl3"
import whip "whip:gui"
import whip_model "whip:model"
import proto "whip:proto"

when #config(WN_WHIP, false) {
	@(private)
	whip_ui: ^whip.SDL_UI
	@(private)
	whip_catalog: ^whip.SDL_UI
	@(private)
	whip_projects: [dynamic]Whip_Project
	@(private)
	whip_project: u32
	@(private)
	whip_tabs: [dynamic]Whip_Tab
	@(private)
	whip_tab: u32
	@(private)
	whip_worker: ^thread.Thread
	@(private)
	whip_allocator: mem.Allocator
	@(private)
	whip_started: i32
	@(private)
	whip_failed: bool
	@(private)
	whip_visible: bool
	@(private)
	whip_enabled: bool
	@(private)
	whip_control: Whip_Control
	@(private)
	whip_new_pending: int
	@(private)
	whip_created_tab: whip_model.Id
	@(private)
	whip_split_pending: int
	@(private)
	whip_created_focus: proto.Pane_Id
	@(private)
	whip_server_mutex: sync.Mutex
	@(private)
	Whip_Create_Job :: struct {
		worker:    ^thread.Thread,
		allocator: mem.Allocator,
		dir:       string,
		state:     Whip_Create_State,
		id:        u32,
		reconnect: bool,
	}
	@(private)
	whip_create: Whip_Create_Job
	@(private)
	Whip_Tab_Job :: struct {
		worker:     ^thread.Thread,
		allocator:  mem.Allocator,
		action:     Whip_Tab_Action,
		state:      Whip_Create_State,
		target, id: u32,
	}
	@(private)
	whip_tab_job: Whip_Tab_Job
	@(private)
	whip_notices: [dynamic]Whip_Notice
	@(private)
	whip_notice_allocator: mem.Allocator

	WhipAvailable :: proc() -> bool {
		path := #config(WN_WHIP_EXE, "")
		return os.is_file(path) && posix.access(cstring(#config(WN_WHIP_EXE, "")), {.X_OK}) == .OK
	}

	// Launch the installed executable, never connect_or_spawn: that API
	// forks /proc/self/exe, which here would start another White Noise.
	@(private)
	whip_start :: proc(t: ^thread.Thread) {
		context.allocator = whip_allocator
		defer free_all(context.temp_allocator)
		ready, _ := whip_server()
		sync.atomic_store(&whip_started, ready ? 1 : -1)
	}

	@(private)
	Whip_Server :: enum {
		Existing,
		Started,
	}

	@(private)
	whip_server :: proc() -> (bool, Whip_Server) {
		// Startup and creation may arrive in the same frame. Only one may
		// launch the installed server; creation also works before WhipFrame.
		sync.lock(&whip_server_mutex)
		defer sync.unlock(&whip_server_mutex)
		fd, ok := proto.connect("default")
		server := Whip_Server.Existing
		if !ok {
			server = .Started
			// The short-lived shell reparents the server so detaching or
			// reloading WN leaves the user's terminal sessions alive.
			child, err := os.process_start(
				{
					command = {
						"/bin/sh",
						"-c",
						`"$1" server default </dev/null &`,
						"sh",
						#config(WN_WHIP_EXE, ""),
					},
					stdout = os.stderr,
					stderr = os.stderr,
				},
			)
			if err != nil {return false, server}
			_, _ = os.process_wait(child)
			fd, ok = proto.connect_retry("default", 2 * time.Second)
		}
		if ok {posix.close(fd)}
		return ok, server
	}

	// CLI creation prints project/tab/pane IDs, or tab/pane IDs for a new
	// tab. Select its first stable ID, never an index in the catalog.
	@(private)
	whip_created_id :: proc(output: string, count: int = 3) -> u32 {
		ids := strings.fields(output, context.temp_allocator)
		if len(ids) != count {return 0}
		created: u32
		for field, i in ids {
			value: u64
			for byte in transmute([]u8)field {
				if byte < '0' || byte > '9' {return 0}
				value = value * 10 + u64(byte - '0')
				if value > 0xffff_ffff {return 0}
			}
			if value == 0 {return 0}
			if i == 0 {created = u32(value)}
		}
		return created
	}

	@(private)
	whip_create_worker :: proc(t: ^thread.Thread) {
		context.allocator = whip_create.allocator
		defer free_all(context.temp_allocator)
		whip_create.state = .Failed
		ready, server := whip_server()
		if !ready {return}
		whip_create.reconnect = server == .Started
		result, output, errors, err := os.process_exec(
			{command = {#config(WN_WHIP_EXE, ""), "project", "new", whip_create.dir}},
			context.allocator,
		)
		defer delete(output)
		defer delete(errors)
		if err != nil || !result.exited || !result.success || result.exit_code != 0 {return}
		whip_create.id = whip_created_id(string(output))
		if whip_create.id != 0 {whip_create.state = .Ready}
	}

	WhipCreate :: proc(dir: string) -> bool {
		if dir == "" || whip_create.worker != nil {return false}
		whip_create = {
			allocator = context.allocator,
			dir       = strings.clone(dir),
		}
		whip_create.worker = thread.create(whip_create_worker)
		if whip_create.worker == nil {
			delete(whip_create.dir, whip_create.allocator)
			whip_create = {}
			return false
		}
		thread.start(whip_create.worker)
		return true
	}

	@(private)
	whip_create_join :: proc() -> (Whip_Create_State, u32) {
		if whip_create.worker == nil {return .Idle, 0}
		thread.join(whip_create.worker)
		state, id := whip_create.state, whip_create.id
		thread.destroy(whip_create.worker)
		delete(whip_create.dir, whip_create.allocator)
		whip_create = {}
		return state, id
	}

	// Terminal results are consumed exactly once; only join a completed job
	// here, while WhipClose deliberately waits before native code is unloaded.
	WhipCreatePoll :: proc() -> (Whip_Create_State, u32) {
		if whip_create.worker == nil {return .Idle, 0}
		if !thread.is_done(whip_create.worker) {return .Creating, 0}
		reconnect := whip_create.reconnect
		status, id := whip_create_join()
		if status == .Ready && (reconnect || whip_failed) {
			// Closing the last project stops Whip's server. Creation can start
			// a new one; its old observer and terminal sockets cannot be reused.
			whip_panes_close()
			if whip_catalog != nil {whip.destroy_sdl(whip_catalog); whip_catalog = nil}
			clear(&whip_projects); whip_tabs_trim(0)
			whip_failed = false
			sync.atomic_store(&whip_started, 1)
		}
		return status, id
	}

	@(private)
	whip_tab_worker :: proc(t: ^thread.Thread) {
		context.allocator = whip_tab_job.allocator
		defer free_all(context.temp_allocator)
		whip_tab_job.state = .Failed
		ready, _ := whip_server()
		if !ready {return}
		verb := whip_tab_job.action == .New ? "new" : "close"
		target := fmt.tprintf("%d", whip_tab_job.target)
		result, output, errors, err := os.process_exec(
			{command = {#config(WN_WHIP_EXE, ""), "tab", verb, target}},
			context.allocator,
		)
		defer delete(output)
		defer delete(errors)
		if err != nil || !result.exited || !result.success || result.exit_code != 0 {return}
		whip_tab_job.id = whip_tab_job.target
		if whip_tab_job.action == .New {
			whip_tab_job.id = whip_created_id(string(output), 2)
		}
		if whip_tab_job.id != 0 {whip_tab_job.state = .Ready}
	}

	// New targets a project; Close targets the exact stable tab ID.
	WhipTabChange :: proc(action: Whip_Tab_Action, id: u32) -> bool {
		if id == 0 || whip_tab_job.worker != nil {return false}
		whip_tab_job = {
			allocator = context.allocator,
			action    = action,
			target    = id,
		}
		whip_tab_job.worker = thread.create(whip_tab_worker)
		if whip_tab_job.worker == nil {whip_tab_job = {}; return false}
		thread.start(whip_tab_job.worker)
		return true
	}

	@(private)
	whip_tab_join :: proc() -> (Whip_Create_State, u32) {
		if whip_tab_job.worker == nil {return .Idle, 0}
		thread.join(whip_tab_job.worker)
		state, id := whip_tab_job.state, whip_tab_job.id
		thread.destroy(whip_tab_job.worker)
		whip_tab_job = {}
		return state, id
	}

	WhipTabPoll :: proc() -> (Whip_Create_State, u32) {
		if whip_tab_job.worker == nil {return .Idle, 0}
		if !thread.is_done(whip_tab_job.worker) {return .Creating, 0}
		return whip_tab_join()
	}

	WhipState :: proc() -> Whip_State {
		if whip_failed || sync.atomic_load(&whip_started) < 0 {return .Failed}
		if whip_catalog != nil && whip.view_status(whip_catalog.view) == .Ready {
			found := whip_project == 0
			for project in whip_projects {
				if project.id == whip_project {found = true; break}
			}
			if !found {return .Missing}
			if whip_tab == 0 {return .Ready}
			found = false
			for tab in whip_tabs {
				if tab.id == whip_tab {found = true; break}
			}
			if !found {return .Missing}
		}
		if whip_catalog != nil && whip.view_status(whip_catalog.view) == .Ready {return .Ready}
		if whip_worker != nil {return .Starting}
		return .Idle
	}

	WhipProjects :: proc() -> []Whip_Project {
		return whip_projects[:]
	}

	WhipTabs :: proc() -> []Whip_Tab {
		return whip_tabs[:]
	}

	WhipControlPoll :: proc() -> Whip_Control {
		control := whip_control
		whip_control = {}
		return control
	}

	// Whip owns chord decoding and pane-local actions. Navigation changes
	// the host's stable selection, never a mounted Pane context's binding.
	@(private)
	whip_host_action :: proc(
		app: ^whip.App,
		action: whip.Action,
		target: whip_model.Id,
		pane: proto.Pane_Id = 0,
	) -> bool {
		if whip_ui == nil || app != whip_ui.view {return false}
		if action == .View_Hint {
			if u32(target) == whip_tab {
				if whip_split_pending == 0 {return false}
				whip_split_pending -= 1
				whip_created_focus = pane
			} else {
				if whip_new_pending == 0 {return false}
				whip_new_pending -= 1
				whip_created_tab = target
			}
			return true
		}
		if action == .Detach {whip_control.detach = true; return true}
		if action == .Toggle_Sidebar {whip_control.sidebar = !whip_control.sidebar; return true}
		if action == .Select_Project {
			if wi, ok := whip_model.find_workspace(&whip_catalog.view.session, target); ok {
				whip_control.project, whip_control.tab =
					u32(whip_catalog.view.session.workspaces[wi].id), 0
				whip_control.selection = true
			}
			return true
		}
		if action == .Select_Tab {
			if wi, _, ok := whip_model.find_tab(&whip_catalog.view.session, target); ok {
				whip_control.project, whip_control.tab =
					u32(whip_catalog.view.session.workspaces[wi].id), u32(target)
				whip_control.selection = true
			}
			return true
		}
		wi, ti, ok := whip_model.find_tab(&whip_catalog.view.session, whip_model.Id(whip_tab))
		if !ok {return false}
		ws := &whip_catalog.view.session.workspaces[wi]
		tab := &ws.tabs[ti]
		#partial switch action {
		case .Split_Right, .Split_Down:
			whip_split_pending += 1
			whip_control.work = .New_Pane
			whip_zoom = 0
			whip.send_split(
				app,
				proto.Pane_Id(whip_focused),
				action == .Split_Right ? .Right : .Down,
			)
		case .Focus_Left, .Focus_Down, .Focus_Up, .Focus_Right:
			whip_pane_neighbor(
				tab,
				whip_model.Direction(int(action) - int(whip.Action.Focus_Left)),
			)
		case .Zoom:
			whip_zoom = whip_zoom == whip_focused ? 0 : whip_focused
		case .Resize_Mode:
			app.mode = .Resize
		case .Resize_Left, .Resize_Right, .Resize_Up, .Resize_Down:
			axis :=
				action == .Resize_Left || action == .Resize_Right ? whip_model.Axis.Right : .Down
			if index, found := whip_model.ancestor_split(tab, proto.Pane_Id(whip_focused), axis);
			   found {
				delta :=
					action == .Resize_Left || action == .Resize_Up ? -whip.RESIZE_STEP : whip.RESIZE_STEP
				WhipPaneRatio(int(index), tab.nodes[index].ratio + f32(delta))
			}
		case .Close_Pane:
			leaves := 0
			for node in tab.nodes {if node.kind == .Leaf {leaves += 1}}
			if leaves == 1 {return whip_host_action(app, .Close_Tab, 0)}
			whip.send_close(app, .Pane, whip_focused)
		case .New_Tab:
			whip_new_pending += 1
			whip_control.work = .New_Tab
			whip.send_new_tab(app, ws.id, proto.Pane_Id(whip_focused))
		case .New_Workspace:
			whip_new_pending += 1
			whip_control.work = .New_Project
			whip.send_id(app, .New_Workspace, whip_focused)
		case .Next_Tab, .Prev_Tab:
			step := action == .Next_Tab ? 1 : len(ws.tabs) - 1
			whip_control.project, whip_control.tab =
				u32(ws.id), u32(ws.tabs[(ti + step) % len(ws.tabs)].id)
			whip_control.selection = true
		case .Next_Workspace, .Prev_Workspace:
			step := action == .Next_Workspace ? 1 : len(whip_catalog.view.session.workspaces) - 1
			whip_control.project, whip_control.tab =
				u32(
					whip_catalog.view.session.workspaces[(wi + step) % len(whip_catalog.view.session.workspaces)].id,
				),
				0
			whip_control.selection = true
		case .Close_Tab, .Close_Workspace:
			if action == .Close_Tab && len(ws.tabs) > 1 {
				next := ti == len(ws.tabs) - 1 ? ti - 1 : ti + 1
				whip_control.project, whip_control.tab = u32(ws.id), u32(ws.tabs[next].id)
				whip_control.selection = true
			} else if len(whip_catalog.view.session.workspaces) > 1 {
				next := wi == len(whip_catalog.view.session.workspaces) - 1 ? wi - 1 : wi + 1
				whip_control.project, whip_control.tab =
					u32(whip_catalog.view.session.workspaces[next].id), 0
				whip_control.selection = true
			} else {
				whip_control.detach = true
			}
			whip.send_close(
				app,
				action == .Close_Tab ? .Tab : .Workspace,
				u32(action == .Close_Tab ? tab.id : ws.id),
			)
		case .Rename_Tab:
			whip.start_rename(app, .Tab, tab.id, tab.name)
		case .Rename_Workspace:
			whip.start_rename(app, .Workspace, ws.id, whip_model.workspace_label(ws))
		case .Toggle_Device:
			whip.device_toggle(app)
		case .Navigate:
			app.mode, app.nav_index = .Navigate, wi
			whip_control.projects = true
		case:
			return false
		}
		return true
	}

	@(private)
	whip_tabs_trim :: proc(count: int) {
		for tab in whip_tabs[count:] {delete(tab.name)}
		resize(&whip_tabs, count)
	}

	WhipNotices :: proc() -> []Whip_Notice {
		return whip_notices[:]
	}

	@(private)
	whip_notices_clear :: proc() {
		for notice in whip_notices {
			delete(notice.title, whip_notice_allocator)
			delete(notice.body, whip_notice_allocator)
		}
		clear(&whip_notices)
	}

	// The SDK hook runs before standalone desktop effects, including the
	// first output replay after a pane's snapshot. Content replicas stay silent;
	// only the observer owns attention and sends payloads to WN's notice policy.
	@(private)
	whip_host_notice :: proc(app: ^whip.App, pane: proto.Pane_Id, title, body: string) {
		if whip_catalog == nil || app != whip_catalog.view {return}
		pv := app.panes[pane]
		if pv == nil {return}
		loc, ok := whip_model.find_pane(&app.session, pane)
		if !ok {return}
		project := &app.session.workspaces[loc.ws]
		tab := &project.tabs[loc.tab]
		if whip_visible &&
		   IsWindowFocused() &&
		   u32(project.id) == whip_project &&
		   u32(tab.id) == whip_tab &&
		   (whip_zoom == 0 || whip_zoom == u32(pane)) {
			pv.attention = false
			return
		}
		if pv.attention {return}
		pv.attention = true
		title := title
		if title == "" {title = whip.pane_label(app, pane)}
		append(
			&whip_notices,
			Whip_Notice {
				project = u32(project.id),
				tab = u32(tab.id),
				title = strings.clone(title, whip_notice_allocator),
				body = strings.clone(body, whip_notice_allocator),
			},
		)
	}

	@(private)
	whip_attention_seen :: proc() {
		if !whip_visible || !IsWindowFocused() {return}
		app := whip_catalog.view
		wi, ti, ok := whip_model.find_tab(&app.session, whip_model.Id(whip_tab))
		if !ok || u32(app.session.workspaces[wi].id) != whip_project {return}
		for node in app.session.workspaces[wi].tabs[ti].nodes {
			if node.kind == .Leaf && (whip_zoom == 0 || whip_zoom == u32(node.pane)) {
				if pv := app.panes[node.pane]; pv != nil {pv.attention = false}
			}
		}
	}

	@(private)
	whip_waiting :: proc(tab: ^whip_model.Tab) -> int {
		waiting := 0
		for node in tab.nodes {
			if node.kind == .Leaf {
				if pv := whip_catalog.view.panes[node.pane]; pv != nil && pv.attention {
					waiting += 1
				}
			}
		}
		return waiting
	}

	// Called after host handlers, so a newly opened modal owns the next input.
	WhipFrame :: proc(visibility: Whip_Visibility, project, tab: u32) {
		whip_notices_clear()
		whip_visible = visibility == .Visible
		whip_enabled = visibility != .Hidden
		if project != whip_project || tab != whip_tab {
			if whip_ui != nil {whip.set_focus(whip_ui.view, .Blurred)}
			whip_ui, whip_zoom = nil, 0
			whip_project, whip_tab = project, tab
		}
		if visibility != .Hidden && WhipState() == .Idle && WhipAvailable() {
			whip_allocator = context.allocator
			whip_worker = thread.create(whip_start)
			if whip_worker == nil {whip_failed = true; return}
			thread.start(whip_worker)
		}
		// This observer never receives input or renders. Its host notice hook
		// opts the Projects context into replicas without standalone lifetime rules.
		if whip_catalog == nil && !whip_failed && sync.atomic_load(&whip_started) == 1 {
			whip_notice_allocator = context.allocator
			whip_catalog = whip.create_sdl(
				state.window,
				state.renderer,
				"default",
				{0, 0, 1, 1},
				{kind = .Projects},
			)
			if whip_catalog == nil {whip_failed = true; return}
			whip.set_notice_handler(whip_catalog.view, whip_host_notice)
		}
		if whip_catalog != nil {
			whip.update(whip_catalog.view)
			whip_panes_sync()
			whip_attention_seen()
			clear(&whip_projects)
			tab_count := 0
			for &entry, project_index in whip.projects(whip_catalog.view) {
				project_waiting := 0
				for &tab, i in whip.tabs(whip_catalog.view, entry.id) {
					waiting := whip_waiting(&tab)
					project_waiting += waiting
					if u32(entry.id) == whip_project {
						// SDK shortening can return frame-arena text. Own changed
						// labels until the next projection, without copying every frame.
						label := whip.tab_label(whip_catalog.view, &tab)
						name := tab_count < len(whip_tabs) ? whip_tabs[tab_count].name : ""
						if name != label {delete(name); name = strings.clone(label)}
						item := Whip_Tab {
							id      = u32(tab.id),
							name    = name,
							active  = i == entry.active,
							waiting = waiting,
						}
						if tab_count <
						   len(
							   whip_tabs,
						   ) {whip_tabs[tab_count] = item} else {append(&whip_tabs, item)}
						tab_count += 1
					}
				}
				append(
					&whip_projects,
					Whip_Project {
						id = u32(entry.id),
						name = whip_model.workspace_label(&entry),
						dir = entry.dir,
						tabs = len(entry.tabs),
						waiting = project_waiting,
						navigating = whip_ui != nil &&
						whip_ui.view.mode == .Navigate &&
						whip_ui.view.nav_index == project_index,
					},
				)
			}
			whip_tabs_trim(tab_count)
			if !whip_catalog.view.running {whip_failed = true}
		}
		whip_panes_update()
		if whip_ui != nil {
			// View can precede its Layout in the stream. Resolve the stable ID
			// only after feed has applied the model that contains the new tab.
			if whip_created_tab != 0 {
				if _, _, found := whip_model.find_tab(
					&whip_catalog.view.session,
					whip_created_tab,
				); found {
					whip_host_action(whip_ui.view, .Select_Tab, whip_created_tab)
					whip_created_tab = 0
					if whip_new_pending == 0 {whip_control.work = .Complete}
				}
			}
			if whip_created_focus != 0 {
				if _, found := whip_model.find_pane(
					&whip_catalog.view.session,
					whip_created_focus,
				); found {
					whip_pane_focus(u32(whip_created_focus))
					whip_created_focus = 0
					if whip_split_pending == 0 {whip_control.work = .Complete}
				}
			}
			if whip_ui != nil && !whip_ui.view.running {
				whip_failed = true
				if whip_new_pending > 0 {whip_new_pending = 0; whip_control.work = .Complete}
				whip_created_tab = 0
			}
		}
	}

	@(private)
	whip_event :: proc(event: sdl.Event) -> bool {
		if whip_visible && !whip_failed {
			#partial switch event.type {
			case .MOUSE_MOTION, .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP, .MOUSE_WHEEL:
				for _, ui in whip_mounts {
					if ui.view.mouse.drag != .None {return whip.event(ui.view, event)}
				}
				x, y: f32
				#partial switch event.type {
				case .MOUSE_MOTION:
					x, y = event.motion.x, event.motion.y
				case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
					x, y = event.button.x, event.button.y
				case .MOUSE_WHEEL:
					x, y = event.wheel.mouse_x, event.wheel.mouse_y
				}
				density := sdl.GetWindowPixelDensity(state.window)
				for id, ui in whip_mounts {
					bounds := ui.view.bounds
					inside :=
						int(x * density) >= bounds.x &&
						int(y * density) >= bounds.y &&
						int(x * density) < bounds.x + bounds.w &&
						int(y * density) < bounds.y + bounds.h
					if inside &&
					   (event.type == .MOUSE_BUTTON_DOWN ||
							   event.type == .MOUSE_MOTION &&
								   ui.view.config.focus_follows_mouse) {whip_pane_focus(id)}
					if inside {return whip.event(ui.view, event)}
				}
				return false
			}
		}
		if whip_ui != nil &&
		   !whip_failed &&
		   (whip_visible || whip_enabled && whip_ui.view.mode == .Navigate) {
			navigating := whip_ui.view.mode == .Navigate
			consumed := whip.event(whip_ui.view, event)
			if navigating && whip_ui.view.mode != .Navigate && !whip_control.selection {
				whip_host_action(whip_ui.view, .Select_Tab, whip_model.Id(whip_tab))
			}
			return consumed
		}
		return false
	}

	WhipClose :: proc() {
		_, _ = whip_create_join()
		_, _ = whip_tab_join()
		if whip_worker != nil {
			thread.join(whip_worker)
			thread.destroy(whip_worker)
		}
		whip_panes_close()
		if whip_catalog != nil {whip.destroy_sdl(whip_catalog)}
		whip_notices_clear()
		delete(whip_notices)
		whip_notices = {}
		whip_notice_allocator = {}
		delete(whip_projects)
		whip_tabs_trim(0)
		delete(whip_tabs)
		whip_projects = {}
		whip_tabs = {}
		whip_catalog = nil
		whip_project, whip_tab = 0, 0
		whip_ui, whip_worker = nil, nil
		whip_started, whip_failed, whip_visible = 0, false, false
		whip_enabled, whip_control = false, {}
		whip_new_pending = 0
		whip_created_tab = 0
		whip_split_pending, whip_created_focus = 0, 0
	}
}
