package sdlrl

import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
close_without_tray_quits :: proc(t: ^testing.T) {
	sync.lock(&sdl_test_mutex)
	defer sync.unlock(&sdl_test_mutex)
	InitWindow(320, 240, "No tray")
	defer CloseWindow()
	defer {state.quit = false}
	SetHideOnClose(true)

	close: sdl.Event
	close.type = .WINDOW_CLOSE_REQUESTED
	close.window.windowID = sdl.GetWindowID(state.window)
	testing.expect(t, sdl.PushEvent(&close))
	testing.expect(t, WindowShouldClose())
	testing.expect(t, .HIDDEN not_in sdl.GetWindowFlags(state.window))
}

@(test)
update_quit_while_hidden :: proc(t: ^testing.T) {
	sync.lock(&sdl_test_mutex)
	defer sync.unlock(&sdl_test_mutex)
	InitWindow(320, 240, "Updater quit")
	defer CloseWindow()
	defer {state.quit = false}
	SetHideOnClose(true)
	testing.expect(t, sdl.HideWindow(state.window))
	RequestQuit()
	testing.expect(t, WindowShouldClose())
}
