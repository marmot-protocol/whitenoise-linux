package main

import "core:fmt"
import "core:encoding/hex"
import rl "sdlrl"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "core:unicode/utf8"
import "core:text/edit"

@(private)
STT_MODELS := [?]struct {name, label, revision: string, bytes: i64, sizes: [4]i64, files: [4]string, count: int, languages: string} {
	{"tiny", "Whisper Tiny", "65176e2deb88badc814a94058666cadccc29b61c", 103609903, {12937772, 89855401, 816730, 0}, {"tiny-encoder.int8.onnx", "tiny-decoder.int8.onnx", "tiny-tokens.txt", ""}, 3, N_("Multilingual. Detects your language automatically.")},
	{"base", "Whisper Base", "bb53ee204431c90d314c1cc08d28d23e5b7927cc", 160609290, {29120534, 130672026, 816730, 0}, {"base-encoder.int8.onnx", "base-decoder.int8.onnx", "base-tokens.txt", ""}, 3, N_("Multilingual. Detects your language automatically.")},
	{"small", "Whisper Small", "8f3c18b358db4d1f2fc1eae49d75cd20989e4309", 375485327, {112442483, 262226114, 816730, 0}, {"small-encoder.int8.onnx", "small-decoder.int8.onnx", "small-tokens.txt", ""}, 3, N_("Multilingual. Detects your language automatically.")},
	{"medium", "Whisper Medium", "8c31d28503847560985df21f90e14f0c736e075e", 946072270, {374196283, 571059257, 816730, 0}, {"medium-encoder.int8.onnx", "medium-decoder.int8.onnx", "medium-tokens.txt", ""}, 3, N_("Multilingual. Detects your language automatically.")},
	{"large-v3", "Whisper Large v3", "2a6507094dd6020d939d78e3f1834a1d06267fca", 1775753918, {766671985, 1008265203, 816730, 0}, {"large-v3-encoder.int8.onnx", "large-v3-decoder.int8.onnx", "large-v3-tokens.txt", ""}, 3, N_("Multilingual. Detects your language automatically.")},
	{"turbo", "Whisper Turbo", "2ca6ff69fc878651b770880507669577ac41c2ff", 1036613791, {674716297, 361080764, 816730, 0}, {"turbo-encoder.int8.onnx", "turbo-decoder.int8.onnx", "turbo-tokens.txt", ""}, 3, N_("Multilingual. Detects your language automatically.")},
	{"parakeet-v3", "Parakeet TDT v3", "2bda32ec70b097a55adaa07d9a7173915b43cc78", 670478772, {652184281, 11845275, 6355277, 93939}, {"encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"}, 4, N_("25 European languages, including English and Italian.")},
	{"sensevoice", "SenseVoice Small", "2365baeacb507f821a0c8120fcee3d484dba7a07", 239549735, {239233841, 315894, 0, 0}, {"model.int8.onnx", "tokens.txt", "", ""}, 2, N_("Chinese, English, Japanese, Korean and Cantonese.")},
}

@(private)
stt_model :: proc(name: string) -> int {
	for model, i in STT_MODELS {
		if model.name == name { return i }
	}
	return 0
}

@(private)
Stt_Purpose :: enum { Transcribe, Download }

@(private)
Stt_State :: struct {
	purpose: Stt_Purpose,
	ready: [len(STT_MODELS)]bool,
	checked_at: f64,
	child: os.Process,
	file: ^os.File,
	status, model, percent: u8,
	account, group, thread, editing, draft: string,
	message: string,
	attachment: int,
	received: int,
	selected_model: int,
}

@(private)
Stt_Action :: enum { Transcribe, Toggle, Cancel }

@(private)
stt_hover: struct {message: string, attachment: int, view: ^Video_View, action: Stt_Action}

@(private)
stt_cache_path :: proc(view: ^Video_View, model: int) -> string {
	hash, _ := hex.encode(view.audio_hash[:], context.temp_allocator)
	return fmt.tprintf("%s/%s-%s.stt", media_cache_dir(), hash, STT_MODELS[model].revision)
}

