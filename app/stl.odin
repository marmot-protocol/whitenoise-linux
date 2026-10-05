// Mesh chat attachments are decoded by isolated helpers, then drawn
// through a clay Custom command. The stack has no 3D API, so every
// model rasterizes on the CPU with a real z-buffer into a streaming
// texture; a still model costs one texture draw per frame.
//
//   stl_view_make ─→ unit-sphere tris, face normals, and for models
//                    over MESH_FRAME_TRIS a clustered stand-in (once)
//   stl_draw: key (size, zoom, yaw, pitch) changed?
//        small model: rasterize every triangle now
//        big model:   rasterize the stand-in now, then the full mesh
//                     in MESH_REFINE_BUDGET slices on later frames
//   handle_orbit: drag = orbit, wheel = zoom (over the tile)
//
// Each pass forks one thread per strip set of rows (up to 8). On 8
// threads at a 600 px tile: a 104k-triangle stand-in takes ~5 ms, a
// 135k-triangle model ~4 ms, and a 1.2M-triangle mesh refines in five
// frames, so dragging, zooming and opening never wait on the full mesh.
package main

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Parent independently enforces the helper's triangle budget.
STL_MAX_TRIS :: 2_000_000

STL_ORBIT_SPEED :: 0.012 // radians per layout px of drag
STL_ZOOM_STEP :: 1.15 // zoom factor per wheel notch
STL_ZOOM_MIN :: 0.3
STL_ZOOM_MAX :: 10.0
STL_BASE :: rl.FColor{0.78, 0.80, 0.84, 1} // neutral resin gray

// Most triangles one frame rasterizes. A model under it renders whole
// on every change; a bigger one shows a stand-in of at most this many
// first.
MESH_FRAME_TRIS :: 150_000

// Per-frame time the full-mesh refinement may take, shared by every
// model on screen, so refining frames stay inside 60 fps.
MESH_REFINE_BUDGET :: 6 * time.Millisecond

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

