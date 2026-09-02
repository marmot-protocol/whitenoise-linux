package main

import "core:testing"

@(test)
sel_snap_whole_url :: proc(t: ^testing.T) {
	// The bug this exists for: a selected tail leaves a shorter URL
	// that is a valid link to a different PR.
	text := "see https://github.com/a/b/pull/1630 ok"
	lo, hi := sel_snap(text, 34, 36) // the "30"
	testing.expect_value(t, lo, 4)
	testing.expect_value(t, hi, 36)

	// Edges outside every URL run are left alone.
	lo2, hi2 := sel_snap(text, 0, 3)
	testing.expect_value(t, lo2, 0)
	testing.expect_value(t, hi2, 3)

	// Already whole: snapping is idempotent.
	lo3, hi3 := sel_snap(text, 4, 36)
	testing.expect_value(t, lo3, 4)
	testing.expect_value(t, hi3, 36)
}
