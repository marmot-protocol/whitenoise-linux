package main

import "core:sync"
import "core:testing"
import "core:time"
import "nendo"
import rl "sdlrl"

@(test)
video_tile_bounds :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	render := #config(ODIN_TEST_NAMES, "") == "video_tile_bounds"
	if render {
		rl.InitWindow(800, 800, "Video regression")
		UI_ZOOM, UI_SCALE = 1, 1
		init_fonts()
	}
	defer if render {rl.CloseWindow()}
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {800, 1200})
	defer {nendo.set_context(previous); delete(memory)}
	old_bars := video_bars
	video_bars = {}
	defer {delete(video_bars); video_bars = old_bars}
	defer {video_bar_drag = {}; video_hover = nil; video_full_hover = {}}
	view := Video_View {
		paused = true,
		dur    = 100,
		time   = 50,
	}
	pixel := [4]u8{56, 65, 90, 255}
	if render {view.tex = rl.LoadTextureFromImage({data = raw_data(pixel[:]), width = 1, height = 1})}
	defer rl.UnloadTexture(view.tex)
	msg := Msg_Ui {
		id     = "video",
		sender = "Alice",
	}
	append(
		&msg.attachments,
		Att_Slot{name = "video.mp4", kind = .Video, state = .Ready, view = &view},
	)
	defer delete(msg.attachments)
	for dimensions in ([][2]i32{{1080, 2400}, {1920, 1080}, {1080, 1080}, {0, 0}}) {
		view.w, view.h = dimensions[0], dimensions[1]
		nendo.set_pointer({-1, -1}, .Up)
		nendo.begin()
		message_row(0, msg)
		commands := nendo.end(0)
		if render && view.w == 1080 && view.h == 2400 {
			rl.BeginDrawing()
			draw_frame(commands)
			rl.TakeScreenshot("/tmp/wn-video-inline.png")
			rl.EndDrawing()
		}
		tile := nendo.element(nendo.id("MsgVideo", 0))
		bar := nendo.element(nendo.id("MsgVideoBar", 0))
		fill := nendo.element(nendo.id("VideoFill", nendo.id("MsgVideoBar", 0).id))
		testing.expect(t, tile.found && bar.found && fill.found)
		testing.expect(t, tile.rect.width <= 320 && tile.rect.height <= 320)
		ratio := view.h > 0 ? f32(view.w) / f32(view.h) : 16.0 / 9.0
		testing.expect(t, abs(tile.rect.width / tile.rect.height - ratio) < 0.00001)
		testing.expect_value(t, bar.rect.width, tile.rect.width)
		testing.expect_value(t, fill.rect.width, bar.rect.width / 2)
		testing.expect_value(t, bar.rect.y + bar.rect.height, tile.rect.y + tile.rect.height)
		testing.expect(t, nendo.element(nendo.id("MsgVideoFull", 0)).found)

		nendo.set_pointer({tile.rect.x + tile.rect.width / 2, tile.rect.y + 50}, .Up)
		nendo.begin()
		message_row(0, msg)
		commands = nendo.end(0)
		if render && view.w == 1080 && view.h == 2400 {
			rl.BeginDrawing()
			draw_frame(commands)
			rl.TakeScreenshot("/tmp/wn-video-hover.png")
			rl.EndDrawing()
		}
		bar = nendo.element(nendo.id("MsgVideoBar", 0))
		testing.expect_value(t, nendo.element(nendo.id("MsgVideo", 0)).rect, tile.rect)
		nendo.set_pointer({bar.rect.x + 10, bar.rect.y + 1}, .Up)
		testing.expect(t, video_bar_active())
		video_bar_drag = {nendo.id("MsgVideoBar", 0), &view}
		nendo.set_pointer({-1, -1}, .Up)
		testing.expect(t, video_bar_active(), "seeking retains the gesture outside the player")
		nendo.begin()
		message_row(0, msg)
		nendo.end(0)
		video_bar_drag = {}
	}
	ui: Ui_State
	append(&ui.messages, msg)
	append(&ui.prefs.quick_reactions, "👍")
	defer {delete(ui.messages); delete(ui.prefs.quick_reactions)}
	// A seek cancels even a hold already armed before the bar claimed it.
	tile := nendo.element(nendo.id("MsgVideo", 0)).rect
	nendo.set_pointer({tile.x + tile.width / 2, tile.y + 50}, .Down)
	rl.PushMouseButton(.LEFT, true)
	handle_react_fan(&ui, nil)
	rl.WindowShouldClose()
	video_bar_drag = {nendo.id("MsgVideoBar", 0), &view}
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
	defer {forced_release = false}
	video_full_hover = {&view, "video.mp4"}
	handle_video()
	testing.expect(
		t,
		preview_shown && rl.IsFullscreen() && preview.vid == &view && preview.vid_shared,
	)
	testing.expect_value(t, preview.vid.time, 50)
	if render {
		view.w, view.h = 1080, 2400
		view.dw, view.dh = 1080, 2400
		nendo.set_dimensions({f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())})
		nendo.begin()
		preview_modal(&ui)
		commands := nendo.end(0)
		box := nendo.element(nendo.id("PvVideo")).rect
		testing.expect(t, box.y >= 0 && box.y + box.height <= f32(rl.GetScreenHeight()))
		rl.BeginDrawing()
		draw_frame(commands)
		rl.TakeScreenshot("/tmp/wn-video-fullscreen.png")
		rl.EndDrawing()
	}
	rl.PushKey(.ESCAPE, true)
	handle_preview(&ui, nil)
	rl.PushKey(.ESCAPE, false)
	testing.expect(t, !preview_shown && !rl.IsFullscreen())
	testing.expect_value(t, view.time, 50)
}
