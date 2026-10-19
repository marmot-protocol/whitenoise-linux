package sdlrl

import "core:c"
import "core:math"
import sdl "vendor:sdl3"

// Set by the theme capability, never by a theme name. Material stays fixed:
// neither drawing nor texture generation reads the clock or schedules frames.
ChalkDrawn: bool

@(private)
CHALK_GRAIN_SIDE :: 1024
@(private)
chalk_grain, chalk_stroke: ^sdl.Texture

@(private)
chalk_hash :: proc(value: u32) -> u32 {
	h := value * 0x9e3779b9
	h ~= h >> 16
	h *= 0x85ebca6b
	h ~= h >> 13
	return h
}

@(private)
Chalk_Texture :: enum {
	Grain,
	Stroke,
}

@(private)
chalk_texture :: proc(kind: Chalk_Texture) -> ^sdl.Texture {
	stroke := kind == .Stroke
	cached := stroke ? &chalk_stroke : &chalk_grain
	if cached^ != nil {return cached^}
	w, h := stroke ? 256 : CHALK_GRAIN_SIDE, stroke ? 16 : CHALK_GRAIN_SIDE
	// One initialization per renderer/reload, not a CPU image pass per frame.
	pixels := make([]u8, w * h * 4, context.temp_allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			i := (y * w + x) * 4
			noise := chalk_hash(u32(y * w + x))
			if stroke {
				center := 7.5 + f32(chalk_hash(u32(x / 7)) % 5) * 0.15 - 0.3
				d := math.abs(f32(y) - center) / 7.5
				coverage := max(1 - d, 0)
				grain := 0.52 + f32(noise % 100) / 210
				pixels[i], pixels[i + 1], pixels[i + 2] = 255, 255, 255
				pixels[i + 3] = u8(255 * coverage * coverage * grain)
			} else {
				// Fine slate pits plus broad, overlapping eraser wipe bands.
				wipe := 7 * math.sin(f32(y) * 0.061 + 0.7 * math.sin(f32(x) * 0.011))
				value := u8(clamp(237 + wipe - f32(noise % 27), 199, 250))
				pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3] = value, value, value, 255
			}
		}
	}
	cached^ = sdl.CreateTexture(state.renderer, .RGBA32, .STATIC, c.int(w), c.int(h))
	track_texture(cached^)
	if cached^ != nil {
		sdl.UpdateTexture(cached^, nil, raw_data(pixels), c.int(w * 4))
		sdl.SetTextureBlendMode(cached^, {.BLEND})
		sdl.SetTextureScaleMode(cached^, .LINEAR)
	}
	return cached^
}

@(private)
chalk_color :: proc(color: Color) -> sdl.FColor {
	return {f32(color.r) / 255, f32(color.g) / 255, f32(color.b) / 255, f32(color.a) / 255}
}

@(private)
chalk_vertex :: proc(px, py, x, y, w, h: f32, color: sdl.FColor) -> sdl.Vertex {
	return {
		position  = {px, py},
		color     = color,
		// Crop a material sample instead of stretching a whole grain tile into
		// every tiny button. Larger panels retain fine grain at normal DPI.
		tex_coord = {
			(px - x) / max(w, f32(CHALK_GRAIN_SIDE)),
			(py - y) / max(h, f32(CHALK_GRAIN_SIDE)),
		},
	}
}

