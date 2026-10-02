package main

import "core:fmt"
import "core:testing"

@(test)
test_qr_version_for :: proc(t: ^testing.T) {
	// Byte-mode capacities include the wider count field at version 10.
	testing.expect_value(t, qr_version_for(17), 1)
	testing.expect_value(t, qr_version_for(18), 2)
	testing.expect_value(t, qr_version_for(106), 5)
	testing.expect_value(t, qr_version_for(107), 6)
	testing.expect_value(t, qr_version_for(230), 9)
	testing.expect_value(t, qr_version_for(231), 10)
	testing.expect_value(t, qr_version_for(2953), 40)
	testing.expect_value(t, qr_version_for(2954), 0)
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

// A scanner deinterleaves each block before Reed-Solomon correction.
@(test)
test_qr_multiblock :: proc(t: ^testing.T) {
	for fixture in ([4][3]int{{6, 2, 120}, {10, 4, 260}, {15, 6, 500}, {40, 25, 2953}}) {
		version, blocks, count := fixture[0], fixture[1], fixture[2]
		payload := make([]u8, count, context.temp_allocator)
		for &b, i in payload {b = u8(i % 251)}
		cw := qr_codewords(payload, version, context.temp_allocator)
		ecc := qr_ecc_cw(version)
		data_len := len(cw) - blocks * ecc
		short_len := data_len / blocks
		short_blocks := blocks - len(cw) % blocks
		data := make([]u8, data_len, context.temp_allocator)
		offset := 0
		for block in 0 ..< blocks {
			block_len := short_len + (block >= short_blocks ? 1 : 0)
			decoded := make([]u8, block_len + ecc, context.temp_allocator)
			for i in 0 ..< block_len {
				column :=
					i < short_len ? i * blocks + block : short_len * blocks + block - short_blocks
				decoded[i] = cw[column]
			}
			copy(data[offset:], decoded[:block_len])
			offset += block_len
			for i in 0 ..< ecc {decoded[block_len + i] = cw[data_len + i * blocks + block]}
			for s in 0 ..< ecc {
				acc: u8
				for b in decoded {acc = qr_gf_mul(acc, qr_gf_pow(s)) ~ b}
				if acc !=
				   0 {testing.fail_now(t, fmt.tprintf("version %d block %d syndrome %d = %d", version, block, s, acc))}
			}
		}
		count_bits := version < 10 ? 8 : 16
		read_bits :: proc(data: []u8, at, count: int) -> int {
			value := 0
			for i in at ..< at + count {value = value << 1 | int(data[i / 8] >> uint(7 - i % 8) & 1)}
			return value
		}
		testing.expect_value(t, read_bits(data, 0, 4), 4)
		testing.expect_value(t, read_bits(data, 4, count_bits), count)
		for b, i in payload {testing.expect_value(t, read_bits(data, 4 + count_bits + i * 8, 8), int(b))}
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
