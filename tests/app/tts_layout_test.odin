package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import rl "sdlrl"

@(test)
tts_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "tts_layout" {
		return
	}
	// Renderer caches have process lifetime, not the test allocator's lifetime.
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(720, 1100, "Voice rows")
	defer rl.CloseWindow()
	UI_ZOOM = 1
	UI_SCALE = 1
	load_themes()
	apply_theme(0, 0)
	init_fonts()
	previous := clay.GetCurrentContext()
	memory := make([]u8, int(clay.MinMemorySize()))
	defer {clay.SetCurrentContext(previous); delete(memory)}
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)),
		{720, 1100},
		{},
	)
	clay.SetMeasureTextFunction(measure_text, nil)
	ui: Ui_State
	ui.prefs.tts_enabled = true
	ui.prefs.stt_enabled = true
	ui.prefs.stt_model = "small"
	ui.stt.ready[0] = true
	ui.stt.purpose = .Download
	ui.stt.status, ui.stt.model, ui.stt.percent = 'D', 1, 42
	ui.stt.file = cast(^os.File)uintptr(1)
	ui.page = .Settings
	ui.settings_section = .Speech
	ui.tts.status, ui.tts.model, ui.tts.percent = 'D', 0, 42
	ui.tts.ready[2] = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	for width in ([]f32{420, 720}) {
		rl.SetWindowSize(i32(width), 1100)
		clay.SetLayoutDimensions({width, 1100})
		for tab in 0 ..< 2 {
			ui.settings_tab = tab
			clay.UpdateScrollContainers(false, {}, 0)
			clay.BeginLayout()
			if clay.UI(clay.ID("VoiceTest"))(
			{
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingGrow()},
					layoutDirection = .TopToBottom,
				},
				backgroundColor = BG,
			},
			) {
				settings_pane(&ui)
			}
			commands := clay.EndLayout(0)
			if tab == 0 {
				for _, i in STT_MODELS {
					box := clay.GetElementData(clay.ID("SttModel", u32(i)))
					testing.expect(
						t,
						box.found &&
						box.boundingBox.x >= 0 &&
						box.boundingBox.x + box.boundingBox.width <= width,
					)
				}
			} else {
				for _, i in TTS_VOICES {
					box := clay.GetElementData(clay.ID("TtsVoice", u32(i)))
					testing.expect(
						t,
						box.found &&
						box.boundingBox.x >= 0 &&
						box.boundingBox.x + box.boundingBox.width <= width,
					)
					preview := clay.GetElementData(clay.ID(fmt.tprintf("TtsPreview%d", i)))
					testing.expect(
						t,
						preview.found &&
						preview.boundingBox.x >= 0 &&
						preview.boundingBox.x + preview.boundingBox.width <= width,
					)
				}
			}
			rl.BeginDrawing()
			draw_frame(&commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/tts-rows-%d-%d.png", int(width), tab))
			rl.EndDrawing()
		}
	}
}