@(private)
stt_cache_load :: proc(view: ^Video_View, model: int) {
	if view.transcript_model == model + 1 { return }
	delete(view.transcript)
	view.transcript = ""
	view.transcript_model = model + 1
	view.transcript_done, view.transcript_open = false, false
	path := stt_cache_path(view, model)
	info, err := os.stat(path, context.temp_allocator)
	if err != nil || info.size > 16424 { return }
	sealed, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil { return }
	plain, ok := vault_open_blob(sealed, context.temp_allocator)
	if !ok || len(plain) > 16384 || !utf8.valid_string(string(plain)) || strings.contains(string(plain), "\x00") { return }
	text := strings.trim_space(string(plain))
	if text == "" { return }
	view.transcript = strings.clone(text)
	view.transcript_done = true
}

@(private)
stt_cache_save :: proc(view: ^Video_View, model: int) -> bool {
	if !view.transcript_done { return false }
	sealed, ok := vault_seal_blob(transmute([]u8)view.transcript, context.temp_allocator)
	if !ok { return false }
	os.make_directory(media_cache_dir())
	path := stt_cache_path(view, model)
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, sealed, {.Read_User, .Write_User}) != nil { return false }
	return os.rename(tmp, path) == nil
}

@(private)
stt_stop :: proc(ui: ^Ui_State) {
	if ui.stt.file == nil {
		return
	}
	if ui.stt.child.pid != 0 {
		_ = os.process_kill(ui.stt.child)
		_, _ = os.process_wait(ui.stt.child)
	}
	os.close(ui.stt.file)
	delete(ui.stt.account)
	delete(ui.stt.group)
	delete(ui.stt.thread)
	delete(ui.stt.editing)
	delete(ui.stt.draft)
	delete(ui.stt.message)
	ui.stt = {ready = ui.stt.ready}
}

@(private)
stt_start :: proc(ui: ^Ui_State, message: string = "", attachment: int = 0, purpose: Stt_Purpose = .Transcribe) {
	if !ui.prefs.stt_enabled || ui.stt.file != nil ||
	   (purpose == .Transcribe && (voice.stream != nil || ui.selected < 0 || ui.selected >= len(ui.chats))) {
		return
	}
	audio: []u8
	view: ^Video_View
	if message != "" {
		for msg in ui.messages {
			if msg.id != message { continue }
			for entry in msg.audios {
				if entry.att == attachment {
					audio = entry.view.data
					view = entry.view
				}
			}
		}
		if len(audio) == 0 || len(audio) > 100 * 1024 * 1024 {
			toast(ui, tr("Couldn't transcribe this audio. Choose an audio file under 100 MB."))
			return
		}
	}
	tts_stop(ui)
	fd, ferr := linux.memfd_create("wn-stt", {.CLOEXEC})
	if ferr != .NONE {
		toast(ui, tr("Couldn't start transcription. Please try again."))
		return
	}
	file := os.new_file(uintptr(fd), "wn-stt")
	if file == nil {
		linux.close(fd)
		toast(ui, tr("Couldn't start transcription. Please try again."))
		return
	}
	ok := false
	defer if !ok {
		os.close(file)
	}
	n, err := os.write_string(file, "G\x00\x00\x00")
	exe, exe_err := os.read_link("/proc/self/exe", context.temp_allocator)
	if err != nil || n != 4 || exe_err != nil {
		toast(ui, tr("Couldn't start transcription. Please try again."))
		return
	}
	input := file
	if message != "" {
		afd, aerr := linux.memfd_create("wn-stt-audio", {.CLOEXEC})
		if aerr != .NONE {
			toast(ui, tr("Couldn't start transcription. Please try again."))
			return
		}
		input = os.new_file(uintptr(afd), "wn-stt-audio")
		if input == nil {
			linux.close(afd)
			toast(ui, tr("Couldn't start transcription. Please try again."))
			return
		}
	}
	defer if input != file { os.close(input) }
	if input != file {
		written, write_err := os.write(input, audio)
		if write_err != nil || written != len(audio) {
			toast(ui, tr("Couldn't start transcription. Please try again."))
			return
		}
	}
	model := STT_MODELS[stt_model(ui.prefs.stt_model)]
	child, start_err := os.process_start({
		command = {fmt.tprintf("%s/wn-stt", filepath.dir(exe)),
			fmt.tprintf("%s/stt/%s", data_home, model.revision), fmt.tprintf("%d", os.get_pid()),
			purpose == .Download ? "download" : (message == "" ? "dictate" : "audio"), model.name},
		stdin = input, stdout = file,
	})
	if start_err != nil {
		toast(ui, tr("Couldn't start transcription. Please try again."))
		return
	}
	ok = true
	if view != nil {
		delete(view.transcript)
		view.transcript = ""
		view.transcript_done = false
		view.transcript_open = true
		view.transcript_model = stt_model(ui.prefs.stt_model) + 1
	}
	ui.stt = {child = child, file = file, status = 'G', purpose = purpose, ready = ui.stt.ready, selected_model = stt_model(ui.prefs.stt_model),
		account = strings.clone(ui.account_ref), group = purpose == .Download ? "" : strings.clone(ui.chats[ui.selected].group_id),
		thread = strings.clone(thread_cur(ui)), editing = strings.clone(ui.editing),
		draft = strings.clone(string(ui.compose[:])), message = strings.clone(message), attachment = attachment}
}

