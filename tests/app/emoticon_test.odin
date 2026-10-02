// Composer emoticon swap: only a whole whitespace-delimited token ending
// at the caret converts, and Ctrl+Z restores the typed text.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:testing"
import "core:text/edit"

@(test)
emoticon_tokens :: proc(t: ^testing.T) {
	ui: Ui_State
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	defer delete(ui.compose)

	for tc in ([]struct {
			text:  string,
			caret: int,
			want:  string,
		}{{":)", -1, "🙂"}, {"hi :-)", -1, "hi 🙂"}, {"ok\n<3", -1, "ok\n❤️"}, {"x :D y", 4, "x 😃 y"}, {"C:D", -1, "C:D"}, {"hi :)x", -1, "hi :)x"}, {":d", -1, ":d"}, {"http://", -1, "http://"}}) {
		ed_set(&ui, &ui.compose, tc.text)
		ed_begin(&ui, &ui.compose)
		if tc.caret >= 0 {
			ui.ed.selection = {tc.caret, tc.caret}
		}
		emoticon_swap(&ui.ed)
		ed_end(&ui, &ui.compose)
		testing.expect_value(t, string(ui.compose[:]), tc.want)
	}
}

@(test)
emoticon_undo :: proc(t: ^testing.T) {
	ui: Ui_State
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	defer delete(ui.compose)

	ed_set(&ui, &ui.compose, "hi :)")
	ed_begin(&ui, &ui.compose)
	emoticon_swap(&ui.ed)
	edit.input_rune(&ui.ed, ' ')
	testing.expect_value(t, string(ui.ed.builder.buf[:]), "hi 🙂 ")
	edit.perform_command(&ui.ed, .Undo)
	ed_end(&ui, &ui.compose)
	testing.expect_value(t, string(ui.compose[:]), "hi :)")
}
