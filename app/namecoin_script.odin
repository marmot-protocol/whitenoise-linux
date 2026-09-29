// Namecoin OP_NAME_UPDATE script assembly and OP_NAME_* vout parsing.
//
// ElectrumX indexes Namecoin names by the scripthash of a canonical
// OP_NAME_UPDATE-shaped script over the name bytes; the resolver hashes
// that here to derive the key it sends to `blockchain.scripthash.get_history`.
// Once history comes back, the same shim decodes the p2 OP_NAME_UPDATE or
// OP_NAME_FIRSTUPDATE vout the transaction carries and pulls the raw name
// value JSON out. Both layouts share the OP_NAME_NEW envelope; only
// FIRSTUPDATE wedges a 20-byte HASH160 commitment between the name and
// the value push.
//
// Matches the shape used by the applesauce, gitworkshop, and Amethyst
// ports of this same layout so a value payload produced against any of
// them roundtrips through this parser.
package main

import "core:crypto/hash"

// Namecoin script opcodes used by the name-index script.
@(private = "file")
NC_OP_NAME_NEW: u8 : 0x51
@(private = "file")
NC_OP_NAME_FIRSTUPDATE: u8 : 0x52
@(private = "file")
NC_OP_NAME_UPDATE: u8 : 0x53
@(private = "file")
NC_OP_2DROP: u8 : 0x6d
@(private = "file")
NC_OP_DROP: u8 : 0x75
@(private = "file")
NC_OP_RETURN: u8 : 0x6a
@(private = "file")
NC_OP_PUSHDATA1: u8 : 0x4c
@(private = "file")
NC_OP_PUSHDATA2: u8 : 0x4d
@(private = "file")
NC_OP_PUSHDATA4: u8 : 0x4e

// HASH160 commitment length in an OP_NAME_FIRSTUPDATE vout, per namecore
// consensus rules.
@(private = "file")
NC_FIRSTUPDATE_RAND_LEN :: 20

// Build the OP_NAME_UPDATE name-index script for `name` bytes:
//   OP_NAME_UPDATE <push(name)> <push(empty)> OP_2DROP OP_DROP OP_RETURN
// Owned by the caller.
nc_build_name_index_script :: proc(name: []u8, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, allocator = allocator)
	append(&out, NC_OP_NAME_UPDATE)
	nc_push_data(&out, name)
	nc_push_data(&out, nil)
	append(&out, NC_OP_2DROP, NC_OP_DROP, NC_OP_RETURN)
	return out[:]
}

@(private = "file")
nc_push_data :: proc(out: ^[dynamic]u8, data: []u8) {
	n := len(data)
	switch {
	case n < int(NC_OP_PUSHDATA1):
		append(out, u8(n))
	case n <= 0xff:
		append(out, NC_OP_PUSHDATA1, u8(n))
	case n <= 0xffff:
		append(out, NC_OP_PUSHDATA2, u8(n & 0xff), u8((n >> 8) & 0xff))
	case:
		append(
			out,
			NC_OP_PUSHDATA4,
			u8(n & 0xff),
			u8((n >> 8) & 0xff),
			u8((n >> 16) & 0xff),
			u8((n >> 24) & 0xff),
		)
	}
	for b in data {
		append(out, b)
	}
}

// Encode `bytes` as lowercase hex, temp-allocated.
@(private = "file")
nc_bytes_to_hex :: proc(bytes: []u8, allocator := context.temp_allocator) -> string {
	hex_chars := "0123456789abcdef"
	out := make([]u8, len(bytes) * 2, allocator)
	for b, i in bytes {
		out[i * 2] = hex_chars[b >> 4]
		out[i * 2 + 1] = hex_chars[b & 0x0f]
	}
	return string(out)
}

// ElectrumX scripthash: SHA-256 of the script, byte-reversed, lowercase
// hex. Every ElectrumX server keys `blockchain.scripthash.get_history`
// by this exact digest.
nc_electrum_scripthash :: proc(script: []u8, allocator := context.temp_allocator) -> string {
	digest: [32]u8
	hash.hash(.SHA256, script, digest[:])
	reversed: [32]u8
	for i in 0 ..< 32 {
		reversed[i] = digest[31 - i]
	}
	return nc_bytes_to_hex(reversed[:], allocator)
}

