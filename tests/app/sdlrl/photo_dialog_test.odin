package sdlrl

import "core:sync"
import "core:testing"

@(test)
photo_dialog_tombstone :: proc(t: ^testing.T) {
	sync.lock(&sdl_test_mutex)
	defer sync.unlock(&sdl_test_mutex)
	old_allocator := callback_allocator
	callback_allocator = context.allocator
	defer {callback_allocator = old_allocator}
	picked_pending = 1
	DiscardFileDialogResult()
	paths := [2]cstring{"late-photo.png", nil}
	dialog_cb(nil, raw_data(paths[:]), 0)
	completed := false
	picked := PickedFiles(&completed)
	defer delete(picked)
	testing.expect(t, completed)
	testing.expect(t, len(picked) == 0, "A photo returning after lock cannot become an attachment")
	testing.expect(t, !FileDialogPending())

	// Cancellation and failure are still completions, not stuck pick routes.
	picked_pending = 1
	dialog_cb(nil, nil, 0)
	picked = PickedFiles(&completed)
	testing.expect(t, completed && !FileDialogPending())
	testing.expect_value(t, len(picked), 0)

	// A completion from one older dialog must not allow a photo pick while
	// another untagged callback is still outstanding.
	picked_pending = 2
	empty := [1]cstring{nil}
	dialog_cb(nil, raw_data(empty[:]), 0)
	picked = PickedFiles(&completed)
	testing.expect(t, completed && FileDialogPending())
	dialog_cb(nil, raw_data(empty[:]), 0)
	picked = PickedFiles(&completed)
	testing.expect(t, completed && !FileDialogPending())
}
