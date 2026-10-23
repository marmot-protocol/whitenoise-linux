package sdlrl

import sdl "vendor:sdl3"

_ :: sdl

Whip_State :: enum {
	Idle,
	Starting,
	Ready,
	Failed,
}

Whip_Visibility :: enum {
	Hidden,
	Visible,
}

// No native imports or linked dependencies in builds without Whip.
when !#config(WN_WHIP, false) {
	WhipAvailable :: proc() -> bool {return false}
	WhipState :: proc() -> Whip_State {return .Idle}
	WhipFrame :: proc(visibility: Whip_Visibility) {}
	DrawWhip :: proc(x, y, w, h: f32) {}
	WhipClose :: proc() {}

	@(private)
	whip_event :: proc(event: sdl.Event) -> bool {return false}
}
