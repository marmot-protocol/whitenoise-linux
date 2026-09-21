// Highlighter checks: the tokenizer decides colors for every source
// preview, and a run that swallows the rest of a line (an unclosed
// string, a stuck block comment) is the failure that shows.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:strings"
import "core:sync"
import "core:testing"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Concatenating the runs must reproduce the line exactly, or the view
// silently drops source.
@(private = "file")
joined :: proc(view: ^Code_View, line: int) -> string {
	out := strings.builder_make(context.temp_allocator)
	for run in view.lines[line].runs {
		strings.write_string(&out, run.text)
	}
	return strings.to_string(out)
}

@(private = "file")
kind_of :: proc(view: ^Code_View, line: int, text: string) -> Code_Kind {
	for run in view.lines[line].runs {
		if run.text == text {
			return run.kind
		}
	}
	return .Plain
}

@(test)
code_tokenizes_c_like :: proc(t: ^testing.T) {
	src := "int x = 42; // trailing\nchar *s = \"hi // not a comment\";\nnope();\n"
	view := code_view_make("demo.c", src)
	testing.expect(t, view != nil)
	if view == nil {
		return
	}
	defer code_view_free(view)

	testing.expect_value(t, len(view.lines), 3)
	testing.expect_value(t, joined(view, 0), "int x = 42; // trailing")
	testing.expect_value(t, kind_of(view, 0, "int"), Code_Kind.Keyword)
	testing.expect_value(t, kind_of(view, 0, "42"), Code_Kind.Number)
	testing.expect_value(t, kind_of(view, 0, "// trailing"), Code_Kind.Comment)
	// A comment token inside a string stays part of the string.
	testing.expect_value(t, kind_of(view, 1, "\"hi // not a comment\""), Code_Kind.Str)
	testing.expect_value(t, joined(view, 2), "nope();")
}

// A block comment spans lines, and the line after the closer must go
// back to normal coloring.
@(test)
code_block_comment_spans :: proc(t: ^testing.T) {
	src := "a = 1;\n/* one\ntwo */ b = 2;\nc = 3;\n"
	view := code_view_make("demo.rs", src)
	testing.expect(t, view != nil)
	if view == nil {
		return
	}
	defer code_view_free(view)

	testing.expect_value(t, len(view.lines), 4)
	testing.expect_value(t, kind_of(view, 2, "2"), Code_Kind.Number)
	testing.expect_value(t, joined(view, 3), "c = 3;")
	for line in 0 ..< len(view.lines) {
		testing.expect(t, len(view.lines[line].runs) > 0 || len(joined(view, line)) == 0)
	}
}

// An unterminated string must end at the line, not eat the file.
@(test)
code_unterminated_string :: proc(t: ^testing.T) {
	src := "s = \"oops\nnext = 1\n"
	view := code_view_make("demo.py", src)
	testing.expect(t, view != nil)
	if view == nil {
		return
	}
	defer code_view_free(view)

	testing.expect_value(t, len(view.lines), 2)
	testing.expect_value(t, joined(view, 1), "next = 1")
	testing.expect_value(t, kind_of(view, 1, "1"), Code_Kind.Number)
}

// Only known extensions highlight; everything else keeps the plain
// text path (or the hex fallback).
@(test)
code_extension_gate :: proc(t: ^testing.T) {
	testing.expect(t, is_code_name("main.odin"))
	testing.expect(t, is_code_name("build.sh"))
	testing.expect(t, is_code_name("config.toml"))
	testing.expect(t, is_code_name("notes.txt"))
	testing.expect(t, !is_code_name("photo.png"))

	view := code_view_make("photo.png", "not source")
	testing.expect(t, view == nil)
}

@(test)
text_attachment_layout :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	when #config(ODIN_TEST_NAMES, "") == "text_attachment_layout" {
		rl.InitWindow(800, 800, "Text attachments")
		load_themes()
		apply_theme(0, 0)
		init_fonts()
	}
	defer {
		when #config(ODIN_TEST_NAMES, "") == "text_attachment_layout" {rl.CloseWindow()}
	}
	src := "type: logcat\r\n\r\n  # not a heading\r\n09-11 14:46:31 4853 I focus=true\r\n"
	for name in ([]string{"logcat.txt", "debug.LOG"}) {
		testing.expect_value(t, media_kind(name, "text/plain"), Media_Kind.Code)
		view := code_view_make(name, src)
		testing.expect(t, view != nil)
		if view == nil {return}
		testing.expect_value(t, len(view.lines), 4)
		testing.expect_value(t, joined(view, 1), "")
		testing.expect_value(t, joined(view, 2), "  # not a heading")
		testing.expect_value(t, joined(view, 3), "09-11 14:46:31 4853 I focus=true")
		for line in view.lines {
			testing.expect_value(t, len(line.runs), 1)
			testing.expect_value(t, line.runs[0].kind, Code_Kind.Plain)
		}
		code_view_free(view)
	}
	testing.expect_value(t, media_kind("notes.md", "text/plain"), Media_Kind.Text)

	// A single enormous paragraph must not escape the attachment plate.
	long := strings.repeat("09-11 14:46:31 I viewroot_draw_event: window=MainActivity ", 1000)
	defer delete(long)
	code := code_view_make("logcat.txt", strings.concatenate({src, long}, context.temp_allocator))
	defer code_view_free(code)
	markdown := txt_view_make(long)
	defer txt_view_free(markdown)
	msg := Msg_Ui {
		sender = strings.clone("Max"),
	}
	defer message_free(msg)
	append(&msg.att_names, strings.clone("logcat.txt"), strings.clone("notes.md"))
	append(&msg.codes, Att_Item(^Code_View){code, 0})
	append(&msg.txts, Att_Item(^Txt_View){markdown, 1})
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 800})
	defer {
		clay.SetCurrentContext(previous)
		delete(memory)
		wrap_clear()
	}
	rl.SetPixelScale(1)
	clay.BeginLayout()
	message_row(0, msg)
	commands := clay.EndLayout(0)
	for id, i in ([]clay.ElementId{clay.ID("MsgCode", 0), clay.ID("MsgTxt", 0)}) {
		box := clay.GetElementData(id).boundingBox
		testing.expect_value(t, box.width, i == 0 ? f32(480) : f32(320))
		testing.expect(t, box.height <= 320)
		testing.expect(t, clay.GetScrollContainerData(id).found)
	}
	plate := clay.GetElementData(clay.ID("MsgTxt", 0)).boundingBox
	for command in commands.internalArray[:commands.length] {
		if command.commandType == .Text && command.boundingBox.y >= plate.y {
			testing.expect(
				t,
				command.boundingBox.x + command.boundingBox.width <= plate.x + plate.width,
			)
		}
	}
	when #config(ODIN_TEST_NAMES, "") == "text_attachment_layout" {
		rl.BeginDrawing()
		draw_frame(&commands)
		rl.TakeScreenshot("/tmp/text-attachments.png")
		rl.EndDrawing()
	}
}
