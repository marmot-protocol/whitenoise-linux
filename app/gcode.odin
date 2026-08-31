// G-code extrusion preview: parse the print moves into 3D segments,
// draw them as screen-billboarded ribbons through the same clay
// Custom command as the mesh views, and let a slider under the tile
// scrub through the print (frac = share of segments drawn).
//
// Segments are drawn in print order, which is bottom-up for a real
// print, so later (higher) extrusions correctly paint over earlier
// ones without a depth sort.
package main

import "core:math"
import "core:strconv"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

GCODE_MAX_SEGS :: 2_000_000 // parse cap, same spirit as STL_MAX_TRIS
GCODE_COLOR :: rl.FColor{0.93, 0.58, 0.25, 1} // filament orange

Gcode_View :: struct {
	kind:  Model_Kind, // .Gcode; must stay the first field
	using orbit: Orbit,
	segs:  []f32, // nseg * 6 endpoint floats, unit-sphere normalized
	frac:  f32, // slider progress, share of segments drawn
	rot:   []f32, // rotated endpoints, same layout
	verts: []rl.Vertex, // cached ribbon buffer, nseg * 6
	built: [6]f32, // (cx, cy, scale, yaw, pitch, frac) verts was built for
}

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
					case 'X': x = v
					case 'Y': y = v
					case 'Z': z = v
					case 'E': e = v
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
				case 'X': nx = abs_move ? v : x + v
				case 'Y': ny = abs_move ? v : y + v
				case 'Z': nz = abs_move ? v : z + v
				case 'E': ne = abs_e ? v : e + v
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
	normalize_tris(segs[:]) // stride-3 points; works on endpoints too
	return segs[:], true
}

gcode_view_make :: proc(segs: []f32) -> ^Gcode_View {
	view := new(Gcode_View)
	view^ = {
		kind  = .Gcode,
		orbit = default_orbit(),
		segs  = segs,
		frac  = 1,
		rot   = make([]f32, len(segs)),
		verts = make([]rl.Vertex, len(segs)),
	}
	return view
}

gcode_view_free :: proc(view: ^Gcode_View) {
	delete(view.segs)
	delete(view.rot)
	delete(view.verts)
	free(view)
}

// Renderer hook (Custom command dispatch). Rotation caches rebuild on
// orbit change; the ribbon buffer rebuilds when those, the slider, or
// the tile placement change.
gcode_draw :: proc(view: ^Gcode_View, bounds: clay.BoundingBox) {
	nseg := len(view.segs) / 6

	if view.dirty {
		view.dirty = false
		cy, sy := math.cos(view.yaw), math.sin(view.yaw)
		cp, sp := math.cos(view.pitch), math.sin(view.pitch)
		for p in 0 ..< nseg * 2 {
			at := p * 3
			px, py, pz := view.segs[at], view.segs[at + 1], view.segs[at + 2]
			rx := px * cy + pz * sy
			tz := -px * sy + pz * cy
			view.rot[at] = rx
			view.rot[at + 1] = py * cp - tz * sp
			view.rot[at + 2] = py * sp + tz * cp
		}
	}

	scale := min(bounds.width, bounds.height) * 0.45 * view.zoom
	cx := bounds.x + bounds.width / 2
	cy := bounds.y + bounds.height / 2
	count := clamp(int(view.frac * f32(nseg) + 0.5), 0, nseg)

	key := [6]f32{cx, cy, scale, view.yaw, view.pitch, view.frac}
	if view.built != key {
		view.built = key
		hw := max(f32(0.75), scale * 0.006) // ribbon half-width, layout px
		for i in 0 ..< count {
			at := i * 6
			x1 := cx + view.rot[at] * scale
			y1 := cy - view.rot[at + 1] * scale
			x2 := cx + view.rot[at + 3] * scale
			y2 := cy - view.rot[at + 4] * scale

			// Screen-space perpendicular expands the segment into a
			// quad; depth only shades (near is brighter).
			dx, dy := x2 - x1, y2 - y1
			length := math.sqrt(dx * dx + dy * dy)
			px, py := hw, f32(0)
			if length > 0.0001 {
				px, py = -dy / length * hw, dx / length * hw
			}
			g := clamp(0.55 + 0.225 * (view.rot[at + 2] + view.rot[at + 5]), 0.2, 1.0)
			color := rl.FColor{GCODE_COLOR.r * g, GCODE_COLOR.g * g, GCODE_COLOR.b * g, 1}

			view.verts[at] = {position = {x1 + px, y1 + py}, color = color}
			view.verts[at + 1] = {position = {x1 - px, y1 - py}, color = color}
			view.verts[at + 2] = {position = {x2 + px, y2 + py}, color = color}
			view.verts[at + 3] = {position = {x2 + px, y2 + py}, color = color}
			view.verts[at + 4] = {position = {x2 - px, y2 - py}, color = color}
			view.verts[at + 5] = {position = {x1 - px, y1 - py}, color = color}
		}
	}

	rl.DrawTrianglesClipped(view.verts[:count * 6], bounds.x, bounds.y, bounds.width, bounds.height)
}

// Slider drag: the bar element's bounds come from clay, so the frac
// is just the pointer's position across it. Bars are re-registered
// every build (id + view), pressed state spans frames.
Gcode_Bar :: struct {
	id:   clay.ElementId,
	view: ^Gcode_View,
}

gcode_bars: [dynamic]Gcode_Bar // rebuilt each frame during layout
gcode_bar_drag: Gcode_Bar

handle_gcode_bar :: proc() {
	if rl.IsMouseButtonPressed(.LEFT) {
		for bar in gcode_bars {
			if clay.PointerOver(bar.id) {
				gcode_bar_drag = bar
				break
			}
		}
	}
	if gcode_bar_drag.view == nil {
		return
	}
	if !rl.IsMouseButtonDown(.LEFT) {
		gcode_bar_drag = {}
		return
	}

	bb := clay.GetElementData(gcode_bar_drag.id).boundingBox
	if bb.width > 0 {
		gcode_bar_drag.view.frac = clamp((rl.GetMousePosition().x / UI_ZOOM - bb.x) / bb.width, 0, 1)
	}
}
