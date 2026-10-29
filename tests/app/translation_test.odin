package main

import "core:os"
import "core:strings"
import "core:testing"

@(test)
translation_revisions :: proc(t: ^testing.T) {
	when !TRANSLATION_AVAILABLE {return}
	ui: Ui_State
	ui.account_ref = "account"
	ui.prefs.translation_enabled = true
	append(&ui.chats, Chat_Row_Ui{group_id = "conversation"})
	append(&ui.messages, Msg_Ui{id = "message", body = "Guten Morgen."})
	defer {translation_clear(&ui); delete(ui.chats); delete(ui.messages)}
	translation_request(&ui, ui.messages[0])
	translation_request(&ui, ui.messages[0])
	testing.expect_value(t, len(ui.translation.results), 1)
	testing.expect(t, ui.translation.results[Translation_Key{id = "message"}].phase == .Queued)
	// An edit is a new request even though its signed message identity is unchanged.
	ui.messages[0].body = "Guten Abend."
	testing.expect(t, translation_lookup(&ui, ui.messages[0]) == nil)
	translation_request(&ui, ui.messages[0])
	testing.expect_value(
		t,
		ui.translation.results[Translation_Key{id = "message"}].original,
		"Guten Abend.",
	)
	testing.expect_value(t, ui.messages[0].body, "Guten Abend.")
	ui.prefs.translation_target = "ja"
	translation_bind(&ui)
	testing.expect_value(t, len(ui.translation.results), 0)
	translation_request(&ui, ui.messages[0])
	ui.messages[0].deleted = true
	translation_tick(&ui)
	testing.expect_value(t, len(ui.translation.results), 0)
	testing.expect(t, ui.translation.file == nil)
}

@(test)
translation_session_cancel :: proc(t: ^testing.T) {
	when !TRANSLATION_AVAILABLE {return}
	ui: Ui_State
	ui.account_ref = "first-account"
	ui.prefs.translation_enabled = true
	append(&ui.chats, Chat_Row_Ui{group_id = "conversation"})
	append(
		&ui.messages,
		Msg_Ui{id = "first", body = "Buongiorno."},
		Msg_Ui{id = "second", body = "Buonasera."},
	)
	defer {translation_clear(&ui); delete(ui.chats); delete(ui.messages)}
	for msg in ui.messages {translation_request(&ui, msg)}
	child, pipe, started := speech_test_process()
	testing.expect(t, started)
	if !started {return}
	defer os.close(pipe)
	ui.translation.child = child
	ui.translation.file = wn_ipc_create(TRANSLATION_IPC_SIZE)
	testing.expect(t, ui.translation.file != nil)
	if ui.translation.file == nil {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child)
		return
	}
	ui.translation.active = ui.translation.results[Translation_Key{id = "first"}]
	ui.translation.active.phase = .Running
	translation_stop(&ui)
	testing.expect(t, ui.translation.results[Translation_Key{id = "first"}].phase == .Cancelled)
	testing.expect(t, ui.translation.results[Translation_Key{id = "second"}].phase == .Queued)
	testing.expect(t, ui.translation.file == nil && ui.translation.child.pid == 0)
	// Switching accounts discards queued text as well as completed renditions.
	ui.account_ref = "second-account"
	translation_bind(&ui)
	testing.expect_value(t, len(ui.translation.results), 0)
	translation_request(&ui, ui.messages[0])
	ui.prefs.translation_enabled = false
	translation_tick(&ui)
	testing.expect_value(t, len(ui.translation.results), 0)
}

@(test)
translation_selection :: proc(t: ^testing.T) {
	ui: Ui_State
	append(&ui.messages, Msg_Ui{id = "first"}, Msg_Ui{id = "second"})
	defer {sel_clear(&ui); delete(ui.messages)}
	ui.sel_on = true
	ui.sel_block = 4096 + 16 // a paragraph in the second message
	ui.sel_copy = strings.clone("Selected original text")
	translation_reflow(&ui, "first")
	testing.expect(t, ui.sel_on)
	testing.expect_value(t, ui.sel_copy, "Selected original text")
	translation_reflow(&ui, "second")
	testing.expect(t, !ui.sel_on && ui.sel_copy == "")
}

@(test)
translation_queue_failure :: proc(t: ^testing.T) {
	when !TRANSLATION_AVAILABLE {return}
	ui: Ui_State
	ui.prefs.translation_enabled = true
	append(
		&ui.messages,
		Msg_Ui{id = "first", body = "Guten Morgen."},
		Msg_Ui{id = "second", body = "Guten Abend."},
	)
	defer {translation_clear(&ui); delete(ui.messages)}
	for msg in ui.messages {translation_request(&ui, msg)}
	translation_fail(&ui, ui.translation.results[Translation_Key{id = "first"}], 1)
	testing.expect(t, ui.translation.paused)
	testing.expect(t, ui.translation.results[Translation_Key{id = "second"}].phase == .Failed)
	testing.expect_value(
		t,
		ui.translation.results[Translation_Key{id = "second"}].error,
		ui.translation.results[Translation_Key{id = "first"}].error,
	)
}

