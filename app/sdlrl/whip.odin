package sdlrl

import sdl "vendor:sdl3"

_ :: sdl

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
}

// Borrowed names/directories remain valid until the next WhipFrame.
Whip_Project :: struct {
	id:        u32,
	name, dir: string,
	tabs:      int,
	waiting:   int,
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

// No native imports or linked dependencies in builds without Whip.
when !#config(WN_WHIP, false) {
	WhipAvailable :: proc() -> bool {return false}
	WhipState :: proc() -> Whip_State {return .Idle}
	WhipFrame :: proc(visibility: Whip_Visibility, project, tab: u32) {}
	WhipProjects :: proc() -> []Whip_Project {return nil}
	WhipTabs :: proc() -> []Whip_Tab {return nil}
	WhipNotices :: proc() -> []Whip_Notice {return nil}
	WhipCreate :: proc(dir: string) -> bool {return false}
	WhipCreatePoll :: proc() -> (Whip_Create_State, u32) {return .Idle, 0}
	WhipTabChange :: proc(action: Whip_Tab_Action, id: u32) -> bool {return false}
	WhipTabPoll :: proc() -> (Whip_Create_State, u32) {return .Idle, 0}
	DrawWhip :: proc(x, y, w, h: f32) {}
	WhipClose :: proc() {}

	@(private)
	whip_event :: proc(event: sdl.Event) -> bool {return false}
}
