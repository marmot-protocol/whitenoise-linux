package main

import "core:mem"
import "core:strings"

import rl "sdlrl"

@(private)
Avatar_Shape :: enum {
	Circle,
	Rounded,
	Square,
}

@(private)
AVATAR_SHAPE_NAMES := [Avatar_Shape]string {
	.Circle  = N_("Circle"),
	.Rounded = N_("Rounded"),
	.Square  = N_("Square"),
}

@(private = "file")
avatar_sources: map[^rl.Texture2D]rl.Image

@(private = "file")
Avatar_Mask_Key :: struct {
	source:   ^rl.Texture2D,
	shape:    string,
	material: Avatar_Material,
}

@(private = "file")
Avatar_Material :: enum {
	Natural,
	Light_Ink,
	Dark_Ink,
}

@(private = "file")
avatar_masks: map[Avatar_Mask_Key]^rl.Texture2D

// Keep square pixels so changing the mask never clips an already round picture.
// 256px covers profile avatars at 2x density without retaining full-size photos.
// CPU only, so the picture worker crops off the UI thread.
@(private)
photo_square :: proc(image: rl.Image) -> ([]u8, i32) {
	side := min(image.width, image.height)
	n := min(side, 256)
	ox, oy := (image.width - side) / 2, (image.height - side) / 2
	pixels := make([]u8, int(n * n * 4))
	for y in 0 ..< n {
		for x in 0 ..< n {
			src := ((oy + y * side / n) * image.width + ox + x * side / n) * 4
			dst := (y * n + x) * 4
			copy(pixels[dst:dst + 4], image.data[src:src + 4])
		}
	}
	return pixels, n
}

// Upload a square photo as a round texture. Takes ownership of the pixels,
// kept for the other mask shapes.
@(private)
photo_install :: proc(pixels: []u8, n: i32, shape: string = "circle") -> ^rl.Texture2D {
	tex := new(rl.Texture2D)
	image := rl.Image {
		data   = raw_data(pixels),
		width  = n,
		height = n,
	}
	avatar_sources[tex] = image
	if shape == "square" {
		tex^ = rl.LoadTextureFromImage(image)
		return tex
	}
	round := avatar_mask_pixels(image, "circle")
	defer delete(round)
	tex^ = rl.LoadTextureFromImage({data = raw_data(round), width = n, height = n})
	return tex
}

@(private)
forget_avatar :: proc(tex: ^rl.Texture2D) {
	if image, found := avatar_sources[tex]; found {
		mem.zero_slice(image.data[:image.width * image.height * 4])
		delete(image.data[:image.width * image.height * 4])
		delete_key(&avatar_sources, tex)
	}
	for key, variant in avatar_masks {
		if key.source != tex {continue}
		rl.UnloadTexture(variant^)
		free(variant)
		delete(key.shape)
		delete_key(&avatar_masks, key)
	}
}

@(private)
shaped_avatar :: proc(tex: ^rl.Texture2D, shape: string) -> ^rl.Texture2D {
	if tex == nil || shape == "" || (shape == "circle" && !CHALK_DRAWN) {return tex}
	image, found := avatar_sources[tex]
	if !found {return tex}
	material :=
		CHALK_DRAWN ? (ink_on(BG) == WHITE ? Avatar_Material.Light_Ink : .Dark_Ink) : Avatar_Material.Natural
	key := Avatar_Mask_Key{tex, shape, material}
	if variant, cached := avatar_masks[key]; cached {return variant}
	pixels := avatar_mask_pixels(image, shape)
	defer delete(pixels)
	if material != .Natural {avatar_sketch_pixels(image, pixels, material)}
	variant := new(rl.Texture2D)
	variant^ = rl.LoadTextureFromImage(
		{data = raw_data(pixels), width = image.width, height = image.height},
	)
	avatar_masks[{tex, strings.clone(shape), material}] = variant
	return variant
}