// One rendered mesh (STL, OBJ, FBX or GLB). tris/norms/proxy are
// computed once at parse; rot and the raster rebuild per pass.
Stl_View :: struct {
	kind:        Model_Kind, // .Mesh; must stay the first field
	using orbit: Orbit,
	tris:        []f32, // ntri * 9 vertex floats, unit-sphere normalized
	norms:       []f32, // ntri * 3 unit face normals
	rot:         []f32, // view-space tris, same layout, written by the full pass
	proxy:       Mesh_Proxy, // empty for models under MESH_FRAME_TRIS
	// View-space axes expressed in model space, set per pass. Corners
	// rotate by them, and the inspector dots vertex normals against
	// them instead of rotating a second normal buffer.
	basis:       [3][3]f32,
	insp:        Inspect, // render mode, overlays, FBX channels + animation
	over:        [dynamic]rl.Vertex, // overlay quads (wireframe / normals)

	// Software z-buffer raster. `built` is the pass key (rw, rh, zoom,
	// yaw, pitch); clearing it forces a new pass after a color change.
	// raster_tex shows the last finished picture while a big model's
	// full pass fills pix over several frames.
	built:       [5]f32,
	rotated:     bool, // the full pass has filled rot
	refined:     bool, // the full pass is done and on raster_tex
	strip_next:  [RASTER_THREADS_MAX]int, // full pass progress per strip set
	pass_time:   time.Duration, // synchronous cost of the last full-size pass start
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

// Decimated stand-in for a big model, drawn while the full mesh is
// still rasterizing. All slices are per triangle, 9 floats each for
// pos/nrm/rot. Built from the rest pose.
Mesh_Proxy :: struct {
	pos: []f32, // model-space corners
	nrm: []f32, // smooth model-space corner normals
	rot: []f32, // pos in view space for the current pass
	src: []i32, // the full triangle each one takes material colors from
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


stl_view_make :: proc(tris: []f32) -> ^Stl_View {
	ntri := len(tris) / 9
	view := new(Stl_View)
	view^ = {
		kind = .Mesh,
		orbit = default_orbit(),
		tris = tris,
		norms = make([]f32, ntri * 3),
		rot = make([]f32, len(tris)),
		insp = {wire = -1, anim = -1},
	}
	stl_face_normals(view)
	view.proxy = mesh_proxy(tris, view.norms)
	return view
}

// The stand-in, by vertex clustering: snap every corner to a grid
// cell, merge each cell's corners into one vertex at their centroid
// with their averaged face normal, and keep the triangles whose
// corners land in three cells. Interpolating those smooth normals is
// what hides the coarse triangles. The grid coarsens until the result
// fits MESH_FRAME_TRIS. Runs where the view is made, off the UI thread.
@(private = "file")
mesh_proxy :: proc(tris, norms: []f32) -> (proxy: Mesh_Proxy) {
	ntri := len(tris) / 9
	if ntri <= MESH_FRAME_TRIS {
		return
	}

	sum := make([dynamic][3]f32, context.temp_allocator) // corner positions per vertex
	nrm := make([dynamic][3]f32, context.temp_allocator) // face normals per vertex
	count := make([dynamic]f32, context.temp_allocator)
	faces := make([dynamic][3]i32, context.temp_allocator) // vertex triples
	src := make([dynamic]i32, context.temp_allocator)
	for grid := 160; grid >= 8; grid = grid * 7 / 8 {
		cells := make([]i32, grid * grid * grid, context.temp_allocator)
		slice.fill(cells, -1)
		clear(&sum)
		clear(&nrm)
		clear(&count)
		clear(&faces)
		clear(&src)

		for tri in 0 ..< ntri {
			n := [3]f32{norms[tri * 3], norms[tri * 3 + 1], norms[tri * 3 + 2]}
			face: [3]i32
			for k in 0 ..< 3 {
				p := [3]f32 {
					tris[tri * 9 + k * 3],
					tris[tri * 9 + k * 3 + 1],
					tris[tri * 9 + k * 3 + 2],
				}
				// Unit-sphere coordinates: [-1, 1] to [0, grid) per axis.
				cell := 0
				for axis in 0 ..< 3 {
					at := int((p[axis] + 1) * 0.5 * f32(grid))
					cell = cell * grid + clamp(at, 0, grid - 1)
				}
				if cells[cell] < 0 {
					cells[cell] = i32(len(sum))
					append(&sum, [3]f32{})
					append(&nrm, [3]f32{})
					append(&count, 0)
				}
				v := cells[cell]
				sum[v] += p
				count[v] += 1
				// STL winding is unreliable: align each normal with the
				// cell's running sum so flipped faces don't cancel out.
				nrm[v] += linalg.dot(nrm[v], n) < 0 ? -n : n
				face[k] = v
			}
			if face[0] != face[1] && face[1] != face[2] && face[0] != face[2] {
				append(&faces, face)
				append(&src, i32(tri))
				if len(faces) > MESH_FRAME_TRIS {
					break // over budget: try a coarser grid
				}
			}
		}
		if len(faces) <= MESH_FRAME_TRIS {
			break
		}
	}

	proxy = {
		pos = make([]f32, len(faces) * 9),
		nrm = make([]f32, len(faces) * 9),
		rot = make([]f32, len(faces) * 9),
		src = slice.clone(src[:]),
	}
	for face, i in faces {
		for v, k in face {
			at := i * 9 + k * 3
			p := sum[v] / count[v]
			n := linalg.normalize0(nrm[v])
			copy(proxy.pos[at:at + 3], p[:])
			copy(proxy.nrm[at:at + 3], n[:])
		}
	}
	return
}

// Unit face normals from the current triangle positions; the raster
// passes rotate these instead of re-deriving them from edges every
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

@(private)
ORBIT_RASTER_SIZE :: 256 // longest edge while dragging; full resolution returns on release

// A view whose full-size pass (the stand-in, or a whole small model)
// took longer than this drags at ORBIT_RASTER_SIZE instead.
@(private)
ORBIT_PASS_BUDGET :: 8 * time.Millisecond

// The triangles one pass draws: the full mesh, or the stand-in.
@(private = "file")
Raster_Mesh :: struct {
	pos, rot: []f32, // model- and view-space corners, 9 floats per triangle
	// Stand-in only: smooth corner normals, and the full triangle each
	// takes material colors from. Stand-ins skip textures, since their
	// corners have no UVs.
	nrm:      []f32,
	src:      []i32,
}

// Passes fork up to this many threads and join them before returning,
// so no raster thread outlives a frame or a reload.
@(private = "file")
RASTER_THREADS_MAX :: 8

// Threads own interleaved strips of this many rows, which keeps them
// evenly loaded when the model fills only the middle of the tile.
@(private = "file")
RASTER_STRIP :: 8

// One thread's share of a pass: a triangle range to rotate, or a set of
// strips to rasterize every triangle of the pass into.
@(private = "file")
Raster_Job :: struct {
	view:        ^Stl_View,
	mesh:        Raster_Mesh,
	first, last: int, // rotate: this thread's triangles
	band:        int, // raster: rows whose strip % threads == band
	threads:     int,
	deadline:    time.Tick, // raster: stop here and resume next frame; {} = never
}

// Probed once, not a syscall per pass.
@(private = "file")
raster_thread_count: int

@(private = "file")
raster_threads :: proc() -> int {
	if raster_thread_count == 0 {
		raster_thread_count = clamp(os.get_processor_core_count(), 1, RASTER_THREADS_MAX)
	}
	return raster_thread_count
}

// Size the buffers to the tile and clear them for a new pass.
@(private = "file")
raster_clear :: proc(view: ^Stl_View, w, h: i32) {
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
}

// View-space z of a triangle's face normal; negative faces away.
// Only Single Sided culls on it: STL winding is unreliable, so the
// shading itself takes |nz|.
@(private)
tri_facing :: proc(view: ^Stl_View, tri: int) -> f32 {
	n, b := view.norms[tri * 3:tri * 3 + 3], view.basis[2]
	return n[0] * b[0] + n[1] * b[1] + n[2] * b[2]
}

// Narrow a row span [lo, hi] (pixel-center x) to where a + b * x >= 0.
@(private = "file")
span_clip :: proc(span: ^[2]f32, a, b: f32) {
	switch {
	case b > 0:
		span[0] = max(span[0], -a / b)
	case b < 0:
		span[1] = min(span[1], -a / b)
	case a < 0:
		span^ = {1, 0} // never true on this row
	}
}

// One view-space triangle of the job's mesh into the job's strips of
// pix, with a depth test. Colors are looked up at the first pixel the
// triangle wins: most triangles of a dense mesh win none.
@(private = "file")
raster_tri :: proc(job: ^Raster_Job, i: int) {
	view, mesh := job.view, job.mesh
	w, h := view.rw, view.rh
	cx, cy := f32(w) / 2, f32(h) / 2
	scale := f32(min(w, h)) * 0.45 * view.zoom

	// Screen-space corners; z stays in view units for the test.
	p := mesh.rot[i * 9:i * 9 + 9]
	x0 := cx + p[0] * scale
	y0 := cy - p[1] * scale
	z0 := p[2]
	x1 := cx + p[3] * scale
	y1 := cy - p[4] * scale
	z1 := p[5]
	x2 := cx + p[6] * scale
	y2 := cy - p[7] * scale
	z2 := p[8]

	// Most triangles of a dense mesh sit inside one strip, so every
	// thread but its owner drops them here.
	lo_y := clamp(int(math.floor(min(y0, y1, y2))), 0, int(h) - 1)
	hi_y := clamp(int(math.ceil(max(y0, y1, y2))), 0, int(h) - 1)
	if lo_y / RASTER_STRIP == hi_y / RASTER_STRIP &&
	   (lo_y / RASTER_STRIP) % job.threads != job.band {
		return
	}

	tri := mesh.src == nil ? i : int(mesh.src[i])
	if view.insp.single_sided && tri_facing(view, tri) < 0 {
		return
	}

	area := (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
	if area == 0 {
		return
	}
	inv := 1 / area

	lo_x := clamp(int(math.floor(min(x0, x1, x2))), 0, int(w) - 1)
	hi_x := clamp(int(math.ceil(max(x0, x1, x2))), 0, int(w) - 1)
	if lo_x > hi_x || lo_y > hi_y {
		return
	}

	full := mesh.src == nil
	checker := full && view.insp.mode == .Uv_Checker && view.insp.uv != nil
	textured := full && len(view.insp.images) > 0
	cell := f32(CHECKER_SQUARES)
	shaded := false
	colors: [3]rl.FColor
	uvs: [3][2]f32
	basis: [5][3]f32

	for py in lo_y ..= hi_y {
		if (py / RASTER_STRIP) % job.threads != job.band {
			continue
		}
		fy := f32(py) + 0.5
		row := py * int(w)

		// Barycentric weights; signs flip with winding, so inside = all
		// three on the same side as the area. Along a row each is
		// linear in x (a + b * fx), so the row is clipped to where all
		// three are >= 0 and no pixel outside the triangle is visited.
		a0, b0 := (x1 * (y2 - fy) - x2 * (y1 - fy)) * inv, (y1 - y2) * inv
		a1, b1 := (x2 * (y0 - fy) - x0 * (y2 - fy)) * inv, (y2 - y0) * inv
		span := [2]f32{f32(lo_x) + 0.5, f32(hi_x) + 0.5}
		span_clip(&span, a0, b0)
		span_clip(&span, a1, b1)
		span_clip(&span, 1 - a0 - a1, -b0 - b1)
		for px in int(math.ceil(span[0] - 0.5)) ..= int(math.floor(span[1] - 0.5)) {
			fx := f32(px) + 0.5
			w0 := a0 + b0 * fx
			w1 := a1 + b1 * fx
			w2 := 1 - w0 - w1
			// Rounding at the span ends can still land a hair outside.
			if w0 < 0 || w1 < 0 || w2 < 0 {
				continue
			}
			z := w0 * z0 + w1 * z1 + w2 * z2
			if z <= view.zbuf[row + px] {
				continue
			}
			if !shaded {
				shaded = true
				normals: [3][3]f32
				if full {
					normals = model_corner_normals(view, tri)
				} else {
					for k in 0 ..< 3 {
						normals[k] = view_space(view.basis, mesh.nrm[i * 9 + k * 3:])
					}
				}
				colors = model_vert_colors(view, tri, normals)
				if checker {
					uvs = model_vert_uvs(view, tri)
				} else if textured {
					for k in 0 ..< 3 {
						uvs[k] = {view.insp.uv[tri * 6 + k * 2], view.insp.uv[tri * 6 + k * 2 + 1]}
					}
					if view.insp.mode == .Final {basis = model_texture_basis(view, tri)}
				}
			}
			r := w0 * colors[0].r + w1 * colors[1].r + w2 * colors[2].r
			g := w0 * colors[0].g + w1 * colors[1].g + w2 * colors[2].g
			b := w0 * colors[0].b + w1 * colors[1].b + w2 * colors[2].b
			alpha := w0 * colors[0].a + w1 * colors[1].a + w2 * colors[2].a
			if checker {
				u := w0 * uvs[0][0] + w1 * uvs[1][0] + w2 * uvs[2][0]
				v := w0 * uvs[0][1] + w1 * uvs[1][1] + w2 * uvs[2][1]
				// 16 squares across the unit UV square,
				// clamped rather than tiled.
				iu := int(clamp(u, 0, 0.9999) * cell)
				iv := int(clamp(v, 0, 0.9999) * cell)
				tone := (iu + iv) % 2 == 0 ? f32(220.0 / 255.0) : f32(90.0 / 255.0)
				r *= tone
				g *= tone
				b *= tone
			} else if textured {
				uv := uvs[0] * w0 + uvs[1] * w1 + uvs[2] * w2
				color := model_texture_color(view, tri, uv, {w0, w1, w2}, basis, {r, g, b, alpha})
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

// Model space to view space through the pass's basis rows: yaw about
// Y, then pitch about X, +z facing the viewer. `v` starts at x.
@(private = "file")
view_space :: #force_inline proc(b: [3][3]f32, v: []f32) -> [3]f32 {
	x, y, z := v[0], v[1], v[2]
	return {
		b[0][0] * x + b[0][1] * y + b[0][2] * z,
		b[1][0] * x + b[1][1] * y + b[1][2] * z,
		b[2][0] * x + b[2][1] * y + b[2][2] * z,
	}
}

// Rotate the job's triangles into view space.
@(private = "file")
rotate_job :: proc(job: ^Raster_Job) {
	b, mesh := job.view.basis, job.mesh
	for at := job.first * 9; at < job.last * 9; at += 3 {
		p := view_space(b, mesh.pos[at:])
		mesh.rot[at], mesh.rot[at + 1], mesh.rot[at + 2] = p[0], p[1], p[2]
	}
}

// Rasterize the job's strips from triangle `first` on, until done or
// past the deadline; `first` is left where the next frame resumes.
@(private = "file")
strip_job :: proc(shared: ^Raster_Job) {
	// A local copy: the jobs sit side by side in one array, and bumping
	// `first` there per triangle bounced their cache lines between
	// cores on every read of view and mesh.
	job := shared^
	defer shared.first = job.first
	for job.first < job.last {
		raster_tri(&job, job.first)
		job.first += 1
		// The clock is read every 4096 triangles; per triangle it
		// would cost about as much as the triangle.
		if job.deadline != {} &&
		   job.first % 4096 == 0 &&
		   time.tick_diff(job.deadline, time.tick_now()) > 0 {
			return
		}
	}
}

// Run one job per thread and wait for all of them.
@(private = "file")
fork_join :: proc(jobs: []Raster_Job, work: proc(job: ^Raster_Job)) {
	workers: [RASTER_THREADS_MAX]^thread.Thread
	for &job, t in jobs {
		workers[t] = thread.create_and_start_with_poly_data(&job, work)
	}
	for worker in workers[:len(jobs)] {
		thread.join(worker)
		thread.destroy(worker)
	}
}

// Rotate a whole mesh, one triangle range per thread.
@(private = "file")
raster_rotate :: proc(view: ^Stl_View, mesh: Raster_Mesh) {
	n := raster_threads()
	count := len(mesh.pos) / 9
	per := (count + n - 1) / n
	jobs: [RASTER_THREADS_MAX]Raster_Job
	for &job, t in jobs[:n] {
		job = {
			view  = view,
			mesh  = mesh,
			first = min(t * per, count),
			last  = min((t + 1) * per, count),
		}
	}
	fork_join(jobs[:n], rotate_job)
}

// Rasterize a rotated mesh, one strip set per thread, each resuming at
// next[band]. Done once every strip set has drawn every triangle.
@(private = "file")
raster_strips :: proc(
	view: ^Stl_View,
	mesh: Raster_Mesh,
	next: []int,
	deadline: time.Tick,
) -> (
	done: bool,
) {
	n := raster_threads()
	count := len(mesh.pos) / 9
	jobs: [RASTER_THREADS_MAX]Raster_Job
	for &job, t in jobs[:n] {
		job = {
			view     = view,
			mesh     = mesh,
			first    = next[t],
			last     = count,
			band     = t,
			threads  = n,
			deadline = deadline,
		}
	}
	fork_join(jobs[:n], strip_job)

	done = true
	for job, t in jobs[:n] {
		next[t] = job.first
		done &&= job.first == count
	}
	return
}

// One refinement deadline per frame for every model on screen, so two
// big tiles share MESH_REFINE_BUDGET instead of each taking it.
@(private = "file")
refine_frame: u32
@(private = "file")
refine_deadline: time.Tick

// Clay renderer hook for the Custom command, clipped to the tile so
// zoom can't bleed over neighboring rows.
stl_draw :: proc(view: ^Stl_View, bounds: clay.BoundingBox) {
	w := i32(bounds.width * UI_SCALE / UI_ZOOM)
	h := i32(bounds.height * UI_SCALE / UI_ZOOM)
	// Drags stay sharp unless the last full-size pass was too slow to
	// redo every frame (a slow machine, or per-pixel texture sampling).
	downscaled :=
		orbit_drag == &view.orbit &&
		orbit_moved &&
		view.pass_time > ORBIT_PASS_BUDGET &&
		max(w, h) > ORBIT_RASTER_SIZE
	if downscaled {
		ratio := f32(ORBIT_RASTER_SIZE) / f32(max(w, h))
		w = max(1, i32(f32(w) * ratio))
		h = max(1, i32(f32(h) * ratio))
	}
	if w <= 0 || h <= 0 {
		return
	}

	// A new key starts a pass. A big model puts its stand-in on screen
	// in this frame and leaves the full mesh to later ones.
	// ponytail: the stand-in is built from the rest pose, so a posed
	// FBX skips it and rasterizes in full every change; re-cluster the
	// posed tris if a big animated model shows up.
	full := Raster_Mesh {
		pos = view.tris,
		rot = view.rot,
	}
	stand_in := len(view.proxy.src) > 0 && !view.insp.posed
	key := [5]f32{f32(w), f32(h), view.zoom, view.yaw, view.pitch}
	started := view.built != key
	pass_start := time.tick_now()
	if started {
		view.built = key
		cy, sy := math.cos(view.yaw), math.sin(view.yaw)
		cp, sp := math.cos(view.pitch), math.sin(view.pitch)
		view.basis = {{cy, 0, sy}, {sy * sp, cp, -cy * sp}, {-sy * cp, sp, cy * cp}}
		view.rotated, view.refined, view.strip_next = false, false, {}
		raster_clear(view, w, h)
		if stand_in {
			proxy := Raster_Mesh {
				pos = view.proxy.pos,
				rot = view.proxy.rot,
				nrm = view.proxy.nrm,
				src = view.proxy.src,
			}
			next: [RASTER_THREADS_MAX]int
			raster_rotate(view, proxy)
			raster_strips(view, proxy, next[:], {})
			rl.UpdateTexturePixels(&view.raster_tex, raw_data(view.pix))
			raster_clear(view, w, h)
		}
	}

	// Small models finish in one go; a big one's full pass spends the
	// frame's shared budget and shows only once complete.
	finished := false
	if !view.refined && !(started && stand_in) {
		deadline: time.Tick
		if stand_in {
			if refine_frame != anim_frame || refine_deadline == {} {
				refine_frame = anim_frame
				refine_deadline = time.tick_add(time.tick_now(), MESH_REFINE_BUDGET)
			}
			deadline = refine_deadline
		}
		if !view.rotated {
			raster_rotate(view, full)
			view.rotated = true
		}
		finished = raster_strips(view, full, view.strip_next[:], deadline)
		view.refined = finished
		if finished {
			rl.UpdateTexturePixels(&view.raster_tex, raw_data(view.pix))
		}
	}
	if started && !downscaled {
		view.pass_time = time.tick_since(pass_start)
	}
	if !view.refined {
		anim_moving += 1 // keep frames coming until the full pass lands
	}

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
	if finished || view.over_built != okey {
		view.over_built = okey
		build_overlay(view, cx, cy, scale)
	}
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
	delete(view.proxy.pos)
	delete(view.proxy.nrm)
	delete(view.proxy.rot)
	delete(view.proxy.src)
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
