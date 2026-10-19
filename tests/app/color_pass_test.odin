package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import rl "sdlrl"

@(test)
whole_view_color_pass :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "whole_view_color_pass" {return}
	context.allocator = runtime.default_context().allocator
	home, err := os.make_directory_temp("", "wn-color-pass", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	old_saturation, old_noir := rl.Saturation, rl.Noir
	defer {rl.Saturation = old_saturation; rl.Noir = old_noir}
	old_frame := rl.NoirFrame
	defer {rl.NoirFrame = old_frame}
	rl.InitWindow(64, 32, "Whole-view color pass")
	defer rl.CloseWindow()
	rl.Noir = false
	pixels := [16]u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 128, 128, 128, 255}
	image := rl.Image {
		data   = raw_data(pixels[:]),
		width  = 4,
		height = 1,
	}
	texture := rl.LoadTextureFromImage(image)
	rl.SetTextureFilter(texture, .POINT)
	defer rl.UnloadTexture(texture)
	stream := rl.CreateStreamTexture(4, 1)
	rl.SetTextureFilter(stream, .POINT)
	defer rl.UnloadTexture(stream)
	rl.UpdateTexturePixels(&stream, raw_data(pixels[:]))
	for saturation in ([3]f32{1, 0.25, 1}) {
		rl.Saturation = saturation
		rl.BeginDrawing()
		rl.BeginMode2D({zoom = 1})
		w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
		rl.DrawTextureRect(&texture, 0, 0, w, h / 2, {255, 255, 255, 255})
		rl.DrawTextureRect(&stream, 0, h / 2, w, h / 2, {255, 255, 255, 255})
		rl.EndMode2D()
		path := fmt.ctprintf("%s/saturation-%v.png", home, saturation)
		rl.TakeScreenshot(path)
		rl.EndDrawing()
		shot := rl.LoadImage(path)
		if !testing.expect(t, shot.data != nil) {return}
		for row in 0 ..< 2 {
			for x in 0 ..< 4 {
				i := x * 4
				grey :=
					f32(pixels[i]) * 0.2126 +
					f32(pixels[i + 1]) * 0.7152 +
					f32(pixels[i + 2]) * 0.0722
				at :=
					((row * 2 + 1) * int(shot.height) / 4 * int(shot.width) +
						(x * 2 + 1) * int(shot.width) / 8) *
					4
				for channel in 0 ..< 3 {
					expected := grey * (1 - saturation) + f32(pixels[i + channel]) * saturation
					testing.expectf(
						t,
						abs(f32(shot.data[at + channel]) - expected) <= 2,
						"saturation %v texture row %d pixel %d channel %d: %d vs %.2f",
						saturation,
						row,
						x,
						channel,
						shot.data[at + channel],
						expected,
					)
				}
			}
		}
		rl.UnloadImage(shot)
	}
	rl.Saturation = 1
	rl.Noir = true
	for seed, frame in ([3]u32{0, 0, 1}) {
		rl.NoirFrame = seed
		rl.BeginDrawing()
		rl.BeginMode2D({zoom = 1})
		rl.DrawRectangleRec(
			0,
			0,
			f32(rl.GetScreenWidth()),
			f32(rl.GetScreenHeight()),
			{128, 128, 128, 255},
		)
		rl.EndMode2D()
		rl.TakeScreenshot(fmt.ctprintf("%s/noir-%d.png", home, frame))
		rl.EndDrawing()
	}
	noir := rl.LoadImage(fmt.ctprintf("%s/noir-0.png", home))
	stable := rl.LoadImage(fmt.ctprintf("%s/noir-1.png", home))
	moving := rl.LoadImage(fmt.ctprintf("%s/noir-2.png", home))
	defer {rl.UnloadImage(noir); rl.UnloadImage(stable); rl.UnloadImage(moving)}
	if !testing.expect(t, noir.data != nil && stable.data != nil && moving.data != nil) {return}
	low, high := 255, 0
	sum: u64
	changed := 0
	for i := 0; i < int(noir.width * noir.height) * 4; i += 4 {
		testing.expect(t, noir.data[i] == noir.data[i + 1] && noir.data[i] == noir.data[i + 2])
		for channel in 0 ..< 4 {testing.expect_value(t, noir.data[i + channel], stable.data[i + channel])}
		low, high = min(low, int(noir.data[i])), max(high, int(noir.data[i]))
		sum += u64(noir.data[i])
		if noir.data[i] != moving.data[i] {changed += 1}
	}
	count := int(noir.width * noir.height)
	testing.expect(t, high - low >= 20, "Film grain must remain visible on flat surfaces")
	testing.expect(
		t,
		abs(f64(sum) / f64(count) - 128) <= 2,
		"Film grain must preserve the scene's exposure",
	)
	testing.expect(t, changed > count / 3, "Advancing the film frame must move the grain")
}
