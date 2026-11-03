package main

import "core:time"

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

// On battery, motion (scrolling, transitions, loading bars) runs at 60
// fps instead of the panel's rate. A 2560x1600 frame costs about 1 ms of
// iGPU time, so motion on a 165 Hz panel drops from roughly 16% busy to
// 6%. AC power keeps the full rate. SDL reads sysfs for the power state,
// so it is checked every few seconds, not every frame.
@(private = "file")
BATTERY_FRAME_SECS :: 1.0 / 60
@(private = "file")
POWER_CHECK_SECS :: 5
@(private = "file")
on_battery: bool
@(private = "file")
power_checked_at: f64

// Sleeps out the rest of a 60 fps frame for frames that did not idle.
@(private)
battery_frame_cap :: proc(frame_start: time.Tick) {
	now := rl.GetTime()
	if power_checked_at == 0 || now - power_checked_at >= POWER_CHECK_SECS {
		power_checked_at = now
		on_battery = sdl.GetPowerInfo(nil, nil) == .ON_BATTERY
	}
	if !on_battery {
		return
	}
	spent := time.duration_seconds(time.tick_since(frame_start))
	if spent < BATTERY_FRAME_SECS {
		time.sleep(time.Duration((BATTERY_FRAME_SECS - spent) * f64(time.Second)))
	}
}
