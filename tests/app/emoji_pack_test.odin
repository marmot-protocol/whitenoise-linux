package main

import "core:testing"

@(test)
test_emoji_pack_bounds :: proc(t: ^testing.T) {
	data := make([]u8, 8 + 2 * EMOJI_RECORD_BYTES)
	defer delete(data)
	copy(data[:4], "WNE1")
	data[4] = 2
	data[8] = 1
	testing.expect(t, emoji_pack_valid(data, 2))
	testing.expect(t, !emoji_pack_valid(data, 1), "catalog and pack must agree")
	for end in ([]int{0, 4, 7, 8, 8 + EMOJI_RECORD_BYTES, len(data) - 1}) {
		testing.expect(t, !emoji_pack_valid(data[:end], 2), "truncated pixels must not reach SDL")
	}
	data[8 + EMOJI_RECORD_BYTES] = 2
	testing.expect(t, !emoji_pack_valid(data, 2), "unknown availability flag")
	data[8 + EMOJI_RECORD_BYTES] = 0
	data[0] = 'X'
	testing.expect(t, !emoji_pack_valid(data, 2), "unknown format")
	data[0] = 'W'
	data[7] = 255
	testing.expect(t, !emoji_pack_valid(data, 2), "oversized record count")
}
