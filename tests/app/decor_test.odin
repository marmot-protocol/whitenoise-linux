package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import rl "sdlrl"

// SDL rendering tests run separately because the renderer is global.
@(test)
wallpaper_proportions :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "wallpaper_proportions" {
		return
	}
	context.allocator = runtime.default_context().allocator
	home, err := os.make_directory_temp("", "wn-wallpaper", context.temp_allocator)
	if !testing.expect(t, err == nil) {
		return
	}
	defer os.remove_all(home)
	rl.InitWindow(1280, 800, "Wallpaper proportions")
	defer rl.CloseWindow()
	previous_wallpaper, previous_zoom := THEME_WALLPAPER, UI_ZOOM
	defer {THEME_WALLPAPER, UI_ZOOM = previous_wallpaper, previous_zoom}

	// A centered square exposes unequal axis scales; the red field exposes gaps.
	pixels: [128 * 80]rl.Color
	for y in 0 ..< 80 {
		for x in 0 ..< 128 {
			pixels[y * 128 + x] = {255, 0, 0, 255}
			if x >= 56 && x < 72 && y >= 32 && y < 48 {
				pixels[y * 128 + x] = {255, 255, 255, 255}
			}
		}
	}
	texture := rl.LoadTextureFromImage({cast([^]u8)raw_data(pixels[:]), 128, 80})
	defer rl.UnloadTexture(texture)
	THEME_WALLPAPER = &texture
	path := strings.clone_to_cstring(fmt.tprintf("%s/frame.png", home), context.temp_allocator)
	for size in ([][2]i32{{1280, 800}, {1680, 720}, {800, 1280}}) {
		rl.SetWindowSize(size[0], size[1])
		for zoom in ([]f32{1, 1.5}) {
			UI_ZOOM = zoom
			rl.BeginDrawing()
			rl.BeginMode2D({zoom = zoom})
			wash_draw({0, 0, f32(size[0]) / zoom, f32(size[1]) / zoom})
			rl.EndMode2D()
			rl.TakeScreenshot(path)
			rl.EndDrawing()
			frame := rl.LoadImage(path)
			if !testing.expect(t, frame.data != nil) {
				return
			}
			min_x, min_y, max_x, max_y := frame.width, frame.height, i32(-1), i32(-1)
			for y in 0 ..< frame.height {
				for x in 0 ..< frame.width {
					i := (y * frame.width + x) * 4
					if frame.data[i + 1] > 250 && frame.data[i + 2] > 250 {
						min_x, max_x = min(min_x, x), max(max_x, x)
						min_y, max_y = min(min_y, y), max(max_y, y)
					}
				}
			}
			testing.expect(t, max_x >= min_x && max_y >= min_y)
			testing.expect(
				t,
				abs((max_x - min_x) - (max_y - min_y)) <= 1,
				fmt.tprintf(
					"A square must stay square at %dx%d, zoom %.1f",
					size[0],
					size[1],
					zoom,
				),
			)
			for corner in ([]int{0, int(frame.width - 1), int((frame.height - 1) * frame.width), int(frame.height * frame.width - 1)}) {
				testing.expect(
					t,
					frame.data[corner * 4] == 255 && frame.data[corner * 4 + 1] == 0,
					fmt.tprintf(
						"Wallpaper edge at %dx%d, zoom %.1f, corner %d: red %d, green %d",
						size[0],
						size[1],
						zoom,
						corner,
						frame.data[corner * 4],
						frame.data[corner * 4 + 1],
					),
				)
			}
			rl.UnloadImage(frame)
		}
	}
}
