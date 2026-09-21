package main

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:text/edit"
import "core:time"

@(test)
stt_draft_safety :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	// A fake helper supplies a real memfd result, without a model or microphone.
	for scenario in 0 ..< 8 {
		ui: Ui_State
		edit.init(&ui.ed, context.allocator, context.allocator)
		ui.prefs.stt_enabled = true
		ui.page = .Chats
		ui.account_ref = "account"
		append(&ui.chats, Chat_Row_Ui{group_id = "chat"})
		append(&ui.compose, "Draft")
		fd, ferr := linux.memfd_create("stt-test", {.CLOEXEC})
		testing.expect(t, ferr == .NONE)
		if ferr != .NONE {
			return
		}
		file := os.new_file(uintptr(fd), "stt-test")
		child, err := os.process_start({command = {"true"}})
		testing.expect(t, file != nil && err == nil)
		if file == nil || err != nil {
			return
		}
		ui.stt = {
			file    = file,
			child   = child,
			account = strings.clone("account"),
			group   = strings.clone("chat"),
			draft   = strings.clone("Draft"),
		}
		ui.stt.status = 'R'
		stt_finish(&ui)
		command: [1]u8
		_, _ = os.read_at(file, command[:], 3)
		testing.expect(t, command[0] == 'S')
		n, write_err := os.write_string(file, "T\x0f\x00\x00こんにちは")
		testing.expect(t, write_err == nil && n > 4)
		view, other: Video_View
		if scenario == 5 || scenario == 6 {
			ui.stt.message = strings.clone("audio")
			ui.stt.attachment = 1
			msg := Msg_Ui {
				id = "audio",
			}
			append(&msg.audios, Att_Item(^Video_View){&other, 0})
			append(&msg.audios, Att_Item(^Video_View){&view, 1})
			append(&ui.messages, msg)
		}
		switch scenario {
		case 1:
			ui.account_ref = "other"
		case 2:
			ui.chats[0].group_id = "other"
		case 3:
			append(&ui.thread_stack, "other")
		case 6:
			ui.account_ref = "other"
		case 7:
			ui.stt.purpose = .Download
			ui.page = .Settings
			ui.selected = -1
		case 4, 5:
			append(&ui.compose, " changed")
		}
		for attempt := 0; attempt < 1000 && ui.stt.file != nil; attempt += 1 {
			stt_tick(&ui)
			time.sleep(time.Millisecond)
		}
		testing.expect(t, ui.stt.file == nil)
		want :=
			scenario == 0 ? "Draft こんにちは" : (scenario == 4 || scenario == 5) ? "Draft changed" : "Draft"
		testing.expect_value(t, string(ui.compose[:]), want)
		testing.expect_value(t, view.transcript, scenario == 5 ? "こんにちは" : "")
		testing.expect_value(t, other.transcript, "")
		delete(ui.toast)
		delete(view.transcript)
		for msg in ui.messages {delete(msg.audios)}
		delete(ui.messages)
		stt_stop(&ui)
		delete(ui.chats)
		delete(ui.compose)
		delete(ui.thread_stack)
		edit.destroy(&ui.ed)
	}
}

