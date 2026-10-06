// Checks for the grapheme boundary helpers behind Backspace/Delete and
// caret motion (core:text/edit's own grapheme mode subtracts monospace
// cell widths and corrupts wide chars, so these are computed locally).
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:text/edit"
import rl "sdlrl"

@(test)
sentence_selection :: proc(t: ^testing.T) {
	for tc in ([]struct {
			text, click, want: string,
		}{{"First sentence. Another sentence! Last one?", "Another", "Another sentence!"}, {"First sentence. Another sentence!", "sentence.", "First sentence."}, {"A long sentence that wraps across several visual rows. Next.", "visual", "A long sentence that wraps across several visual rows."}, {"Price is 3.14. Next.", "14", "Price is 3.14."}, {"See https://example.com/a?q=yes. Next.", "example", "See https://example.com/a?q=yes."}, {"He said “Hello!” Next.", "Hello", "He said “Hello!”"}, {"Really?! Yes... Done.", "Really", "Really?!"}, {"Really?! Yes... Done.", "Yes", "Yes..."}, {"最初です。次の文です！最後。", "次", "次の文です！"}, {"Hi 👩🏽‍💻! Café é.", "👩", "Hi 👩🏽‍💻!"}, {"First line\nSecond line", "Second", "Second line"}, {"First. Last without punctuation", "Last", "Last without punctuation"}, {"  Last sentence.  ", "", "Last sentence."}, {"", "", ""}, {"   ", "", ""}}) {
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
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)),
		{600, 200},
		{},
	)
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

// A composer mention chip is one caret unit: steps and clicks land on
// its edges, never inside the token it draws over.
@(test)
composer_mention_steps :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	rl.SetPixelScale(1)
	npub := hex_npub("66675158e6338fe89fda418e42a0bf2a7a2b132504dd347f015a18971b644430")
	defer delete(npub)
	text := fmt.tprintf("hi @%s ok", npub)
	start, end := 3, 4 + len(npub)

	testing.expect_value(t, compose_prev(text, end), start)
	testing.expect_value(t, compose_next(text, start), end)
	testing.expect_value(t, compose_prev(text, start), start - 1)
	testing.expect_value(t, compose_next(text, end), end + 1)

	lead: f32
	for r in "hi " {lead += rl.MeasureTextLine(FONT_BODY, BODY_FS, fmt.tprint(r), 0).x}
	atom_end, width := compose_atom(text, start)
	testing.expect_value(t, atom_end, end)
	testing.expect_value(t, hit_compose_line(text, lead + width * 0.25), start)
	testing.expect_value(t, hit_compose_line(text, lead + width * 0.75), end)

	// A token broken by typing stays plain text, stepped per grapheme.
	broken := fmt.tprintf("hi @%sx", npub)
	testing.expect_value(t, compose_prev(broken, len(broken)), len(broken) - 1)
}
