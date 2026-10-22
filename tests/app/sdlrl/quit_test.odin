package sdlrl

import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
update_quit_after_tray_close :: proc(t: ^testing.T) {
	sync.lock(&sdl_test_mutex)
	defer sync.unlock(&sdl_test_mutex)
	InitWindow(320, 240, "Updater quit")
	defer CloseWindow()
	defer {
		hide_on_close = false
		swallow_quit = false
		state.quit = false
	}
	SetHideOnClose(true)

	// With an active tray SDL does not synthesize QUIT after this request.
	event: sdl.Event
	event.type = .WINDOW_CLOSE_REQUESTED
	event.window.windowID = sdl.GetWindowID(state.window)
	testing.expect(t, sdl.PushEvent(&event))
	testing.expect(t, !WindowShouldClose())
	ShowWindow()

	// Installing an update must exit rather than consume the pending suppression.
	RequestQuit()
	testing.expect(t, WindowShouldClose())
}
