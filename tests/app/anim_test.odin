package main

import "base:runtime"
import "core:sync"
import "core:testing"

// The runner frees each test's allocator when the test ends, so a global
// map first grown inside one test points at dead memory in the next and
// its next insert panics. Allocate the anim maps from the heap up front,
// as the app's own context does.
@(init)
anim_maps_on_heap :: proc "contextless" () {
	context = runtime.default_context()
	anim_vals = make(map[u32]Anim)
	anim_cols = make(map[u32]Anim_Color)
}

// The scroll-lag split must never change a row's height: if it does,
// the timeline's content resizes mid-scroll and the bottom-pinned view
// slides off the newest message.
// A pinned entry must not replay: after anim_set, the next anim_to at
// the same target returns it immediately instead of easing in from the
// value the drag started at.
@(test)
test_anim_set_no_replay :: proc(t: ^testing.T) {
	// Layout tests step the same global anim state under this lock.
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	anim_tick(1.0 / 60)
	_ = anim_to(0x77770001, 100) // first sighting seeds at the target
	anim_tick(1.0 / 60)
	anim_set(0x77770001, 340)
	anim_tick(1.0 / 60)
	testing.expect(t, anim_to(0x77770001, 340) == 340, "entry replayed the drag")
}

@(test)
test_lag_pads_total :: proc(t: ^testing.T) {
	for i in -120 ..= 120 {
		lag := f32(i) / 10
		top, bottom := lag_pads(lag)
		testing.expectf(t, top + bottom == 2 * MSG_PAD_Y, "lag %v split %v+%v", lag, top, bottom)
	}
}
