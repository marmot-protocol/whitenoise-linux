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
			if whip_ui != nil {whip.destroy_sdl(whip_ui); whip_ui = nil}
			if whip_catalog != nil {whip.destroy_sdl(whip_catalog); whip_catalog = nil}
			clear(&whip_projects); clear(&whip_tabs)
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
		if whip_ui != nil {
			switch whip.view_status(whip_ui.view) {
			case .Missing:
				return .Missing
			case .Stopped:
				return .Failed
			case .Pending:
				return .Starting
			case .Ready:
				return .Ready
			}
		}
		if whip_worker != nil {return .Starting}
		return .Idle
	}

	WhipProjects :: proc() -> []Whip_Project {
		return whip_projects[:]
	}

	WhipTabs :: proc() -> []Whip_Tab {
		return whip_tabs[:]
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
		   u32(tab.id) == whip_tab {
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
			if node.kind == .Leaf {
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
		was_visible := whip_visible
		whip_visible = visibility == .Visible
		if project != whip_project || tab != whip_tab {
			if whip_ui != nil {whip.destroy_sdl(whip_ui); whip_ui = nil}
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
			whip_attention_seen()
			clear(&whip_projects)
			clear(&whip_tabs)
			for &entry in whip.projects(whip_catalog.view) {
				project_waiting := 0
				for &tab, i in whip.tabs(whip_catalog.view, entry.id) {
					waiting := whip_waiting(&tab)
					project_waiting += waiting
					if u32(entry.id) == whip_project {
						append(
							&whip_tabs,
							Whip_Tab {
								id = u32(tab.id),
								name = whip.tab_label(whip_catalog.view, &tab),
								active = i == entry.active,
								waiting = waiting,
							},
						)
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
					},
				)
			}
			if !whip_catalog.view.running {whip_failed = true}
		}
		if whip_ui != nil {
			if whip_visible && !was_visible {whip.set_focus(whip_ui.view, .Focused)}
			if !whip_visible {
				whip.set_focus(whip_ui.view, .Blurred)
				whip.set_bounds(whip_ui.view, {})
			}
			whip.update(whip_ui.view)
			if !whip_ui.view.running {whip_failed = true}
		}
	}

	@(private)
	whip_event :: proc(event: sdl.Event) -> bool {
		if whip_ui != nil && whip_visible && !whip_failed {
			return whip.event(whip_ui.view, event)
		}
		return false
	}

	// Clay supplies logical bounds; Whip uses physical framebuffer pixels.
	DrawWhip :: proc(x, y, w, h: f32) {
		if whip_failed ||
		   whip_catalog == nil ||
		   whip_project == 0 ||
		   whip_tab == 0 ||
		   WhipState() == .Missing {return}
		sx, sy: f32
		sdl.GetRenderScale(state.renderer, &sx, &sy)
		bounds := whip_model.Rect{int(x * sx), int(y * sy), int(w * sx), int(h * sy)}
		if bounds.w <= 0 || bounds.h <= 0 {return}
		if whip_ui == nil {
			whip_ui = whip.create_sdl(
				state.window,
				state.renderer,
				"default",
				bounds,
				{kind = .Tab, id = whip_model.Id(whip_tab)},
			)
			if whip_ui == nil {whip_failed = true; return}
			whip.set_notice_handler(whip_ui.view, whip_host_notice)
			whip.set_focus(whip_ui.view, .Focused)
		}
		whip.set_bounds(whip_ui.view, bounds)
		if !whip.render_sdl(whip_ui) {whip_failed = true}
	}

	WhipClose :: proc() {
		_, _ = whip_create_join()
		_, _ = whip_tab_join()
		if whip_worker != nil {
			thread.join(whip_worker)
			thread.destroy(whip_worker)
		}
		if whip_ui != nil {whip.destroy_sdl(whip_ui)}
		if whip_catalog != nil {whip.destroy_sdl(whip_catalog)}
		whip_notices_clear()
		delete(whip_notices)
		whip_notices = {}
		whip_notice_allocator = {}
		delete(whip_projects)
		delete(whip_tabs)
		whip_projects = {}
		whip_tabs = {}
		whip_catalog = nil
		whip_project, whip_tab = 0, 0
		whip_ui, whip_worker = nil, nil
		whip_started, whip_failed, whip_visible = 0, false, false
	}
}
