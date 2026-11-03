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

// InitWindow lets the screensaver run. Hold it off only while something
// is being watched.
@(private = "file")
screen_held: bool

@(private)
screensaver_update :: proc() {
	hold := nes_player.open || (preview_shown && clip_playing(preview.vid))
	for _, view in video_views {
		hold ||= clip_playing(view)
	}
	if hold == screen_held {
		return
	}
	screen_held = hold
	if hold {
		sdl.DisableScreenSaver()
	} else {
		sdl.EnableScreenSaver()
	}
}

@(private = "file")
clip_playing :: proc(view: ^Video_View) -> bool {
	return view != nil && !view.failed && !view.paused && !view.looping && !view.audio
}