@(test)
stt_model_selection :: proc(t: ^testing.T) {
	manifest :: string(#load("stt_models.h"))
	prefs: Prefs
	testing.expect_value(t, stt_model(prefs.stt_model), 0)
	testing.expect_value(t, stt_model("unknown"), 0)
	for model, i in STT_MODELS {
		testing.expect_value(t, stt_model(model.name), i)
		testing.expect(t, strings.contains(manifest, model.revision))
		testing.expect_value(
			t,
			model.sizes[0] + model.sizes[1] + model.sizes[2] + model.sizes[3],
			model.bytes,
		)
		encoded, err := json.marshal(Prefs{stt_model = model.name})
		testing.expect(t, err == nil)
		decoded: Prefs
		testing.expect(t, json.unmarshal(encoded, &decoded) == nil)
		testing.expect_value(t, decoded.stt_model, model.name)
		delete(decoded.stt_model)
		delete(encoded)
	}
}

@(test)
stt_partial_results :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	for attachment in 0 ..< 2 {
		ui: Ui_State
		edit.init(&ui.ed, context.allocator, context.allocator)
		ui.prefs.stt_enabled = true
		ui.page = .Chats
		append(&ui.chats, Chat_Row_Ui{group_id = "chat"})
		append(&ui.compose, "Draft")
		fd, ferr := linux.memfd_create("stt-partial", {.CLOEXEC})
		testing.expect(t, ferr == .NONE)
		file := os.new_file(uintptr(fd), "stt-partial")
		child, err := os.process_start({command = {"sleep", "0.05"}})
		testing.expect(t, file != nil && err == nil)
		ui.stt = {
			file  = file,
			child = child,
			group = strings.clone("chat"),
			draft = strings.clone("Draft"),
		}
		view: Video_View
		if attachment == 1 {
			ui.stt.message = strings.clone("audio")
			msg := Msg_Ui {
				id = "audio",
			}
			append(&msg.audios, Att_Item(^Video_View){&view, 0})
			append(&ui.messages, msg)
		}
		// Bytes beyond the published length must remain invisible.
		_, _ = os.write_string(file, "P\x05\x00\x00Hello unfinished")
		stt_tick(&ui)
		testing.expect(t, ui.stt.file != nil && ui.stt.child.pid == child.pid)
		testing.expect_value(t, string(ui.compose[:]), attachment == 0 ? "Draft Hello" : "Draft")
		testing.expect_value(t, view.transcript, attachment == 1 ? "Hello" : "")
		_, _ = os.write_at(file, transmute([]u8)string("P\x0b\x00\x00Hello world"), 0)
		stt_tick(&ui)
		stt_tick(&ui) // Polling the same segment must not duplicate it.
		testing.expect_value(
			t,
			string(ui.compose[:]),
			attachment == 0 ? "Draft Hello world" : "Draft",
		)
		testing.expect_value(t, view.transcript, attachment == 1 ? "Hello world" : "")
		if attachment == 1 {
			_, _ = os.write_at(file, []u8{'T'}, 0)
			for attempt := 0; attempt < 1000 && ui.stt.file != nil; attempt += 1 {
				stt_tick(&ui)
				time.sleep(time.Millisecond)
			}
			testing.expect(t, view.transcript_done && view.transcript_open)
			testing.expect_value(t, view.transcript, "Hello world")
		}
		stt_stop(&ui)
		testing.expect_value(
			t,
			string(ui.compose[:]),
			attachment == 0 ? "Draft Hello world" : "Draft",
		)
		delete(ui.toast)
		delete(view.transcript)
		for msg in ui.messages {delete(msg.audios)}
		delete(ui.messages)
		delete(ui.chats)
		delete(ui.compose)
		edit.destroy(&ui.ed)
	}
}

@(test)
stt_cache_round_trip :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	previous_home, previous_vault := data_home, g_vault
	data_home = "/tmp/wn-stt-cache-unit"
	g_vault = {
		unlocked = true,
	}
	defer {data_home, g_vault = previous_home, previous_vault}
	os.make_directory(data_home)
	defer os.remove_all(data_home)
	view := Video_View {
		transcript      = strings.clone("Completed text"),
		transcript_done = true,
	}
	defer delete(view.transcript)
	testing.expect(t, stt_cache_save(&view, 0))
	sealed, err := os.read_entire_file(stt_cache_path(&view, 0), context.temp_allocator)
	testing.expect(t, err == nil && !strings.contains(string(sealed), "Completed text"))
	stt_cache_load(&view, 0)
	testing.expect(t, view.transcript_done && !view.transcript_open)
	testing.expect_value(t, view.transcript, "Completed text")
	stt_cache_load(&view, 1)
	testing.expect(t, !view.transcript_done && view.transcript == "")
	testing.expect(t, !stt_cache_save(&view, 1))
	stt_cache_load(&view, 0)
	testing.expect_value(t, view.transcript, "Completed text")
	view.audio_hash[0] = 1
	view.transcript_model = 0
	stt_cache_load(&view, 0)
	testing.expect(t, !view.transcript_done && view.transcript == "")
	view.audio_hash[0] = 0
	view.transcript_model = 0
	g_vault.key[0] = 1
	stt_cache_load(&view, 0)
	testing.expect(t, !view.transcript_done && view.transcript == "")
}
