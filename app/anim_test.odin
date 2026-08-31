package main

import "core:testing"

// The scroll-lag split must never change a row's height: if it does,
// the timeline's content resizes mid-scroll and the bottom-pinned view
// slides off the newest message.
@(test)
test_lag_pads_total :: proc(t: ^testing.T) {
	for i in -120 ..= 120 {
		lag := f32(i) / 10
		top, bottom := lag_pads(lag)
		testing.expectf(t, top + bottom == 2 * MSG_PAD_Y, "lag %v split %v+%v", lag, top, bottom)
	}
}
