// Emoji group image: Android's layout on an opaque square JPEG.
// Run: tests/odin.sh app
package main

import "core:testing"

@(private = "file")
mix_px :: proc(draft: Pic_Draft, x, y: int) -> [3]u8 {
	i := (y * int(draft.image.width) + x) * 4
	return {draft.image.data[i], draft.image.data[i + 1], draft.image.data[i + 2]}
}

// Solid opaque tile under a fake emoji key, standing in for the pack.
@(private = "file")
mix_tile :: proc(key: string, color: [3]u8) -> []u8 {
	pixels := make([]u8, EMOJI_SIDE * EMOJI_SIDE * 4)
	for i := 0; i < len(pixels); i += 4 {
		pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3] = color.r, color.g, color.b, 255
	}
	emoji_pixels[key] = pixels
	return pixels
}

@(test)
emoji_mix_layout :: proc(t: ^testing.T) {
	RED :: [3]u8{255, 0, 0}
	BLUE :: [3]u8{0, 0, 255}
	created := emoji_pixels == nil
	red := mix_tile("mix-red", RED)
	blue := mix_tile("mix-blue", BLUE)
	defer {
		delete(red)
		delete(blue)
		delete_key(&emoji_pixels, "mix-red")
		delete_key(&emoji_pixels, "mix-blue")
		if created {
			delete(emoji_pixels)
			emoji_pixels = nil
		}
	}

	// Pixels are read from the canvas the JPEG was encoded from.
	one, ok_one := emoji_mix_render({"mix-red"})
	testing.expect(t, ok_one)
	defer pic_draft_free(&one)
	testing.expect_value(t, one.media_type, "image/jpeg")
	testing.expect_value(t, one.image.width, EMOJI_MIX_SIDE)
	testing.expect_value(t, one.image.height, EMOJI_MIX_SIDE)
	testing.expect(
		t,
		len(one.data) > 2 && one.data[0] == 0xFF && one.data[1] == 0xD8,
		"not a JPEG",
	)
	testing.expect_value(t, mix_px(one, 0, 0), EMOJI_MIX_BG)
	testing.expect_value(t, mix_px(one, 256, 256), RED)

	// Side by side with a background gap down the middle, first pick left.
	two, ok_two := emoji_mix_render({"mix-red", "mix-blue"})
	testing.expect(t, ok_two)
	defer pic_draft_free(&two)
	testing.expect_value(t, mix_px(two, 256, 256), EMOJI_MIX_BG)
	testing.expect_value(t, mix_px(two, 135, 256), RED)
	testing.expect_value(t, mix_px(two, 377, 256), BLUE)

	_, ok_three := emoji_mix_render({"mix-red", "mix-blue", "mix-red"})
	testing.expect(t, !ok_three, "at most two emoji")
	_, ok_missing := emoji_mix_render({"no-such-emoji"})
	testing.expect(t, !ok_missing, "an emoji without a tile")

	// Built-in custom artwork mixes with Unicode emoji.
	custom, ok_custom := emoji_mix_render({":marmot:", "mix-blue"})
	testing.expect(t, ok_custom, ":marmot: renders")
	defer pic_draft_free(&custom)
	testing.expect_value(t, mix_px(custom, 377, 256), BLUE)
}

// A wide custom emoji keeps its aspect: letterboxed, not stretched.
@(test)
emoji_mix_keeps_aspect :: proc(t: ^testing.T) {
	SIDE :: 64
	canvas := make([]u8, SIDE * SIDE * 4)
	defer delete(canvas)
	wide := [2 * 4]u8{255, 0, 0, 255, 255, 0, 0, 255}
	blend_tile(canvas, SIDE, {data = raw_data(wide[:]), width = 2, height = 1}, {0, 0}, SIDE)

	px :: proc(canvas: []u8, x, y: int) -> u8 {return canvas[(y * SIDE + x) * 4]}
	testing.expect_value(t, px(canvas, 32, 32), 255) // band through the middle
	testing.expect_value(t, px(canvas, 32, 4), 0) // empty above it
	testing.expect_value(t, px(canvas, 32, 60), 0) // and below
}
