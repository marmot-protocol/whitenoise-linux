// Openverse response-parse checks.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:testing"

@(test)
ov_parse_results :: proc(t: ^testing.T) {
	body := `{"result_count":2,"results":[
		{"title":"a","url":"https://x/a.jpg","thumbnail":"https://x/a_t.jpg"},
		{"title":"no thumb","url":"https://x/b.jpg","thumbnail":""},
		{"title":"no url","thumbnail":"https://x/c_t.jpg"}
	]}`
	hits, fail := ov_parse(transmute([]u8)body)
	testing.expect_value(t, len(hits), 1)
	testing.expect_value(t, hits[0].full, "https://x/a.jpg")
	testing.expect_value(t, hits[0].thumb, "https://x/a_t.jpg")
	testing.expect_value(t, fail, "")
}

@(test)
ov_parse_garbage :: proc(t: ^testing.T) {
	_, fail := ov_parse(transmute([]u8)string("not json"))
	testing.expect(t, len(fail) > 0)
}

@(test)
ov_parse_empty :: proc(t: ^testing.T) {
	hits, fail := ov_parse(transmute([]u8)string(`{"results":[]}`))
	testing.expect_value(t, len(hits), 0)
	testing.expect_value(t, fail, "No results. Try another search.")
}
