package main

import rl "sdlrl"
import sdl "vendor:sdl3"

@(private)
IDLE_REFRESH_MS :: 250 // periodic services still need a bounded polling deadline
@(private)
frame_deadline: f64

// SDL's event queue is thread-safe and also wakes WaitEventTimeout.
@(private)
frame_wake :: proc() {
	event := sdl.Event {
		type = .USER,
	}
	_ = sdl.PushEvent(&event)
}

@(private)
frame_idle :: proc() -> bool {
	if anim_moving > 0 ||
	   scroll_jumped ||
	   voice.stream != nil ||
	   web_modal.open ||
	   rl.IsMouseButtonDown(.LEFT) ||
	   rl.IsMouseButtonDown(.RIGHT) {
		return false
	}
	for _, view in video_views {
		if view != nil && !view.failed && (!view.paused || (!view.audio && !view.sized)) {
			return false
		}
	}
	if g_ui != nil &&
	   g_ui.picker_open &&
	   g_ui.gif_tab &&
	   g_ui.gif_view != nil &&
	   !g_ui.gif_view.failed {
		return false
	}
	if preview_shown &&
	   preview.vid != nil &&
	   !preview.vid.failed &&
	   (!preview.vid.paused || (!preview.vid.audio && !preview.vid.sized)) {
		return false
	}
	return true
}
