// The Model Inspector: the sidebar next to a model in the preview
// modal, and the per-vertex coloring every one of its modes produces.
//
// The renderer is the same painter-sorted triangle soup the STL tile
// has always drawn, so a "channel" here is a color function, not a
// shader:
//
//   model_vert_colors → one FColor per triangle corner, per mode
//   model_vert_uvs    → tex coords, only the UV-checker mode uses them
//   build_overlay     → wireframe / vertex-normal quads, drawn after
//   inspector_panel   → the sidebar itself
//
// Modes needing data a format doesn't carry (skin weights, materials,
// UVs) stay listed but unavailable, so the panel doesn't reshuffle
// between files.
package main

import "core:fmt"
import "core:math"
import "core:math/linalg"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Wireframe overlay swatches, in the order the panel shows them; the
// first entry is "off" and draws as an empty chip.
WIRE_COLORS := [7]rl.FColor {
	{0, 0, 0, 0}, // off
	{0.05, 0.05, 0.06, 1},
	{0.72, 0.74, 0.78, 1},
	{0.90, 0.24, 0.24, 1},
	{0.24, 0.45, 0.95, 1},
	{0.24, 0.78, 0.36, 1},
	{0.95, 0.85, 0.22, 1},
}

MATCAP_LIGHT :: [3]f32{-0.45, 0.62, 0.64} // upper-left key light, view space
OVERLAY_WIDTH :: 0.9 // overlay quad half-width in layout px
NORMAL_LEN :: 0.06 // vertex-normal spike length, unit-sphere units
CHECKER_SIZE :: 256 // UV-checker texture, 16 squares across
CHECKER_SQUARES :: 16

// Panel row: a mode plus the label the sidebar prints for it.
Insp_Row :: struct {
	mode:  Render_Mode,
	label: string,
}

INSP_RENDER := []Insp_Row {
	{.Final, "Final render"},
	{.Matcap, "Matcap"},
	{.Wireframe, "Wireframe"},
	{.Vertex_Normals, "Vertex normals"},
}
INSP_SKIN := []Insp_Row{{.Bones, "Bones"}, {.Bone_Influence, "Bones influence"}}
INSP_CHANNELS := []Insp_Row {
	{.Base_Color, "Base color"},
	{.Metalness, "Metalness"},
	{.Roughness, "Roughness"},
	{.Emission, "Emission"},
	{.Specular, "Specular F0"},
}
INSP_UV := []Insp_Row{{.Uv_Checker, "UV checker"}}

// One panel section. The id prefix keys both the layout and the click
// pass, so they can't drift apart.
Insp_Section :: struct {
	id:    string,
	label: string,
	rows:  []Insp_Row,
}

INSP_SECTIONS := []Insp_Section {
	{"MiRender", "RENDER", INSP_RENDER},
	{"MiSkin", "SKIN", INSP_SKIN},
	{"MiChan", "MATERIAL CHANNELS", INSP_CHANNELS},
	{"MiUv", "UV", INSP_UV},
}

// A mode is unavailable when the file carries no data for it.
mode_ready :: proc(view: ^Stl_View, mode: Render_Mode) -> bool {
	insp := &view.insp
	#partial switch mode {
	case .Bones, .Bone_Influence:
		return insp.bone != nil
	case .Base_Color, .Metalness, .Roughness, .Emission, .Specular:
		return insp.mats != nil
	case .Uv_Checker:
		return insp.uv != nil
	case .Wireframe, .Vertex_Normals:
		return len(view.tris) / 9 <= WIRE_MAX_TRIS
	}
	return true
}

// ── Per-vertex color ────────────────────────────────────────────────

