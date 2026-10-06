// bech32 codec (BIP-173) for the NIP-19 entities: npub, nsec, note,
// nevent, nprofile, naddr.
package main

import "core:strings"

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
convert_bits :: proc(
	data: []u8,
	from, to: uint,
	pad: bool,
	allocator := context.temp_allocator,
) -> (
	[]u8,
	bool,
) {
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
	if s != lower && s != strings.to_upper(s, context.temp_allocator) {return "", nil, false}
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
