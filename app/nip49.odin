// NIP-49 private-key encryption (ncryptsec) plus the bech32 codec it
// needs. Odin core has XChaCha20-Poly1305 and PBKDF2 but no scrypt,
// so scrypt (PBKDF2-HMAC-SHA256 + ROMix over Salsa20/8) lives here.
//
//   nsec1... ──bech32──► 32-byte key ──XChaCha20-Poly1305──► payload
//                              ▲                               │
//        password ──scrypt─────┘            ncryptsec1... ◄────┘
package main

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/hash"
import "core:crypto/pbkdf2"
import "core:fmt"
import "core:strings"

// ── bech32 ──────────────────────────────────────────────────────────

BECH32_CHARSET := "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

@(private = "file")
bech32_polymod :: proc(values: []u8) -> u32 {
	GEN := [5]u32{0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3}
	chk: u32 = 1
	for v in values {
		b := chk >> 25
		chk = (chk & 0x1ffffff) << 5 ~ u32(v)
		for i in 0 ..< 5 {
			if (b >> u32(i)) & 1 == 1 {
				chk ~= GEN[i]
			}
		}
	}
	return chk
}

@(private = "file")
bech32_hrp_expand :: proc(hrp: string, out: ^[dynamic]u8) {
	for c in hrp {
		append(out, u8(c) >> 5)
	}
	append(out, 0)
	for c in hrp {
		append(out, u8(c) & 31)
	}
}

// 8-bit → 5-bit regroup (pad = true for encode).
@(private = "file")
convert_bits :: proc(data: []u8, from, to: uint, pad: bool, allocator := context.temp_allocator) -> ([]u8, bool) {
	out := make([dynamic]u8, allocator)
	acc: u32
	bits: uint
	max_v := u32(1 << to) - 1
	for b in data {
		acc = acc << from | u32(b)
		bits += from
		for bits >= to {
			bits -= to
			append(&out, u8((acc >> bits) & max_v))
		}
	}
	if pad {
		if bits > 0 {
			append(&out, u8((acc << (to - bits)) & max_v))
		}
	} else if bits >= from || (acc << (to - bits)) & max_v != 0 {
		return nil, false
	}
	return out[:], true
}

bech32_encode :: proc(hrp: string, data: []u8) -> string {
	five, _ := convert_bits(data, 8, 5, true)
	values := make([dynamic]u8, context.temp_allocator)
	bech32_hrp_expand(hrp, &values)
	append(&values, ..five)
	for _ in 0 ..< 6 {
		append(&values, 0)
	}
	polymod := bech32_polymod(values[:]) ~ 1

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, hrp)
	strings.write_byte(&sb, '1')
	for v in five {
		strings.write_byte(&sb, BECH32_CHARSET[v])
	}
	for i in 0 ..< 6 {
		strings.write_byte(&sb, BECH32_CHARSET[(polymod >> uint(5 * (5 - i))) & 31])
	}
	return strings.clone(strings.to_string(sb))
}

// Returns (hrp, payload bytes, ok). Checksum is verified.
bech32_decode :: proc(s: string, allocator := context.temp_allocator) -> (string, []u8, bool) {
	lower := strings.to_lower(s, context.temp_allocator)
	if s != lower && s != strings.to_upper(s, context.temp_allocator) { return "", nil, false }
	sep := strings.last_index_byte(lower, '1')
	if sep < 1 || sep + 7 > len(lower) {
		return "", nil, false
	}
	hrp := lower[:sep]

	five := make([dynamic]u8, context.temp_allocator)
	for c in lower[sep + 1:] {
		idx := strings.index_byte(BECH32_CHARSET, u8(c))
		if idx < 0 {
			return "", nil, false
		}
		append(&five, u8(idx))
	}

	values := make([dynamic]u8, context.temp_allocator)
	bech32_hrp_expand(hrp, &values)
	append(&values, ..five[:])
	if bech32_polymod(values[:]) != 1 {
		return "", nil, false
	}

	data, ok := convert_bits(five[:len(five) - 6], 5, 8, false, allocator)
	return hrp, data, ok
}

// ── scrypt (RFC 7914, the subset NIP-49 needs: r=8, p=1) ────────────

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
		block[i] = u32(raw[i * 4]) | u32(raw[i * 4 + 1]) << 8 | u32(raw[i * 4 + 2]) << 16 | u32(raw[i * 4 + 3]) << 24
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

// ── NIP-49 ──────────────────────────────────────────────────────────

NIP49_LOG_N :: 16
NIP49_VERSION :: 0x02
NIP49_SECURITY_UNKNOWN :: 0x02

// Encrypt an "nsec1..." key under a password; "" on any failure.
// ponytail: password is used as typed (no NFKC normalization).
nip49_encrypt :: proc(nsec: string, password: string) -> string {
	hrp, key, ok := bech32_decode(nsec)
	if !ok || hrp != "nsec" || len(key) != 32 {
		return ""
	}

	salt: [16]u8
	nonce: [24]u8
	crypto.rand_bytes(salt[:])
	crypto.rand_bytes(nonce[:])

	sym: [32]u8
	scrypt_r8p1(transmute([]u8)password, salt[:], NIP49_LOG_N, sym[:])

	ad := [1]u8{NIP49_SECURITY_UNKNOWN}
	ciphertext: [32]u8
	tag: [16]u8
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, sym[:])
	chacha20poly1305.seal(&ctx, ciphertext[:], tag[:], nonce[:], ad[:], key)

	payload: [91]u8
	payload[0] = NIP49_VERSION
	payload[1] = NIP49_LOG_N
	copy(payload[2:18], salt[:])
	copy(payload[18:42], nonce[:])
	payload[42] = ad[0]
	copy(payload[43:75], ciphertext[:])
	copy(payload[75:91], tag[:])
	return bech32_encode("ncryptsec", payload[:])
}

// Decrypt back to the 32-byte key hex; "" on wrong password/format.
// Used by the self-check below (an import flow can reuse it).
nip49_decrypt :: proc(ncryptsec: string, password: string) -> string {
	hrp, payload, ok := bech32_decode(ncryptsec)
	if !ok || hrp != "ncryptsec" || len(payload) != 91 || payload[0] != NIP49_VERSION {
		return ""
	}

	sym: [32]u8
	scrypt_r8p1(transmute([]u8)password, payload[2:18], uint(payload[1]), sym[:])

	key: [32]u8
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, sym[:])
	if !chacha20poly1305.open(&ctx, key[:], payload[18:42], payload[42:43], payload[43:75], payload[75:91]) {
		return ""
	}

	sb := strings.builder_make(context.temp_allocator)
	for b in key {
		fmt.sbprintf(&sb, "%02x", b)
	}
	return strings.clone(strings.to_string(sb))
}
