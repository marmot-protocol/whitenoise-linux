package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:math"
import rl "sdlrl"
import sdl "vendor:sdl3"

@(private)
STICKER_IMAGE :: uintptr(1)
@(private)
STICKER_GRID :: 24

@(private)
sticker_masks: map[^sdl.Texture]rl.Texture2D

@(private)
sticker_texture_load :: proc(image: rl.Image) -> rl.Texture2D {
	art := rl.LoadTextureFromImage(image)
	if art.tex == nil {return art}
	// A white alpha mask lets foil reflect its own colors, even over black ink.
	pixels := make([][4]u8, int(image.width * image.height), context.temp_allocator)
	source := ([^][4]u8)(image.data)
	for &pixel, i in pixels {pixel = {255, 255, 255, source[i][3]}}
	mask := rl.LoadTextureFromImage(
		{data = ([^]u8)(raw_data(pixels)), width = image.width, height = image.height},
	)
	if mask.tex != nil {sticker_masks[art.tex] = mask}
	return art
}

@(private)
sticker_texture_free :: proc(tex: rl.Texture2D) {
	if mask, found := sticker_masks[tex.tex]; found {
		rl.UnloadTexture(mask)
		delete_key(&sticker_masks, tex.tex)
	}
	rl.UnloadTexture(tex)
}

// Tessellation approximates perspective with SDL's affine textured triangles.
// The artwork and foil share UVs, so transparent cutouts stay transparent.
@(private)
sticker_vertex :: proc(u, v: f32, box: clay.BoundingBox, tilt: rl.Vector2) -> rl.Vertex {
	x, y := (u - 0.5) * box.width, (v - 0.5) * box.height
	sx, cx := math.sin(tilt.y * 0.32), math.cos(tilt.y * 0.32)
	sy, cy := math.sin(-tilt.x * 0.32), math.cos(-tilt.x * 0.32)
	z := y * sx
	rx, ry, rz := x * cy + z * sy, y * cx, -x * sy + z * cy
	distance := max(box.width, box.height) * 2.5
	perspective := distance / (distance - rz)
	return {
		position = {
			box.x + box.width / 2 + rx * perspective,
			box.y + box.height / 2 + ry * perspective,
		},
		tex_coord = {u, v},
		color = {1, 1, 1, 1},
	}
}

@(private)
sticker_draw :: proc(tex: ^rl.Texture2D, box: clay.BoundingBox, id: u32, tint: rl.Color) {
	if tex == nil || box.width <= 0 || box.height <= 0 {return}
	active := motion_on() && clay.PointerOver({id = id})
	pointer := clay.GetPointerState().position
	target: rl.Vector2
	if active {
		target = {
			clamp(2 * (pointer.x - box.x) / box.width - 1, -1, 1),
			clamp(2 * (pointer.y - box.y) / box.height - 1, -1, 1),
		}
	}
	tilt := rl.Vector2{anim_to(anim_key(id, 31), target.x), anim_to(anim_key(id, 32), target.y)}
	strength := anim_to(anim_key(id, 33), active ? 1 : 0)
	if !motion_on() || strength < ANIM_EPS {
		rl.DrawTextureRect(tex, box.x, box.y, box.width, box.height, tint)
		return
	}
	grid: [(STICKER_GRID + 1) * (STICKER_GRID + 1)]rl.Vertex
	foil: [len(grid)]rl.FColor
	for y in 0 ..= STICKER_GRID {
		for x in 0 ..= STICKER_GRID {
			u, v := f32(x) / STICKER_GRID, f32(y) / STICKER_GRID
			i := y * (STICKER_GRID + 1) + x
			grid[i] = sticker_vertex(u, v, box, tilt)
			grid[i].color = {
				f32(tint.r) / 255,
				f32(tint.g) / 255,
				f32(tint.b) / 255,
				f32(tint.a) / 255,
			}
			// Angle-dependent spectral bands, a broad light, and fine foil facets.
			phase := u * 1.3 + v * 0.9 + tilt.x * 0.7 + tilt.y * 0.5
			rainbow := hsv((phase - math.floor(phase)) * 360, 0.8, 1)
			dx, dy := u - (0.5 + tilt.x * 0.3), v - (0.5 + tilt.y * 0.3)
			glare := math.pow(max(0, 1 - (dx * dx + dy * dy) * 2.5), 5)
			facet := math.pow(max(0, math.sin(f32(x * 17 + y * 29) + phase * 9)), 18)
			light := strength * (0.26 + 0.20 * facet)
			foil[i] = {
				(rainbow.r / 255 * light + glare * strength * 0.24) * f32(tint.r) / 255,
				(rainbow.g / 255 * light + glare * strength * 0.24) * f32(tint.g) / 255,
				(rainbow.b / 255 * light + glare * strength * 0.24) * f32(tint.b) / 255,
				f32(tint.a) / 255,
			}
		}
	}
	vertices: [STICKER_GRID * STICKER_GRID * 6]rl.Vertex
	// The additive mask samples the same alpha as the artwork and leaves
	// destination alpha unchanged, preserving the artwork's cutouts.
	for pass in 0 ..< 2 {
		texture := tex
		mask := sticker_masks[tex.tex]
		if pass == 1 {
			if mask.tex == nil || !sdl.SetTextureBlendMode(mask.tex, {.ADD}) {break}
			texture = &mask
		}
		at := 0
		for y in 0 ..< STICKER_GRID {
			for x in 0 ..< STICKER_GRID {
				i := y * (STICKER_GRID + 1) + x
				for corner in ([6]int{i, i + 1, i + STICKER_GRID + 2, i, i + STICKER_GRID + 2, i + STICKER_GRID + 1}) {
					vertices[at] = grid[corner]
					if pass == 1 {vertices[at].color = foil[corner]}
					at += 1
				}
			}
		}
		pad := max(box.width, box.height) * 0.1
		rl.DrawTrianglesClipped(
			vertices[:],
			box.x - pad,
			box.y - pad,
			box.width + 2 * pad,
			box.height + 2 * pad,
			texture,
		)
	}
}