// View-space normal of one corner. FBX carries real per-vertex
// normals, so its models shade smooth; STL/OBJ fall back to the face
// normal and stay faceted, which is what those formats describe.
@(private = "file")
corner_normal :: proc(view: ^Stl_View, tri, k: int) -> [3]f32 {
	n: [3]f32
	if view.insp.vnrm != nil {
		at := tri * 9 + k * 3
		n = {view.insp.vnrm[at], view.insp.vnrm[at + 1], view.insp.vnrm[at + 2]}
	} else {
		n = {view.norms[tri * 3], view.norms[tri * 3 + 1], view.norms[tri * 3 + 2]}
	}
	// Model space to view space: dot against the rotation rows.
	return {
		n[0] * view.basis[0][0] + n[1] * view.basis[0][1] + n[2] * view.basis[0][2],
		n[0] * view.basis[1][0] + n[1] * view.basis[1][1] + n[2] * view.basis[1][2],
		n[0] * view.basis[2][0] + n[1] * view.basis[2][1] + n[2] * view.basis[2][2],
	}
}

// Headlight term, the same 0.25 ambient floor the flat path used.
@(private = "file")
lambert :: proc(n: [3]f32) -> f32 {
	return 0.25 + 0.75 * abs(n[2])
}

// The material row for a triangle, or a neutral stand-in.
@(private = "file")
material_of :: proc(view: ^Stl_View, tri: int) -> []f32 {
	insp := &view.insp
	if insp.mats == nil || insp.mat == nil || tri >= len(insp.mat) {
		return nil
	}
	index := int(insp.mat[tri])
	if index < 0 || (index + 1) * FBX_MAT_FLOATS > len(insp.mats) {
		return nil
	}
	return insp.mats[index * FBX_MAT_FLOATS:(index + 1) * FBX_MAT_FLOATS]
}

// Distinct-enough hue per bone index, so a skeleton reads as bands.
@(private = "file")
bone_color :: proc(index: int) -> [3]f32 {
	if index < 0 {
		return {0.35, 0.35, 0.38}
	}
	// Golden-ratio hue steps, straight to RGB through a 3-phase wave.
	hue := f32(index) * 0.61803399
	hue -= math.floor(hue)
	wave :: proc(t: f32) -> f32 {
		return clamp(abs(t - math.floor(t) - 0.5) * 6 - 1, 0, 1)
	}
	return {wave(hue), wave(hue + 1.0 / 3.0), wave(hue + 2.0 / 3.0)}
}

// Blue → green → red heat ramp for weight views.
@(private = "file")
heat :: proc(t: f32) -> [3]f32 {
	v := clamp(t, 0, 1)
	return {
		clamp(v * 2 - 0.6, 0, 1),
		clamp(1 - abs(v - 0.5) * 2.2, 0, 1),
		clamp(1.2 - v * 2.4, 0, 1),
	}
}

