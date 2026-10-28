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
	testing.expect(
		t,
		GetMousePosition().x > -1000,
		"the release frame keeps the tap position for its click",
	)
	WindowShouldClose()
	testing.expect(t, GetMousePosition().x < -1000, "a lifted finger leaves no hover behind")
	event.type = .MOUSE_MOTION
	event.motion.windowID = sdl.GetWindowID(state.window)
	event.motion.which = 0
	testing.expect(t, sdl.PushEvent(&event))
	WindowShouldClose()
	testing.expect(
		t,
		GetMousePosition().x < -1000,
		"a motion event that did not move the mouse keeps the pointer parked",
	)
	event.motion.xrel = 1
	testing.expect(t, sdl.PushEvent(&event))
	WindowShouldClose()
	testing.expect(t, GetMousePosition().x > -1000, "a mouse moving again restores the pointer")
	testing.expect(t, !TouchActive(), "a moving mouse becomes the active modality")
}
