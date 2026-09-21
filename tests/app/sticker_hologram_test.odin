package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:testing"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=sticker_hologram
@(test)
sticker_hologram :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "sticker_hologram" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(400, 400, "Sticker hologram")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	memory: []u8
	init_layout(&memory, 32768, {400, 400})
	defer delete(memory)
	ui: Ui_State
	g_prefs = &ui.prefs
	defer {g_prefs = nil}
	art := rl.LoadImage("vendor/twemoji/1f9ab.png")
	defer rl.UnloadImage(art)
	tex := sticker_texture_load(art)
	defer {
		sticker_texture_free(tex)
		testing.expect_value(t, len(sticker_masks), 0)
		delete(sticker_masks); sticker_masks = {}
	}
	testing.expect_value(t, len(sticker_masks), 1)
	id := clay.ID("HoloArt")
	box := clay.BoundingBox{70, 70, 260, 260}
	flat := sticker_vertex(0, 0, box, {})
	left := sticker_vertex(0, 0, box, {-0.8, -0.7})
	right := sticker_vertex(0, 0, box, {0.8, 0.7})
	testing.expect_value(t, flat.position.x, box.x)
	testing.expect_value(t, flat.position.y, box.y)
	testing.expect(t, left.position != right.position && left.position != flat.position)
	testing.expect_value(t, left.tex_coord, flat.tex_coord)
	shots: [5]rl.Image
	points := [5]clay.Vector2{{0, 0}, {90, 100}, {310, 300}, {0, 0}, {310, 300}}
	defer {for shot in shots {rl.UnloadImage(shot)}}
	for name, i in ([5]string{"idle", "left", "right", "leave", "reduced"}) {
		ui.prefs.reduce_motion = i == 4
		point := points[i]
		for frame in 0 ..< 40 {
			anim_tick(1.0 / 60)
			clay.SetPointerState(point, false)
			clay.BeginLayout()
			if clay.UI(clay.ID("HoloRoot"))(
			{
				layout = {
					sizing = {clay.SizingFixed(400), clay.SizingFixed(400)},
					padding = clay.PaddingAll(70),
				},
			},
			) {
				if clay.UI(id)(
				{
					layout = {sizing = {clay.SizingFixed(260), clay.SizingFixed(260)}},
					image = {imageData = &tex},
					userData = rawptr(STICKER_IMAGE),
				},
				) {}
			}
			commands := clay.EndLayout(1.0 / 60)
			rl.BeginDrawing()
			rl.DrawRectangleRec(0, 0, 400, 400, {28, 30, 38, 255})
			clay_raylib_render(&commands)
			if frame == 39 {rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-holo-%s.png", name))}
			rl.EndDrawing()
		}
		shots[i] = rl.LoadImage(fmt.ctprintf("/tmp/wn-holo-%s.png", name))
		testing.expect(t, shots[i].data != nil)
		if shots[i].data == nil {return}
	}
	changed := 0
	reduced_matches := true
	leave_matches := true
	for i in 0 ..< 400 * 400 * 4 {
		reduced_matches &&= shots[0].data[i] == shots[4].data[i]
		leave_matches &&= shots[0].data[i] == shots[3].data[i]
		if shots[1].data[i] != shots[2].data[i] {changed += 1}
	}
	testing.expect(t, reduced_matches, "reduced motion preserves the flat artwork")
	testing.expect(t, leave_matches, "leaving the sticker settles back to its original artwork")
	testing.expect(t, changed > 1000, "moving the pointer changes tilt and foil")
	for shot in shots {
		pixel := ([^][4]u8)(shot.data)
		testing.expect_value(t, pixel[80 * 400 + 80], [4]u8{28, 30, 38, 255})
	}
}
