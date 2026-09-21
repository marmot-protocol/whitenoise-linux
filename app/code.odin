// Source-code previews: one small tokenizer that colors comments,
// strings, numbers, and keywords, rendered as monospace lines with a
// line-number gutter.
//
//   code_view_make → per-line runs, tokenized once at open
//   code_lines     → the clay rows, shared by the tile and the modal
//
// ponytail: one keyword set for every language, plus per-family
// comment and string rules. A real per-language grammar is the
// upgrade; this reads correctly for the file kinds people actually
// send each other, and misses only exotic keywords.
package main

import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"

// Colors come from the active theme's own tokens, so a light or retro
// pack stays readable without new pack fields.
Code_Kind :: enum u8 {
	Plain,
	Comment,
	Str,
	Number,
	Keyword,
}

CODE_MAX_LINES :: 4000 // parse cap; a generated file can be enormous
CODE_TILE_LINES :: 14 // rows on a timeline tile
// ponytail: 1000 rows keeps the modal under clay's element budget
// (32k) with room for the rest of the frame; virtualized rows are the
// upgrade if whole generated files need to scroll.
CODE_MODAL_LINES :: 1000 // rows in the preview modal (it scrolls)

// One colored span of a line; text borrows from the view's source.
Code_Run :: struct {
	text: string,
	kind: Code_Kind,
}

Code_Line :: struct {
	runs: []Code_Run,
}

Code_View :: struct {
	src:   string, // owned
	lines: []Code_Line,
	lang:  string, // label shown in the modal header
}

// Comment and string rules per family. The keyword set is shared.
@(private = "file")
Code_Lang :: struct {
	label: string,
	exts:  []string,
	line:  string, // line-comment token
	open:  string, // block-comment open, "" when the family has none
	close: string,
}

@(private = "file")
CODE_LANGS := []Code_Lang {
	{"Text", {".txt", ".log"}, "", "", ""},
	{"Odin", {".odin"}, "//", "/*", "*/"},
	{
		"C-like",
		{
			".c",
			".h",
			".cc",
			".cpp",
			".hpp",
			".cs",
			".java",
			".go",
			".rs",
			".js",
			".mjs",
			".ts",
			".tsx",
			".jsx",
			".swift",
			".kt",
			".zig",
			".glsl",
			".php",
			".scala",
			".dart",
		},
		"//",
		"/*",
		"*/",
	},
	{"Python", {".py", ".pyw"}, "#", `"""`, `"""`},
	{"Shell", {".sh", ".bash", ".zsh", ".fish", ".nu"}, "#", "", ""},
	{"Config", {".toml", ".ini", ".conf", ".cfg", ".yaml", ".yml"}, "#", "", ""},
	{"Ruby", {".rb"}, "#", "=begin", "=end"},
	{"Lua", {".lua"}, "--", "--[[", "]]"},
	{"SQL", {".sql"}, "--", "/*", "*/"},
	{"Lisp", {".el", ".lisp", ".clj", ".scm"}, ";", "", ""},
}

// Union of the common keywords across those families: a word only
// colors when it stands alone, so a stray match inside another
// language is rare and harmless.
@(private = "file")
CODE_KEYWORDS := []string {
	"as",
	"assert",
	"async",
	"await",
	"bool",
	"break",
	"case",
	"catch",
	"char",
	"class",
	"const",
	"constexpr",
	"continue",
	"def",
	"default",
	"defer",
	"delete",
	"do",
	"double",
	"elif",
	"else",
	"end",
	"enum",
	"except",
	"extern",
	"false",
	"final",
	"finally",
	"float",
	"fn",
	"for",
	"foreach",
	"from",
	"func",
	"function",
	"global",
	"go",
	"goto",
	"if",
	"impl",
	"import",
	"in",
	"int",
	"interface",
	"is",
	"lambda",
	"let",
	"local",
	"loop",
	"match",
	"mod",
	"module",
	"mut",
	"namespace",
	"new",
	"nil",
	"none",
	"not",
	"null",
	"or",
	"package",
	"pass",
	"private",
	"proc",
	"protected",
	"public",
	"raise",
	"range",
	"record",
	"ref",
	"require",
	"return",
	"select",
	"self",
	"static",
	"struct",
	"switch",
	"template",
	"then",
	"this",
	"throw",
	"trait",
	"true",
	"try",
	"type",
	"typedef",
	"union",
	"unsafe",
	"use",
	"using",
	"var",
	"void",
	"when",
	"where",
	"while",
	"with",
	"yield",
}

