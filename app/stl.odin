// STL chat attachments rendered as interactive 3D: parse both STL
// flavors, then draw through a clay Custom command. The stack has no
// 3D API; models up to RASTER_MAX_TRIS rasterize on the CPU with a
// real z-buffer into a streaming texture (layered shells sit closer
// together than any per-triangle sort can order), and bigger ones
// fall back to the painter's bucket sort + RenderGeometry, whose cost
// scales better and whose small facets rarely misorder.
//
//   parse_stl ─→ unit-sphere tris + face normals (once)
//        stl_update: rotate + shade + bucket-sort   (orientation change)
//        stl_draw:   rebuild cached vertex buffer   (orientation, zoom,
//                    or bounds change) → DrawTrianglesClipped
//        handle_stl: drag = orbit, wheel = zoom (over the tile)
//
// Every stage is O(n) with no per-frame allocation; a still model
// costs only the RenderGeometry call. Measured, 200k random tris per
// orbit step: 125ms before; now 20.0ms at -o:minimal, 3.4ms at
// -o:speed (the app build, see scripts/build.sh).
package main

import "core:encoding/endian"
import "core:math"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Binary layout: 80-byte header + u32 count, then 50 bytes per
// triangle (normal + 3 verts as f32le, u16 attribute).
STL_HEADER_BYTES :: 84
STL_TRI_BYTES :: 50
// Parse cap so a bogus binary count can't allocate gigabytes.
STL_MAX_TRIS :: 2_000_000

STL_ORBIT_SPEED :: 0.012 // radians per layout px of drag
STL_ZOOM_STEP :: 1.15 // zoom factor per wheel notch
STL_ZOOM_MIN :: 0.3
STL_ZOOM_MAX :: 10.0
STL_BASE :: rl.FColor{0.78, 0.80, 0.84, 1} // neutral resin gray

// Painter's-order depth buckets; z spans [-1, 1] after unit-sphere
// normalization, so 256 slices are far below visible error.
STL_BUCKETS :: 65536

// First field of every Custom-command payload: the renderer peeks it
// to dispatch (mesh models and the G-code extrusion view share the
// one Custom command type clay offers).
Model_Kind :: enum u8 {
	Mesh,
	Gcode,
	Synth, // theme decor: the synthwave grid backdrop (decor.odin)
	Dust, // theme decor: drifting motes behind paper themes
	Scan, // theme decor: CRT scanlines and roll
	Wash, // theme decor: the page's vertical gradient wash
	Deco, // theme decor: art-deco sunburst fan
	Blinds, // theme decor: venetian light bars
	Stripes, // theme decor: diagonal hazard banding
	Waves, // theme decor: slow horizon swells
	Airmail, // theme decor: the airmail border chevrons
	Check, // the delivery tick, drawn stroke by stroke
	Glow, // an additive halo behind an element (glow.odin)
	Shade, // a linear drop-shadow gradient beside a panel (threads.odin)
	Image_Crop, // attachment thumbnails with extreme aspect ratios
	Profile_Background, // cover or tile media confined to a profile
	Hidden_Border, // rainbow outline around a zero-width message carrier
	Avatar_Hinge, // a photo cover rotating around its top-center pivot
}

// Shared orbit state: drag rotates, wheel zooms; one handler serves
// every 3D tile kind.
Orbit :: struct {
	yaw:   f32,
	pitch: f32,
	zoom:  f32,
	dirty: bool, // rotation-dependent caches need a rebuild
}

