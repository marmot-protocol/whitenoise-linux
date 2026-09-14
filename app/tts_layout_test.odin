package main

import "core:fmt"
import "core:testing"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
tts_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "tts_layout" {
		return
	}
	rl.InitWindow(720, 1100, "Voice rows")
	defer rl.CloseWindow()
	UI_ZOOM = 1
	UI_SCALE = 1
	load_themes()
	apply_theme(0, 0)
	init_fonts()
	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	clay.Initialize(clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)), {720, 1100}, {})
	clay.SetMeasureTextFunction(measure_text, nil)
	ui: Ui_State
	ui.prefs.tts_enabled = true
	ui.settings_section = .Speech
	ui.tts.status, ui.tts.model, ui.tts.percent = 'D', 0, 42
	ui.tts.ready[2] = true
	g_ui, g_prefs = &ui, &ui.prefs
	for width in ([]f32{420, 720}) {
		clay.SetLayoutDimensions({width, 1100})
		clay.BeginLayout()
		if clay.UI(clay.ID("VoiceTest"))({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(16), childGap = 8}, backgroundColor = BG}) {
			settings_pane(&ui)
		}
		commands := clay.EndLayout(0)
		testing.expect(t, clay.GetElementData(clay.ID("RowStt")).found)
		testing.expect(t, clay.GetElementData(clay.ID("RowTts")).found)
		testing.expect(t, !clay.GetElementData(clay.ID("RowLaunch")).found)
		for _, i in TTS_VOICES {
			box := clay.GetElementData(clay.ID("TtsVoice", u32(i)))
			testing.expect(t, box.found)
			testing.expect(t, box.boundingBox.x + box.boundingBox.width <= width)
			preview := clay.GetElementData(clay.ID(fmt.tprintf("TtsPreview%d", i)))
			testing.expect(t, preview.found && preview.boundingBox.x + preview.boundingBox.width <= width)
		}
		rl.BeginDrawing()
		draw_frame(&commands)
		rl.TakeScreenshot(fmt.ctprintf("/tmp/tts-rows-%d.png", int(width)))
		rl.EndDrawing()
	}
}