// Line-oriented previews. Only Markdown uses the block renderer.
is_code_name :: proc(lower: string) -> bool {
	return code_lang_for(lower) != nil
}

@(private = "file")
code_lang_for :: proc(lower: string) -> ^Code_Lang {
	for &lang in CODE_LANGS {
		for ext in lang.exts {
			if strings.has_suffix(lower, ext) {
				return &lang
			}
		}
	}
	return nil
}

// Tokenize once at open. The source is copied, so callers keep
// ownership of the bytes they passed in.
code_view_make :: proc(name: string, text: string) -> ^Code_View {
	lower := strings.to_lower(name, context.temp_allocator)
	lang := code_lang_for(lower)
	if lang == nil {
		return nil
	}

	view := new(Code_View)
	// The mono faces have no tab glyph (it draws as tofu), so tabs
	// become spaces up front; runs then borrow from the expanded copy.
	expanded, allocated := strings.replace_all(text, "\t", "    ")
	view^ = {
		src  = allocated ? expanded : strings.clone(text),
		lang = lang.label,
	}

	lines := make([dynamic]Code_Line)
	rest := view.src
	in_block := false
	for line in strings.split_lines_iterator(&rest) {
		append(&lines, Code_Line{code_runs(line, lang, &in_block)})
		if len(lines) >= CODE_MAX_LINES {
			break
		}
	}
	view.lines = lines[:]
	return view
}

// One line to colored runs. `in_block` carries block-comment state
// across lines, which is why lines are tokenized in file order.
@(private = "file")
code_runs :: proc(line: string, lang: ^Code_Lang, in_block: ^bool) -> []Code_Run {
	runs := make([dynamic]Code_Run)
	if lang.line == "" {
		append(&runs, Code_Run{line, .Plain})
		return runs[:]
	}
	i := 0
	plain_start := 0

	flush :: proc(runs: ^[dynamic]Code_Run, line: string, from, to: int) {
		if to > from {
			append(runs, Code_Run{line[from:to], .Plain})
		}
	}
	emit :: proc(runs: ^[dynamic]Code_Run, text: string, kind: Code_Kind) {
		if len(text) > 0 {
			append(runs, Code_Run{text, kind})
		}
	}

	for i < len(line) {
		if in_block^ {
			// Inside a block comment: everything up to the closer.
			if end := strings.index(line[i:], lang.close); end >= 0 {
				emit(&runs, line[i:i + end + len(lang.close)], .Comment)
				i += end + len(lang.close)
				in_block^ = false
				plain_start = i
				continue
			}
			emit(&runs, line[i:], .Comment)
			return runs[:]
		}

		rest := line[i:]
		switch {
		case len(lang.line) > 0 && strings.has_prefix(rest, lang.line):
			flush(&runs, line, plain_start, i)
			emit(&runs, rest, .Comment)
			return runs[:]

		case len(lang.open) > 0 && strings.has_prefix(rest, lang.open):
			flush(&runs, line, plain_start, i)
			in_block^ = true
			i += len(lang.open)
			plain_start = i

		case rest[0] == '"' || rest[0] == '\'' || rest[0] == '`':
			flush(&runs, line, plain_start, i)
			length := string_len(rest)
			emit(&runs, rest[:length], .Str)
			i += length
			plain_start = i

		case is_digit(rest[0]) && (i == 0 || !is_word(line[i - 1])):
			flush(&runs, line, plain_start, i)
			length := 0
			for length < len(rest) && (is_word(rest[length]) || rest[length] == '.') {
				length += 1
			}
			emit(&runs, rest[:length], .Number)
			i += length
			plain_start = i

		case is_word(rest[0]) && (i == 0 || !is_word(line[i - 1])):
			length := 0
			for length < len(rest) && is_word(rest[length]) {
				length += 1
			}
			word := rest[:length]
			if is_keyword(word) {
				flush(&runs, line, plain_start, i)
				emit(&runs, word, .Keyword)
				plain_start = i + length
			}
			i += length

		case:
			i += 1
		}
	}

	flush(&runs, line, plain_start, len(line))
	return runs[:]
}