// One rendered mesh (STL or OBJ). tris/norms are computed once at
// parse; the rotation caches (rot/shade/order) rebuild on orientation
// change, and verts rebuilds when those or the tile placement change.
Stl_View :: struct {
	kind:        Model_Kind, // .Mesh; must stay the first field
	using orbit: Orbit,
	tris:        []f32, // ntri * 9 vertex floats, unit-sphere normalized
	norms:       []f32, // ntri * 3 unit face normals
	rot:         []f32, // rotated tris, same layout
	shade:       []f32, // per-tri view-space normal z (sign = facing)
	order:       []i32, // triangle indices, back to front
	verts:       []rl.Vertex, // cached draw buffer, ntri * 3
	built:       [5]f32, // (cx, cy, scale, yaw, pitch) verts was built for
	// View-space axes expressed in model space, rebuilt with the
	// rotation caches. The inspector dots vertex normals against
	// these instead of rotating a second normal buffer per frame.
	basis:       [3][3]f32,
	insp:        Inspect, // render mode, overlays, FBX channels + animation
	over:        [dynamic]rl.Vertex, // overlay quads (wireframe / normals)

	// Software z-buffer raster (models under RASTER_MAX_TRIS): the
	// painter's sort can't order stacked shells, so the surface is
	// rasterized into a streaming texture with real depth instead.
	// `built` doubles as its cache key ((rw, rh, zoom, yaw, pitch)
	// there), so everything that already clears `built` to force a
	// color rebuild invalidates the raster the same way.
	pix:         []u8, // rw * rh RGBA
	zbuf:        []f32,
	raster_tex:  rl.Texture2D,
	rw, rh:      i32,
	over_built:  [5]f32, // (cx, cy, scale, yaw, pitch) the overlay has
}

// Extension picks the parser; both produce the same triangle soup.
// FBX comes back as a whole view instead (it carries skin weights,
// materials, and animation takes), so it has its own entry point.
parse_model :: proc(name: string, data: []u8) -> ([]f32, bool) {
	if strings.has_suffix(name, ".obj") {
		return parse_obj(data)
	}
	return parse_stl(data)
}

// Every mesh format the viewer opens, from the lowercased name.
is_model_name :: proc(lower: string) -> bool {
	return(
		strings.has_suffix(lower, ".stl") ||
		strings.has_suffix(lower, ".obj") ||
		strings.has_suffix(lower, ".fbx") ||
		strings.has_suffix(lower, ".glb") \
	)
}

// One entry point for the timeline and the preview modal: parse any
// mesh format into a ready view, or nil.
model_view_make :: proc(lower: string, data: []u8) -> ^Stl_View {
	if strings.has_suffix(lower, ".glb") {
		view, ok := parse_glb(data)
		return ok ? view : nil
	}
	if strings.has_suffix(lower, ".fbx") {
		view, ok := parse_fbx(data)
		return ok ? view : nil
	}
	tris, ok := parse_model(lower, data)
	if !ok {
		return nil
	}
	return stl_view_make(tris)
}

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
				if !ok {
					return fail(&tris)
				}
				append(&pos, v)
				rest = rest[n:]
			}

		case strings.has_prefix(l, "f "):
			rest := l[2:]
			nv := len(pos) / 3
			corners := make([dynamic]int, context.temp_allocator)
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
	normalize_tris(tris[:])
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

	normalize_tris(tris)
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
			if !ok {
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

// Center on the bbox and scale into the unit sphere so drawing never
// needs the model's real dimensions. Works on any stride-3 point
// array (the g-code view runs its segment endpoints through it too).
normalize_tris :: proc(tris: []f32) {
	lo := [3]f32{max(f32), max(f32), max(f32)}
	hi := [3]f32{min(f32), min(f32), min(f32)}
	for i in 0 ..< len(tris) / 3 {
		for a in 0 ..< 3 {
			v := tris[i * 3 + a]
			lo[a] = min(lo[a], v)
			hi[a] = max(hi[a], v)
		}
	}

	center := [3]f32{(lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2}
	d := [3]f32{hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]}
	radius := math.sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]) / 2
	if radius <= 0 {
		radius = 1
	}
	for i in 0 ..< len(tris) / 3 {
		for a in 0 ..< 3 {
			tris[i * 3 + a] = (tris[i * 3 + a] - center[a]) / radius
		}
	}
}

stl_view_make :: proc(tris: []f32) -> ^Stl_View {
	ntri := len(tris) / 9
	view := new(Stl_View)
	view^ = {
		kind = .Mesh,
		orbit = default_orbit(),
		tris = tris,
		norms = make([]f32, ntri * 3),
		rot = make([]f32, len(tris)),
		shade = make([]f32, ntri),
		order = make([]i32, ntri),
		verts = make([]rl.Vertex, ntri * 3),
		insp = {wire = -1, anim = -1},
	}
	stl_face_normals(view)
	return view
}

