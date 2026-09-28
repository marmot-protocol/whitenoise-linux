package main

import "core:strconv"
import "core:strings"

GCODE_MAX_SEGS :: 2_000_000

// Extrusion segments from the move stream: G0/G1 with a positive E
// delta and actual motion. Handles absolute/relative modes (G90/G91,
// M82/M83) and E resets (G92). G-code is Z-up; the renderer is Y-up,
// so axes map (x, y, z) → (x, z, y).
parse_gcode :: proc(data: []u8) -> ([]f32, bool) {
	x, y, z, e: f32
	abs_move, abs_e := true, true
	segs := make([dynamic]f32)
	text := string(data)

	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if semi := strings.index_byte(l, ';'); semi >= 0 {
			l = strings.trim_space(l[:semi])
		}
		if len(l) == 0 {
			continue
		}

		fields := l
		cmd, _ := strings.fields_iterator(&fields)
		switch cmd {
		case "G90":
			abs_move, abs_e = true, true
		case "G91":
			abs_move, abs_e = false, false
		case "M82":
			abs_e = true
		case "M83":
			abs_e = false

		case "G92":
			for tok in strings.fields_iterator(&fields) {
				if v, ok := strconv.parse_f32(tok[1:]); ok {
					switch tok[0] {
					case 'X':
						x = v
					case 'Y':
						y = v
					case 'Z':
						z = v
					case 'E':
						e = v
					}
				}
			}

		case "G0", "G1":
			nx, ny, nz, ne := x, y, z, e
			for tok in strings.fields_iterator(&fields) {
				if len(tok) < 2 {
					continue
				}
				v, ok := strconv.parse_f32(tok[1:])
				if !ok {
					continue
				}
				switch tok[0] {
				case 'X':
					nx = abs_move ? v : x + v
				case 'Y':
					ny = abs_move ? v : y + v
				case 'Z':
					nz = abs_move ? v : z + v
				case 'E':
					ne = abs_e ? v : e + v
				}
			}
			extruding := ne > e && (nx != x || ny != y || nz != z)
			if extruding && len(segs) / 6 < GCODE_MAX_SEGS {
				append(&segs, x, z, y, nx, nz, ny)
			}
			x, y, z, e = nx, ny, nz, ne
		}
	}

	if len(segs) == 0 {
		delete(segs)
		return nil, false
	}
	glb_normalize(segs[:])
	return segs[:], true
}
