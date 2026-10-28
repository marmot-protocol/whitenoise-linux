package sdlrl

import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
touch_mouse_enables_targets :: proc(t: ^testing.T) {
	sync.lock(&sdl_test_mutex)
	defer sync.unlock(&sdl_test_mutex)
	InitWindow(360, 640, "Touch input")
	defer CloseWindow()
	state.touch = false
	event: sdl.Event
	event.type = .MOUSE_BUTTON_DOWN
	event.button.windowID = sdl.GetWindowID(state.window)
	event.button.which = sdl.TOUCH_MOUSEID
	event.button.button = 1
	event.button.down = true
	event.button.clicks = 1
	testing.expect(t, sdl.PushEvent(&event))
	WindowShouldClose()
	testing.expect(t, HasTouch(), "first touch enables touch controls without restarting")
	testing.expect(t, IsMouseButtonPressed(.LEFT) && IsMouseButtonDown(.LEFT))
	event.type = .MOUSE_BUTTON_UP
	event.button.down = false
	testing.expect(t, sdl.PushEvent(&event))
	WindowShouldClose()
	testing.expect(
		t,
		IsMouseButtonReleased(.LEFT) && !IsMouseButtonDown(.LEFT),
		"touch release completes the same input sequence as a mouse click",
	)
}
