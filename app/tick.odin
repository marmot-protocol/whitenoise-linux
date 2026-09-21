// The delivery tick, drawn rather than typed. The icon font has a
// checkmark glyph, but a glyph can only appear; a stroked path can be
// revealed along its own length, so the tick draws itself the moment a
// message lands and then just sits there.
//
// It rides the Custom render command like the 3D tiles and the decor
// scenes do: the payload is a temp-allocated view (freed with the
// frame, after the renderer has walked the commands).
package main

import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

CHECK_SECS :: 0.34
CHECK_W :: f32(11)
CHECK_H :: f32(9)
CHECK_LAG :: 0.12 // the second tick of a double, trailing the first

Check_View :: struct {
	kind:   Model_Kind, // .Check; must stay the first field
	start:  f64,
	double: bool,
	color:  clay.Color,
}

// When each chat's delivery state last changed, so the stroke is drawn
// once per transition instead of on every frame the state holds.
tick_at: map[string]struct {
	state: marmot.Delivery_State,
	at:    f64,
}

// One tick (pending) or two (delivered), drawing themselves in.
delivery_tick :: proc(group_id: string, index: u32, state: marmot.Delivery_State) {
	seen, ok := tick_at[group_id]
	if !ok || seen.state != state {
		seen = {state, rl.GetTime()}
		// Clone only on first sight: a later transition reuses the key
		// already in the map.
		tick_at[ok ? group_id : strings.clone(group_id)] = seen
	}

	view := new(Check_View, context.temp_allocator)
	view^ = {
		kind   = .Check,
		start  = seen.at,
		double = state == .DELIVERED,
		color  = state == .DELIVERED ? ACCENT_DIM : TEXT_LO,
	}
	width := view.double ? CHECK_W + 4 : CHECK_W
	if rl.GetTime() - seen.at < CHECK_SECS + CHECK_LAG {
		anim_moving += 1
	}
	if clay.UI(clay.ID("Tick", index))(
	{
		layout = {sizing = {width = clay.SizingFixed(width), height = clay.SizingFixed(CHECK_H)}},
		custom = {customData = view},
	},
	) {}
}

// A thick line segment as two triangles.
@(private = "file")
stroke :: proc(verts: ^[dynamic]rl.Vertex, x0, y0, x1, y1, w: f32, color: rl.FColor) {
	dx := x1 - x0
	dy := y1 - y0
	mag := max(sqrt_approx(dx * dx + dy * dy), 0.001)
	// Normal to the segment, scaled to half the stroke width.
	nx := -dy / mag * w / 2
	ny := dx / mag * w / 2
	a := rl.Vertex {
		position = {x0 + nx, y0 + ny},
		color    = color,
	}
	b := rl.Vertex {
		position = {x0 - nx, y0 - ny},
		color    = color,
	}
	c := rl.Vertex {
		position = {x1 + nx, y1 + ny},
		color    = color,
	}
	d := rl.Vertex {
		position = {x1 - nx, y1 - ny},
		color    = color,
	}
	append(verts, a, b, c, b, d, c)
}

// Newton steps from a decent guess: this is called a handful of times a
// frame, and it keeps the file free of a math import.
sqrt_approx :: proc(x: f32) -> f32 {
	if x <= 0 {
		return 0
	}
	guess := x > 1 ? x / 2 : x
	for _ in 0 ..< 6 {
		guess = 0.5 * (guess + x / guess)
	}
	return guess
}

// The checkmark path: down to the elbow, then up to the tip. `progress`
// is how much of the total length is drawn.
@(private = "file")
check_path :: proc(verts: ^[dynamic]rl.Vertex, x, y, progress: f32, color: rl.FColor) {
	ELBOW :: f32(0.36) // share of the path spent on the short leg
	x0, y0 := x, y + CHECK_H * 0.55
	x1, y1 := x + CHECK_W * 0.36, y + CHECK_H * 0.95
	x2, y2 := x + CHECK_W, y + CHECK_H * 0.1

	if progress <= 0 {
		return
	}
	first := min(progress / ELBOW, 1)
	stroke(verts, x0, y0, x0 + (x1 - x0) * first, y0 + (y1 - y0) * first, 1.8, color)
	if progress <= ELBOW {
		return
	}
	second := (progress - ELBOW) / (1 - ELBOW)
	stroke(verts, x1, y1, x1 + (x2 - x1) * second, y1 + (y2 - y1) * second, 1.8, color)
}

check_draw :: proc(view: ^Check_View, bounds: clay.BoundingBox) {
	color := rl.FColor {
		view.color.r / 255,
		view.color.g / 255,
		view.color.b / 255,
		view.color.a / 255,
	}
	elapsed := rl.GetTime() - view.start

	verts := make([dynamic]rl.Vertex, context.temp_allocator)
	check_path(&verts, bounds.x, bounds.y, ease_out(f32(clamp(elapsed / CHECK_SECS, 0, 1))), color)
	if view.double {
		lag := clamp((elapsed - CHECK_LAG) / CHECK_SECS, 0, 1)
		check_path(&verts, bounds.x + 4, bounds.y, ease_out(f32(lag)), color)
	}
	if len(verts) > 0 {
		rl.DrawTrianglesClipped(
			verts[:],
			bounds.x - 1,
			bounds.y - 1,
			bounds.width + 2,
			bounds.height + 2,
		)
	}
}
