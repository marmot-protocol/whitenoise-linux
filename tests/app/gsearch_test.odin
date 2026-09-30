// Global-search matcher checks.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:strings"
import "core:testing"

@(test)
gs_fold_latin1 :: proc(t: ^testing.T) {
	testing.expect_value(t, gs_fold("Café Über"), "cafe uber")
	testing.expect_value(t, gs_fold("naïve"), "naive")
	testing.expect_value(t, gs_fold("寝る"), "寝る") // non-latin passes through
}

@(test)
gs_subseq_match :: proc(t: ^testing.T) {
	testing.expect(t, gs_subseq("white noise linux", "wnl"))
	testing.expect(t, !gs_subseq("white noise", "wnl"))
	testing.expect(t, gs_subseq("anything", ""))
}

@(test)
gs_snippet_window :: proc(t: ^testing.T) {
	s := gs_snippet("one\ntwo", 0)
	defer delete(s)
	testing.expect_value(t, s, "one two") // newline flattened
}

// A mention renders as a chip only while its token is whole, so the
// window never cuts one and charges it a single rune.
@(test)
gs_snippet_keeps_mentions :: proc(t: ^testing.T) {
	NPUB :: "@npub1ven4zk8xxw873876gx8y9g9l9fazkye9qnwnglcptgvfwxmygscqsxddfh"
	pad := strings.repeat("a", 100, context.temp_allocator)

	// Token starts 3 runes before the 90-rune cut.
	head := pad[:86]
	s := gs_snippet(strings.concatenate({head, " ", NPUB, " tail"}, context.temp_allocator), 0)
	defer delete(s)
	testing.expect_value(
		t,
		s,
		strings.concatenate({head, " ", NPUB, " t\u2026"}, context.temp_allocator),
	)

	// Window start lands inside the token: it is kept whole.
	u := gs_snippet(strings.concatenate({NPUB, " ", pad}, context.temp_allocator), 30)
	defer delete(u)
	testing.expect_value(
		t,
		u,
		strings.concatenate({"\u2026", NPUB, " ", pad[:88], "\u2026"}, context.temp_allocator),
	)
}
