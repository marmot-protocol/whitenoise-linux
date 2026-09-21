package main

import "core:testing"

@(test)
gh_ref_scan :: proc(t: ^testing.T) {
	ref, ok := gh_ref("https://github.com/marmot-protocol/mdk/pull/42")
	testing.expect(t, ok)
	testing.expect_value(t, ref.owner, "marmot-protocol")
	testing.expect_value(t, ref.repo, "mdk")
	testing.expect_value(t, ref.num, "42")
	testing.expect(t, ref.pull)
	testing.expect_value(t, gh_key(ref), "marmot-protocol/mdk/pulls/42")

	iss, ok2 := gh_ref("https://github.com/a/b/issues/7#issuecomment-9")
	testing.expect(t, ok2)
	testing.expect(t, !iss.pull)
	testing.expect_value(t, iss.num, "7")

	_, ok3 := gh_ref("https://github.com/a/b")
	testing.expect(t, !ok3)
	_, ok4 := gh_ref("https://github.com/a/b/pull/head")
	testing.expect(t, !ok4)
	_, ok5 := gh_ref("https://gitlab.com/a/b/pull/1")
	testing.expect(t, !ok5)
}

@(test)
gh_parse_fields :: proc(t: ^testing.T) {
	merged := gh_parse(
		transmute([]u8)string(
			`{"title":"Fix it","state":"closed","merged_at":"2026-01-02T03:04:05Z","draft":false,"user":{"login":"dannym"}}`,
		),
	)
	testing.expect_value(t, merged.title, "Fix it")
	testing.expect_value(t, merged.state, "merged")
	testing.expect_value(t, merged.author, "dannym")

	draft := gh_parse(
		transmute([]u8)string(`{"title":"WIP","state":"open","merged_at":null,"draft":true}`),
	)
	testing.expect_value(t, draft.state, "draft")
	testing.expect_value(t, draft.author, "")

	// A 404 body has no title, so the card keeps its reference fallback.
	miss := gh_parse(transmute([]u8)string(`{"message":"Not Found"}`))
	testing.expect_value(t, miss.title, "")
}
