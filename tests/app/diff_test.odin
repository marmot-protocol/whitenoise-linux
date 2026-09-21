// Checks for the edit-history word diff.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:strings"
import "core:testing"

@(test)
history_original_completion :: proc(t: ^testing.T) {
	old := ops_done
	ops_done = {}
	defer {delete(ops_done); ops_done = old}
	ui := Ui_State {
		hist_ticket = 2,
	}
	defer {
		for v in ui.hist_versions {delete(v.at); delete(v.text)}
		delete(ui.hist_versions)
	}
	// A stale result must not supply another message's original.
	append(
		&ops_done,
		Op_Done {
			ticket = 1,
			op = .History,
			has_original = true,
			content = strings.clone("other message"),
		},
	)
	drain_ops(&ui, nil)
	testing.expect_value(t, len(ui.hist_versions), 0)
	testing.expect_value(t, ui.hist_ticket, 2)
	append(
		&ops_done,
		Op_Done {
			ticket = 2,
			op = .History,
			has_original = true,
			original_at = 123,
			content = strings.clone("original message"),
		},
	)
	drain_ops(&ui, nil)
	testing.expect(t, ui.hist_original)
	testing.expect_value(t, ui.hist_ticket, 0)
	if testing.expect_value(t, len(ui.hist_versions), 1) {
		testing.expect_value(t, ui.hist_versions[0].text, "original message")
		at := format_when(123)
		defer delete(at)
		testing.expect_value(t, ui.hist_versions[0].at, at)
	}
}

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