// One color per corner of a triangle: the whole inspector, per mode.
model_vert_colors :: proc(view: ^Stl_View, tri: int) -> [3]rl.FColor {
	insp := &view.insp
	mat := material_of(view, tri)
	out: [3]rl.FColor

	for k in 0 ..< 3 {
		n := corner_normal(view, tri, k)
		g := lambert(n)
		rgb: [3]f32

		switch insp.mode {
		case .Final:
			base := [3]f32{STL_BASE.r, STL_BASE.g, STL_BASE.b}
			if mat != nil {
				base = {mat[0], mat[1], mat[2]}
			}
			rgb = {base[0] * g, base[1] * g, base[2] * g}

		case .Bones:
			influence := insp.bone != nil ? int(insp.bone[tri * 3 + k]) : -1
			c := bone_color(influence)
			rgb = {c[0] * g, c[1] * g, c[2] * g}

		case .Bone_Influence:
			weight := insp.bwt != nil ? insp.bwt[tri * 3 + k] : 0
			c := heat(weight)
			rgb = {c[0] * g, c[1] * g, c[2] * g}

		case .Base_Color:
			rgb = mat != nil ? [3]f32{mat[0], mat[1], mat[2]} : {0.5, 0.5, 0.5}

		case .Metalness:
			v := mat != nil ? mat[3] : 0
			rgb = {v, v, v}

		case .Roughness:
			v := mat != nil ? mat[4] : 0
			rgb = {v, v, v}

		case .Emission:
			rgb = mat != nil ? [3]f32{mat[5], mat[6], mat[7]} : {0, 0, 0}

		case .Specular:
			rgb = mat != nil ? [3]f32{mat[8], mat[9], mat[10]} : {0.04, 0.04, 0.04}

		case .Matcap:
			// Studio ball: a key light plus a rim term, both from the
			// view-space normal, which is what a matcap texture bakes.
			key := max(0, n[0] * MATCAP_LIGHT[0] + n[1] * MATCAP_LIGHT[1] + n[2] * MATCAP_LIGHT[2])
			rim := math.pow(1 - abs(n[2]), 3)
			v := clamp(0.10 + 0.75 * key * key + 0.35 * rim, 0, 1)
			rgb = {v, v * 0.99, v * 0.96}

		case .Wireframe:
			// Surface drops back so the overlay lines carry the read.
			rgb = {0.10 * g, 0.11 * g, 0.13 * g}

		case .Vertex_Normals:
			rgb = {0.16 * g, 0.17 * g, 0.20 * g}

		case .Uv_Checker:
			// The checker texture supplies the pattern; the vertex
			// color only shades it.
			rgb = insp.uv != nil ? [3]f32{g, g, g} : {0.5 * g, 0.5 * g, 0.5 * g}
		}

		alpha := f32(1)
		if mat != nil && (insp.mode == .Final || insp.mode == .Base_Color) {
			alpha = mat[11]
		}
		out[k] = {rgb[0], rgb[1], rgb[2], alpha}
	}
	return out
}

// Tex coords for the UV-checker pass, zeroed for every other mode.
// ponytail: UVs outside [0,1] clamp instead of tiling (the SDL
// binding exposes no wrap mode), so a tiled unwrap shows a stretched
// band at the seam.
model_vert_uvs :: proc(view: ^Stl_View, tri: int) -> [3][2]f32 {
	insp := &view.insp
	if insp.mode != .Uv_Checker || insp.uv == nil {
		return {}
	}
	out: [3][2]f32
	for k in 0 ..< 3 {
		at := tri * 6 + k * 2
		out[k] = {insp.uv[at], 1 - insp.uv[at + 1]} // FBX V runs up, textures down
	}
	return out
}

// ── Overlays ────────────────────────────────────────────────────────

// Wireframe edges and vertex-normal spikes, as thin screen-space
// quads appended to a second buffer. Built with the main vertex
// buffer, so it follows the same rebuild key.
build_overlay :: proc(view: ^Stl_View, cx, cy, scale: f32) {
	clear(&view.over)
	insp := &view.insp
	wire := insp.wire > 0 || insp.mode == .Wireframe
	normals := insp.mode == .Vertex_Normals
	ntri := len(view.tris) / 9
	if (!wire && !normals) || ntri > WIRE_MAX_TRIS {
		return
	}

	color := insp.wire > 0 ? WIRE_COLORS[insp.wire] : rl.FColor{0.72, 0.74, 0.78, 1}
	if normals {
		color = {0.45, 0.72, 1, 1}
	}

	for idx in view.order {
		tri := int(idx)
		if insp.single_sided && view.shade[tri] < 0 {
			continue
		}
		at := tri * 9

		// Screen position of each corner, matching stl_build_verts.
		p: [3]rl.Vector2
		for k in 0 ..< 3 {
			p[k] = {cx + view.rot[at + k * 3] * scale, cy - view.rot[at + k * 3 + 1] * scale}
		}

		if wire {
			for k in 0 ..< 3 {
				push_quad(&view.over, p[k], p[(k + 1) % 3], color)
			}
		}
		if normals {
			for k in 0 ..< 3 {
				n := corner_normal(view, tri, k)
				tip := rl.Vector2 {
					p[k].x + n[0] * NORMAL_LEN * scale,
					p[k].y - n[1] * NORMAL_LEN * scale,
				}
				push_quad(&view.over, p[k], tip, color)
			}
		}
	}
}

