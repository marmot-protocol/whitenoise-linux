package main

import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"
import "core:text/edit"

@(test)
stt_draft_safety :: proc(t: ^testing.T) {
	// A fake helper supplies a real memfd result, without a model or microphone.
	for scenario in 0 ..< 5 {
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
		ui.stt = {file = file, child = child, account = strings.clone("account"),
			group = strings.clone("chat"), draft = strings.clone("Draft")}
		ui.stt.status = 'R'
		stt_finish(&ui)
		command: [1]u8
		_, _ = os.read_at(file, command[:], 3)
		testing.expect(t, command[0] == 'S')
		n, write_err := os.write_string(file, "T\x00\x00\x00こんにちは")
		testing.expect(t, write_err == nil && n > 4)
		switch scenario {
		case 1: ui.account_ref = "other"
		case 2: ui.chats[0].group_id = "other"
		case 3: append(&ui.thread_stack, "other")
		case 4: append(&ui.compose, " changed")
		}
		for attempt := 0; attempt < 1000 && ui.stt.file != nil; attempt += 1 {
			stt_tick(&ui)
			time.sleep(time.Millisecond)
		}
		testing.expect(t, ui.stt.file == nil)
		want := scenario == 0 ? "Draft こんにちは" : scenario == 4 ? "Draft changed" : "Draft"
		testing.expect_value(t, string(ui.compose[:]), want)
		stt_stop(&ui)
		delete(ui.chats)
		delete(ui.compose)
		delete(ui.thread_stack)
		edit.destroy(&ui.ed)
	}
}
