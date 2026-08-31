package main

import "core:fmt"
import "core:testing"

@(test)
test_qr_version_for :: proc(t: ^testing.T) {
	// Version boundaries: data codewords minus the two-codeword header.
	testing.expect_value(t, qr_version_for(17), 1)
	testing.expect_value(t, qr_version_for(18), 2)
	testing.expect_value(t, qr_version_for(106), 5)
	testing.expect_value(t, qr_version_for(107), 0)
}

// A Reed-Solomon codeword is a polynomial with a^0 .. a^(ecc-1) as roots,
// so every syndrome must come out zero. This fails on any slip in the
// generator, the division, or the bit packing that feeds them.
@(test)
test_qr_syndromes :: proc(t: ^testing.T) {
	payload := "marmot://profile/npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqp7fdmr?from=qr"
	version := qr_version_for(len(payload))
	testing.expect(t, version > 0, "the profile link must fit")

	cw := qr_codewords(transmute([]u8)payload, version, context.temp_allocator)
	testing.expect_value(t, cw[0], u8(0x40 | len(payload) >> 4)) // mode + count high nibble

	for s in 0 ..< qr_ecc_cw(version) {
		acc: u8
		for b in cw {
			acc = qr_gf_mul(acc, qr_gf_pow(s)) ~ b
		}
		if acc != 0 {
			testing.fail_now(t, fmt.tprintf("syndrome %d = %d", s, acc))
		}
	}
}

// Function patterns land where a decoder looks for them.
@(test)
test_qr_matrix :: proc(t: ^testing.T) {
	mods, size, ok := qr_encode("marmot://profile/npub1test?from=qr", context.temp_allocator)
	testing.expect(t, ok, "short link encodes")
	testing.expect_value(t, size, qr_size(qr_version_for(34)))

	at :: proc(mods: []u8, size, x, y: int) -> u8 {return mods[y * size + x]}
	for corner in ([3][2]int{{0, 0}, {size - 7, 0}, {0, size - 7}}) {
		ox, oy := corner[0], corner[1]
		testing.expect_value(t, at(mods, size, ox, oy), u8(1)) // finder ring
		testing.expect_value(t, at(mods, size, ox + 1, oy + 1), u8(0)) // light ring
		testing.expect_value(t, at(mods, size, ox + 3, oy + 3), u8(1)) // dark core
	}

	// Timing pair alternates between the finders.
	for i in 8 ..< size - 8 {
		testing.expect_value(t, at(mods, size, i, 6), u8(i % 2 == 0 ? 1 : 0))
		testing.expect_value(t, at(mods, size, 6, i), u8(i % 2 == 0 ? 1 : 0))
	}

	testing.expect_value(t, at(mods, size, 8, size - 8), u8(1)) // always-dark module
}