// One screen-space segment as two triangles; the renderer has no line
// primitive and this reuses the geometry call already in flight.
@(private = "file")
push_quad :: proc(out: ^[dynamic]rl.Vertex, a, b: rl.Vector2, color: rl.FColor) {
	dx, dy := b.x - a.x, b.y - a.y
	length := math.sqrt(dx * dx + dy * dy)
	if length <= 0 {
		return
	}
	nx, ny := -dy / length * OVERLAY_WIDTH, dx / length * OVERLAY_WIDTH
	v0 := rl.Vertex {
		position = {a.x + nx, a.y + ny},
		color    = color,
	}
	v1 := rl.Vertex {
		position = {a.x - nx, a.y - ny},
		color    = color,
	}
	v2 := rl.Vertex {
		position = {b.x + nx, b.y + ny},
		color    = color,
	}
	v3 := rl.Vertex {
		position = {b.x - nx, b.y - ny},
		color    = color,
	}
	append(out, v0, v1, v2, v2, v1, v3)
}

// The UV-checker texture, built once and kept for the session.
checker_tex: rl.Texture2D
checker_ready: bool

checker_texture :: proc() -> ^rl.Texture2D {
	if checker_ready {
		return &checker_tex
	}
	pixels := make([]u8, CHECKER_SIZE * CHECKER_SIZE * 4)
	defer delete(pixels)
	cell := CHECKER_SIZE / CHECKER_SQUARES
	for y in 0 ..< CHECKER_SIZE {
		for x in 0 ..< CHECKER_SIZE {
			light := ((x / cell) + (y / cell)) % 2 == 0
			shade: u8 = light ? 220 : 90
			at := (y * CHECKER_SIZE + x) * 4
			pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3] = shade, shade, shade, 255
		}
	}
	checker_tex = rl.CreateStreamTexture(CHECKER_SIZE, CHECKER_SIZE)
	rl.UpdateTexturePixels(&checker_tex, raw_data(pixels))
	checker_ready = true
	return &checker_tex
}

// ── Panel ───────────────────────────────────────────────────────────

INSP_WIDTH :: 196

// The sidebar, `height` layout px tall. A file with many takes makes
// the list longer than the modal allows, so the column scrolls on its
// own: the model beside it stays put while the panel moves.
inspector_panel :: proc(view: ^Stl_View, height: f32) {
	if clay.UI(clay.ID("MiPanel"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(INSP_WIDTH), height = clay.SizingFixed(height)},
			padding = clay.PaddingAll(10),
			childGap = 8,
		},
		backgroundColor = PLATE,
		cornerRadius = rr(8),
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		clay.Text("Model inspector", {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})

		insp_caption("MiWireCap", "WIREFRAME", len(WIRE_COLORS) - 1)
		if clay.UI(clay.ID("MiWireRow"))(
		{layout = {childGap = 4, sizing = {width = clay.SizingGrow()}}},
		) {
			for color, i in WIRE_COLORS {
				on := view.insp.wire == i || (i == 0 && view.insp.wire <= 0)
				if clay.UI(clay.ID("MiWire", u32(i)))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(20), height = clay.SizingFixed(20)},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = i == 0 ? ROW_BG : {color.r * 255, color.g * 255, color.b * 255, 255},
					cornerRadius = rr(4),
					border = {color = on ? ACCENT : ELEVATED_BORDER, width = bw()},
				},
				) {
					if i == 0 {
						clay.Text(
							ICON_CLOSE,
							{fontId = FONT_ICON, fontSize = 9, textColor = TEXT_DIM},
						)
					}
				}
			}
		}

		insp_toggle_row(view)

		for section in INSP_SECTIONS {
			insp_section(view, section)
		}

		if len(view.insp.takes) > 0 {
			insp_animation(view)
		}
	}
	scrollbar(clay.ID("MiPanel"))
}

