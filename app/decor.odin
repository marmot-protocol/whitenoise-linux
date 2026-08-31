// Theme decor layers, the ui/theme-decor port. Three scenes, picked by
// the active pack's capability flags and mounted as the Timeline
// element's Custom payload: clay emits the Custom command before the
// element's children, so a scene paints behind the messages, inside the
// timeline bounds.
//
//   synth-grid    a vanishing-point rail fan whose rungs roll toward
//                 the viewer, with the whole floor leaning on the mouse
//   paper-doodles slow motes drifting across the page (the doodles
//                 themselves are path art with no cheap equivalent)
//   scanlines     CRT lines plus a bright band rolling down the screen
//
// All three are drawn from geometry rather than assets, so they follow
// the accent color and cost one triangle batch a frame.
package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

Decor_View :: struct {
	kind: Model_Kind, // .Synth / .Dust / .Scan; must stay the first field
}

synth_decor := Decor_View {
	kind = .Synth,
}
dust_decor := Decor_View {
	kind = .Dust,
}
scan_decor := Decor_View {
	kind = .Scan,
}

// The scene this theme asks for, or nil. One payload pointer, so the
// timeline mounts decor without branching on theme identity.
decor_payload :: proc() -> rawptr {
	switch {
	case SYNTH_GRID:
		return &synth_decor
	case PAPER_DECOR:
		return &dust_decor
	case SCANLINES:
		return &scan_decor
	}
	return nil
}

// How far the scenes lean on the pointer, in px at the window edge.
PARALLAX :: f32(14)

// -1..1 for each axis, from the pointer's place in the window.
parallax :: proc() -> (x, y: f32) {
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())
	if w <= 0 || h <= 0 {
		return 0, 0
	}
	pos := rl.GetMousePosition()
	return clamp(pos.x / w * 2 - 1, -1, 1), clamp(pos.y / h * 2 - 1, -1, 1)
}

// ── Synthwave floor ─────────────────────────────────────────────────

SYNTH_HORIZON :: 0.58 // horizon at 58% height, like the slint scene
SYNTH_RAILS :: 9
SYNTH_RUNGS :: 7
SYNTH_ROLL :: 0.22 // rungs per second travelling toward the viewer

// One thin accent-colored quad from (x0,y0)-(x1,y1), w px wide.
@(private = "file")
rail_quad :: proc(verts: ^[dynamic]rl.Vertex, x0, y0, x1, y1, w: f32, color: rl.FColor) {
	h := w / 2
	a := rl.Vertex{position = {x0 - h, y0}, color = color}
	b := rl.Vertex{position = {x0 + h, y0}, color = color}
	c := rl.Vertex{position = {x1 - h, y1}, color = color}
	d := rl.Vertex{position = {x1 + h, y1}, color = color}
	append(verts, a, b, c, b, d, c)
}

