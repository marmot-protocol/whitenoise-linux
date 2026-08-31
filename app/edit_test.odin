// Checks for the grapheme boundary helpers behind Backspace/Delete and
// caret motion (core:text/edit's own grapheme mode subtracts monospace
// cell widths and corrupts wide chars, so these are computed locally).
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:testing"

@(test)
grapheme_boundaries :: proc(t: ^testing.T) {
	// CJK: each kana/kanji is one 3-byte grapheme.
	testing.expect_value(t, prev_grapheme("寝る", 6), 3)
	testing.expect_value(t, prev_grapheme("寝る", 3), 0)
	testing.expect_value(t, next_grapheme("寝る", 0), 3)
	testing.expect_value(t, next_grapheme("寝る", 3), 6)

	// ZWJ emoji family is one cluster.
	family := "👨‍👩‍👧"
	testing.expect_value(t, prev_grapheme(family, len(family)), 0)
	testing.expect_value(t, next_grapheme(family, 0), len(family))

	// Combining accent rides its base: "e" + U+0301.
	testing.expect_value(t, prev_grapheme("aé", 3), 1)

	// Ends clamp.
	testing.expect_value(t, prev_grapheme("abc", 0), 0)
	testing.expect_value(t, next_grapheme("abc", 3), 3)
}
