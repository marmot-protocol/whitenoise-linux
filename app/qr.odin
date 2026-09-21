// QR encoder for the contact and profile deep links, so the app owns
// the pixels instead of shelling out to the system qrencode binary.
//
// Byte mode, ECC level L. The matrix is built the usual way:
//
//   ███████ · ·  ███████    finder + separator in three corners
//   █     █ · ·  █     █    timing pair along row 6 and column 6
//   █ ███ █      █ ███ █    one alignment pattern (version >= 2)
//   ███████ ·    ███████    format bits ring the top-left finder
//   ·                       data snakes up and down in two-column
//   ███████     ▟▙          strips from the right edge, skipping
//   █     █      ▘          every module the patterns reserved
//
// ponytail: versions 1-5 only. They are exactly the versions with a
// single Reed-Solomon block, which is what keeps the interleaving and
// the per-version block tables out of here. Payload ceiling is 106
// bytes; the profile link is 88. Longer text needs the v6+ tables.
package main

import rl "sdlrl"

QR_MAX_VERSION :: 5

// Total and error-correction codewords per version at ECC level L;
// the data codewords are the difference.
@(private = "file")
QR_TOTAL_CW := [QR_MAX_VERSION + 1]int{0, 26, 44, 70, 100, 134}
@(private = "file")
QR_ECC_CW := [QR_MAX_VERSION + 1]int{0, 7, 10, 15, 20, 26}

// Mode nibble plus the 8-bit character count, in codewords: the fixed
// overhead every byte-mode payload pays.
@(private = "file")
QR_HEADER_CW :: 2

// ── GF(256), the Reed-Solomon field ─────────────────────────────────

@(private = "file")
gf_exp: [512]u8
@(private = "file")
gf_log: [256]u8

@(init)
qr_gf_init :: proc "contextless" () {
	x := 1
	for i in 0 ..< 255 {
		gf_exp[i] = u8(x)
		gf_log[x] = u8(i)
		x <<= 1
		if x & 0x100 != 0 {
			x ~= 0x11D // the QR primitive polynomial
		}
	}
	// Doubled so a log sum never needs a modulo.
	for i in 255 ..< 512 {
		gf_exp[i] = gf_exp[i - 255]
	}
}

qr_gf_mul :: proc(a, b: u8) -> u8 {
	if a == 0 || b == 0 {
		return 0
	}
	return gf_exp[int(gf_log[a]) + int(gf_log[b])]
}

qr_gf_pow :: proc(i: int) -> u8 {
	return gf_exp[i % 255]
}

// Remainder of `data` divided by the degree-`ecc_len` generator
// polynomial: the error-correction codewords, high order first.
@(private = "file")
qr_rs :: proc(data: []u8, ecc_len: int) -> []u8 {
	// Generator: the product of (x - a^i), leading coefficient implied.
	gen := make([]u8, ecc_len, context.temp_allocator)
	gen[ecc_len - 1] = 1
	root: u8 = 1
	for _ in 0 ..< ecc_len {
		for j in 0 ..< ecc_len {
			gen[j] = qr_gf_mul(gen[j], root)
			if j + 1 < ecc_len {
				gen[j] ~= gen[j + 1]
			}
		}
		root = qr_gf_mul(root, 2)
	}

	rem := make([]u8, ecc_len, context.temp_allocator)
	for b in data {
		factor := b ~ rem[0]
		copy(rem, rem[1:])
		rem[ecc_len - 1] = 0
		for j in 0 ..< ecc_len {
			rem[j] ~= qr_gf_mul(gen[j], factor)
		}
	}
	return rem
}

// ── Codewords ───────────────────────────────────────────────────────

qr_ecc_cw :: proc(version: int) -> int {
	return QR_ECC_CW[version]
}

// Smallest version that holds `n` payload bytes, 0 when none does.
qr_version_for :: proc(n: int) -> int {
	for v in 1 ..= QR_MAX_VERSION {
		if n + QR_HEADER_CW <= QR_TOTAL_CW[v] - QR_ECC_CW[v] {
			return v
		}
	}
	return 0
}

@(private = "file")
qr_put :: proc(out: []u8, at: ^int, value: int, n: int) {
	for i := n - 1; i >= 0; i -= 1 {
		if value & (1 << uint(i)) != 0 {
			out[at^ / 8] |= 1 << uint(7 - at^ % 8)
		}
		at^ += 1
	}
}

// Data codewords (mode, length, payload, padding) followed by the
// error-correction block.
qr_codewords :: proc(payload: []u8, version: int, allocator := context.allocator) -> []u8 {
	data_len := QR_TOTAL_CW[version] - QR_ECC_CW[version]
	out := make([]u8, QR_TOTAL_CW[version], allocator)

	at := 0
	qr_put(out, &at, 0b0100, 4) // byte mode
	qr_put(out, &at, len(payload), 8)
	for b in payload {
		qr_put(out, &at, int(b), 8)
	}

	// The terminator and the byte alignment are already there: the
	// buffer is zeroed. The rest takes the spec's alternating pad.
	pad := [2]u8{0xEC, 0x11}
	first := (at + 7) / 8
	for i in first ..< data_len {
		out[i] = pad[(i - first) % 2]
	}

	copy(out[data_len:], qr_rs(out[:data_len], QR_ECC_CW[version]))
	return out
}

