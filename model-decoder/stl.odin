package main

import "core:encoding/endian"
import "core:strconv"
import "core:strings"

STL_HEADER_BYTES :: 84
STL_TRI_BYTES :: 50
STL_MAX_TRIS :: 2_000_000

// Wavefront OBJ, geometry only: v records and fan-triangulated f
// records (texture/normal indices after '/' are ignored). Negative
// indices count from the end, per spec.
parse_obj :: proc(data: []u8) -> ([]f32, bool) {
	pos := make([dynamic]f32)
	defer delete(pos)
	tris := make([dynamic]f32)
	text := string(data)

	fail :: proc(tris: ^[dynamic]f32) -> ([]f32, bool) {
		delete(tris^)
		return nil, false
	}

	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		switch {
		case strings.has_prefix(l, "v "):
			rest := l[2:]
			for _ in 0 ..< 3 {
				rest = strings.trim_left_space(rest)
				v, n, ok := strconv.parse_f32_prefix(rest)
				if !ok || !glb_finite(f64(v)) {
					return fail(&tris)
				}
				append(&pos, v)
				rest = rest[n:]
			}

		case strings.has_prefix(l, "f "):
			rest := l[2:]
			nv := len(pos) / 3
			corners := make([dynamic]int, context.temp_allocator)
			defer delete(corners)
			for tok in strings.fields_iterator(&rest) {
				head := tok
				if slash := strings.index_byte(head, '/'); slash >= 0 {
					head = head[:slash]
				}
				idx, ok := strconv.parse_int(head)
				if !ok {
					return fail(&tris)
				}
				if idx < 0 {
					idx += nv
				} else {
					idx -= 1
				}
				if idx < 0 || idx >= nv {
					return fail(&tris)
				}
				append(&corners, idx)
			}
			if len(corners) < 3 {
				return fail(&tris)
			}
			for k in 2 ..< len(corners) {
				for corner in ([3]int{corners[0], corners[k - 1], corners[k]}) {
					append(&tris, pos[corner * 3], pos[corner * 3 + 1], pos[corner * 3 + 2])
				}
				if len(tris) / 9 > STL_MAX_TRIS {
					return fail(&tris)
				}
			}
		}
	}

	if len(tris) == 0 {
		return fail(&tris)
	}
	glb_normalize(tris[:])
	return tris[:], true
}

// Both STL flavors: binary first (exact size math; many binary files
// also start with "solid"), ASCII as the fallback.
parse_stl :: proc(data: []u8) -> ([]f32, bool) {
	tris := parse_stl_binary(data)
	if tris == nil {
		tris = parse_stl_ascii(data)
	}
	if tris == nil {
		return nil, false
	}

	for v in tris {
		if !glb_finite(f64(v)) {delete(tris); return nil, false}
	}
	glb_normalize(tris)
	return tris, true
}

@(private = "file")
parse_stl_binary :: proc(data: []u8) -> []f32 {
	if len(data) < STL_HEADER_BYTES {
		return nil
	}
	count_u32, _ := endian.get_u32(data[80:84], .Little)
	count := int(count_u32)
	if count == 0 || count > STL_MAX_TRIS || len(data) < STL_HEADER_BYTES + count * STL_TRI_BYTES {
		return nil
	}

	out := make([]f32, count * 9)
	for i in 0 ..< count {
		base := STL_HEADER_BYTES + i * STL_TRI_BYTES + 12 // skip the stored normal
		for j in 0 ..< 9 {
			out[i * 9 + j], _ = endian.get_f32(data[base + j * 4:][:4], .Little)
		}
	}
	return out
}

@(private = "file")
parse_stl_ascii :: proc(data: []u8) -> []f32 {
	text := string(data)
	if !strings.has_prefix(strings.trim_left_space(text), "solid") {
		return nil
	}

	// Token stream: every "vertex" keyword owes three floats.
	out := make([dynamic]f32)
	pending := 0
	for tok in strings.fields_iterator(&text) {
		if pending > 0 {
			v, ok := strconv.parse_f32(tok)
			if !ok || !glb_finite(f64(v)) || len(out) >= STL_MAX_TRIS * 9 {
				delete(out)
				return nil
			}
			append(&out, v)
			pending -= 1
			continue
		}
		if tok == "vertex" {
			pending = 3
		}
	}

	if pending != 0 || len(out) == 0 || len(out) % 9 != 0 || len(out) / 9 > STL_MAX_TRIS {
		delete(out)
		return nil
	}
	return out[:]
}
