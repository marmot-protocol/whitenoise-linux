package main

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

// Keep a real helper process alive until the test closes its stdin. No sleeps
// or shell-dependent timing are needed to exercise cancellation and completion.
speech_test_process :: proc() -> (os.Process, ^os.File, bool) {
	reader, writer, pipe_err := os.pipe()
	if pipe_err != nil {return {}, nil, false}
	defer os.close(reader)
	command: []string
	when ODIN_OS == .Windows {
		command = []string {
			"powershell",
			"-NoProfile",
			"-NonInteractive",
			"-Command",
			"[Console]::In.ReadToEnd() | Out-Null",
		}
	} else {
		command = []string{"cat"}
	}
	child, err := os.process_start({command = command, stdin = reader})
	if err != nil {
		os.close(writer)
		return {}, nil, false
	}
	return child, writer, true
}

@(test)
tts_controls :: proc(t: ^testing.T) {
	prefs: Prefs
	testing.expect(
		t,
		json.unmarshal(
			transmute([]u8)string(`{"tts_enabled":true,"tts_voice":7,"tts_language":"de"}`),
			&prefs,
		) ==
		nil,
	)
	testing.expect(t, prefs.tts_enabled && prefs.tts_voice == 7)

	ui: Ui_State
	tts_read(&ui, "Disabled speech must not spawn a helper.")
	testing.expect(t, ui.tts.file == nil)
	ui.prefs.tts_enabled = true
	tts_read(&ui, " \n\t")
	testing.expect(t, ui.tts.file == nil)

	file := wn_ipc_create(4)
	testing.expect(t, file != nil)
	if file == nil {return}
	child, pipe, started := speech_test_process()
	testing.expect(t, started)
	if !started {
		wn_ipc_close(file)
		return
	}
	defer os.close(pipe)
	ui.tts = {
		child   = child,
		file    = file,
		account = strings.clone("previous-account"),
	}
	defer tts_stop(&ui)
	ui.account_ref = "previous-account"
	testing.expect_value(t, helper_write_string(file, "D\x02\x32"), 3)
	tts_tick(&ui)
	testing.expect(t, ui.tts.status == 'D' && ui.tts.model == 2 && ui.tts.percent == 50)
	ui.account_ref = "next-account"
	// Account changes must kill and reap work, even when no result is ready.
	tts_tick(&ui)
	testing.expect(t, ui.tts.file == nil)
	testing.expect(t, ui.tts.child.pid == 0)
	tts_stop(&ui) // Stopping twice is harmless.
}

@(test)
tts_reading_language :: proc(t: ^testing.T) {
	ui: Ui_State
	testing.expect_value(t, TTS_LANGUAGES[tts_language(&ui, "こんにちは")].code, "ja")
	testing.expect_value(t, TTS_LANGUAGES[tts_language(&ui, "Hello こんにちは")].code, "ja")
	ui.prefs.locale = "it"
	testing.expect_value(t, TTS_LANGUAGES[tts_language(&ui, "Ciao")].code, "it")
	ui.prefs.locale = "ja"
	testing.expect_value(t, TTS_LANGUAGES[tts_language(&ui, "東京")].code, "ja")
	ui.prefs.locale = "de"
	testing.expect_value(t, TTS_LANGUAGES[tts_language(&ui, "Hallo")].code, "de")
	testing.expect_value(t, TTS_LANGUAGES[tts_language(&ui, "こんにちは")].code, "ja")
	testing.expect_value(t, TTS_LANGUAGES[tts_language(&ui, "ｺﾝﾆﾁﾊ")].code, "ja")
	ui.prefs.locale = "unknown"
	testing.expect_value(t, TTS_LANGUAGES[tts_language(&ui, "Hello")].code, "en")
}