@(private)
chalk_surface :: proc(x, y, w, h, radius: f32, color: Color) {
	if w <= 0 || h <= 0 || color.a == 0 {return}
	tex := chalk_texture(.Grain)
	fc := chalk_color(color)
	if radius <= 0 {
		vertices := [4]sdl.Vertex {
			chalk_vertex(x, y, x, y, w, h, fc),
			chalk_vertex(x + w, y, x, y, w, h, fc),
			chalk_vertex(x + w, y + h, x, y, w, h, fc),
			chalk_vertex(x, y + h, x, y, w, h, fc),
		}
		indices := [6]c.int{0, 1, 2, 0, 2, 3}
		sdl.RenderGeometry(state.renderer, tex, &vertices[0], 4, &indices[0], 6)
		return
	}
	vertices: [70]sdl.Vertex
	indices: [204]c.int
	n := 1
	vertices[0] = chalk_vertex(x + w / 2, y + h / 2, x, y, w, h, fc)
	r := clamp(radius, 0, min(w, h) / 2)
	centers := [4][2]f32 {
		{x + w - r, y + r},
		{x + w - r, y + h - r},
		{x + r, y + h - r},
		{x + r, y + r},
	}
	for center, corner in centers {
		for i in 0 ..= 16 {
			a := (-math.PI / 2 + f32(corner) * math.PI / 2) + f32(i) * math.PI / 32
			vertices[n] = chalk_vertex(
				center.x + math.cos(a) * r,
				center.y + math.sin(a) * r,
				x,
				y,
				w,
				h,
				fc,
			)
			n += 1
		}
	}
	for i in 0 ..< n - 1 {
		indices[i * 3], indices[i * 3 + 1], indices[i * 3 + 2] =
			0, c.int(i + 1), c.int(i == n - 2 ? 1 : i + 2)
	}
	sdl.RenderGeometry(
		state.renderer,
		tex,
		&vertices[0],
		c.int(n),
		&indices[0],
		c.int((n - 1) * 3),
	)
	// Filled pills and buttons do not all emit Clay borders. Their paint edge
	// still belongs to the same chalk medium as bordered cards and fields.
	if color.a >= 160 && w >= 12 && h >= 12 {
		ink := Color {
			u8(min(int(color.r) + 80, 255)),
			u8(min(int(color.g) + 80, 255)),
			u8(min(int(color.b) + 80, 255)),
			u8(u32(color.a) * 45 / 100),
		}
		chalk_line(x + r, y + 0.6, x + w - r, y + 0.6, 1.2, ink)
		chalk_line(x + r, y + h - 0.6, x + w - r, y + h - 0.6, 1.2, ink)
		chalk_line(x + 0.6, y + r, x + 0.6, y + h - r, 1.2, ink)
		chalk_line(x + w - 0.6, y + r, x + w - 0.6, y + h - r, 1.2, ink)
		chalk_arc(x + r, y + r, r, 180, 270, 1.2, ink)
		chalk_arc(x + w - r, y + r, r, 270, 360, 1.2, ink)
		chalk_arc(x + r, y + h - r, r, 90, 180, 1.2, ink)
		chalk_arc(x + w - r, y + h - r, r, 0, 90, 1.2, ink)
	}
}

// Rough center stroke and soft powdered edges. All geometry is stack-backed;
// long lines are submitted in bounded chunks rather than allocated per control.
@(private)
chalk_line :: proc(x1, y1, x2, y2, thickness: f32, color: Color) {
	dx, dy := x2 - x1, y2 - y1
	length := math.sqrt(dx * dx + dy * dy)
	if length <= 0 || color.a == 0 {return}
	tex := chalk_texture(.Stroke)
	nx, ny := -dy / length, dx / length
	half := max(thickness, 1.2) * 1.15
	count := max(1, int(math.ceil(length / 9)))
	fc := chalk_color(color)
	vertices: [32 * 6]sdl.Vertex
	used := 0
	for i in 0 ..< count {
		points: [4][2]f32
		for end in 0 ..< 2 {
			t := f32(i + end) / f32(count)
			offset :=
				(f32(chalk_hash(u32(i + end)) % 101) / 100 - 0.5) * min(thickness, 1.4) * 0.52
			cx, cy := x1 + dx * t + nx * offset, y1 + dy * t + ny * offset
			points[end * 2] = {cx + nx * half, cy + ny * half}
			points[end * 2 + 1] = {cx - nx * half, cy - ny * half}
		}
		for corner, k in ([6]int{0, 1, 2, 1, 3, 2}) {
			vertices[used + k] = {
				position  = {points[corner].x, points[corner].y},
				color     = fc,
				tex_coord = {f32((i % 16) + corner / 2) / 16, f32(corner % 2)},
			}
		}
		used += 6
		if used == len(vertices) || i == count - 1 {
			sdl.RenderGeometry(state.renderer, tex, &vertices[0], c.int(used), nil, 0)
			used = 0
		}
	}
}

@(private)
chalk_arc :: proc(cx, cy, radius, start_deg, end_deg, thickness: f32, color: Color) {
	if radius <= 0 || thickness <= 0 || color.a == 0 {return}
	tex := chalk_texture(.Stroke)
	fc := chalk_color(color)
	vertices: [64 * 6]sdl.Vertex
	count := clamp(
		int(math.ceil(radius * math.abs(end_deg - start_deg) * math.PI / 180 / 5)),
		8,
		64,
	)
	half := max(thickness, 1.2) * 1.15
	for i in 0 ..< count {
		points: [4][2]f32
		for end in 0 ..< 2 {
			a := (start_deg + (end_deg - start_deg) * f32(i + end) / f32(count)) * math.PI / 180
			offset := (f32(chalk_hash(u32(i + end)) % 101) / 100 - 0.5) * 0.28
			r := radius - thickness / 2 + offset
			for side in 0 ..< 2 {
				rr := r + (side == 0 ? half : -half)
				points[end * 2 + side] = {cx + math.cos(a) * rr, cy + math.sin(a) * rr}
			}
		}
		for corner, k in ([6]int{0, 1, 2, 1, 3, 2}) {
			vertices[i * 6 + k] = {
				position  = {points[corner].x, points[corner].y},
				color     = fc,
				tex_coord = {f32((i % 16) + corner / 2) / 16, f32(corner % 2)},
			}
		}
	}
	sdl.RenderGeometry(state.renderer, tex, &vertices[0], c.int(count * 6), nil, 0)
}
