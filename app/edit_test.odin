// Checks for the grapheme boundary helpers behind Backspace/Delete and
// caret motion (core:text/edit's own grapheme mode subtracts monospace
// cell widths and corrupts wide chars, so these are computed locally).
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:testing"
import "core:strings"
import "core:sync"
import "core:text/edit"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
sentence_selection :: proc(t: ^testing.T) {
	for tc in ([]struct { text, click, want: string }{
		{"First sentence. Another sentence! Last one?", "Another", "Another sentence!"},
		{"First sentence. Another sentence!", "sentence.", "First sentence."},
		{"A long sentence that wraps across several visual rows. Next.", "visual", "A long sentence that wraps across several visual rows."},
		{"Price is 3.14. Next.", "14", "Price is 3.14."},
		{"See https://example.com/a?q=yes. Next.", "example", "See https://example.com/a?q=yes."},
		{"He said “Hello!” Next.", "Hello", "He said “Hello!”"},
		{"Really?! Yes... Done.", "Really", "Really?!"},
		{"Really?! Yes... Done.", "Yes", "Yes..."},
		{"最初です。次の文です！最後。", "次", "次の文です！"},
		{"Hi 👩🏽‍💻! Café é.", "👩", "Hi 👩🏽‍💻!"},
		{"First line\nSecond line", "Second", "Second line"},
		{"First. Last without punctuation", "Last", "Last without punctuation"},
		{"  Last sentence.  ", "", "Last sentence."},
		{"", "", ""},
		{"   ", "", ""},
	}) {
		at := tc.click == "" ? len(tc.text) : strings.index(tc.text, tc.click)
		lo, hi := sentence_bounds(tc.text, at)
		testing.expect_value(t, tc.text[lo:hi], tc.want)
		testing.expect_value(t, rune_snap(tc.text, lo), lo)
		testing.expect_value(t, rune_snap(tc.text, hi), hi)
	}
}

@(test)
wrapped_caret_motion :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous := clay.GetCurrentContext()
	defer clay.SetCurrentContext(previous)
	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	clay.Initialize(clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)), {600, 200}, {})
	rl.SetPixelScale(1)
	defer wrap_clear()
	ui: Ui_State
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	defer delete(ui.compose)
	for unit in ([]string{"a", "é", "é", "日"}) {
		text := strings.repeat(unit, 200, context.temp_allocator)
		ed_set(&ui, &ui.compose, text)
		ed_begin(&ui, &ui.compose)
		lines := compose_lines(text)
		testing.expect(t, len(lines) >= 3)
		from := lines[1][0] + 5 * len(unit)
		ui.ed.selection = {from, from}
		set_lines(&ui.ed, true)
		edit.perform_command(&ui.ed, .Select_Up)
		testing.expect_value(t, ui.ed.selection, [2]int{5 * len(unit), from})
		set_lines(&ui.ed, true)
		edit.perform_command(&ui.ed, .Down)
		testing.expect_value(t, ui.ed.selection, [2]int{from, from})
		ui.ed.selection = {lines[1][1], lines[1][1]}
		set_lines(&ui.ed, true)
		testing.expect_value(t, ui.ed.line_start, 0)
		testing.expect_value(t, ui.ed.up_index, lines[0][1])
		ed_end(&ui, &ui.compose)
	}
	ed_set(&ui, &ui.compose, "abc\n\nabc")
	ed_begin(&ui, &ui.compose)
	ui.ed.selection = {6, 6}
	set_lines(&ui.ed, true)
	testing.expect_value(t, ui.ed.up_index, 4)
	ui.ed.selection = {0, 0}
	set_lines(&ui.ed, true)
	testing.expect_value(t, ui.ed.up_index, 0)
	set_lines(&ui.ed, false)
	testing.expect_value(t, ui.ed.line_end, len(ui.compose))
	testing.expect_value(t, ui.ed.down_index, 0)
	ed_end(&ui, &ui.compose)
}

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
