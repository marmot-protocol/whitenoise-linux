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

// Videos are not listed: mpv wakes the loop for each event and frame.
@(private)
frame_idle :: proc() -> bool {
	if anim_moving > 0 ||
	   scroll_jumped ||
	   voice_active() ||
	   web_modal.open ||
	   nes_player.open ||
	   rl.IsMouseButtonDown(.LEFT) ||
	   rl.IsMouseButtonDown(.RIGHT) {
		return false
	}
	return true
}