// ── Matrix ──────────────────────────────────────────────────────────

qr_size :: proc(version: int) -> int {
	return 17 + 4 * version
}

@(private = "file")
Grid :: struct {
	mods: []u8, // 1 = dark
	res:  []bool, // reserved by a function pattern
	size: int,
}

@(private = "file")
gset :: proc(g: ^Grid, x, y: int, dark: bool) {
	g.mods[y * g.size + x] = dark ? 1 : 0
	g.res[y * g.size + x] = true
}

// 7x7 finder plus its light separator, anchored at the top-left of the
// finder itself. Cells outside the matrix are skipped.
@(private = "file")
qr_finder :: proc(g: ^Grid, ox, oy: int) {
	for dy in -1 ..= 7 {
		for dx in -1 ..= 7 {
			x, y := ox + dx, oy + dy
			if x < 0 || y < 0 || x >= g.size || y >= g.size {
				continue
			}
			inside := dx >= 0 && dx <= 6 && dy >= 0 && dy <= 6
			d := max(abs(dx - 3), abs(dy - 3)) // Chebyshev from the center
			gset(g, x, y, inside && (d == 3 || d <= 1))
		}
	}
}

// The reserved format-information ring, drawn later by qr_format.
@(private = "file")
qr_reserve_format :: proc(g: ^Grid) {
	for i in 0 ..= 8 {
		g.res[8 * g.size + i] = true
		g.res[i * g.size + 8] = true
	}
	for i in 0 ..< 8 {
		g.res[8 * g.size + (g.size - 1 - i)] = true
		g.res[(g.size - 1 - i) * g.size + 8] = true
	}
}

@(private = "file")
qr_format :: proc(g: ^Grid, mask: int) {
	// 5 data bits (ECC level L = 01, then the mask) plus a 10-bit BCH
	// remainder, the whole thing XORed with the spec's 0x5412.
	data := 0b01 << 3 | mask
	rem := data
	for _ in 0 ..< 10 {
		rem = (rem << 1) ~ ((rem >> 9) * 0x537)
	}
	bits := ((data << 10) | rem) ~ 0x5412

	bit :: proc(bits, i: int) -> bool {return bits >> uint(i) & 1 != 0}
	set :: proc(g: ^Grid, x, y: int, dark: bool) {g.mods[y * g.size + x] = dark ? 1 : 0}

	// Copy one, wrapped around the top-left finder.
	for i in 0 ..= 5 {
		set(g, 8, i, bit(bits, i))
	}
	set(g, 8, 7, bit(bits, 6))
	set(g, 8, 8, bit(bits, 7))
	set(g, 7, 8, bit(bits, 8))
	for i in 9 ..= 14 {
		set(g, 14 - i, 8, bit(bits, i))
	}

	// Copy two, split between the other two finders.
	for i in 0 ..= 7 {
		set(g, g.size - 1 - i, 8, bit(bits, i))
	}
	for i in 8 ..= 14 {
		set(g, 8, g.size - 15 + i, bit(bits, i))
	}
	set(g, 8, g.size - 8, true) // the always-dark module
}

@(private = "file")
qr_mask_bit :: proc(mask, x, y: int) -> bool {
	switch mask {
	case 0:
		return (x + y) % 2 == 0
	case 1:
		return y % 2 == 0
	case 2:
		return x % 3 == 0
	case 3:
		return (x + y) % 3 == 0
	case 4:
		return (y / 2 + x / 3) % 2 == 0
	case 5:
		return x * y % 2 + x * y % 3 == 0
	case 6:
		return (x * y % 2 + x * y % 3) % 2 == 0
	case:
		return ((x + y) % 2 + x * y % 3) % 2 == 0
	}
}

@(private = "file")
qr_apply_mask :: proc(g: ^Grid, mask: int) {
	for y in 0 ..< g.size {
		for x in 0 ..< g.size {
			if g.res[y * g.size + x] {
				continue
			}
			if qr_mask_bit(mask, x, y) {
				g.mods[y * g.size + x] ~= 1
			}
		}
	}
}

