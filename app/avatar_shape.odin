package main

import "core:strings"

import rl "sdlrl"

@(private)
Avatar_Shape :: enum { Circle, Rounded, Square }

@(private)
AVATAR_SHAPE_NAMES := [Avatar_Shape]string{.Circle = N_("Circle"), .Rounded = N_("Rounded"), .Square = N_("Square")}

@(private = "file")
avatar_sources: map[^rl.Texture2D]rl.Image

@(private = "file")
Avatar_Mask_Key :: struct { source: ^rl.Texture2D, shape: string }

@(private = "file")
avatar_masks: map[Avatar_Mask_Key]^rl.Texture2D

// Keep square pixels so changing the mask never clips an already round picture.
// 256px covers profile avatars at 2x density without retaining full-size photos.
@(private)
photo_texture :: proc(image: rl.Image) -> ^rl.Texture2D {
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
	tex := new(rl.Texture2D)
	image := rl.Image{data = raw_data(pixels), width = n, height = n}
	avatar_sources[tex] = image
	round := avatar_mask_pixels(image, "circle")
	defer delete(round)
	tex^ = rl.LoadTextureFromImage({data = raw_data(round), width = n, height = n})
	return tex
}

@(private)
forget_avatar :: proc(tex: ^rl.Texture2D) {
	if image, found := avatar_sources[tex]; found {
		delete(image.data[:image.width * image.height * 4])
		delete_key(&avatar_sources, tex)
	}
	for key, variant in avatar_masks {
		if key.source != tex { continue }
		rl.UnloadTexture(variant^)
		free(variant)
		delete(key.shape)
		delete_key(&avatar_masks, key)
	}
}

@(private)
shaped_avatar :: proc(tex: ^rl.Texture2D, shape: string) -> ^rl.Texture2D {
	if tex == nil || shape == "" || shape == "circle" { return tex }
	image, found := avatar_sources[tex]
	if !found { return tex }
	key := Avatar_Mask_Key{tex, shape}
	if variant, cached := avatar_masks[key]; cached { return variant }
	pixels := avatar_mask_pixels(image, shape)
	defer delete(pixels)
	variant := new(rl.Texture2D)
	variant^ = rl.LoadTextureFromImage({data = raw_data(pixels), width = image.width, height = image.height})
	avatar_masks[{tex, strings.clone(shape)}] = variant
	return variant
}

@(private)
avatar_mask_pixels :: proc(image: rl.Image, shape: string) -> []u8 {
	n := image.width
	out := make([]u8, int(n * n * 4))
	copy(out, image.data[:len(out)])
	mask: rl.Image
	if shape != "circle" && shape != "rounded" && shape != "square" { mask = emoji_image(shape) }
	defer rl.UnloadImage(mask)
	left, top, right, bottom := mask.width, mask.height, i32(-1), i32(-1)
	for y in 0 ..< mask.height {
		for x in 0 ..< mask.width {
			if mask.data[(y * mask.width + x) * 4 + 3] <= 25 { continue }
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
				if mx >= 0 && mx < mask.width && my >= 0 && my < mask.height { coverage = f32(mask.data[(my * mask.width + mx) * 4 + 3]) / 255 }
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