// Unit face normals from the current triangle positions; stl_update
// rotates these instead of re-deriving them from edges every
// orientation change. A posed FBX frame re-runs this, since skinning
// moved the vertices.
stl_face_normals :: proc(view: ^Stl_View) {
	tris := view.tris
	for i in 0 ..< len(tris) / 9 {
		at := i * 9
		e1 := [3]f32 {
			tris[at + 3] - tris[at],
			tris[at + 4] - tris[at + 1],
			tris[at + 5] - tris[at + 2],
		}
		e2 := [3]f32 {
			tris[at + 6] - tris[at],
			tris[at + 7] - tris[at + 1],
			tris[at + 8] - tris[at + 2],
		}
		nx := e1[1] * e2[2] - e1[2] * e2[1]
		ny := e1[2] * e2[0] - e1[0] * e2[2]
		nz := e1[0] * e2[1] - e1[1] * e2[0]
		length := math.sqrt(nx * nx + ny * ny + nz * nz)
		if length <= 0 {
			length = 1
		}
		view.norms[i * 3], view.norms[i * 3 + 1], view.norms[i * 3 + 2] =
			nx / length, ny / length, nz / length
	}
}

// Rebuild the rotation-dependent caches: rotated verts, headlight
// shading from the rotated face normal, and the paint order via an
// O(n) depth bucket sort (a comparison sort here was the frame-rate
// bottleneck).
@(private = "file")
stl_update :: proc(view: ^Stl_View) {
	if !view.dirty {
		return
	}
	view.dirty = false

	cy, sy := math.cos(view.yaw), math.sin(view.yaw)
	cp, sp := math.cos(view.pitch), math.sin(view.pitch)
	ntri := len(view.tris) / 9

	// Rows of the rotation matrix below: the view's right/up/forward
	// axes in model space, for the inspector's per-vertex shading.
	view.basis = {{cy, 0, sy}, {sy * sp, cp, -cy * sp}, {-sy * cp, sp, cy * cp}}

	// z ∈ [-1, 1] → bucket; count, prefix-sum, place. Far (small z)
	// buckets paint first. 64k buckets: layered shells sit ~0.007
	// apart in unit-sphere space, so 256 buckets tied them and file
	// order picked the winner per triangle.
	bucket := make([]u16, ntri, context.temp_allocator)
	counts := make([]i32, STL_BUCKETS, context.temp_allocator)

	for i in 0 ..< ntri {
		// Yaw about Y, then pitch about X; +z faces the viewer.
		for k in 0 ..< 3 {
			at := i * 9 + k * 3
			x, y, z := view.tris[at], view.tris[at + 1], view.tris[at + 2]
			rx := x * cy + z * sy
			tz := -x * sy + z * cy
			view.rot[at] = rx
			view.rot[at + 1] = y * cp - tz * sp
			view.rot[at + 2] = y * sp + tz * cp
		}

		// STL winding is not reliable, so the default shading takes
		// |nz| of the rotated normal rather than culling backfaces.
		// The signed value is kept: Single Sided culls on it.
		nx, ny, nz := view.norms[i * 3], view.norms[i * 3 + 1], view.norms[i * 3 + 2]
		view.shade[i] = ny * sp + (-nx * sy + nz * cy) * cp

		at := i * 9
		// Nearest corner, not the centroid: a large face keeps a
		// middling centroid while a sliver overlapping it sorts nearer
		// and wrongly paints on top.
		// ponytail: this path only serves models too big for the
		// z-buffer raster, and can still misorder close layered
		// sheets; raise RASTER_MAX_TRIS if that ever shows there.
		z_near := max(view.rot[at + 2], view.rot[at + 5], view.rot[at + 8])
		b := u16(clamp(int((z_near + 1) * (STL_BUCKETS / 2)), 0, STL_BUCKETS - 1))
		bucket[i] = b
		counts[b] += 1
	}

	next := make([]i32, STL_BUCKETS, context.temp_allocator)
	total: i32
	for c, b in counts {
		next[b] = total
		total += c
	}
	for i in 0 ..< ntri {
		b := bucket[i]
		view.order[next[b]] = i32(i)
		next[b] += 1
	}
}