@(private)
stt_finish :: proc(ui: ^Ui_State) {
	if ui.stt.file == nil || ui.stt.status != 'R' {
		return
	}
	n, err := os.write_at(ui.stt.file, []u8{'S'}, 3)
	if err != nil || n != 1 {
		stt_stop(ui)
		toast(ui, tr("Couldn't finish dictation. Please try again."))
	}
}

@(private)
stt_tick :: proc(ui: ^Ui_State) {
	if ui.page == .Chats && ui.prefs.stt_enabled {
		for msg in ui.messages {
			for entry in msg.audios { stt_cache_load(entry.view, stt_model(ui.prefs.stt_model)) }
		}
	}
	if ui.page == .Settings && ui.prefs.stt_enabled &&
	   (ui.stt.checked_at == 0 || rl.GetTime() - ui.stt.checked_at >= 1) {
		for model, i in STT_MODELS {
			ui.stt.ready[i] = true
			for j in 0 ..< model.count {
				info, err := os.stat(fmt.tprintf("%s/stt/%s/%s", data_home, model.revision, model.files[j]), context.temp_allocator)
				ui.stt.ready[i] = ui.stt.ready[i] && err == nil && info.type == .Regular && info.size == model.sizes[j]
			}
		}
		ui.stt.checked_at = rl.GetTime()
	}
	if ui.stt.file == nil {
		return
	}
	// Bind the result to the original draft, never another account/chat/thread.
	if !ui.prefs.stt_enabled || ui.stt.account != ui.account_ref || (ui.stt.purpose == .Transcribe && (ui.page != .Chats || ui.selected < 0 || ui.selected >= len(ui.chats) ||
	   ui.stt.group != ui.chats[ui.selected].group_id ||
	   ui.stt.thread != thread_cur(ui) ||
	   (ui.stt.message == "" && (ui.stt.editing != ui.editing || ui.stt.draft != string(ui.compose[:]))))) {
		stt_stop(ui)
		return
	}
	status: [3]u8
	if n, err := os.read_at(ui.stt.file, status[:], 0); err == nil && n == len(status) {
		ui.stt.status = status[0]
		if status[0] == 'D' && int(status[1]) < STT_MODELS[ui.stt.selected_model].count && status[2] <= 100 {
			ui.stt.model, ui.stt.percent = status[1], status[2]
		}
	}
	state, err := os.process_wait(ui.stt.child, timeout = 0)
	running := err == .Timeout
	if running && ui.stt.status != 'P' { return }
	// Only clear the PID once reaped; partial results keep the helper cancellable.
	if !running { ui.stt.child = {} }
	defer if !running { stt_stop(ui) }
	if !running && (err != nil || state.exit_code != 0) {
		switch state.exit_code {
		case 1: toast(ui, tr("Couldn't download the speech model. Check your connection and available disk space, then try again."))
		case 3:
			if ui.stt.message == "" {
				toast(ui, tr("Couldn't open the microphone. Please try again."))
			} else {
				toast(ui, tr("Couldn't decode this audio. Try another audio file."))
			}
		case 4: toast(ui, tr("Couldn't transcribe this audio. Choose a recording under 10 minutes."))
		case: toast(ui, tr("Couldn't transcribe your speech. Please try again."))
		}
		return
	}
	if ui.stt.purpose == .Download { return }
	header_n, header_err := os.read_at(ui.stt.file, status[:], 0)
	length := int(status[1]) | (int(status[2]) << 8)
	if header_err != nil || header_n != len(status) ||
	   (status[0] != 'P' && status[0] != 'T') || length > 16384 || length < ui.stt.received {
		stt_stop(ui)
		toast(ui, tr("Couldn't transcribe your speech. Please try again."))
		return
	}
	if running && length > 0 && length == ui.stt.received { return }
	buf: [16384]u8
	n, read_err := os.read_at(ui.stt.file, buf[:length], 4)
	if (read_err != nil && read_err != .EOF) || n != length ||
	   !utf8.valid_string(string(buf[:n])) || strings.contains(string(buf[:n]), "\x00") {
		stt_stop(ui)
		toast(ui, tr("Couldn't transcribe your speech. Please try again."))
		return
	}
	text := strings.trim_space(string(buf[:n]))
	previous := ui.stt.received
	if text == "" {
		if running { return }
		toast(ui, tr("Couldn't hear any speech. Speak clearly and try again."))
		return
	}
	ui.stt.received = length
	if ui.stt.message != "" {
		for msg in ui.messages {
			if msg.id != ui.stt.message { continue }
			for entry in msg.audios {
				if entry.att == ui.stt.attachment {
					delete(entry.view.transcript)
					entry.view.transcript = strings.clone(text)
					entry.view.transcript_open = true
					if !running {
						entry.view.transcript_done = true
						if !stt_cache_save(entry.view, ui.stt.selected_model) {
							toast(ui, tr("Couldn't cache your transcription. Please try again."))
						}
					}
					return
				}
			}
		}
		return
	}
	if previous == n { return }
	// Append only new bytes, preserving the draft binding after our own edit.
	text = string(buf[previous:n])
	if previous == 0 { text = strings.trim_left_space(text) }
	ed_begin(ui, &ui.compose)
	at := len(ui.compose)
	ui.ed.selection = {at, at}
	if previous == 0 && at > 0 && !strings.has_suffix(string(ui.compose[:]), " ") && !strings.has_suffix(string(ui.compose[:]), "\n") {
		edit.input_text(&ui.ed, " ")
	}
	edit.input_text(&ui.ed, text)
	ed_end(ui, &ui.compose)
	delete(ui.stt.draft)
	ui.stt.draft = strings.clone(string(ui.compose[:]))
	ui.focus = .Compose
}

@(private)
stt_status :: proc(ui: ^Ui_State) -> string {
	switch ui.stt.status {
	case 'D': return fmt.tprintf("%s %d/%d: %d%%", tr("Downloading speech model..."), ui.stt.model + 1, STT_MODELS[ui.stt.selected_model].count, ui.stt.percent)
	case 'R': return tr("Listening... Finish when you're done (30 seconds maximum).")
	case 'C', 'P': return tr("Transcribing...")
	case: return ui.stt.message == "" ? tr("Preparing dictation...") : tr("Preparing transcription...")
	}
}
