package sdlrl

import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"

// SDL and picker tests share the shim's process-global state.
@(private)
sdl_test_mutex: sync.Mutex

@(private)
push_drop_event :: proc(
	t: ^testing.T,
	kind: sdl.EventType,
	window: sdl.WindowID,
	position: Vector2 = {},
	data: cstring = nil,
) {
	event: sdl.Event
	event.type = kind
	event.drop.windowID = window
	event.drop.x = position.x
	event.drop.y = position.y
	event.drop.data = data
	testing.expect(t, sdl.PushEvent(&event))
}

// Run headlessly: SDL_VIDEODRIVER=dummy tests/odin.sh app/sdlrl
@(test)
file_drop_complete_batches :: proc(t: ^testing.T) {
	sync.lock(&sdl_test_mutex)
	defer sync.unlock(&sdl_test_mutex)
	InitWindow(320, 240, "File drops")
	defer CloseWindow()
	window := sdl.GetWindowID(state.window)

	// Keep the pushed payload alive through the pump, then change it to prove
	// the pending batch owns a copy, not SDL's transient event pointer.
	first := make([]u8, len("/tmp/first photo.png") + 1)
	copy(first, "/tmp/first photo.png")
	defer delete(first)
	push_drop_event(t, .DROP_BEGIN, window)
	push_drop_event(t, .DROP_POSITION, window, {71.5, 42.25})
	push_drop_event(t, .DROP_FILE, window, {71.5, 42.25}, cstring(raw_data(first)))
	push_drop_event(t, .DROP_FILE, window, {71.5, 42.25}, "/tmp/another folder/second file.txt")
	changed := false
	testing.expect(t, !WindowShouldClose(&changed))
	testing.expect(t, changed && FileDropActive())
	testing.expect_value(t, FileDropPosition(), Vector2{71.5, 42.25})
	incomplete := DroppedFiles()
	defer delete(incomplete)
	testing.expect_value(t, len(incomplete), 0)
	first[5] = 'X'

	// Native picker completions stay in their own queue, even during a drag.
	picker_paths := [2]cstring{"/tmp/picked separately.txt", nil}
	picked_pending = 1
	dialog_cb(nil, raw_data(picker_paths[:]), 0)
	push_drop_event(t, .DROP_COMPLETE, window, {91.75, 63.5})
	// Two complete batches in the same pump preserve arrival order.
	push_drop_event(t, .DROP_BEGIN, window)
	push_drop_event(t, .DROP_FILE, window, {101, 77}, "/tmp/third.txt")
	push_drop_event(t, .DROP_COMPLETE, window, {101, 77})
	testing.expect(t, !WindowShouldClose())
	testing.expect(t, !FileDropActive())
	testing.expect_value(t, FileDropPosition(), Vector2{101, 77})
	paths := DroppedFiles()
	defer {
		for file in paths {delete(file.path)}
		delete(paths)
	}
	testing.expect_value(t, len(paths), 3)
	if len(paths) == 3 {
		testing.expect_value(t, paths[0].path, "/tmp/first photo.png")
		testing.expect_value(t, paths[1].path, "/tmp/another folder/second file.txt")
		testing.expect_value(t, paths[2].path, "/tmp/third.txt")
		testing.expect_value(t, paths[0].position, Vector2{91.75, 63.5})
		testing.expect_value(t, paths[1].position, Vector2{91.75, 63.5})
		testing.expect_value(t, paths[2].position, Vector2{101, 77})
	}
	again := DroppedFiles()
	defer delete(again)
	testing.expect_value(t, len(again), 0)
	completed := false
	picked := PickedFiles(&completed)
	defer {
		for path in picked {delete(path)}
		delete(picked)
	}
	testing.expect(t, completed && !FileDialogPending())
	testing.expect_value(t, len(picked), 1)
	if len(picked) == 1 {testing.expect_value(t, picked[0], "/tmp/picked separately.txt")}

	// A later pump cannot free data whose ownership was transferred to us.
	testing.expect(t, !WindowShouldClose())
	if len(paths) == 3 {testing.expect_value(t, paths[0].path, "/tmp/first photo.png")}
}