// Rebuild the cached vertex buffer for a tile placement. Skipped
// entirely when nothing moved, so a still model costs only the
// RenderGeometry call per frame.
@(private = "file")
stl_build_verts :: proc(view: ^Stl_View, cx, cy, scale: f32) {
	key := [5]f32{cx, cy, scale, view.yaw, view.pitch}
	if view.built == key {
		return
	}
	view.built = key

	for idx, i in view.order {
		at := int(idx) * 9
		// Single Sided drops back-facing triangles by collapsing them
		// to a point, which keeps every buffer index stable.
		if view.insp.single_sided && view.shade[idx] < 0 {
			p := rl.Vertex {
				position = {cx, cy},
			}
			view.verts[i * 3], view.verts[i * 3 + 1], view.verts[i * 3 + 2] = p, p, p
			continue
		}

		colors := model_vert_colors(view, int(idx))
		uvs := model_vert_uvs(view, int(idx))
		for k in 0 ..< 3 {
			view.verts[i * 3 + k] = {
				position  = {
					cx + view.rot[at + k * 3] * scale,
					cy - view.rot[at + k * 3 + 1] * scale,
				},
				color     = colors[k],
				tex_coord = {uvs[k][0], uvs[k][1]},
			}
		}
	}

	build_overlay(view, cx, cy, scale)
}

// Under this, the model draws through the software z-buffer; over it,
// the painter's sort (raster setup cost scales with triangles, and a
// huge STL orbits fine sorted: its facets are small).
RASTER_MAX_TRIS :: 150_000

@(private)
ORBIT_RASTER_SIZE :: 256 // longest edge while dragging; full resolution returns on release

