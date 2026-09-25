package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:fmt"
import "core:testing"
import rl "sdlrl"

@(test)
audio_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "audio_layout" {return}
	rl.InitWindow(720, 900, "Audio messages")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes()
	apply_theme(0, 0)
	init_fonts()
	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)),
		{720, 900},
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
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Audio"})
	views := [2]Video_View {
		{paused = true, time = 27, dur = 27},
		{paused = false, time = 3, dur = 6},
	}
	for name, i in ([]string{"mono_44100_127389__acclivity__thetimehascome.wav", "if-you-are-going-to-get-mad-at-me-every-time-i-do-something-stupid-then-i-guess-i-will-just-have-to-stop-doing-stupid-things.mp3"}) {
		msg := Msg_Ui {
			id     = fmt.aprintf("message%d", i),
			sender = "Danny",
		}
		append(&msg.att_names, name)
		append(&msg.att_keys, name)
		blob_sizes[name] = i == 0 ? 2500000 : 20300
		append(&msg.audios, Att_Item(^Video_View){&views[i], 0})
		append(&ui.messages, msg)
	}
	views[1].transcript = "If you're going to get mad at me every time I do something stupid, then I guess I'll just have to stop doing stupid things."
	views[1].transcript_done, views[1].transcript_open = true, true
	g_ui, g_prefs = &ui, &ui.prefs
	for width in ([]f32{340, 420, 720}) {
		rl.SetWindowSize(i32(width), 900)
		clay.SetLayoutDimensions({width, 900})
		_ = build_layout(&ui, 0)
		commands := build_layout(&ui, 0)
		for i in 0 ..< 2 {
			id := u32(i * 1024)
			tile := clay.GetElementData(clay.ID("MsgAudio", id)).boundingBox
			for key in ([]string{"MsgAudioName", "MsgAudioBar", "MsgAudioMeta"}) {
				box := clay.GetElementData(clay.ID(key, id))
				testing.expect(t, box.found)
				testing.expect(
					t,
					box.boundingBox.x + box.boundingBox.width <= tile.x + tile.width,
					key,
				)
			}
			testing.expect(t, tile.x + tile.width <= width)
		}
		before := [3]clay.BoundingBox {
			clay.GetElementData(clay.ID("Timeline")).boundingBox,
			clay.GetElementData(clay.ID("MsgAudio", 0)).boundingBox,
			clay.GetElementData(clay.ID("MsgAudio", 1024)).boundingBox,
		}
		file := wn_ipc_create(4)
		testing.expect(t, file != nil)
		if file == nil {return}
		defer wn_ipc_close(file)
		ui.stt = {
			file    = file,
			message = "message1",
			status  = 'D',
			percent = 42,
		}
		_ = build_layout(&ui, 0)
		after := [3]clay.BoundingBox {
			clay.GetElementData(clay.ID("Timeline")).boundingBox,
			clay.GetElementData(clay.ID("MsgAudio", 0)).boundingBox,
			clay.GetElementData(clay.ID("MsgAudio", 1024)).boundingBox,
		}
		testing.expect_value(t, after, before)
		testing.expect(t, !clay.GetElementData(clay.ID("SttBar")).found)
		ui.stt = {}
		commands = build_layout(&ui, 0)
		rl.BeginDrawing()
		draw_frame(&commands)
		rl.TakeScreenshot(fmt.ctprintf("/tmp/audio-%d.png", int(width)))
		rl.EndDrawing()
	}
}
