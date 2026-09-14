package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "core:unicode/utf8"
import "core:text/edit"

@(private)
STT_MODEL_REV :: "65176e2deb88badc814a94058666cadccc29b61c"

@(private)
Stt_State :: struct {
	child: os.Process,
	file: ^os.File,
	status, model, percent: u8,
	account, group, thread, editing, draft: string,
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
	ui.stt = {}
}

@(private)
stt_start :: proc(ui: ^Ui_State) {
	if !ui.prefs.stt_enabled || ui.stt.file != nil || voice.stream != nil ||
	   ui.selected < 0 || ui.selected >= len(ui.chats) {
		return
	}
	tts_stop(ui)
	fd, ferr := linux.memfd_create("wn-stt", {.CLOEXEC})
	if ferr != .NONE {
		toast(ui, tr("Couldn't start dictation. Please try again."))
		return
	}
	file := os.new_file(uintptr(fd), "wn-stt")
	if file == nil {
		linux.close(fd)
		toast(ui, tr("Couldn't start dictation. Please try again."))
		return
	}
	ok := false
	defer if !ok {
		os.close(file)
	}
	n, err := os.write_string(file, "G\x00\x00\x00")
	exe, exe_err := os.read_link("/proc/self/exe", context.temp_allocator)
	if err != nil || n != 4 || exe_err != nil {
		toast(ui, tr("Couldn't start dictation. Please try again."))
		return
	}
	child, start_err := os.process_start({
		command = {fmt.tprintf("%s/wn-stt", filepath.dir(exe)),
			fmt.tprintf("%s/stt/%s", data_home, STT_MODEL_REV), fmt.tprintf("%d", os.get_pid())},
		stdin = file, stdout = file,
	})
	if start_err != nil {
		toast(ui, tr("Couldn't start dictation. Please try again."))
		return
	}
	ok = true
	ui.stt = {child = child, file = file, status = 'G',
		account = strings.clone(ui.account_ref), group = strings.clone(ui.chats[ui.selected].group_id),
		thread = strings.clone(thread_cur(ui)), editing = strings.clone(ui.editing),
		draft = strings.clone(string(ui.compose[:]))}
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
	if ui.stt.file == nil {
		return
	}
	// Bind the result to the original draft, never another account/chat/thread.
	if !ui.prefs.stt_enabled || ui.page != .Chats || ui.selected < 0 || ui.selected >= len(ui.chats) ||
	   ui.stt.account != ui.account_ref || ui.stt.group != ui.chats[ui.selected].group_id ||
	   ui.stt.thread != thread_cur(ui) || ui.stt.editing != ui.editing || ui.stt.draft != string(ui.compose[:]) {
		stt_stop(ui)
		return
	}
	status: [3]u8
	if n, err := os.read_at(ui.stt.file, status[:], 0); err == nil && n == len(status) && status[1] < 3 && status[2] <= 100 {
		ui.stt.status, ui.stt.model, ui.stt.percent = status[0], status[1], status[2]
	}
	state, err := os.process_wait(ui.stt.child, timeout = 0)
	if err == .Timeout {
		return
	}
	// The child is already reaped. Cleanup must not signal a reused PID.
	ui.stt.child = {}
	defer stt_stop(ui)
	if err != nil || state.exit_code != 0 {
		switch state.exit_code {
		case 1: toast(ui, tr("Couldn't download the speech model. Check your connection and available disk space, then try again."))
		case 3: toast(ui, tr("Couldn't open the microphone. Please try again."))
		case: toast(ui, tr("Couldn't transcribe your speech. Please try again."))
		}
		return
	}
	header_n, header_err := os.read_at(ui.stt.file, status[:], 0)
	buf: [16385]u8
	n, read_err := os.read_at(ui.stt.file, buf[:], 4)
	if header_err != nil || header_n != len(status) || status[0] != 'T' ||
	   (read_err != nil && read_err != .EOF) || n >= len(buf) ||
	   !utf8.valid_string(string(buf[:n])) || strings.contains(string(buf[:n]), "\x00") {
		toast(ui, tr("Couldn't transcribe your speech. Please try again."))
		return
	}
	text := strings.trim_space(string(buf[:n]))
	if text == "" {
		toast(ui, tr("Couldn't hear any speech. Speak clearly and try again."))
		return
	}
	ed_begin(ui, &ui.compose)
	at := len(ui.compose)
	ui.ed.selection = {at, at}
	if at > 0 && !strings.has_suffix(string(ui.compose[:]), " ") && !strings.has_suffix(string(ui.compose[:]), "\n") {
		edit.input_text(&ui.ed, " ")
	}
	edit.input_text(&ui.ed, text)
	ed_end(ui, &ui.compose)
	ui.focus = .Compose
}

@(private)
stt_status :: proc(ui: ^Ui_State) -> string {
	switch ui.stt.status {
	case 'D': return fmt.tprintf("%s %d/3: %d%%", tr("Downloading speech model..."), ui.stt.model + 1, ui.stt.percent)
	case 'R': return tr("Listening... Finish when you're done (30 seconds maximum).")
	case 'C': return tr("Transcribing...")
	case: return tr("Preparing dictation...")
	}
}