@(test)
file_drop_cancellation_scope_and_stale_results :: proc(t: ^testing.T) {
	sync.lock(&sdl_test_mutex)
	defer sync.unlock(&sdl_test_mutex)
	InitWindow(320, 240, "Drop cancellation")
	defer CloseWindow()
	window := sdl.GetWindowID(state.window)
	other_window := window + 1

	push_drop_event(t, .DROP_BEGIN, window)
	push_drop_event(t, .DROP_POSITION, window, {20, 30})
	testing.expect(t, !WindowShouldClose())
	testing.expect(t, FileDropActive())
	// No normal mouse motion and no new drop events: the drag remains active
	// at its last SDL drop position across frames.
	testing.expect(t, !WindowShouldClose())
	testing.expect(t, FileDropActive())
	testing.expect_value(t, FileDropPosition(), Vector2{20, 30})
	push_drop_event(t, .DROP_POSITION, other_window, {200, 210})
	push_drop_event(t, .DROP_FILE, other_window, {200, 210}, "/tmp/foreign.txt")
	push_drop_event(t, .DROP_COMPLETE, other_window, {200, 210})
	testing.expect(t, !WindowShouldClose())
	testing.expect(t, FileDropActive())
	testing.expect_value(t, FileDropPosition(), Vector2{20, 30})

	// SDL signals leaving/cancelling with an empty DROP_COMPLETE, not a
	// dedicated cancellation event. It must end highlighting without files.
	push_drop_event(t, .DROP_COMPLETE, window, {20, 30})
	testing.expect(t, !WindowShouldClose())
	testing.expect(t, !FileDropActive())
	cancelled := DroppedFiles()
	defer delete(cancelled)
	testing.expect_value(t, len(cancelled), 0)

	push_drop_event(t, .DROP_BEGIN, window)
	push_drop_event(t, .DROP_FILE, window, {30, 40}, "/tmp/abandoned.txt")
	testing.expect(t, !WindowShouldClose())
	push_drop_event(t, .DROP_BEGIN, window)
	push_drop_event(t, .DROP_FILE, window, {40, 50}, "/tmp/unconsumed.txt")
	push_drop_event(t, .DROP_COMPLETE, window, {40, 50})
	// A later in-progress batch must not expose its files early, nor inherit
	// files from the abandoned batch or the unconsumed completed batch.
	push_drop_event(t, .DROP_BEGIN, window)
	push_drop_event(t, .DROP_FILE, window, {50, 60}, "/tmp/current.txt")
	testing.expect(t, !WindowShouldClose())
	testing.expect(t, FileDropActive())
	testing.expect(t, !WindowShouldClose()) // expire the unconsumed result
	stale := DroppedFiles()
	defer delete(stale)
	testing.expect_value(t, len(stale), 0)
	push_drop_event(t, .DROP_COMPLETE, window, {55, 65})
	testing.expect(t, !WindowShouldClose())
	testing.expect(t, !FileDropActive())
	testing.expect_value(t, FileDropPosition(), Vector2{55, 65})
	current := DroppedFiles()
	defer {
		for file in current {delete(file.path)}
		delete(current)
	}
	testing.expect_value(t, len(current), 1)
	if len(current) == 1 {
		testing.expect_value(t, current[0].path, "/tmp/current.txt")
		testing.expect_value(t, current[0].position, Vector2{55, 65})
	}

	// An orphan payload/completion cannot resurrect a previous drag.
	push_drop_event(t, .DROP_FILE, window, {60, 70}, "/tmp/orphan.txt")
	push_drop_event(t, .DROP_COMPLETE, window, {60, 70})
	testing.expect(t, !WindowShouldClose())
	orphan := DroppedFiles()
	defer delete(orphan)
	testing.expect_value(t, len(orphan), 0)
	testing.expect(t, !FileDropActive())
}

@(test)
file_drop_shutdown_clears_batches :: proc(t: ^testing.T) {
	sync.lock(&sdl_test_mutex)
	defer sync.unlock(&sdl_test_mutex)
	InitWindow(320, 240, "Drop shutdown")
	window := sdl.GetWindowID(state.window)
	push_drop_event(t, .DROP_BEGIN, window)
	push_drop_event(t, .DROP_FILE, window, {10, 20}, "/tmp/complete-before-close.txt")
	push_drop_event(t, .DROP_COMPLETE, window, {10, 20})
	push_drop_event(t, .DROP_BEGIN, window)
	push_drop_event(t, .DROP_FILE, window, {30, 40}, "/tmp/incomplete-before-close.txt")
	testing.expect(t, !WindowShouldClose())
	testing.expect(t, FileDropActive())
	CloseWindow()
	testing.expect(t, !FileDropActive())
	testing.expect_value(t, FileDropPosition(), Vector2{})
	testing.expect_value(t, len(state.drop_paths), 0)
	after_close := DroppedFiles()
	defer delete(after_close)
	testing.expect_value(t, len(after_close), 0)

	InitWindow(320, 240, "New drop session")
	defer CloseWindow()
	window = sdl.GetWindowID(state.window)
	push_drop_event(t, .DROP_COMPLETE, window, {30, 40})
	push_drop_event(t, .DROP_BEGIN, window)
	push_drop_event(t, .DROP_FILE, window, {50, 60}, "/tmp/new-session.txt")
	push_drop_event(t, .DROP_COMPLETE, window, {50, 60})
	testing.expect(t, !WindowShouldClose())
	paths := DroppedFiles()
	defer {
		for file in paths {delete(file.path)}
		delete(paths)
	}
	testing.expect_value(t, len(paths), 1)
	if len(paths) == 1 {
		testing.expect_value(t, paths[0].path, "/tmp/new-session.txt")
		testing.expect_value(t, paths[0].position, Vector2{50, 60})
	}
}
