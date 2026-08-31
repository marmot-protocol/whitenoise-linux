// Global-search matcher checks.
// Run: ODIN_ROOT=build/odin-root odin test app
package main

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