// ALL-CAPS eyebrow with the count of pickable rows, as in the rest of
// the settings panes.
@(private = "file")
insp_caption :: proc(id: string, label: string, count: int) {
	if clay.UI(clay.ID(id))({layout = {padding = {top = 4}}}) {
		clay.Text(
			fmt.tprintf("%s (%d)", label, count),
			{fontId = FONT_BODY, fontSize = 9, textColor = TEXT_DIM},
		)
	}
}

// Caption plus one row per mode. Unavailable rows stay visible and
// dimmed, so the panel keeps its shape across files.
@(private = "file")
insp_section :: proc(view: ^Stl_View, section: Insp_Section) {
	ready := 0
	for row in section.rows {
		if mode_ready(view, row.mode) {
			ready += 1
		}
	}
	insp_caption(fmt.tprintf("%sCap", section.id), section.label, ready)

	for row, i in section.rows {
		available := mode_ready(view, row.mode)
		selected := view.insp.mode == row.mode
		if clay.UI(clay.ID(section.id, u32(i)))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				padding = {left = 6, right = 6, top = 5, bottom = 5},
				childAlignment = {y = .Center},
			},
			backgroundColor = selected ? ACCENT : (available && hovered() ? HOVER : ROW_BG),
			cornerRadius = rr(6),
		},
		) {
			color := selected ? PLATE : (available ? TEXT : TEXT_DIM)
			clay.Text(row.label, {fontId = FONT_BODY, fontSize = 11, textColor = color})
		}
	}
}

@(private = "file")
insp_toggle_row :: proc(view: ^Stl_View) {
	if clay.UI(clay.ID("MiSingle"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {left = 6, right = 6, top = 5, bottom = 5},
			childGap = 8,
			childAlignment = {y = .Center},
		},
		backgroundColor = hovered() ? HOVER : ROW_BG,
		cornerRadius = rr(6),
	},
	) {
		on := view.insp.single_sided
		if clay.UI(clay.ID("MiSingleSw"))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(28), height = clay.SizingFixed(16)},
				padding = clay.PaddingAll(2),
				childAlignment = {x = on ? .Right : .Left, y = .Center},
			},
			backgroundColor = on ? ACCENT : ROW_BG,
			cornerRadius = rr(8),
			border = {color = ELEVATED_BORDER, width = bw()},
		},
		) {
			if clay.UI(clay.ID("MiSingleKnob"))(
			{
				layout = {sizing = {width = clay.SizingFixed(12), height = clay.SizingFixed(12)}},
				backgroundColor = on ? PLATE : TEXT_DIM,
				cornerRadius = rr(6),
			},
			) {}
		}
		clay.Text("Single sided", {fontId = FONT_BODY, fontSize = 11, textColor = TEXT})
	}
}

