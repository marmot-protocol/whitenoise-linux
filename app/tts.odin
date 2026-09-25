package main

import "core:fmt"
import "core:os"
import "core:strings"
import rl "sdlrl"

@(private)
TTS_VOICES := [?]string{"F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"}

@(private)
TTS_DESCRIPTIONS := [?]string {
	N_("Female voice. Supports all reading languages."),
	N_("Female voice. Supports all reading languages."),
	N_("Female voice. Supports all reading languages."),
	N_("Female voice. Supports all reading languages."),
	N_("Female voice. Supports all reading languages."),
	N_("Male voice. Supports all reading languages."),
	N_("Male voice. Supports all reading languages."),
	N_("Male voice. Supports all reading languages."),
	N_("Male voice. Supports all reading languages."),
	N_("Male voice. Supports all reading languages."),
}

@(private)
TTS_MODEL_REV :: "cca5a0e6c96e1d2c720986bf7e75fcc81dee3ae4"

// Same order and byte sizes as the pinned manifest in tts_models.h.
@(private)
TTS_MODEL_SIZES := [?]i64{3700147, 36416150, 78400833, 25991073, 8253, 262144, 517168, 1070}

@(private)
TTS_MODEL_FILES := [?]string {
	"duration_predictor.int8.onnx",
	"text_encoder.int8.onnx",
	"vector_estimator.int8.onnx",
	"vocoder.int8.onnx",
	"tts.json",
	"unicode_indexer.bin",
	"voice.bin",
	"LICENSE",
}

@(private)
Tts_State :: struct {
	child:          os.Process,
	file:           ^Helper_Ipc,
	status:         u8,
	account:        string,
	model, percent: u8,
	ready:          [len(TTS_MODEL_SIZES)]bool,
	checked_at:     f64,
}

@(private)
tts_stop :: proc(ui: ^Ui_State) {
	if ui.tts.file == nil {
		return
	}
	_ = os.process_kill(ui.tts.child)
	_, _ = os.process_wait(ui.tts.child)
	wn_ipc_close(ui.tts.file)
	delete(ui.tts.account)
	ui.tts = {
		ready = ui.tts.ready,
	}
}

@(private)
tts_read :: proc(ui: ^Ui_State, text: string) {
	if !ui.prefs.tts_enabled || strings.trim_space(text) == "" {
		return
	}
	tts_stop(ui)
	stt_stop(ui)
	if len(text) > 1024 * 1024 || strings.contains(text, "\x00") {
		toast(ui, tr("Couldn't read this message aloud. Choose a shorter text message."))
		return
	}
	// The helper sees only a random mapping token, never message text in argv or files.
	file := wn_ipc_create(uint(len(text) + 3))
	if file == nil {
		toast(ui, tr("Couldn't start reading aloud. Please try again."))
		return
	}
	ok := false
	defer if !ok {
		wn_ipc_close(file)
	}
	if helper_write_string(file, fmt.tprintf("G\x00\x00%s", text)) != len(text) + 3 {
		toast(ui, tr("Couldn't start reading aloud. Please try again."))
		return
	}
	child, start_err := os.process_start(
		{
			command = {
				helper_path("wn-tts"),
				fmt.tprintf("%s/tts/%s", data_home, TTS_MODEL_REV),
				TTS_VOICES[clamp(ui.prefs.tts_voice, 0, len(TTS_VOICES) - 1)],
				fmt.tprintf("%d", os.get_pid()),
				TTS_LANGUAGES[tts_language(ui, text)].code,
				string(wn_ipc_name(file)),
				fmt.tprintf("%d", wn_ipc_size(file)),
			},
		},
	)
	if start_err != nil {
		toast(ui, tr("Couldn't start reading aloud. Please try again."))
		return
	}
	ok = true
	ui.tts = {
		child   = child,
		file    = file,
		status  = 'G',
		account = strings.clone(ui.account_ref),
		ready   = ui.tts.ready,
	}
}

@(private)
tts_tick :: proc(ui: ^Ui_State) {
	if ui.page == .Settings &&
	   ui.prefs.tts_enabled &&
	   (ui.tts.checked_at == 0 || rl.GetTime() - ui.tts.checked_at >= 1) {
		for size, i in TTS_MODEL_SIZES {
			name := TTS_MODEL_FILES[i]
			info, err := os.stat(
				fmt.tprintf("%s/tts/%s/%s", data_home, TTS_MODEL_REV, name),
				context.temp_allocator,
			)
			ui.tts.ready[i] = err == nil && info.type == .Regular && info.size == size
		}
		ui.tts.checked_at = rl.GetTime()
	}
	if ui.tts.file == nil {
		return
	}
	if !ui.prefs.tts_enabled || ui.tts.account != ui.account_ref {
		tts_stop(ui)
		return
	}
	status: [3]u8
	if n := helper_read_at(ui.tts.file, status[:], 0);
	   n == len(status) && int(status[1]) < len(TTS_MODEL_SIZES) && status[2] <= 100 {
		ui.tts.status = status[0]
		ui.tts.model, ui.tts.percent = status[1], status[2]
	}
	state, err := os.process_wait(ui.tts.child, timeout = 0)
	if err == .Timeout {
		return
	}
	wn_ipc_close(ui.tts.file)
	delete(ui.tts.account)
	model := ui.tts.model
	ui.tts = {
		ready = ui.tts.ready,
	}
	if err != nil || state.exit_code != 0 {
		if state.exit_code == 1 {
			ui.tts.status, ui.tts.model = 'F', model
		}
		switch state.exit_code {
		case 1:
			toast(
				ui,
				tr(
					"Couldn't download the speech model. Check your connection and available disk space, then try again.",
				),
			)
		case 3:
			toast(ui, tr("Couldn't play speech. Check your audio output and try again."))
		case:
			toast(ui, tr("Couldn't read this message aloud. Please try again."))
		}
	}
}

@(private)
tts_status :: proc(ui: ^Ui_State) -> string {
	switch ui.tts.status {
	case 'D':
		return tr("Downloading speech model...")
	case 'P':
		return tr("Reading aloud...")
	case:
		return tr("Preparing speech...")
	}
}
