package main

import "core:sync"
import "core:testing"
import "core:time"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
video_tile_bounds :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	render := #config(ODIN_TEST_NAMES, "") == "video_tile_bounds"
	if render {
		rl.InitWindow(800, 800, "Video regression")
		UI_ZOOM, UI_SCALE = 1, 1
		init_fonts()
	}
	defer if render { rl.CloseWindow() }
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 1200})
	defer { clay.SetCurrentContext(previous); delete(memory) }
	old_bars := video_bars
	video_bars = {}
	defer { delete(video_bars); video_bars = old_bars }
	defer { video_bar_drag = {}; video_hover = nil; video_full_hover = {} }
	view := Video_View{paused = true, dur = 100, time = 50}
	pixel := [4]u8{56, 65, 90, 255}
	if render { view.tex = rl.LoadTextureFromImage({data = raw_data(pixel[:]), width = 1, height = 1}) }
	defer rl.UnloadTexture(view.tex)
	msg := Msg_Ui{id = "video", sender = "Alice"}
	append(&msg.att_names, "video.mp4")
	append(&msg.videos, Att_Item(^Video_View){&view, 0})
	defer { delete(msg.att_names); delete(msg.videos) }
	for dimensions in ([][2]i32{{1080, 2400}, {1920, 1080}, {1080, 1080}, {0, 0}}) {
		view.w, view.h = dimensions[0], dimensions[1]
		clay.SetPointerState({-1, -1}, false)
		clay.BeginLayout()
		message_row(0, msg)
		commands := clay.EndLayout(0)
		if render && view.w == 1080 && view.h == 2400 {
			rl.BeginDrawing(); draw_frame(&commands); rl.TakeScreenshot("/tmp/wn-video-inline.png"); rl.EndDrawing()
		}
		tile := clay.GetElementData(clay.ID("MsgVideo", 0))
		bar := clay.GetElementData(clay.ID("MsgVideoBar", 0))
		fill := clay.GetElementData(clay.ID("VideoFill", clay.ID("MsgVideoBar", 0).id))
		testing.expect(t, tile.found && bar.found && fill.found)
		testing.expect(t, tile.boundingBox.width <= 320 && tile.boundingBox.height <= 320)
		ratio := view.h > 0 ? f32(view.w) / f32(view.h) : 16.0 / 9.0
		testing.expect(t, abs(tile.boundingBox.width / tile.boundingBox.height - ratio) < 0.00001)
		testing.expect_value(t, bar.boundingBox.width, tile.boundingBox.width)
		testing.expect_value(t, fill.boundingBox.width, bar.boundingBox.width / 2)
		testing.expect_value(t, bar.boundingBox.height, 2)
		testing.expect_value(t, bar.boundingBox.y + bar.boundingBox.height, tile.boundingBox.y + tile.boundingBox.height)
		testing.expect(t, clay.GetElementData(clay.ID("MsgVideoFull", 0)).found)

		clay.SetPointerState({tile.boundingBox.x + tile.boundingBox.width / 2, tile.boundingBox.y + 50}, false)
		clay.BeginLayout()
		message_row(0, msg)
		commands = clay.EndLayout(0)
		if render && view.w == 1080 && view.h == 2400 {
			rl.BeginDrawing(); draw_frame(&commands); rl.TakeScreenshot("/tmp/wn-video-hover.png"); rl.EndDrawing()
		}
		bar = clay.GetElementData(clay.ID("MsgVideoBar", 0))
		testing.expect_value(t, bar.boundingBox.height, 14)
		testing.expect_value(t, clay.GetElementData(clay.ID("MsgVideo", 0)).boundingBox, tile.boundingBox)
		clay.SetPointerState({bar.boundingBox.x + 10, bar.boundingBox.y + 1}, false)
		testing.expect(t, video_bar_active())
		video_bar_drag = {clay.ID("MsgVideoBar", 0), &view}
		clay.SetPointerState({-1, -1}, false)
		testing.expect(t, video_bar_active(), "seeking retains the gesture outside the player")
		clay.BeginLayout()
		message_row(0, msg)
		clay.EndLayout(0)
		testing.expect_value(t, clay.GetElementData(clay.ID("MsgVideoBar", 0)).boundingBox.height, 14)
		video_bar_drag = {}
	}
	ui: Ui_State
	append(&ui.messages, msg)
	append(&ui.prefs.quick_reactions, "👍")
	defer { delete(ui.messages); delete(ui.prefs.quick_reactions) }
	// A seek cancels even a hold already armed before the bar claimed it.
	tile := clay.GetElementData(clay.ID("MsgVideo", 0)).boundingBox
	clay.SetPointerState({tile.x + tile.width / 2, tile.y + 50}, true)
	rl.PushMouseButton(.LEFT, true)
	handle_react_fan(&ui, nil)
	rl.WindowShouldClose()
	video_bar_drag = {clay.ID("MsgVideoBar", 0), &view}
	time.sleep(500 * time.Millisecond)
	handle_react_fan(&ui, nil)
	testing.expect(t, !fan_open(), "seeking must not open the reaction wheel")
	rl.PushMouseButton(.LEFT, false)
	video_hover = &view
	video_full_hover = {&view, "video.mp4"}
	handle_video() // must not toggle playback on a seek release
	testing.expect(t, !preview_shown, "a seek release must not click fullscreen")
	video_bar_drag = {}
	handle_react_fan(&ui, nil)

	// Fullscreen borrows the cache's playback and must not free it on close.
	forced_release = true
	defer { forced_release = false }
	video_full_hover = {&view, "video.mp4"}
	handle_video()
	testing.expect(t, preview_shown && rl.IsFullscreen() && preview.vid == &view && preview.vid_shared)
	testing.expect_value(t, preview.vid.time, 50)
	if render {
		view.w, view.h = 1080, 2400
		clay.SetLayoutDimensions({f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())})
		clay.BeginLayout()
		preview_modal(&ui)
		commands := clay.EndLayout(0)
		box := clay.GetElementData(clay.ID("PvVideo")).boundingBox
		testing.expect(t, box.y >= 0 && box.y + box.height <= f32(rl.GetScreenHeight()))
		rl.BeginDrawing(); draw_frame(&commands); rl.TakeScreenshot("/tmp/wn-video-fullscreen.png"); rl.EndDrawing()
	}
	rl.PushKey(.ESCAPE, true)
	handle_preview(&ui, nil)
	rl.PushKey(.ESCAPE, false)
	testing.expect(t, !preview_shown && !rl.IsFullscreen())
	testing.expect_value(t, view.time, 50)
}
