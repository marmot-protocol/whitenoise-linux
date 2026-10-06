// scrypt (RFC 7914), only the r=8, p=1 subset the backup container
// uses. Odin core has PBKDF2 but no scrypt, so PBKDF2-HMAC-SHA256 +
// ROMix over Salsa20/8 lives here.
package main

import "core:crypto/hash"
import "core:crypto/pbkdf2"

@(private = "file")
salsa20_8 :: proc(b: ^[16]u32) {
	x := b^
	for _ in 0 ..< 4 {
		// Column round.
		x[4] ~= rotl(x[0] + x[12], 7); x[8] ~= rotl(x[4] + x[0], 9)
		x[12] ~= rotl(x[8] + x[4], 13); x[0] ~= rotl(x[12] + x[8], 18)
		x[9] ~= rotl(x[5] + x[1], 7); x[13] ~= rotl(x[9] + x[5], 9)
		x[1] ~= rotl(x[13] + x[9], 13); x[5] ~= rotl(x[1] + x[13], 18)
		x[14] ~= rotl(x[10] + x[6], 7); x[2] ~= rotl(x[14] + x[10], 9)
		x[6] ~= rotl(x[2] + x[14], 13); x[10] ~= rotl(x[6] + x[2], 18)
		x[3] ~= rotl(x[15] + x[11], 7); x[7] ~= rotl(x[3] + x[15], 9)
		x[11] ~= rotl(x[7] + x[3], 13); x[15] ~= rotl(x[11] + x[7], 18)
		// Row round.
		x[1] ~= rotl(x[0] + x[3], 7); x[2] ~= rotl(x[1] + x[0], 9)
		x[3] ~= rotl(x[2] + x[1], 13); x[0] ~= rotl(x[3] + x[2], 18)
		x[6] ~= rotl(x[5] + x[4], 7); x[7] ~= rotl(x[6] + x[5], 9)
		x[4] ~= rotl(x[7] + x[6], 13); x[5] ~= rotl(x[4] + x[7], 18)
		x[11] ~= rotl(x[10] + x[9], 7); x[8] ~= rotl(x[11] + x[10], 9)
		x[9] ~= rotl(x[8] + x[11], 13); x[10] ~= rotl(x[9] + x[8], 18)
		x[12] ~= rotl(x[15] + x[14], 7); x[13] ~= rotl(x[12] + x[15], 9)
		x[14] ~= rotl(x[13] + x[12], 13); x[15] ~= rotl(x[14] + x[13], 18)
	}
	for i in 0 ..< 16 {
		b[i] += x[i]
	}
}

@(private = "file")
rotl :: #force_inline proc(v: u32, n: uint) -> u32 {
	return v << n | v >> (32 - n)
}

// BlockMix for r=8: B is 16 64-byte sub-blocks viewed as [16][16]u32.
@(private = "file")
block_mix :: proc(b: ^[256]u32, out: ^[256]u32) {
	x: [16]u32
	copy(x[:], b[240:256])
	for i in 0 ..< 16 {
		for j in 0 ..< 16 {
			x[j] ~= b[i * 16 + j]
		}
		salsa20_8(&x)
		// Even sub-blocks to the front half, odd to the back.
		dst := i % 2 == 0 ? i / 2 : 8 + i / 2
		copy(out[dst * 16:dst * 16 + 16], x[:])
	}
}

// r=8, p=1 scrypt: 128*r = 1024-byte working block, N = 1 << log_n.
scrypt_r8p1 :: proc(password: []u8, salt: []u8, log_n: uint, dst: []u8) {
	n := uint(1) << log_n

	block: [256]u32 // 1024 bytes as u32 little-endian
	raw := make([]u8, 1024, context.temp_allocator)
	pbkdf2.derive(hash.Algorithm.SHA256, password, salt, 1, raw)
	for i in 0 ..< 256 {
		block[i] =
			u32(raw[i * 4]) |
			u32(raw[i * 4 + 1]) << 8 |
			u32(raw[i * 4 + 2]) << 16 |
			u32(raw[i * 4 + 3]) << 24
	}

	v := make([][256]u32, n)
	defer delete(v)
	tmp: [256]u32
	for i in 0 ..< n {
		v[i] = block
		block_mix(&v[i], &tmp)
		block = tmp
	}
	for _ in 0 ..< n {
		j := uint(u64(block[240]) | u64(block[241]) << 32) & (n - 1)
		for k in 0 ..< 256 {
			block[k] ~= v[j][k]
		}
		block_mix(&block, &tmp)
		block = tmp
	}

	for i in 0 ..< 256 {
		raw[i * 4] = u8(block[i])
		raw[i * 4 + 1] = u8(block[i] >> 8)
		raw[i * 4 + 2] = u8(block[i] >> 16)
		raw[i * 4 + 3] = u8(block[i] >> 24)
	}
	pbkdf2.derive(hash.Algorithm.SHA256, password, raw, 1, dst)
}
