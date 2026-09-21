package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

@(test)
tts_controls :: proc(t: ^testing.T) {
	manifest :: string(#load("tts_models.h"))
	for size, i in TTS_MODEL_SIZES {
		testing.expect(
			t,
			strings.contains(manifest, fmt.tprintf("\"%s\", %d,", TTS_MODEL_FILES[i], size)),
		)
	}
	for language in TTS_LANGUAGES {
		testing.expect(t, strings.contains(manifest, fmt.tprintf("\"%s\"", language.code)))
	}
	prefs: Prefs
	testing.expect(t, !prefs.tts_enabled)
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

	fd, ferr := linux.memfd_create("tts-controls", {.CLOEXEC})
	testing.expect(t, ferr == .NONE)
	if ferr != .NONE {
		return
	}
	file := os.new_file(uintptr(fd), "tts-controls")
	testing.expect(t, file != nil)
	if file == nil {
		linux.close(fd)
		return
	}
	child, err := os.process_start({command = {"sleep", "30"}})
	testing.expect(t, err == nil)
	if err != nil {
		os.close(file)
		return
	}
	ui.tts = {
		child   = child,
		file    = file,
		account = strings.clone("previous-account"),
	}
	defer tts_stop(&ui)
	ui.account_ref = "previous-account"
	n, write_err := os.write_string(file, "D\x02\x32")
	testing.expect(t, write_err == nil && n == 3)
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