@(test)
translation_audio_sources :: proc(t: ^testing.T) {
	when !TRANSLATION_AVAILABLE {return}
	ui: Ui_State
	ui.prefs.translation_enabled = true
	first := Video_View {
		audio           = true,
		transcript      = "Guten Morgen.",
		transcript_done = true,
	}
	second := Video_View {
		audio           = true,
		transcript      = "Buonasera.",
		transcript_done = true,
	}
	append(&ui.messages, Msg_Ui{id = "message", body = "Meeting at noon."})
	append(
		&ui.messages[0].attachments,
		Att_Slot{kind = .Audio, view = &first},
		Att_Slot{kind = .Audio, view = &second},
	)
	defer {translation_clear(&ui); delete(ui.messages[0].attachments); delete(ui.messages)}
	translation_request(&ui, ui.messages[0])
	translation_request(&ui, ui.messages[0], .Transcript, 0)
	translation_request(&ui, ui.messages[0], .Transcript, 1)
	body := translation_lookup(&ui, ui.messages[0])
	audio := translation_lookup(&ui, ui.messages[0], .Transcript, 0)
	other := translation_lookup(&ui, ui.messages[0], .Transcript, 1)
	testing.expect(t, body != nil && audio != nil && other != nil)
	if body == nil || audio == nil || other == nil {return}
	testing.expect_value(t, body.original, "Meeting at noon.")
	testing.expect_value(t, audio.original, "Guten Morgen.")
	testing.expect_value(t, other.original, "Buonasera.")
	audio.phase, audio.text = .Ready, strings.clone("Good morning.")
	translation_request(&ui, ui.messages[0], .Transcript, 1)
	testing.expect_value(t, audio.text, "Good morning.")
	testing.expect_value(t, first.transcript, "Guten Morgen.")
	testing.expect_value(t, ui.messages[0].body, "Meeting at noon.")
	first.transcript = "Guten Abend."
	testing.expect(t, translation_lookup(&ui, ui.messages[0], .Transcript, 0) == nil)
	translation_request(&ui, ui.messages[0], .Transcript, 0)
	testing.expect_value(
		t,
		translation_lookup(&ui, ui.messages[0], .Transcript, 0).original,
		"Guten Abend.",
	)
	testing.expect_value(
		t,
		translation_lookup(&ui, ui.messages[0], .Transcript, 1).original,
		"Buonasera.",
	)
	testing.expect_value(t, translation_lookup(&ui, ui.messages[0]).original, "Meeting at noon.")
}

@(test)
translation_audio_revisions :: proc(t: ^testing.T) {
	when !TRANSLATION_AVAILABLE {return}
	ui: Ui_State
	ui.prefs.translation_enabled = true
	view := Video_View {
		audio      = true,
		transcript = "Guten Morgen.",
	}
	append(&ui.messages, Msg_Ui{id = "message"})
	append(&ui.messages[0].attachments, Att_Slot{kind = .Audio, view = &view})
	defer {translation_clear(&ui); delete(ui.messages[0].attachments); delete(ui.messages)}
	translation_request(&ui, ui.messages[0], .Transcript, 0)
	testing.expect_value(t, len(ui.translation.results), 0)
	view.transcript_done = true
	translation_request(&ui, ui.messages[0], .Transcript, 0)
	testing.expect(t, translation_lookup(&ui, ui.messages[0], .Transcript, 0) != nil)
	ui.translation.paused = true
	view.transcript_done = false
	translation_tick(&ui)
	testing.expect_value(t, len(ui.translation.results), 0)
	view.transcript_done = true
	translation_request(&ui, ui.messages[0], .Transcript, 0)
	ui.messages[0].attachments[0].kind = .Video
	translation_tick(&ui)
	testing.expect_value(t, len(ui.translation.results), 0)
	ui.messages[0].attachments[0].kind = .Audio
	translation_request(&ui, ui.messages[0], .Transcript, 0)
	ui.messages[0].deleted = true
	translation_tick(&ui)
	testing.expect_value(t, len(ui.translation.results), 0)
	ui.messages[0].deleted = false
	translation_request(&ui, ui.messages[0], .Transcript, 0)
	resize(&ui.messages[0].attachments, 0)
	translation_tick(&ui)
	testing.expect_value(t, len(ui.translation.results), 0)
}
