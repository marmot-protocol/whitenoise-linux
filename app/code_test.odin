// Highlighter checks: the tokenizer decides colors for every source
// preview, and a run that swallows the rest of a line (an unclosed
// string, a stuck block comment) is the failure that shows.
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:strings"
import "core:testing"

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
	testing.expect(t, !is_code_name("notes.txt"))
	testing.expect(t, !is_code_name("photo.png"))

	view := code_view_make("photo.png", "not source")
	testing.expect(t, view == nil)
}