// Length of the quoted literal starting at text[0], including both
// quotes; an unterminated literal runs to the end of the line.
@(private = "file")
string_len :: proc(text: string) -> int {
	quote := text[0]
	i := 1
	for i < len(text) {
		if text[i] == '\\' {
			i += 2
			continue
		}
		if text[i] == quote {
			return i + 1
		}
		i += 1
	}
	return len(text)
}

@(private = "file")
is_word :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || is_digit(c)
}

@(private = "file")
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
is_keyword :: proc(word: string) -> bool {
	for keyword in CODE_KEYWORDS {
		if word == keyword {
			return true
		}
	}
	return false
}

code_view_free :: proc(view: ^Code_View) {
	for line in view.lines {
		delete(line.runs)
	}
	delete(view.lines)
	delete(view.src)
	free(view)
}

// Reuse the attachment tokenizer without retaining another copy of the source.
@(private)
md_code_kinds :: proc(info, text: string) -> string {
	name := strings.to_lower(strings.trim_space(info), context.temp_allocator)
	if end := strings.index_any(name, " \t"); end >= 0 {name = name[:end]}
	for alias in ([][2]string{{"python", "py"}, {"javascript", "js"}, {"typescript", "ts"}, {"rust", "rs"}, {"shell", "sh"}, {"bash", "sh"}, {"json", "js"}, {"c++", "cpp"}}) {
		if name == alias[0] {name = alias[1]; break}
	}
	lang := code_lang_for(fmt.tprintf(".%s", name))
	if lang == nil {return ""}
	kinds := make([]u8, len(text))
	in_block := false
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		runs := code_runs(line, lang, &in_block)
		for run in runs {
			start := int(uintptr(raw_data(run.text)) - uintptr(raw_data(text)))
			for &kind in kinds[start:start + len(run.text)] {kind = u8(run.kind)}
		}
		delete(runs)
	}
	return string(kinds)
}

@(private)
md_code_text :: proc(text, kinds: string, size: u16, fonts: string = "") {
	for at := 0; at < len(text); {
		kind := len(kinds) > 0 ? Code_Kind(kinds[at]) : Code_Kind.Plain
		end := at + 1
		for end < len(text) &&
		    (len(kinds) == 0 || kinds[end] == kinds[at]) &&
		    (len(fonts) == 0 || fonts[end] == fonts[at]) {end += 1}
		clay.Text(
			text[at:end],
			{
				fontId = FONT_MONO,
				fontSize = size,
				textColor = code_color(kind),
				wrapMode = .None,
				userData = rawptr(
					uintptr(len(fonts) > 0 ? fonts[at] & (TEXT_ADDED | TEXT_REMOVED) : 0),
				),
			},
		)
		at = end
	}
}

// ── Render ──────────────────────────────────────────────────────────

@(private = "file")
code_color :: proc(kind: Code_Kind) -> clay.Color {
	switch kind {
	case .Comment:
		return TEXT_LO
	case .Str:
		return ACCENT_DIM
	case .Number:
		return TEXT_DIM
	case .Keyword:
		return ACCENT
	case .Plain:
		return TEXT
	}
	return TEXT
}

// Numbered monospace lines. Runs word-wrap inside their own box, so a
// long comment or literal folds under its own start instead of running
// past the tile; the gutter never wraps.
// ponytail: a line whose runs overflow *together* still clips (clay
// rows don't wrap children); a run/line reflow model is the upgrade.
code_lines :: proc(view: ^Code_View, id_seed: u32, limit: int) {
	shown := min(len(view.lines), limit)
	for line, i in view.lines[:shown] {
		if clay.UI(clay.ID("CodeLine", id_seed + u32(i)))(
		{layout = {sizing = {width = clay.SizingGrow()}}},
		) {
			clay.Text(
				fmt.tprintf("%4d ", i + 1),
				{fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO, wrapMode = .None},
			)
			for run in line.runs {
				clay.Text(
					run.text,
					{fontId = FONT_MONO, fontSize = 11, textColor = code_color(run.kind)},
				)
			}
		}
	}
	if len(view.lines) > shown {
		clay.Text(
			fmt.tprintf("and %d more lines", len(view.lines) - shown),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
		)
	}
}