// Read one push from `script` at `pos`; returns the pushed bytes plus
// the position just past it. `ok=false` for a malformed / truncated push.
@(private = "file")
nc_read_push :: proc(script: []u8, pos: int) -> (data: []u8, next: int, ok: bool) {
	if pos >= len(script) {
		return
	}
	op := script[pos]
	if op == 0x00 {
		return script[pos:pos], pos + 1, true
	}
	if op < NC_OP_PUSHDATA1 {
		length := int(op)
		end := pos + 1 + length
		if end > len(script) {
			return
		}
		return script[pos + 1:end], end, true
	}
	if op == NC_OP_PUSHDATA1 {
		if pos + 2 > len(script) {
			return
		}
		length := int(script[pos + 1])
		end := pos + 2 + length
		if end > len(script) {
			return
		}
		return script[pos + 2:end], end, true
	}
	if op == NC_OP_PUSHDATA2 {
		if pos + 3 > len(script) {
			return
		}
		length := int(script[pos + 1]) | (int(script[pos + 2]) << 8)
		end := pos + 3 + length
		if end > len(script) {
			return
		}
		return script[pos + 3:end], end, true
	}
	if op == NC_OP_PUSHDATA4 {
		if pos + 5 > len(script) {
			return
		}
		length :=
			int(script[pos + 1]) |
			(int(script[pos + 2]) << 8) |
			(int(script[pos + 3]) << 16) |
			(int(script[pos + 4]) << 24)
		end := pos + 5 + length
		if end < 0 || end > len(script) {
			return
		}
		return script[pos + 5:end], end, true
	}
	return
}

// Decode one Namecoin name-op vout into its `(name, value)` pair.
// Accepts both value-carrying layouts:
//
//   OP_NAME_FIRSTUPDATE <name> <rand> <value> OP_2DROP OP_2DROP OP_DROP <p2pkh>
//   OP_NAME_UPDATE      <name> <value>        OP_2DROP OP_DROP        <p2pkh>
//
// OP_NAME_NEW carries no value here; returns "", "", false for it.
nc_parse_name_script :: proc(script: []u8) -> (name: string, value: string, ok: bool) {
	if len(script) == 0 {
		return
	}
	op := script[0]
	if op != NC_OP_NAME_UPDATE && op != NC_OP_NAME_FIRSTUPDATE {
		return
	}
	name_bytes, pos, name_ok := nc_read_push(script, 1)
	if !name_ok {
		return
	}
	if op == NC_OP_NAME_FIRSTUPDATE {
		rand_bytes, next, rand_ok := nc_read_push(script, pos)
		if !rand_ok || len(rand_bytes) != NC_FIRSTUPDATE_RAND_LEN {
			return
		}
		pos = next
	}
	value_bytes, _, value_ok := nc_read_push(script, pos)
	if !value_ok {
		return
	}
	return string(name_bytes), string(value_bytes), true
}

// Decode one lower-case hex string into bytes; nil on any malformed
// nibble. Temp-allocated.
nc_hex_decode :: proc(s: string, allocator := context.temp_allocator) -> []u8 {
	if len(s) % 2 != 0 {
		return nil
	}
	out := make([]u8, len(s) / 2, allocator)
	for i in 0 ..< len(out) {
		hi := nc_hex_nibble(s[i * 2])
		lo := nc_hex_nibble(s[i * 2 + 1])
		if hi < 0 || lo < 0 {
			return nil
		}
		out[i] = u8((hi << 4) | lo)
	}
	return out
}

@(private = "file")
nc_hex_nibble :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a') + 10
	case 'A' ..= 'F':
		return int(c - 'A') + 10
	}
	return -1
}

// Walk `vouts` (each a hex-encoded scriptPubKey) and return the raw name
// value string for the vout that carries `name`. "" when no vout matches.
nc_extract_name_value :: proc(vouts: []string, name: string) -> string {
	for hex_script in vouts {
		if len(hex_script) < 2 {
			continue
		}
		// Cheap front-door: only 0x52 / 0x53 opcodes carry a value.
		if !(hex_script[0] == '5' && (hex_script[1] == '2' || hex_script[1] == '3')) {
			continue
		}
		bytes := nc_hex_decode(hex_script)
		if bytes == nil {
			continue
		}
		got_name, got_value, ok := nc_parse_name_script(bytes)
		if !ok {
			continue
		}
		if got_name == name {
			return got_value
		}
	}
	return ""
}