// ANIMATION section: one row per take, then a transport line with
// play/pause and a scrub bar over the take's own time range.
@(private = "file")
insp_animation :: proc(view: ^Stl_View) {
	insp := &view.insp
	insp_caption("MiAnimCap", "ANIMATION", len(insp.takes))

	for take, i in insp.takes {
		selected := insp.anim == i
		if clay.UI(clay.ID("MiTake", u32(i)))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				padding = {left = 6, right = 6, top = 5, bottom = 5},
				childAlignment = {y = .Center},
			},
			backgroundColor = selected ? ACCENT : (hovered() ? HOVER : ROW_BG),
			cornerRadius = rr(6),
		},
		) {
			label := len(take) > 0 ? take : fmt.tprintf("Take %d", i + 1)
			clay.Text(
				label,
				{fontId = FONT_BODY, fontSize = 11, textColor = selected ? PLATE : TEXT},
			)
		}
	}

	if insp.anim < 0 {
		return
	}

	if clay.UI(clay.ID("MiTransport"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {top = 4},
			childGap = 8,
			childAlignment = {y = .Center},
		},
	},
	) {
		if clay.UI(clay.ID("MiPlay"))(
		{
			layout = {padding = {left = 8, right = 8, top = 4, bottom = 4}},
			backgroundColor = hovered() ? HOVER : ROW_BG,
			cornerRadius = rr(6),
		},
		) {
			clay.Text(
				insp.playing ? "Pause" : "Play",
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT},
			)
		}
		span := insp.t1 - insp.t0
		clay.Text(
			fmt.tprintf("%.2fs / %.2fs", insp.time - insp.t0, span),
			{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_DIM},
		)
	}

	bar_id := clay.ID("MiBar")
	append(&anim_bars, Anim_Bar{bar_id, view})
	width: f32 = INSP_WIDTH - 20
	frac := f32((insp.time - insp.t0) / max(insp.t1 - insp.t0, 0.001))
	if clay.UI(bar_id)(
	{
		layout = {
			sizing = {width = clay.SizingFixed(width), height = clay.SizingFixed(12)},
			padding = {left = 2, right = 2},
			childAlignment = {y = .Center},
		},
		backgroundColor = ROW_BG,
		cornerRadius = rr(6),
	},
	) {
		if clay.UI(clay.ID("MiBarFill"))(
		{
			layout = {
				sizing = {
					width = clay.SizingFixed(max(8, frac * (width - 4))),
					height = clay.SizingFixed(8),
				},
			},
			backgroundColor = ACCENT,
			cornerRadius = rr(4),
		},
		) {}
	}
}

// Scrub-bar drag registry, same shape as the g-code slider: bars
// re-register every build, the pressed state spans frames.
Anim_Bar :: struct {
	id:   clay.ElementId,
	view: ^Stl_View,
}

anim_bars: [dynamic]Anim_Bar
anim_bar_drag: Anim_Bar

// Panel clicks. Runs after layout, like every other handler here.
handle_inspector :: proc(view: ^Stl_View) {
	if view == nil {
		return
	}
	insp := &view.insp

	for section in INSP_SECTIONS {
		for row, i in section.rows {
			if !clicked_id(clay.ID(section.id, u32(i))) {
				continue
			}
			if mode_ready(view, row.mode) {
				insp.mode = row.mode
				view.built = {} // colors changed; rebuild the buffer
			}
			return
		}
	}

	for i in 0 ..< len(WIRE_COLORS) {
		if clicked_id(clay.ID("MiWire", u32(i))) {
			insp.wire = i
			view.built = {}
			return
		}
	}

	if clicked("MiSingle") {
		insp.single_sided = !insp.single_sided
		view.built = {}
		return
	}

	for i in 0 ..< len(insp.takes) {
		if !clicked_id(clay.ID("MiTake", u32(i))) {
			continue
		}
		// Tapping the open take stops it; the panel keeps the pose.
		if insp.anim == i {
			insp.playing = !insp.playing
			return
		}
		fbx_select_take(view, i)
		insp.playing = true
		return
	}

	if clicked("MiPlay") {
		insp.playing = !insp.playing
	}
}

// Drag anywhere on the bar to scrub; scrubbing pauses playback so the
// pose stays where it was dropped.
handle_anim_bar :: proc() {
	if rl.IsMouseButtonPressed(.LEFT) {
		for bar in anim_bars {
			if clay.PointerOver(bar.id) {
				anim_bar_drag = bar
				break
			}
		}
	}
	if anim_bar_drag.view == nil {
		return
	}
	if !rl.IsMouseButtonDown(.LEFT) {
		anim_bar_drag = {}
		return
	}

	view := anim_bar_drag.view
	bb := clay.GetElementData(anim_bar_drag.id).boundingBox
	if bb.width <= 0 {
		return
	}
	frac := clamp((rl.GetMousePosition().x / UI_ZOOM - bb.x) / bb.width, 0, 1)
	insp := &view.insp
	insp.playing = false
	insp.time = insp.t0 + f64(frac) * (insp.t1 - insp.t0)
	fbx_pose(view, insp.time)
}

