// Interface-language lookup: the gettext catalogs the slint app
// maintains in lang/ (msgids are the English source strings),
// embedded at build time and parsed into one msgid → msgstr map on
// boot and on locale switch. No plural or msgctxt support; entries
// needing either fall back to English.
package main

import "core:strings"

// en is the msgid source, so it needs no catalog.
CATALOGS := [][2]string{
	{"it", #load("../lang/it/LC_MESSAGES/wnl-ui.po", string)},
	{"de", #load("../lang/de/LC_MESSAGES/wnl-ui.po", string)},
	{"ja", #load("../lang/ja/LC_MESSAGES/wnl-ui.po", string)},
}

@(private = "file")
g_tr: map[string]string

// English msgid → translation. A missing entry falls back to the
// English string, which also covers Odin-only strings the slint
// catalogs never saw.
tr :: proc(s: string) -> string {
	if out, ok := g_tr[s]; ok {
		return out
	}
	return s
}

// gettext's noop marker. Identity at runtime; it exists so
// scripts/update-translations.sh can extract a string whose tr() runs
// somewhere else, which is every string held in a package-level table
// or returned from a copy proc. Mark at the literal, translate at the
// point of use.
N_ :: proc "contextless" (s: string) -> string {
	return s
}

set_locale :: proc(code: string) {
	for id, str in g_tr {
		delete(id)
		delete(str)
	}
	clear(&g_tr)
	for pair in CATALOGS {
		if pair[0] == code {
			po_parse(pair[1], &g_tr)
			return
		}
	}
}

@(private = "file")
Po_Mode :: enum {
	None, // between entries, or a part tr ignores (msgctxt, plurals)
	Id,
	Str,
}

// Append one quoted .po payload ("..." with \n \t \" \\ escapes) to
// the builder. Continuation lines concatenate by calling this again.
po_unquote :: proc(l: string, b: ^strings.Builder) {
	first := strings.index_byte(l, '"')
	last := strings.last_index_byte(l, '"')
	if first < 0 || last <= first {
		return
	}
	s := l[first + 1:last]
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 'n':
				strings.write_byte(b, '\n')
			case 't':
				strings.write_byte(b, '\t')
			case:
				strings.write_byte(b, s[i]) // \" and \\
			}
			continue
		}
		strings.write_byte(b, c)
	}
}

// Line-by-line .po walk. An entry commits when the next `msgid` (or
// EOF) arrives; fuzzy entries, plural entries, and empty msgstrs are
// dropped so tr falls back to English for them.
po_parse :: proc(src: string, out: ^map[string]string) {
	id := strings.builder_make(context.temp_allocator)
	str := strings.builder_make(context.temp_allocator)
	mode := Po_Mode.None
	fuzzy := false // seen in the comment block above the next msgid
	entry_fuzzy := false
	plural := false

	commit :: proc(out: ^map[string]string, id, str: ^strings.Builder, drop: bool) {
		i := strings.to_string(id^)
		s := strings.to_string(str^)
		// First entry wins on duplicate msgids (msgctxt variants);
		// re-inserting would leak the cloned key.
		if !drop && len(i) > 0 && len(s) > 0 && !(i in out) {
			out[strings.clone(i)] = strings.clone(s)
		}
		strings.builder_reset(id)
		strings.builder_reset(str)
	}

	it := src
	for line in strings.split_lines_iterator(&it) {
		l := strings.trim_space(line)
		switch {
		case strings.has_prefix(l, "#,"):
			fuzzy = fuzzy || strings.contains(l, "fuzzy")
		case strings.has_prefix(l, "#"):
		// other comments
		case strings.has_prefix(l, "msgctxt"):
			mode = .None
		case strings.has_prefix(l, "msgid_plural"):
			plural = true
			mode = .None
		case strings.has_prefix(l, "msgid"):
			commit(out, &id, &str, entry_fuzzy || plural)
			entry_fuzzy = fuzzy
			fuzzy = false
			plural = false
			mode = .Id
			po_unquote(l, &id)
		case strings.has_prefix(l, "msgstr["):
			mode = .None // plural form, dropped via the plural flag
		case strings.has_prefix(l, "msgstr"):
			mode = .Str
			po_unquote(l, &str)
		case strings.has_prefix(l, "\""):
			#partial switch mode {
			case .Id:
				po_unquote(l, &id)
			case .Str:
				po_unquote(l, &str)
			}
		}
	}
	commit(out, &id, &str, entry_fuzzy || plural)
}
