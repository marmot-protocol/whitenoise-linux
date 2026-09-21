package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:fmt"
import "core:os"
import "core:testing"
import rl "sdlrl"

@(test)
stt_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "stt_layout" {
		return
	}
	rl.InitWindow(720, 700, "Dictation")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes()
	apply_theme(0, 0)
	init_fonts()
	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)),
		{720, 700},
		{},
	)
	clay.SetMeasureTextFunction(measure_text, nil)
	ui := Ui_State {
		row_menu         = -1,
		member_menu      = -1,
		selected_contact = -1,
	}
	ui.prefs.stt_enabled = true
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Dictation"})
	g_ui, g_prefs = &ui, &ui.prefs
	for width in ([]f32{420, 720}) {
		clay.SetLayoutDimensions({width, 700})
		ui.stt.file = nil
		_ = build_layout(&ui, 0)
		testing.expect(t, clay.GetElementData(clay.ID("DictateBtn")).found)
		file: os.File
		ui.stt.file, ui.stt.status = &file, 'R'
		commands := build_layout(&ui, 0)
		for id in ([]string{"SttCancel", "SttFinish"}) {
			box := clay.GetElementData(clay.ID(id))
			testing.expect(t, box.found && box.boundingBox.x + box.boundingBox.width <= width)
		}
		rl.BeginDrawing()
		draw_frame(&commands)
		rl.TakeScreenshot(fmt.ctprintf("/tmp/stt-%d.png", int(width)))
		rl.EndDrawing()
	}
}
