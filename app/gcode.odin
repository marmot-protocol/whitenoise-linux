// Extrusion toolpaths rasterize into a cached texture with rounded,
// shaded strokes and a depth buffer. The slider selects a print-order
// prefix; visibility depends on the camera, not on extrusion order.
package main

import "core:math"
import "core:mem"
import "core:slice"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

GCODE_COLOR :: rl.FColor{0.93, 0.58, 0.25, 1} // filament orange

Gcode_View :: struct {
	kind:        Model_Kind, // .Gcode; must stay the first field
	using orbit: Orbit,
	segs:        []f32, // nseg * 6 endpoint floats, unit-sphere normalized
	frac:        f32, // slider progress, share of segments drawn
	built:       [6]f32, // (w, h, zoom, yaw, pitch, frac)
	pix:         []u8,
	zbuf:        []f32,
	raster_tex:  rl.Texture2D,
	rw, rh:      i32,
	next:        int, // next segment in the current raster pass
}

// Source parsing is isolated; the UI receives normalized extrusion endpoints.
parse_gcode :: proc(data: []u8) -> ([]f32, bool) {
	return mesh_parse_points(data, 4)
}

gcode_view_make :: proc(segs: []f32) -> ^Gcode_View {
	view := new(Gcode_View)
	view^ = {
		kind  = .Gcode,
		orbit = default_orbit(),
		segs  = segs,
		frac  = 1,
	}
	return view
}

gcode_view_free :: proc(view: ^Gcode_View) {
	delete(view.segs)
	delete(view.pix)
	delete(view.zbuf)
	rl.UnloadTexture(view.raster_tex)
	free(view)
}

// Rasterize a projected capsule. Walking its major axis limits the
// inner span to the stroke width, even for long diagonal toolpaths.
@(private)
gcode_raster_seg :: proc(view: ^Gcode_View, p: [6]f32, scale, radius: f32) {
	x0 := f32(view.rw) / 2 + p[0] * scale
	y0 := f32(view.rh) / 2 - p[1] * scale
	x1 := f32(view.rw) / 2 + p[3] * scale
	y1 := f32(view.rh) / 2 - p[4] * scale
	dx, dy := x1 - x0, y1 - y0
	length2 := dx * dx + dy * dy
	swap := abs(dy) > abs(dx)
	a0, b0, da, db := x0, y0, dx, dy
	aw, bw := int(view.rw), int(view.rh)
	if swap {
		a0, b0, da, db = y0, x0, dy, dx
		aw, bw = bw, aw
	}
	lo := max(0, int(math.ceil(min(a0, a0 + da) - radius - 0.5)))
	hi := min(aw - 1, int(math.floor(max(a0, a0 + da) + radius - 0.5)))
	length := math.sqrt(length2)
	span := da == 0 ? radius : radius * length / abs(da)
	for a in lo ..= hi {
		ac := f32(a) + 0.5
		t := da == 0 ? f32(0) : clamp((ac - a0) / da, 0, 1)
		bc := b0 + db * t
		blo := max(0, int(math.ceil(bc - span - 0.5)))
		bhi := min(bw - 1, int(math.floor(bc + span - 0.5)))
		for b in blo ..= bhi {
			x, y := swap ? b : a, swap ? a : b
			qx, qy := f32(x) + 0.5 - x0, f32(y) + 0.5 - y0
			u :=
				length2 == 0 ? (p[5] > p[2] ? f32(1) : f32(0)) : clamp((qx * dx + qy * dy) / length2, 0, 1)
			nx, ny := qx - u * dx, qy - u * dy
			dist2 := nx * nx + ny * ny
			if dist2 >= radius * radius {continue}
			nz := math.sqrt(radius * radius - dist2)
			z := p[2] + u * (p[5] - p[2]) + nz / scale
			at := y * int(view.rw) + x
			if z <= view.zbuf[at] {continue}
			view.zbuf[at] = z
			light := clamp(0.45 + (0.75 * nz - 0.3 * nx - 0.4 * ny) / radius, 0.3, 1)
			pixel := view.pix[at * 4:at * 4 + 4]
			pixel[0] = u8(GCODE_COLOR.r * light * 255)
			pixel[1] = u8(GCODE_COLOR.g * light * 255)
			pixel[2] = u8(GCODE_COLOR.b * light * 255)
			pixel[3] = 255
		}
	}
}