// clicked() takes a string; the generated section/index ids need the
// same test against an already-built id.
@(private = "file")
clicked_id :: proc(id: clay.ElementId) -> bool {
	return mouse_released() && clay.PointerOver(id)
}

// View-space normals and tangent frame, computed once per textured triangle.
@(private)
model_texture_basis :: proc(view: ^Stl_View, tri: int) -> [5][3]f32 {
	out: [5][3]f32
	for k in 0 ..< 3 {out[k] = corner_normal(view, tri, k)}
	at := tri * 9
	e1 :=
		[3]f32{view.rot[at + 3], view.rot[at + 4], view.rot[at + 5]} -
		[3]f32{view.rot[at], view.rot[at + 1], view.rot[at + 2]}
	e2 :=
		[3]f32{view.rot[at + 6], view.rot[at + 7], view.rot[at + 8]} -
		[3]f32{view.rot[at], view.rot[at + 1], view.rot[at + 2]}
	uv := view.insp.uv[tri * 6:tri * 6 + 6]
	d1 := [2]f32{uv[2] - uv[0], uv[3] - uv[1]}
	d2 := [2]f32{uv[4] - uv[0], uv[5] - uv[1]}
	det := d1[0] * d2[1] - d1[1] * d2[0]
	if abs(det) > 0.000001 {
		out[3] = linalg.normalize0((e1 * d2[1] - e2 * d1[1]) / det)
		out[4] = linalg.normalize0((e2 * d1[0] - e1 * d2[0]) / det)
	}
	return out
}

@(private)
model_texture_color :: proc(
	view: ^Stl_View,
	tri: int,
	uv: [2]f32,
	weights: [3]f32,
	basis: [5][3]f32,
	fallback: rl.FColor,
) -> rl.FColor {
	index := int(view.insp.mat[tri])
	if index < 0 || index >= len(view.insp.textures) {return fallback}
	textures := &view.insp.textures[index]
	mode := view.insp.mode
	channel: Fbx_Channel
	#partial switch mode {
	case .Final, .Base_Color:
		channel = .Base_Color
	case .Metalness:
		channel = .Metalness
	case .Roughness:
		channel = .Roughness
	case .Emission:
		channel = .Emission
	case .Specular:
		channel = .Specular
	case:
		return fallback
	}
	color := [4]f32{fallback.r, fallback.g, fallback.b, fallback.a}
	if textures[channel].image.data != nil {
		color = fbx_sample_texture(&textures[channel], uv)
		if channel == .Metalness || channel == .Roughness {
			color = {color[0], color[0], color[0], 1}
		}
	}
	if mode == .Final {
		mat := material_of(view, tri)
		if textures[.Base_Color].image.data == nil {
			color = {mat[0], mat[1], mat[2], mat[11]}
		}
		n := linalg.normalize0(
			basis[0] * weights[0] + basis[1] * weights[1] + basis[2] * weights[2],
		)
		if textures[.Normal].image.data != nil && linalg.dot(basis[3], basis[3]) > 0 {
			sample := fbx_sample_texture(&textures[.Normal], uv)
			tangent := linalg.normalize0(basis[3] - n * linalg.dot(n, basis[3]))
			bitangent := linalg.cross(n, tangent)
			if linalg.dot(bitangent, basis[4]) < 0 {bitangent = -bitangent}
			n = linalg.normalize0(
				tangent * (sample[0] * 2 - 1) +
				bitangent * (sample[1] * 2 - 1) +
				n * (sample[2] * 2 - 1),
			)
		}
		g := lambert(n)
		for k in 0 ..< 3 {color[k] *= g}
		if textures[.Emission].image.data != nil {
			emission := fbx_sample_texture(&textures[.Emission], uv)
			for k in 0 ..< 3 {color[k] += emission[k]}
		}
	}
	return {color[0], color[1], color[2], color[3]}
}
