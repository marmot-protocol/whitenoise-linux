package main

import "base:runtime"
import "core:fmt"
import "core:testing"
import "nendo"
import rl "sdlrl"

@(test)
audio_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "audio_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(720, 900, "Audio messages")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes()
	apply_theme(0, 0)
	init_fonts()
	memory := make([]u8, int(nendo.min_memory_size()))
	defer delete(memory)
	nendo.init(memory, {720, 900}, {})
	nendo.set_measure_text(measure_text, nil)
	ui := Ui_State {
		row_menu         = -1,
		member_menu      = -1,
		selected_contact = -1,
	}
	ui.prefs.stt_enabled = true
	append(&ui.accounts, Account_Row_Ui{name = "Test"})
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
		blob_sizes[name] = i == 0 ? 2500000 : 20300
		append(
			&msg.attachments,
			Att_Slot{name = name, key = name, kind = .Audio, state = .Ready, view = &views[i]},
		)
		append(&ui.messages, msg)
	}
	views[1].transcript = "If you're going to get mad at me every time I do something stupid, then I guess I'll just have to stop doing stupid things."
	views[1].transcript_done, views[1].transcript_open = true, true
	g_ui, g_prefs = &ui, &ui.prefs
	for width in ([]f32{340, 420, 720}) {
		rl.SetWindowSize(i32(width), 900)
		nendo.set_dimensions({width, 900})
		_ = build_layout(&ui, 0)
		commands := build_layout(&ui, 0)
		for i in 0 ..< 2 {
			id := u32(i * 1024)
			tile := nendo.element(nendo.id("MsgAudio", id)).rect
			for key in ([]string{"MsgAudioName", "MsgAudioBar", "MsgAudioMeta"}) {
				box := nendo.element(nendo.id(key, id))
				testing.expect(t, box.found)
				testing.expect(t, box.rect.x + box.rect.width <= tile.x + tile.width, key)
			}
			testing.expect(t, tile.x + tile.width <= width)
		}
		before := [3]nendo.Rect {
			nendo.element(nendo.id("Timeline")).rect,
			nendo.element(nendo.id("MsgAudio", 0)).rect,
			nendo.element(nendo.id("MsgAudio", 1024)).rect,
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
		after := [3]nendo.Rect {
			nendo.element(nendo.id("Timeline")).rect,
			nendo.element(nendo.id("MsgAudio", 0)).rect,
			nendo.element(nendo.id("MsgAudio", 1024)).rect,
		}
		testing.expect_value(t, after, before)
		testing.expect(t, !nendo.element(nendo.id("SttBar")).found)
		ui.stt = {}
		commands = build_layout(&ui, 0)
		rl.BeginDrawing()
		draw_frame(commands)
		rl.TakeScreenshot(fmt.ctprintf("/tmp/audio-%d.png", int(width)))
		rl.EndDrawing()
	}
}