// Cache by camera, raster size and print prefix, not tile placement.
// A long pass publishes partial geometry each frame within the mesh budget.
gcode_draw :: proc(view: ^Gcode_View, bounds: clay.BoundingBox) {
	nseg := len(view.segs) / 6
	// Opaque depth samples at twice output resolution avoid transparent
	// edge fragments punching holes through previously drawn filaments.
	w := i32(bounds.width * UI_SCALE / UI_ZOOM) * 2
	h := i32(bounds.height * UI_SCALE / UI_ZOOM) * 2
	if w <= 0 || h <= 0 {return}
	count := clamp(int(view.frac * f32(nseg) + 0.5), 0, nseg)
	key := [6]f32{f32(w), f32(h), view.zoom, view.yaw, view.pitch, view.frac}
	if view.built != key {
		view.built = key
		view.next, view.dirty = 0, false
		if view.rw != w || view.rh != h {
			delete(view.pix)
			delete(view.zbuf)
			rl.UnloadTexture(view.raster_tex)
			view.pix = make([]u8, int(w) * int(h) * 4)
			view.zbuf = make([]f32, int(w) * int(h))
			view.raster_tex = rl.CreateStreamTexture(w, h, blend = true)
			view.rw, view.rh = w, h
		}
		mem.zero_slice(view.pix)
		slice.fill(view.zbuf, math.NEG_INF_F32)
		// Even an empty slider prefix must erase the previous texture.
		if count == 0 {rl.UpdateTexturePixels(&view.raster_tex, raw_data(view.pix))}
	}

	if view.next < count {
		deadline := time.tick_add(time.tick_now(), MESH_REFINE_BUDGET)
		cy, sy := math.cos(view.yaw), math.sin(view.yaw)
		cp, sp := math.cos(view.pitch), math.sin(view.pitch)
		scale := f32(min(w, h)) * 0.45 * view.zoom
		// ponytail: the endpoint protocol has no nozzle diameter. Use a
		// thin visual stroke; physical bead widths need extrusion metadata.
		radius := max(f32(1), scale * 0.003)
		for view.next < count {
			p: [6]f32
			for k in 0 ..< 2 {
				at := view.next * 6 + k * 3
				x, y, z := view.segs[at], view.segs[at + 1], view.segs[at + 2]
				rx, rz := x * cy + z * sy, -x * sy + z * cy
				p[k * 3], p[k * 3 + 1], p[k * 3 + 2] = rx, y * cp - rz * sp, y * sp + rz * cp
			}
			gcode_raster_seg(view, p, scale, radius)
			view.next += 1
			if view.next % 32 == 0 && time.tick_diff(deadline, time.tick_now()) > 0 {break}
		}
		rl.UpdateTexturePixels(&view.raster_tex, raw_data(view.pix))
	}
	rl.DrawTextureRect(
		&view.raster_tex,
		bounds.x,
		bounds.y,
		bounds.width,
		bounds.height,
		{255, 255, 255, 255},
	)
	if view.next < count {
		anim_moving += 1
		rl.DrawRectangleRec(
			bounds.x,
			bounds.y + bounds.height - 30,
			bounds.width,
			30,
			clay_color(PLATE),
		)
		rl.DrawTextLine(
			FONT_BODY,
			11,
			tr("Rendering toolpaths"),
			bounds.x + 8,
			bounds.y + bounds.height - 26,
			0,
			clay_color(TEXT),
		)
		rl.DrawRectangleRec(
			bounds.x + 8,
			bounds.y + bounds.height - 8,
			max(0, bounds.width - 16),
			3,
			clay_color(ROW_BG),
		)
		rl.DrawRectangleRec(
			bounds.x + 8,
			bounds.y + bounds.height - 8,
			max(0, bounds.width - 16) * f32(view.next) / f32(count),
			3,
			clay_color(ACCENT),
		)
	}
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
		gcode_bar_drag.view.frac = clamp(
			(rl.GetMousePosition().x / UI_ZOOM - bb.x) / bb.width,
			0,
			1,
		)
	}
}
