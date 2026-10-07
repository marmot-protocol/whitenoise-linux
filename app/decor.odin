// Theme decor layers. Page washes and wallpapers mount on the root;
// geometric scenes mount on the Timeline's Custom payload. Clay draws
// each payload before its children, keeping content above the scene.
package main

import "core:math"

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

wash_decor := Decor_View {
	kind = .Wash,
}
deco_decor := Decor_View {
	kind = .Deco,
}
blinds_decor := Decor_View {
	kind = .Blinds,
}
stripes_decor := Decor_View {
	kind = .Stripes,
}
waves_decor := Decor_View {
	kind = .Waves,
}
airmail_decor := Decor_View {
	kind = .Airmail,
}

// Rendered from Sidecar's pinned CSS; scripts/render-sidecar-themes.ts regenerates them.
// These are scene assets, not theme identities. Custom packs can select them too.
@(private = "file")
DECOR_IMAGES := [?]struct {
	name: string,
	png:  []u8,
} {
	{"image:quilt", #load("assets/themes/quilt.png")},
	{"image:film", #load("assets/themes/film.png")},
	{"image:masonry", #load("assets/themes/masonry.png")},
	{"image:mesh", #load("assets/themes/mesh.png")},
	{"image:rays", #load("assets/themes/rays.png")},
	{"image:sunburst", #load("assets/themes/sunburst.png")},
	{"image:meander", #load("assets/themes/meander.png")},
	{"image:airmail-map", #load("assets/themes/airmail-map.png")},
	{"image:circle-grid", #load("assets/themes/circle-grid.png")},
	{"image:comic-dots", #load("assets/themes/comic-dots.png")},
	{"image:cast-metal", #load("assets/themes/cast-metal.png")},
	{"image:star-atlas", #load("assets/themes/star-atlas.png")},
	{"image:split-flaps", #load("assets/themes/split-flaps.png")},
	{"image:jazz-stage", #load("assets/themes/jazz-stage.png")},
	{"image:fungal-threads", #load("assets/themes/fungal-threads.png")},
	{"image:circle-lattice", #load("assets/themes/circle-lattice.png")},
	{"image:hollow-night", #load("assets/themes/hollow-night.png")},
	{"image:subway-tile", #load("assets/themes/subway-tile.png")},
	{"image:woodblock-waves", #load("assets/themes/woodblock-waves.png")},
	{"image:kintsugi", #load("assets/themes/kintsugi.png")},
	{"image:secession-grid", #load("assets/themes/secession-grid.png")},
}
@(private = "file")
decor_images: [len(DECOR_IMAGES)]rl.Texture2D

@(private)
init_decor :: proc() {
	// Preload before the event loop: hovering never decodes or uploads a wallpaper.
	// SDL owns these textures and destroys them with the renderer, including reload.
	for image, i in DECOR_IMAGES {
		decoded := rl.LoadImageFromMemory(".png", raw_data(image.png), i32(len(image.png)))
		assert(decoded.data != nil, "Couldn't decode bundled theme wallpaper")
		decor_images[i] = rl.LoadTextureFromImage(decoded)
		rl.UnloadImage(decoded)
		assert(decor_images[i].tex != nil, "Couldn't upload bundled theme wallpaper")
	}
}

@(private)
decor_texture :: proc(backdrop: string) -> ^rl.Texture2D {
	for image, i in DECOR_IMAGES {
		if image.name == backdrop {
			return &decor_images[i]
		}
	}
	return nil
}

// The page's own gradient, mounted on the root rather than the
// timeline so it runs under the rail and the panels too. nil when the
// pack names no second stop, which leaves the flat BG fill.
wash_payload :: proc() -> rawptr {
	return THEME_WALLPAPER != nil || BG_2.a > 0 ? &wash_decor : nil
}

@(private)
decor_canvas_fill :: proc() -> clay.Color {
	// Page content sits on the wallpaper; dialogs and sheets keep their own surfaces.
	return THEME_WALLPAPER != nil ? clay.Color{} : CARD
}

// A vertical wash from BG to BG_2, in bands. Cheap, and the only
// gradient the renderer needs: clay fills are flat.
WASH_BANDS :: 32

wash_draw :: proc(bounds: clay.BoundingBox) {
	if THEME_WALLPAPER != nil {
		// One wall, anchored to the window even inside a scrolled timeline.
		// ponytail: a 1280x800 raster scales with the window; regenerate at higher
		// resolution or port tiled layers if large-window detail needs more pixels.
		rl.BeginScissorMode(
			i32(math.floor(bounds.x)),
			i32(math.floor(bounds.y)),
			i32(math.ceil(bounds.width)),
			i32(math.ceil(bounds.height)),
		)
		rl.DrawTextureRect(
			THEME_WALLPAPER,
			0,
			0,
			f32(rl.GetScreenWidth()) / UI_ZOOM,
			f32(rl.GetScreenHeight()) / UI_ZOOM,
			{255, 255, 255, 255},
		)
		rl.EndScissorMode()
		return
	}

	h := bounds.height / WASH_BANDS + 1
	for i in 0 ..< WASH_BANDS {
		t := f32(i) / f32(WASH_BANDS - 1)
		tint := clay.Color {
			BG.r + (BG_2.r - BG.r) * t,
			BG.g + (BG_2.g - BG.g) * t,
			BG.b + (BG_2.b - BG.b) * t,
			255,
		}
		rl.DrawRectangleRec(
			bounds.x,
			bounds.y + f32(i) * bounds.height / WASH_BANDS,
			bounds.width,
			h,
			clay_color(tint),
		)
	}
}

// The scene this theme asks for by name, or nil. One payload pointer,
// so the timeline mounts decor without branching on theme identity.
// Animated scenes disappear under reduced motion and must not prevent idle.
decor_payload :: proc() -> rawptr {
	if THEME_WALLPAPER != nil {
		return nil // The root already paints the fixed wall behind the transparent canvas.
	}

	animated: rawptr
	switch BACKDROP {
	case "synth":
		animated = &synth_decor
	case "dust":
		animated = &dust_decor
	case "scan":
		animated = &scan_decor
	case "deco":
		return &deco_decor
	case "blinds":
		return &blinds_decor
	case "stripes":
		return &stripes_decor
	case "waves":
		animated = &waves_decor
	case "airmail":
		return &airmail_decor
	}
	if animated != nil && motion_on() {
		anim_moving += 1
		return animated
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

SYNTH_HORIZON :: 0.58 // horizon at 58% of the height
SYNTH_RAILS :: 9
SYNTH_RUNGS :: 7
SYNTH_ROLL :: 0.22 // rungs per second travelling toward the viewer

// One thin accent-colored quad from (x0,y0)-(x1,y1), w px wide.
@(private = "file")
rail_quad :: proc(verts: ^[dynamic]rl.Vertex, x0, y0, x1, y1, w: f32, color: rl.FColor) {
	h := w / 2
	a := rl.Vertex {
		position = {x0 - h, y0},
		color    = color,
	}
	b := rl.Vertex {
		position = {x0 + h, y0},
		color    = color,
	}
	c := rl.Vertex {
		position = {x1 - h, y1},
		color    = color,
	}
	d := rl.Vertex {
		position = {x1 + h, y1},
		color    = color,
	}
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
	rl.DrawRectangleRec(
		bounds.x,
		horizon_y,
		bounds.width,
		1,
		clay_color({ACCENT.r, ACCENT.g, ACCENT.b, 70}),
	)

	verts := make([dynamic]rl.Vertex, context.temp_allocator)
	// Rails: from the vanishing point on the horizon, fanning out to
	// the bottom edge (and past it, clipped by the draw).
	for i in 0 ..< SYNTH_RAILS {
		t := f32(i) / f32(SYNTH_RAILS - 1)
		bottom_x :=
			bounds.x + (t - 0.5) * bounds.width * 2.6 + bounds.width / 2 - px * PARALLAX * 2
		rail_quad(&verts, center_x, horizon_y, bottom_x, bounds.y + bounds.height, 1.5, tint)
	}
	rl.DrawTrianglesClipped(
		verts[:],
		bounds.x,
		horizon_y,
		bounds.width,
		bounds.y + bounds.height - horizon_y,
	)

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
		rl.DrawRectangleRec(
			bounds.x,
			y,
			bounds.width,
			1,
			clay_color({ACCENT.r, ACCENT.g, ACCENT.b, alpha}),
		)
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
		y := bounds.y + lane * bounds.height + 6 * f32(math.sin(now * 0.6 + f64(i)))

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


// ── Art deco sunburst ───────────────────────────────────────────────
//
// A fan of rays from a low centre, the shape over every cinema door of
// the period. Rays are drawn as thin quads so they hold their width at
// any angle, and the whole fan leans on the pointer like the others.

DECO_RAYS :: 19
DECO_ARCS :: 4

deco_draw :: proc(bounds: clay.BoundingBox) {
	px, py := parallax()
	cx := bounds.x + bounds.width / 2 + px * PARALLAX * 0.4
	cy := bounds.y + bounds.height * 1.02 + py * PARALLAX * 0.2
	reach := bounds.height * 1.5

	verts := make([dynamic]rl.Vertex, context.temp_allocator)
	tint := rl.FColor{ACCENT.r / 255, ACCENT.g / 255, ACCENT.b / 255, 0.05}
	for i in 0 ..< DECO_RAYS {
		// Half a turn, spread evenly, skipping the two along the floor.
		t := f32(i) / f32(DECO_RAYS - 1)
		angle := -f32(3.14159) * (0.08 + t * 0.84)
		rail_quad(
			&verts,
			cx,
			cy,
			cx + reach * f32(math.cos(f64(angle))),
			cy + reach * f32(math.sin(f64(angle))),
			8,
			tint,
		)
	}
	rl.DrawTrianglesClipped(verts[:], bounds.x, bounds.y, bounds.width, bounds.height)

	// Concentric arcs over the fan, the deco "rising sun" banding.
	for i in 1 ..= DECO_ARCS {
		r := bounds.height * (0.22 * f32(i))
		ring := clay_color({ACCENT.r, ACCENT.g, ACCENT.b, 10})
		for step in 0 ..< 48 {
			a := f32(3.14159) * (1 + f32(step) / 48)
			rl.DrawRectangleRec(
				cx + r * f32(math.cos(f64(a))),
				cy + r * f32(math.sin(f64(a))),
				2,
				2,
				ring,
			)
		}
	}
}

// ── Venetian blinds ─────────────────────────────────────────────────
//
// Hard light through a slatted window, the one lighting cue every noir
// picture owns. Bars are steeply sheared so they read as thrown light
// rather than as a table.

BLIND_GAP :: f32(46)
BLIND_SHEAR :: f32(0.42)

blinds_draw :: proc(bounds: clay.BoundingBox) {
	_, py := parallax()
	verts := make([dynamic]rl.Vertex, context.temp_allocator)
	pale := rl.FColor{TEXT.r / 255, TEXT.g / 255, TEXT.b / 255, 0.035}

	span := bounds.height + bounds.width * BLIND_SHEAR
	for y := -bounds.width * BLIND_SHEAR; y < span; y += BLIND_GAP {
		top := bounds.y + y + py * PARALLAX * 0.5
		a := rl.Vertex {
			position = {bounds.x, top},
			color    = pale,
		}
		b := rl.Vertex {
			position = {bounds.x, top + BLIND_GAP * 0.45},
			color    = pale,
		}
		c := rl.Vertex {
			position = {bounds.x + bounds.width, top + bounds.width * BLIND_SHEAR},
			color    = pale,
		}
		d := rl.Vertex {
			position = {
				bounds.x + bounds.width,
				top + bounds.width * BLIND_SHEAR + BLIND_GAP * 0.45,
			},
			color    = pale,
		}
		append(&verts, a, b, c, b, d, c)
	}
	rl.DrawTrianglesClipped(verts[:], bounds.x, bounds.y, bounds.width, bounds.height)
}

// ── Hazard banding ──────────────────────────────────────────────────
//
// The diagonal stripe painted on anything that can crush you. Kept to
// a whisper of alpha: it is a wall, not a warning.

STRIPE_W :: f32(28)

stripes_draw :: proc(bounds: clay.BoundingBox) {
	verts := make([dynamic]rl.Vertex, context.temp_allocator)
	tint := rl.FColor{WARNING.r / 255, WARNING.g / 255, WARNING.b / 255, 0.045}

	for x := bounds.x - bounds.height; x < bounds.x + bounds.width; x += STRIPE_W * 2 {
		a := rl.Vertex {
			position = {x, bounds.y + bounds.height},
			color    = tint,
		}
		b := rl.Vertex {
			position = {x + STRIPE_W, bounds.y + bounds.height},
			color    = tint,
		}
		c := rl.Vertex {
			position = {x + bounds.height, bounds.y},
			color    = tint,
		}
		d := rl.Vertex {
			position = {x + bounds.height + STRIPE_W, bounds.y},
			color    = tint,
		}
		append(&verts, a, b, c, b, d, c)
	}
	rl.DrawTrianglesClipped(verts[:], bounds.x, bounds.y, bounds.width, bounds.height)
}

// ── Sea swells ──────────────────────────────────────────────────────
//
// Long low sine bands, each a little slower than the one above it, so
// the page reads as water seen from a terrace.

WAVE_LINES :: 7

waves_draw :: proc(bounds: clay.BoundingBox) {
	now := rl.GetTime()
	for i in 0 ..< WAVE_LINES {
		t := f32(i) / f32(WAVE_LINES)
		base := bounds.y + bounds.height * (0.35 + t * 0.6)
		amp := 7 + 5 * t
		tint := clay_color({ACCENT.r, ACCENT.g, ACCENT.b, 14 - t * 8})
		// Sampled coarsely: the eye reads the curve, not the segments.
		for x := bounds.x; x < bounds.x + bounds.width; x += 6 {
			phase := f64(x) * 0.008 + now * (0.25 + f64(t) * 0.2)
			rl.DrawRectangleRec(x, base + amp * f32(math.sin(phase)), 6, 2, tint)
		}
	}
}

// ── Airmail border ──────────────────────────────────────────────────
//
// The red-and-blue chevron band off a par avion envelope, run down both
// margins so the conversation sits on the paper rather than in it.

AIR_CHEVRON :: f32(18)

airmail_draw :: proc(bounds: clay.BoundingBox) {
	verts := make([dynamic]rl.Vertex, context.temp_allocator)
	// Slot 0 and 1 are the pack's blue and red; the band alternates.
	blue := rl.FColor{ACCENT.r / 255, ACCENT.g / 255, ACCENT.b / 255, 0.5}
	red := rl.FColor{DANGER.r / 255, DANGER.g / 255, DANGER.b / 255, 0.5}

	band :: proc(verts: ^[dynamic]rl.Vertex, x, top, h, w: f32, color: rl.FColor) {
		a := rl.Vertex {
			position = {x, top},
			color    = color,
		}
		b := rl.Vertex {
			position = {x + w, top},
			color    = color,
		}
		c := rl.Vertex {
			position = {x, top + h},
			color    = color,
		}
		d := rl.Vertex {
			position = {x + w, top + h},
			color    = color,
		}
		append(verts, a, b, c, b, d, c)
	}

	i := 0
	for y := bounds.y; y < bounds.y + bounds.height; y += AIR_CHEVRON {
		color := i % 2 == 0 ? blue : red
		band(&verts, bounds.x, y, AIR_CHEVRON, 7, color)
		band(&verts, bounds.x + bounds.width - 7, y, AIR_CHEVRON, 7, color)
		i += 1
	}
	rl.DrawTrianglesClipped(verts[:], bounds.x, bounds.y, bounds.width, bounds.height)
}