// Rasterize the model into view.pix with a real depth test, at the
// tile's pixel size. Rebuilds only when the key (size, orbit, or a
// cleared `built`) moves; a still model costs one texture draw.
@(private = "file")
stl_raster :: proc(view: ^Stl_View, w, h: i32) -> (rebuilt: bool) {
	key := [5]f32{f32(w), f32(h), view.zoom, view.yaw, view.pitch}
	if view.built == key {
		return false
	}
	view.built = key

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
	for &z in view.zbuf {
		z = math.NEG_INF_F32
	}

	cx, cy := f32(w) / 2, f32(h) / 2
	scale := f32(min(w, h)) * 0.45 * view.zoom
	checker := view.insp.mode == .Uv_Checker && view.insp.uv != nil
	textured := len(view.insp.images) > 0
	cell := f32(CHECKER_SQUARES)

	ntri := len(view.tris) / 9
	for tri in 0 ..< ntri {
		if view.insp.single_sided && view.shade[tri] < 0 {
			continue
		}
		at := tri * 9
		// Screen-space corners; z stays in view units for the test.
		x0 := cx + view.rot[at] * scale
		y0 := cy - view.rot[at + 1] * scale
		z0 := view.rot[at + 2]
		x1 := cx + view.rot[at + 3] * scale
		y1 := cy - view.rot[at + 4] * scale
		z1 := view.rot[at + 5]
		x2 := cx + view.rot[at + 6] * scale
		y2 := cy - view.rot[at + 7] * scale
		z2 := view.rot[at + 8]

		area := (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
		if area == 0 {
			continue
		}
		inv := 1 / area

		lo_x := clamp(int(math.floor(min(x0, x1, x2))), 0, int(w) - 1)
		hi_x := clamp(int(math.ceil(max(x0, x1, x2))), 0, int(w) - 1)
		lo_y := clamp(int(math.floor(min(y0, y1, y2))), 0, int(h) - 1)
		hi_y := clamp(int(math.ceil(max(y0, y1, y2))), 0, int(h) - 1)
		if lo_x > hi_x || lo_y > hi_y {
			continue
		}

		colors := model_vert_colors(view, tri)
		uvs: [3][2]f32
		basis: [5][3]f32
		if checker {
			uvs = model_vert_uvs(view, tri)
		} else if textured {
			for k in 0 ..< 3 {
				uvs[k] = {view.insp.uv[tri * 6 + k * 2], view.insp.uv[tri * 6 + k * 2 + 1]}
			}
			if view.insp.mode == .Final {basis = model_texture_basis(view, tri)}
		}

		for py in lo_y ..= hi_y {
			fy := f32(py) + 0.5
			row := py * int(w)
			for px in lo_x ..= hi_x {
				fx := f32(px) + 0.5
				// Barycentric weights; signs flip with winding, so
				// inside = all three on the same side as the area.
				w0 := ((x1 - fx) * (y2 - fy) - (x2 - fx) * (y1 - fy)) * inv
				w1 := ((x2 - fx) * (y0 - fy) - (x0 - fx) * (y2 - fy)) * inv
				w2 := 1 - w0 - w1
				if w0 < 0 || w1 < 0 || w2 < 0 {
					continue
				}
				z := w0 * z0 + w1 * z1 + w2 * z2
				if z <= view.zbuf[row + px] {
					continue
				}
				r := w0 * colors[0].r + w1 * colors[1].r + w2 * colors[2].r
				g := w0 * colors[0].g + w1 * colors[1].g + w2 * colors[2].g
				b := w0 * colors[0].b + w1 * colors[1].b + w2 * colors[2].b
				alpha := w0 * colors[0].a + w1 * colors[1].a + w2 * colors[2].a
				if checker {
					u := w0 * uvs[0][0] + w1 * uvs[1][0] + w2 * uvs[2][0]
					v := w0 * uvs[0][1] + w1 * uvs[1][1] + w2 * uvs[2][1]
					// The same 16-square pattern the texture bakes,
					// clamped like the GPU path (no wrap mode there).
					iu := int(clamp(u, 0, 0.9999) * cell)
					iv := int(clamp(v, 0, 0.9999) * cell)
					tone := (iu + iv) % 2 == 0 ? f32(220.0 / 255.0) : f32(90.0 / 255.0)
					r *= tone
					g *= tone
					b *= tone
				} else if textured {
					uv := uvs[0] * w0 + uvs[1] * w1 + uvs[2] * w2
					color := model_texture_color(
						view,
						tri,
						uv,
						{w0, w1, w2},
						basis,
						{r, g, b, alpha},
					)
					r, g, b, alpha = color.r, color.g, color.b, color.a
				}
				// ponytail: alpha cutouts; translucent surfaces need a sorted blend pass.
				if alpha < 0.5 {continue}
				view.zbuf[row + px] = z
				out := (row + px) * 4
				view.pix[out] = u8(clamp(r, 0, 1) * 255)
				view.pix[out + 1] = u8(clamp(g, 0, 1) * 255)
				view.pix[out + 2] = u8(clamp(b, 0, 1) * 255)
				view.pix[out + 3] = 255
			}
		}
	}
	rl.UpdateTexturePixels(&view.raster_tex, raw_data(view.pix))
	return true
}

// Clay renderer hook for the Custom command, clipped to the tile so
// zoom can't bleed over neighboring rows.
stl_draw :: proc(view: ^Stl_View, bounds: clay.BoundingBox) {
	stl_update(view)

	// Textures need per-pixel sampling; the large-mesh SDL fallback only colors vertices.
	if len(view.tris) / 9 <= RASTER_MAX_TRIS || len(view.insp.images) > 0 {
		w := i32(bounds.width * UI_SCALE / UI_ZOOM)
		h := i32(bounds.height * UI_SCALE / UI_ZOOM)
		if orbit_drag == &view.orbit && orbit_moved && max(w, h) > ORBIT_RASTER_SIZE {
			ratio := f32(ORBIT_RASTER_SIZE) / f32(max(w, h))
			w = max(1, i32(f32(w) * ratio))
			h = max(1, i32(f32(h) * ratio))
		}
		if w > 0 && h > 0 {
			rebuilt := stl_raster(view, w, h)
			rl.DrawTextureRect(
				&view.raster_tex,
				bounds.x,
				bounds.y,
				bounds.width,
				bounds.height,
				{255, 255, 255, 255},
			)
			cx := bounds.x + bounds.width / 2
			cy := bounds.y + bounds.height / 2
			scale := min(bounds.width, bounds.height) * 0.45 * view.zoom
			okey := [5]f32{cx, cy, scale, view.yaw, view.pitch}
			if rebuilt || view.over_built != okey {
				view.over_built = okey
				build_overlay(view, cx, cy, scale)
			}
			if len(view.over) > 0 {
				rl.DrawTrianglesClipped(
					view.over[:],
					bounds.x,
					bounds.y,
					bounds.width,
					bounds.height,
				)
			}
			return
		}
	}

	stl_build_verts(
		view,
		bounds.x + bounds.width / 2,
		bounds.y + bounds.height / 2,
		min(bounds.width, bounds.height) * 0.45 * view.zoom,
	)

	texture: ^rl.Texture2D
	if view.insp.mode == .Uv_Checker && view.insp.uv != nil {
		texture = checker_texture()
	}
	rl.DrawTrianglesClipped(view.verts, bounds.x, bounds.y, bounds.width, bounds.height, texture)
	if len(view.over) > 0 {
		rl.DrawTrianglesClipped(view.over[:], bounds.x, bounds.y, bounds.width, bounds.height)
	}
}

// Only preview-modal views are ever freed; the timeline caches keep
// theirs for the session.
stl_view_free :: proc(view: ^Stl_View) {
	fbx_free(&view.insp)
	delete(view.over)
	delete(view.tris)
	delete(view.norms)
	delete(view.rot)
	delete(view.shade)
	delete(view.order)
	delete(view.verts)
	delete(view.pix)
	delete(view.zbuf)
	rl.UnloadTexture(view.raster_tex)
	free(view)
}

default_orbit :: proc() -> Orbit {
	// WN_TEST_ORBIT="yaw,pitch" (degrees) pins the opening angle, so a
	// headless run can shoot a model from any side.
	if to := os.get_env("WN_TEST_ORBIT", context.temp_allocator); to != "" {
		if comma := strings.index_byte(to, ','); comma > 0 {
			yaw, _ := strconv.parse_f32(to[:comma])
			pitch, _ := strconv.parse_f32(to[comma + 1:])
			return {
				yaw = yaw * math.PI / 180,
				pitch = pitch * math.PI / 180,
				zoom = 1,
				dirty = true,
			}
		}
	}
	// Slight top-down tilt so a flat model reads as 3D.
	return {yaw = 0.6, pitch = -0.4, zoom = 1, dirty = true}
}

// Hover is recorded during the layout build (clay.Hovered inside the
// tile) and consumed by the input pass; drag state spans frames. All
// 3D tile kinds share these.
orbit_hover: ^Orbit
orbit_drag: ^Orbit
orbit_grab: rl.Vector2

// The timeline model tile under the pointer, rebound every build like
// att_hover: a press that never turns into a drag opens the preview
// modal on that same attachment, so a model sent on its own reaches
// the inspector without going through an archive.
Model_Ref :: struct {
	msg_id: string,
	att:    int,
	name:   string,
}
model_hover: Model_Ref
orbit_moved: bool // the press became an orbit drag, so it is not a click

// Orbit drag + wheel zoom; runs after layout like the other handlers.
// The frame loop feeds clay a zeroed wheel while a tile is hovered so
// zooming doesn't also scroll the timeline.
handle_orbit :: proc() {
	mouse := rl.GetMousePosition()
	// att_hover set = the press is on the download chip, not the model.
	if rl.IsMouseButtonPressed(.LEFT) && orbit_hover != nil && att_hover.msg_id == "" {
		orbit_drag = orbit_hover
		orbit_grab = mouse
		orbit_moved = false
	}

	if orbit_drag != nil {
		if rl.IsMouseButtonDown(.LEFT) {
			dx := (mouse.x - orbit_grab.x) / UI_ZOOM
			dy := (mouse.y - orbit_grab.y) / UI_ZOOM
			if dx != 0 || dy != 0 {
				orbit_drag.yaw += dx * STL_ORBIT_SPEED
				orbit_drag.pitch = clamp(
					orbit_drag.pitch + dy * STL_ORBIT_SPEED,
					-math.PI / 2,
					math.PI / 2,
				)
				orbit_drag.dirty = true
				orbit_grab = mouse
				orbit_moved = true
			}
		} else {
			orbit_drag = nil
		}
	}

	if orbit_hover != nil {
		wheel := rl.GetMouseWheelMoveV().y
		if wheel != 0 {
			orbit_hover.zoom = clamp(
				orbit_hover.zoom * math.pow(f32(STL_ZOOM_STEP), wheel),
				STL_ZOOM_MIN,
				STL_ZOOM_MAX,
			)
		}
	}
}
