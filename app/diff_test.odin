// Checks for the edit-history word diff.
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:testing"

@(test)
diff_word_cases :: proc(t: ^testing.T) {
	// One word inserted; neighbours stay unchanged.
	runs := diff_words("remove the bubbles", "remove the message bubbles")
	testing.expect_value(t, len(runs), 4)
	testing.expect_value(t, runs[2], Diff_Run{.Added, "message"})
	testing.expect_value(t, runs[3], Diff_Run{.Same, "bubbles"})

	// One word removed.
	runs = diff_words("hello old world", "hello world")
	testing.expect_value(t, runs[1], Diff_Run{.Removed, "old"})

	// Replacement: removed before added within the gap.
	runs = diff_words("make it red", "make it blue")
	testing.expect_value(t, runs[2], Diff_Run{.Removed, "red"})
	testing.expect_value(t, runs[3], Diff_Run{.Added, "blue"})

	// Full rewrite and empty sides.
	runs = diff_words("old text", "completely new words")
	testing.expect_value(t, len(runs), 5)
	testing.expect_value(t, len(diff_words("", "")), 0)
	testing.expect_value(t, diff_words("", "hi")[0], Diff_Run{.Added, "hi"})
}
