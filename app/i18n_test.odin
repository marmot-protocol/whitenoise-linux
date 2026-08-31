// The .po reader: multiline strings, escapes, fuzzy + plural skip.
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:testing"

@(test)
po_reader :: proc(t: ^testing.T) {
	src := `msgid ""
msgstr ""
"Project-Id-Version: wnl-ui\n"

msgctxt "some context"
msgid "Launch at login"
msgstr "Avvio automatico"

msgid "Line "
"one\n"
"and \"two\""
msgstr "Riga "
"uno\n"
"e \"due\""

#, fuzzy
msgid "Fuzzy one"
msgstr "Sfocata"

msgid "%n chats"
msgid_plural "%n chats plural"
msgstr[0] "%n chat"
msgstr[1] "%n chat"

msgid "Untranslated"
msgstr ""

msgid "Last"
msgstr "Ultima"`

	out: map[string]string
	defer {
		for id, str in out {
			delete(id)
			delete(str)
		}
		delete(out)
	}
	po_parse(src, &out)

	testing.expect_value(t, len(out), 3)
	testing.expect_value(t, out["Launch at login"], "Avvio automatico")
	testing.expect_value(t, out["Line one\nand \"two\""], "Riga uno\ne \"due\"")
	testing.expect_value(t, out["Last"], "Ultima")
	_, fuzzy := out["Fuzzy one"]
	testing.expect(t, !fuzzy, "fuzzy entry must be dropped")
	_, header := out[""]
	testing.expect(t, !header, "header entry must be dropped")
}

// The embedded catalogs themselves parse and carry the strings the
// Odin UI looks up.
@(test)
po_catalogs :: proc(t: ^testing.T) {
	for pair in CATALOGS {
		out: map[string]string
		defer {
			for id, str in out {
				delete(id)
				delete(str)
			}
			delete(out)
		}
		po_parse(pair[1], &out)
		// Confirmed translations only: po_parse drops fuzzy and empty
		// entries, so this sits well under the catalog's msgid count
		// while the port's reworded strings wait on a translator.
		testing.expect(t, len(out) > 150, "catalog too small")
		_, ok := out["Launch at login"]
		testing.expect(t, ok, "missing a settings msgid")
	}
}