// The spec's four penalty rules; the lowest-scoring mask wins.
@(private = "file")
qr_penalty :: proc(g: ^Grid) -> int {
	score := 0
	dark := 0

	// Rules 1 and 3: runs of five or more, and the finder-lookalike
	// 1011101 with four light modules on either side.
	for line in 0 ..< 2 {
		for a in 0 ..< g.size {
			run, run_color := 0, u8(2) // 2 = no run yet
			window := 0
			for b in 0 ..< g.size {
				x, y := line == 0 ? b : a, line == 0 ? a : b
				m := g.mods[y * g.size + x]
				if m == run_color {
					run += 1
					score += run == 5 ? 3 : run > 5 ? 1 : 0
				} else {
					run_color, run = m, 1
				}
				window = (window << 1 | int(m)) & 0x7FF
				if b >= 10 && (window == 0b10111010000 || window == 0b00001011101) {
					score += 40
				}
				if line == 0 {
					dark += int(m)
				}
			}
		}
	}

	// Rule 2: every 2x2 block of one color.
	for y in 0 ..< g.size - 1 {
		for x in 0 ..< g.size - 1 {
			m := g.mods[y * g.size + x]
			if m == g.mods[y * g.size + x + 1] &&
			   m == g.mods[(y + 1) * g.size + x] &&
			   m == g.mods[(y + 1) * g.size + x + 1] {
				score += 3
			}
		}
	}

	// Rule 4: how far the dark share strays from half, in 5% steps.
	total := g.size * g.size
	k := (abs(dark * 20 - total * 10) + total - 1) / total
	return score + k * 10
}

// Lay the codewords into a finished module grid. `mods` is one byte
// per module, 1 = dark, row-major.
qr_matrix :: proc(
	cw: []u8,
	version: int,
	allocator := context.allocator,
) -> (
	mods: []u8,
	size: int,
) {
	size = qr_size(version)
	g := Grid {
		mods = make([]u8, size * size, allocator),
		res  = make([]bool, size * size, context.temp_allocator),
		size = size,
	}

	qr_finder(&g, 0, 0)
	qr_finder(&g, size - 7, 0)
	qr_finder(&g, 0, size - 7)

	// Timing: the alternating pair that fixes the module pitch.
	for i in 0 ..< size {
		if !g.res[6 * size + i] {
			gset(&g, i, 6, i % 2 == 0)
		}
		if !g.res[i * size + 6] {
			gset(&g, 6, i, i % 2 == 0)
		}
	}

	// Versions 2-5 carry exactly one alignment pattern, centered at
	// 4*version+10 on both axes.
	if version >= 2 {
		c := 4 * version + 10
		for dy in -2 ..= 2 {
			for dx in -2 ..= 2 {
				gset(&g, c + dx, c + dy, max(abs(dx), abs(dy)) != 1)
			}
		}
	}

	g.res[(size - 8) * size + 8] = true // the always-dark module
	qr_reserve_format(&g)

	// Data: two-column strips, right to left, alternating direction,
	// skipping the vertical timing column.
	bit := 0
	for right := size - 1; right >= 1; right -= 2 {
		if right == 6 {
			right = 5
		}
		for vert in 0 ..< size {
			for j in 0 ..< 2 {
				x := right - j
				y := (right + 1) & 2 == 0 ? size - 1 - vert : vert
				if g.res[y * size + x] || bit >= len(cw) * 8 {
					continue
				}
				g.mods[y * size + x] = cw[bit / 8] >> uint(7 - bit % 8) & 1
				bit += 1
			}
		}
	}

	// Pick the mask that scores lowest, then leave it applied.
	best, best_score := 0, max(int)
	for mask in 0 ..< 8 {
		qr_apply_mask(&g, mask)
		qr_format(&g, mask)
		if s := qr_penalty(&g); s < best_score {
			best, best_score = mask, s
		}
		qr_apply_mask(&g, mask) // XOR is its own inverse
	}
	qr_apply_mask(&g, best)
	qr_format(&g, best)
	return g.mods, size
}

// Modules for `text`, or ok = false when it does not fit version 5.
qr_encode :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	mods: []u8,
	size: int,
	ok: bool,
) {
	payload := transmute([]u8)text
	version := qr_version_for(len(payload))
	if version == 0 {
		return nil, 0, false
	}
	cw := qr_codewords(payload, version, context.temp_allocator)
	mods, size = qr_matrix(cw, version, allocator)
	return mods, size, true
}

// Black-on-white RGBA texture, `scale` pixels per module plus a quiet
// zone. Black on white regardless of theme: a scanner needs the
// contrast, and every camera app expects that polarity.
QR_SCALE :: 8
QR_QUIET :: 4

qr_image :: proc(text: string) -> (rl.Image, bool) {
	mods, size, ok := qr_encode(text, context.temp_allocator)
	if !ok {
		return {}, false
	}

	side := (size + 2 * QR_QUIET) * QR_SCALE
	px := make([]u8, side * side * 4, context.temp_allocator)
	for i in 0 ..< side * side {
		px[i * 4 + 0] = 255
		px[i * 4 + 1] = 255
		px[i * 4 + 2] = 255
		px[i * 4 + 3] = 255
	}

	for my in 0 ..< size {
		for mx in 0 ..< size {
			if mods[my * size + mx] == 0 {
				continue
			}
			ox := (mx + QR_QUIET) * QR_SCALE
			oy := (my + QR_QUIET) * QR_SCALE
			for y in oy ..< oy + QR_SCALE {
				for x in ox ..< ox + QR_SCALE {
					d := (y * side + x) * 4
					px[d + 0], px[d + 1], px[d + 2] = 0, 0, 0
				}
			}
		}
	}
	return rl.Image{data = raw_data(px), width = i32(side), height = i32(side)}, true
}