// Smooth photographic noise before tracing contours. Pigment follows the face;
// fixed, broken hatching and paper pores supply the drawing's shading.
@(private = "file")
avatar_sketch_pixels :: proc(image: rl.Image, pixels: []u8, material: Avatar_Material) {
	n := int(image.width)
	light := make([]f32, n * n, context.temp_allocator)
	for y in 0 ..< n {
		for x in 0 ..< n {
			value: f32
			for dy in -1 ..= 1 {
				for dx in -1 ..= 1 {
					i := (clamp(y + dy, 0, n - 1) * n + clamp(x + dx, 0, n - 1)) * 4
					value +=
						(f32(image.data[i]) * 3 +
							f32(image.data[i + 1]) * 6 +
							f32(image.data[i + 2])) /
						10
				}
			}
			light[y * n + x] = value / 9
		}
	}
	for y in 0 ..< n {
		for x in 0 ..< n {
			i := (y * n + x) * 4
			if pixels[i + 3] == 0 {continue}
			left, right := max(x - 1, 0), min(x + 1, n - 1)
			top, bottom := max(y - 1, 0), min(y + 1, n - 1)
			gx :=
				light[top * n + right] +
				2 * light[y * n + right] +
				light[bottom * n + right] -
				light[top * n + left] -
				2 * light[y * n + left] -
				light[bottom * n + left]
			gy :=
				light[bottom * n + left] +
				2 * light[bottom * n + x] +
				light[bottom * n + right] -
				light[top * n + left] -
				2 * light[top * n + x] -
				light[top * n + right]
			contour := clamp((abs(gx) + abs(gy) - 22) / 190, 0, 1)
			shade := light[y * n + x]
			h := u32(x / 11 + (y / 11) * n) * 0x9e3779b9
			h ~= h >> 16
			stroke :=
				((x + y + int(h % 3)) % 8 <= 1 && shade < 220) ||
				((x - y + n + int(h % 3)) % 9 == 0 && shade < 105)
			if stroke && h % 7 != 0 {contour = max(contour, 0.48)}
			grain := u32(x + y * n) * 0x85ebca6b
			grain ~= grain >> 13
			for channel in 0 ..< 3 {
				pigment := f32(image.data[i + channel]) * 0.72 + shade * 0.08 + 38
				ink := material == .Light_Ink ? f32(238) : f32(32)
				value := pigment * (1 - contour) + ink * contour
				value *= 0.83 + f32(grain % 18) / 100
				pixels[i + channel] = u8(clamp(value, 0, 255))
			}
			pixels[i + 3] = u8(u32(pixels[i + 3]) * (grain % 29 == 0 ? 150 : 235) / 255)
		}
	}
}

@(private)
avatar_mask_pixels :: proc(image: rl.Image, shape: string) -> []u8 {
	n := image.width
	out := make([]u8, int(n * n * 4))
	copy(out, image.data[:len(out)])
	mask: rl.Image
	if shape != "circle" && shape != "rounded" && shape != "square" {mask = emoji_image(shape)}
	defer rl.UnloadImage(mask)
	left, top, right, bottom := mask.width, mask.height, i32(-1), i32(-1)
	for y in 0 ..< mask.height {
		for x in 0 ..< mask.width {
			if mask.data[(y * mask.width + x) * 4 + 3] <= 25 {continue}
			left, top, right, bottom = min(left, x), min(top, y), max(right, x), max(bottom, y)
		}
	}
	side := max(right - left + 1, bottom - top + 1)
	left -= (side - (right - left + 1)) / 2
	top -= (side - (bottom - top + 1)) / 2
	for y in 0 ..< n {
		for x in 0 ..< n {
			coverage: f32 = 1
			if side > 0 {
				mx, my := left + x * side / n, top + y * side / n
				coverage = 0
				if mx >= 0 &&
				   mx < mask.width &&
				   my >= 0 &&
				   my <
					   mask.height {coverage = f32(mask.data[(my * mask.width + mx) * 4 + 3]) / 255}
			} else if shape != "square" {
				radius := shape == "rounded" ? f32(n) * 0.2 : f32(n) / 2
				dx := max(abs(f32(x) + 0.5 - f32(n) / 2) - (f32(n) / 2 - radius), 0)
				dy := max(abs(f32(y) + 0.5 - f32(n) / 2) - (f32(n) / 2 - radius), 0)
				coverage = dx * dx + dy * dy <= radius * radius ? 1 : 0
			}
			out[(y * n + x) * 4 + 3] = u8(f32(out[(y * n + x) * 4 + 3]) * coverage)
		}
	}
	return out
}
