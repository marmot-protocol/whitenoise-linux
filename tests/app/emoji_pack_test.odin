package main

import "core:testing"

@(test)
test_emoji_pack_bounds :: proc(t: ^testing.T) {
	data := make([]u8, 8 + 2 * EMOJI_RECORD_BYTES)
	defer delete(data)
	copy(data[:4], "WNE1")
	data[4] = 2
	flags := []u8{1, 0}
	testing.expect(t, emoji_pack_valid(data, flags))
	testing.expect(t, !emoji_pack_valid(data, flags[:1]), "catalog and pack must agree")
	for end in ([]int{0, 4, 7, 8, 8 + EMOJI_RECORD_BYTES, len(data) - 1}) {
		testing.expect(
			t,
			!emoji_pack_valid(data[:end], flags),
			"truncated pixels must not reach SDL",
		)
	}
	flags[1] = 2
	testing.expect(t, !emoji_pack_valid(data, flags), "unknown availability flag")
	flags[1] = 0
	data[0] = 'X'
	testing.expect(t, !emoji_pack_valid(data, flags), "unknown format")
	data[0] = 'W'
	data[7] = 255
	testing.expect(t, !emoji_pack_valid(data, flags), "oversized record count")
}
