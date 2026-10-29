package sdlrl

import sdl "vendor:sdl3"

_ :: sdl

@(private)
whip_input_yield: bool

@(private)
inbox_navigation :: proc(event: sdl.Event) -> bool {
	return(
		event.type == .KEY_DOWN &&
		event.key.mod & sdl.KMOD_CTRL != {} &&
		(event.key.scancode == .TAB ||
				event.key.mod & sdl.KMOD_SHIFT != {} &&
					(event.key.scancode == .UP || event.key.scancode == .DOWN)) \
	)
}

Whip_State :: enum {
	Idle,
	Starting,
	Ready,
	Failed,
	Missing,
}

Whip_Create_State :: enum {
	Idle,
	Creating,
	Ready,
	Failed,
}

Whip_Visibility :: enum {
	Hidden,
	Projects,
	Visible,
	Unfocused,
	Navigation,
}

// Borrowed names/directories remain valid until the next WhipFrame.
Whip_Project :: struct {
	id:          u32,
	session:     [4]u64,
	name, dir:   string,
	source_dir:  string, // raw Whip cwd, before host project-root overrides
	source_name: string,
	tabs:        int,
	waiting:     int,
	activity_at: u64, // observed live activity, Unix seconds; unknown history stays zero
	navigating:  bool,
}

// Borrowed names remain valid until the next WhipFrame.
Whip_Tab :: struct {
	id:      u32,
	name:    string,
	active:  bool,
	waiting: int,
}

// Borrowed notice payloads remain valid until the next WhipFrame.
Whip_Notice :: struct {
	project, tab: u32,
	title, body:  string,
}

Whip_Tab_Action :: enum {
	New,
	Close,
}

Whip_Work :: enum {
	None,
	New_Tab,
	New_Project,
	New_Pane,
	Complete,
}

Whip_Control :: struct {
	project, tab:                                  u32,
	pane:                                          u32,
	project_step:                                  int,
	selection, sidebar, projects, detach, focused: bool,
	work:                                          Whip_Work,
}

Whip_Axis :: enum u8 {
	Right,
	Down,
}
Whip_Node_Kind :: enum u8 {
	Free,
	Leaf,
	Split,
}
Whip_Node :: struct {
	kind:          Whip_Node_Kind,
	axis:          Whip_Axis,
	ratio:         f32,
	first, second: int,
	pane:          u32,
	slot:          int,
}
Whip_Pane :: struct {
	id:                                   u32,
	project, tab:                         u32,
	session:                              [4]u64, // connected server credentials, process start and boot identity
	name, mode:                           string,
	focused, waiting, loading, restoring: bool,
}
// Lists every detached pane, including chat docks that are currently hidden.
Whip_Surface :: struct {
	pane:    u32,
	visible: bool,
}
Whip_Pane_Action :: enum {
	Focus,
	Split_Right,
	Split_Down,
	Close,
	Zoom,
}

// No native imports or linked dependencies in builds without Whip.
when !#config(WN_WHIP, false) {
	WhipAvailable :: proc() -> bool {return false}
	WhipState :: proc() -> Whip_State {return .Idle}
	WhipFrame :: proc(
		visibility: Whip_Visibility,
		project, tab: u32,
		surfaces: []Whip_Surface = nil,
		focused: u32 = 0,
	) {}
	WhipProjects :: proc() -> []Whip_Project {return nil}
	WhipTabs :: proc() -> []Whip_Tab {return nil}
	WhipNotices :: proc() -> []Whip_Notice {return nil}
	WhipControlPoll :: proc() -> Whip_Control {return {}}
	WhipCreate :: proc(dir: string) -> bool {return false}
	WhipCreatePoll :: proc() -> (Whip_Create_State, u32) {return .Idle, 0}
	WhipTabChange :: proc(action: Whip_Tab_Action, id: u32) -> bool {return false}
	WhipTabPoll :: proc() -> (Whip_Create_State, u32) {return .Idle, 0}
	WhipPanes :: proc() -> []Whip_Pane {return nil}
	WhipPaneInfo :: proc(pane: u32) -> (Whip_Pane, bool) {return {}, false}
	WhipTree :: proc() -> ([]Whip_Node, int, u32) {return nil, -1, 0}
	WhipPaneAct :: proc(action: Whip_Pane_Action, pane: u32) {}
	WhipPaneRatio :: proc(node: int, ratio: f32) {}
	DrawWhipPane :: proc(pane: u32, x, y, w, h: f32, input_top: f32 = 0) {}
	WhipClose :: proc() {}

	@(private)
	whip_event :: proc(event: sdl.Event) -> bool {return false}
	@(private)
	whip_input_pending :: proc() -> bool {return false}
}
