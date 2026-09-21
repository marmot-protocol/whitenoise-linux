package main

import "core:testing"

// A relay on both of the contact's lists is one row, and only the ones
// you publish to count as shared.
@(test)
test_merge_relays :: proc(t: ^testing.T) {
	out := make([dynamic]Contact_Relay, context.temp_allocator)
	// merge_relays clones each url; production frees them when the
	// selection changes (read_contact_relays).
	defer for r in out {
		delete(r.url)
	}
	mutual := merge_relays(
		{"wss://a.example", "wss://both.example"},
		{"wss://both.example", "wss://inbox.example"},
		{"wss://both.example", "wss://mine-only.example"},
		&out,
	)

	testing.expect_value(t, len(out), 3)
	testing.expect_value(t, mutual, 1)

	testing.expect_value(t, out[0].url, "wss://a.example")
	testing.expect_value(t, out[0].mutual, false)
	// Seen on their NIP-65 list first, so it is not labelled inbox.
	testing.expect_value(t, out[1].url, "wss://both.example")
	testing.expect_value(t, out[1].mutual, true)
	testing.expect_value(t, out[1].inbox, false)
	testing.expect_value(t, out[2].url, "wss://inbox.example")
	testing.expect_value(t, out[2].inbox, true)
}

// A contact who has published nothing yields no rows, which is what
// sends the pane to the relays for a fetch.
@(test)
test_merge_relays_empty :: proc(t: ^testing.T) {
	out := make([dynamic]Contact_Relay, context.temp_allocator)
	testing.expect_value(t, merge_relays({}, {}, {"wss://mine.example"}, &out), 0)
	testing.expect_value(t, len(out), 0)
}