synth_draw :: proc(bounds: clay.BoundingBox) {
	px, py := parallax()
	horizon_y := bounds.y + bounds.height * SYNTH_HORIZON + py * PARALLAX * 0.4
	center_x := bounds.x + bounds.width / 2 - px * PARALLAX
	tint := rl.FColor{ACCENT.r / 255, ACCENT.g / 255, ACCENT.b / 255, 0.16}

	// Sky glow band above the horizon.
	glow := clay_color({ACCENT.r, ACCENT.g, ACCENT.b, 18})
	rl.DrawRectangleRec(bounds.x, horizon_y - 60, bounds.width, 60, glow)
	// Horizon line.
	rl.DrawRectangleRec(bounds.x, horizon_y, bounds.width, 1, clay_color({ACCENT.r, ACCENT.g, ACCENT.b, 70}))

	verts := make([dynamic]rl.Vertex, context.temp_allocator)
	// Rails: from the vanishing point on the horizon, fanning out to
	// the bottom edge (and past it, clipped by the draw).
	for i in 0 ..< SYNTH_RAILS {
		t := f32(i) / f32(SYNTH_RAILS - 1)
		bottom_x := bounds.x + (t - 0.5) * bounds.width * 2.6 + bounds.width / 2 - px * PARALLAX * 2
		rail_quad(&verts, center_x, horizon_y, bottom_x, bounds.y + bounds.height, 1.5, tint)
	}
	rl.DrawTrianglesClipped(verts[:], bounds.x, horizon_y, bounds.width, bounds.y + bounds.height - horizon_y)

	// Rungs: perspective-spaced horizontals, denser near the horizon,
	// each one sliding down its own curve so the floor rolls forward.
	// The fractional part of the roll keeps the spacing continuous as a
	// rung falls off the bottom and a new one is born at the horizon.
	floor_h := bounds.y + bounds.height - horizon_y
	roll := f32(rl.GetTime()) * SYNTH_ROLL
	roll -= f32(int(roll))
	for i in 0 ..= SYNTH_RUNGS {
		t := (f32(i) + roll) / f32(SYNTH_RUNGS)
		if t > 1 {
			continue
		}
		y := horizon_y + t * t * floor_h
		// Fade in at the horizon so a new rung doesn't pop.
		alpha := 45 * min(t * 6, 1)
		rl.DrawRectangleRec(bounds.x, y, bounds.width, 1, clay_color({ACCENT.r, ACCENT.g, ACCENT.b, alpha}))
	}
}

// ── Paper motes ─────────────────────────────────────────────────────

// Cheap integer scramble: each mote's lane, size and speed come from
// its index, so the field has no state to keep.
@(private = "file")
hash_int :: proc(x: u32) -> u32 {
	h := x
	h ~= h >> 16
	h *= 0x7feb352d
	h ~= h >> 15
	h *= 0x846ca68b
	h ~= h >> 16
	return h
}

DUST_MOTES :: 26
DUST_DRIFT :: 9 // px per second sideways

// Slow specks crossing the page, like chalk dust or paper fibre in a
// light beam. Positions are a hash of the index, so there is no state
// and no PRNG: each mote has its own lane, size and speed.
dust_draw :: proc(bounds: clay.BoundingBox) {
	px, py := parallax()
	now := rl.GetTime()
	for i in 0 ..< DUST_MOTES {
		seed := f32(hash_int(u32(i)) % 1000) / 1000
		lane := f32(hash_int(u32(i) + 977) % 1000) / 1000
		speed := 0.4 + seed * 1.2
		size := 1.5 + seed * 2.5

		// Wrap across the width, bobbing on a slow sine.
		travel := f32(now) * DUST_DRIFT * speed + seed * bounds.width
		x := bounds.x + travel - bounds.width * f32(int(travel / bounds.width))
		y := bounds.y + lane * bounds.height + 6 * sin_approx(now * 0.6 + f64(i))

		alpha := 12 + 22 * seed
		rl.DrawRectangleRoundedPx(
			x + px * PARALLAX * (0.3 + seed),
			y + py * PARALLAX * (0.3 + seed),
			size,
			size,
			size / 2,
			clay_color({TEXT.r, TEXT.g, TEXT.b, alpha}),
		)
	}
}

// ── CRT scanlines ───────────────────────────────────────────────────

SCAN_GAP :: f32(3) // px between lines
SCAN_ROLL :: f32(70) // px per second for the bright band

scan_draw :: proc(bounds: clay.BoundingBox) {
	for y := bounds.y; y < bounds.y + bounds.height; y += SCAN_GAP {
		rl.DrawRectangleRec(bounds.x, y, bounds.width, 1, clay_color({0, 0, 0, 26}))
	}
	// One soft band rolling down the tube, the phosphor sweep.
	band_h := f32(90)
	span := bounds.height + band_h
	pos := f32(rl.GetTime()) * SCAN_ROLL
	top := bounds.y - band_h + (pos - span * f32(int(pos / span)))
	for i in 0 ..< 6 {
		t := f32(i) / 5
		rl.DrawRectangleRec(
			bounds.x,
			top + t * band_h,
			bounds.width,
			band_h / 6 + 1,
			clay_color({ACCENT.r, ACCENT.g, ACCENT.b, 5 * (1 - t)}),
		)
	}
}
