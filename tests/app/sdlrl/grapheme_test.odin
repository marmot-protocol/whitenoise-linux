package sdlrl

import "core:testing"
import "core:unicode/utf8"

// A ZWJ sequence on a non-pictographic base must stay one cluster, or
// its tile is never looked up. A trailing ZWJ has nothing to absorb.
@(test)
test_grapheme_zwj_join :: proc(t: ^testing.T) {
	cases := []struct {
		text: string,
		want: []string,
	} {
		{"a\u2B21\uFE0F\u200D\U0001F7E7b", {"a", "\u2B21\uFE0F\u200D\U0001F7E7", "b"}},
		{"\U0001FBC7\u200D\U0001F457\U0001F600", {"\U0001FBC7\u200D\U0001F457", "\U0001F600"}},
		{"x\u2B21\u200D", {"x", "\u2B21\u200D"}},
	}
	for c in cases {
		it := utf8.decode_grapheme_iterator_make(c.text)
		got: [dynamic]string
		defer delete(got)
		for cluster, grapheme in grapheme_iterate(&it) {
			testing.expect_value(t, grapheme.text, cluster)
			append(&got, cluster)
		}
		testing.expectf(t, len(got) == len(c.want), "%q: got %q", c.text, got[:])
		for cluster, i in got {
			if i < len(c.want) {
				testing.expect_value(t, cluster, c.want[i])
			}
		}
	}
}
