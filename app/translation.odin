package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

@(private)
TRANSLATION_TEXT_CAP :: 65536
@(private)
TRANSLATION_IPC_SIZE :: 8 + 2 * TRANSLATION_TEXT_CAP
@(private)
TRANSLATION_CACHE_CAP :: 128

@(private)
Translation_Phase :: enum {
	Queued,
	Running,
	Ready,
	Failed,
	Cancelled,
}

@(private)
Translation_Result :: struct {
	id, original, text: string,
	error:              string, // static gettext key
	phase:              Translation_Phase,
	show:               bool,
	current:            bool,
	order:              u64,
}

@(private)
Translation_State :: struct {
	child:                          os.Process,
	file:                           ^Helper_Ipc,
	status, model, percent:         u8,
	account, group, source, target: string,
	active:                         ^Translation_Result,
	results:                        map[string]^Translation_Result,
	order:                          u64,
	language_menu:                  int,
	language_choice:                int,
	paused:                         bool, // a failed model load must not retry for every visible message
}

@(private)
translation_target :: proc(ui: ^Ui_State) -> string {
	if ui.prefs.translation_target != "" {return ui.prefs.translation_target}
	for lang in TRANSLATION_LANGUAGES {
		if lang.code == ui.prefs.locale {return lang.code}
	}
	return "en"
}

@(private)
translation_eligible :: proc(ui: ^Ui_State, msg: Msg_Ui) -> bool {
	when !TRANSLATION_AVAILABLE {return false}
	return(
		ui != nil &&
		ui.prefs.translation_enabled &&
		msg.id != "" &&
		!msg.deleted &&
		!msg.system &&
		len(msg.secrets) == 0 &&
		msg.theme_name == "" &&
		!ui.blocked[msg.sender_id] &&
		len(msg.body) < TRANSLATION_TEXT_CAP &&
		strings.trim_space(msg.body) != "" &&
		!strings.contains(msg.body, "\x00") \
	)
}

@(private)
translation_stop :: proc(ui: ^Ui_State) {
	s := &ui.translation
	if s.file != nil {
		_ = os.process_kill(s.child)
		_, _ = os.process_wait(s.child)
		wn_ipc_close(s.file)
		if s.active != nil {s.active.phase = .Cancelled}
		s.file, s.child, s.active = nil, {}, nil
	}
	s.status, s.model, s.percent = 0, 0, 0
}

@(private)
translation_free :: proc(result: ^Translation_Result) {
	for value in ([]string{result.id, result.original, result.text}) {
		mem.zero_slice(transmute([]u8)value)
		delete(value)
	}
	free(result)
}

@(private)
translation_clear :: proc(ui: ^Ui_State) {
	translation_stop(ui)
	if len(ui.translation.results) > 0 {sel_clear(ui)}
	for _, result in ui.translation.results {translation_free(result)}
	delete(ui.translation.results)
	for value in ([]string{ui.translation.account, ui.translation.group, ui.translation.source, ui.translation.target}) {delete(value)}
	ui.translation = {
		language_menu = ui.translation.language_menu,
	}
	for &msg in ui.messages {msg.row_height = 0}
}

// Results never cross an account, conversation, or language choice.
@(private)
translation_bind :: proc(ui: ^Ui_State) {
	group := ui.selected >= 0 && ui.selected < len(ui.chats) ? ui.chats[ui.selected].group_id : ""
	source := ui.prefs.translation_source != "" ? ui.prefs.translation_source : "auto"
	target := translation_target(ui)
	s := &ui.translation
	if s.account == ui.account_ref &&
	   s.group == group &&
	   s.source == source &&
	   s.target == target {return}
	translation_clear(ui)
	s.account, s.group = strings.clone(ui.account_ref), strings.clone(group)
	s.source, s.target = strings.clone(source), strings.clone(target)
	s.results = make(map[string]^Translation_Result)
}

@(private)
translation_lookup :: proc(ui: ^Ui_State, msg: Msg_Ui) -> ^Translation_Result {
	if !translation_eligible(ui, msg) {return nil}
	result := ui.translation.results[msg.id]
	if result != nil && result.original == msg.body {return result}
	return nil
}

@(private)
translation_request :: proc(ui: ^Ui_State, msg: Msg_Ui) {
	if !translation_eligible(ui, msg) {return}
	translation_bind(ui)
	s := &ui.translation
	if old := s.results[msg.id]; old != nil {
		if old.original == msg.body &&
		   (old.phase == .Queued || old.phase == .Running || old.phase == .Ready) {return}
		if s.active == old {translation_stop(ui)}
		delete_key(&s.results, old.id)
		translation_free(old)
	}
	// Bound plaintext session memory. Only completed, least-recent requests can go.
	if len(s.results) >= TRANSLATION_CACHE_CAP {
		oldest: ^Translation_Result
		for _, result in s.results {
			if result.phase == .Running || result.phase == .Queued {continue}
			if oldest == nil || result.order < oldest.order {oldest = result}
		}
		if oldest == nil {return}
		delete_key(&s.results, oldest.id)
		translation_reflow(ui, oldest.id)
		translation_free(oldest)
	}
	s.order += 1
	result := new(Translation_Result)
	result^ = {
		id       = strings.clone(msg.id),
		original = strings.clone(msg.body),
		phase    = .Queued,
		show     = true,
		order    = s.order,
	}
	s.results[result.id] = result
	for &row in ui.messages {if row.id == msg.id {row.row_height = 0}}
}

@(private)
translation_fail :: proc(ui: ^Ui_State, result: ^Translation_Result, code: int) {
	result.phase = .Failed
	result.error = N_("Couldn't translate this message. Please try again.")
	switch code {
	case 1:
		result.error = N_(
			"Couldn't download the translation model. Check your connection and available disk space, then try again.",
		)
		ui.translation.paused = true
	case 3:
		result.error = N_(
			"Couldn't identify a supported language. Choose the source language in translation settings and try again.",
		)
	case 4:
		result.error = N_("Couldn't translate this message. Choose a shorter text message.")
	}
	if code == 2 {ui.translation.paused = true}
	if ui.translation.paused {
		for _, queued in ui.translation.results {
			if queued.phase != .Queued {continue}
			queued.phase, queued.error = .Failed, result.error
		}
	}
}

@(private)
translation_launch :: proc(ui: ^Ui_State, result: ^Translation_Result) {
	s := &ui.translation
	file := wn_ipc_create(TRANSLATION_IPC_SIZE)
	if file == nil {translation_fail(ui, result, 2); return}
	ok := false
	defer if !ok {wn_ipc_close(file)}
	if helper_write_at(file, []u8{'G', 0, 0, 0, 0, 0, 0, 0}) != 8 ||
	   helper_write_at(file, transmute([]u8)result.original, 8) != len(result.original) ||
	   helper_write_at(file, []u8{0}, uint(8 + len(result.original))) != 1 {
		translation_fail(ui, result, 2)
		return
	}
	child, err := os.process_start(
		{
			command = {
				helper_path("wn-translate"),
				fmt.tprintf("%s/translation/%s", data_home, TRANSLATION_MODEL_DIR),
				fmt.tprintf("%d", os.get_pid()),
				s.source,
				s.target,
				string(wn_ipc_name(file)),
				fmt.tprintf("%d", TRANSLATION_IPC_SIZE),
			},
		},
	)
	if err != nil {
		translation_fail(ui, result, 2)
		result.error = N_("Couldn't start translation. Reinstall White Noise and try again.")
		return
	}
	ok = true
	s.child, s.file, s.active, s.status = child, file, result, 'G'
	result.phase = .Running
}

@(private)
translation_tick :: proc(ui: ^Ui_State) {
	if !ui.prefs.translation_enabled {if len(ui.translation.results) > 0 || ui.translation.file != nil {translation_clear(ui)}; return}
	translation_bind(ui)
	s := &ui.translation
	for _, result in s.results {result.current = false}
	for msg in ui.messages {
		result := s.results[msg.id]
		if result !=
		   nil {result.current = result.original == msg.body && translation_eligible(ui, msg)}
	}
	for _, result in s.results {
		if result.current {continue}
		if s.active == result {translation_stop(ui)}
		delete_key(&s.results, result.id)
		translation_reflow(ui, result.id)
		translation_free(result)
	}
	if s.file != nil {
		header: [8]u8
		if helper_read_at(s.file, header[:], 0) == len(header) && header[2] <= 100 {
			s.status, s.model, s.percent = header[0], header[1], header[2]
		}
		state, err := os.process_wait(s.child, timeout = 0)
		if err == .Timeout {return}
		result := s.active
		// The child can publish and exit between the progress read and wait.
		finished := helper_read_at(s.file, header[:], 0) == len(header)
		if err == nil && state.exit_code == 0 && finished && header[0] == 'R' {
			word, _ := endian.get_u32(header[4:8], .Little)
			length := int(word)
			if length > 0 && length < TRANSLATION_TEXT_CAP {
				bytes := make([]u8, length)
				if helper_read_at(s.file, bytes, 8 + TRANSLATION_TEXT_CAP) == length &&
				   utf8.valid_string(string(bytes)) &&
				   !strings.contains(string(bytes), "\x00") {
					result.text, result.phase = string(bytes), .Ready
				} else {delete(bytes)}
			}
		}
		if result.phase !=
		   .Ready {translation_fail(ui, result, err == nil ? int(state.exit_code) : 2)}
		wn_ipc_close(s.file)
		s.file, s.child, s.active = nil, {}, nil
		translation_reflow(ui, result.id)
	}
	if s.paused {return}
	// Queue only measured rows in the viewport, not a conversation's entire history.
	if ui.prefs.translation_auto && ui.page == .Chats && !ui.show_members {
		view := clay.GetScrollContainerData(clay.ID("Timeline"))
		if view.found {
			for msg in ui.messages {
				y := msg.row_top + view.scrollPosition.y
				if msg.mine ||
				   (msg.thread_of != thread_cur(ui) && msg.id != thread_cur(ui)) ||
				   msg.row_height <= 0 ||
				   y + msg.row_height < 0 ||
				   y > view.scrollContainerDimensions.height {continue}
				if s.results[msg.id] == nil {translation_request(ui, msg)}
			}
		}
	}
	next: ^Translation_Result
	for _, result in s.results {
		if result.phase == .Queued && (next == nil || result.order < next.order) {next = result}
	}
	if next != nil {translation_launch(ui, next)}
}

@(private)
translation_status :: proc(ui: ^Ui_State) -> string {
	if ui.translation.file == nil {return ""}
	switch ui.translation.status {
	case 'D':
		return tr("Downloading translation model...")
	case 'T':
		return tr("Translating on your device...")
	case:
		return tr("Preparing translation model...")
	}
}

@(private)
translation_controls :: proc(ui: ^Ui_State, index: u32, msg: Msg_Ui) {
	result := translation_lookup(ui, msg)
	if result == nil {return}
	if clay.UI(clay.ID("TranslationControls", index))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childGap = 4,
		},
	},
	) {
		switch result.phase {
		case .Queued:
			clay.Text(
				tr("Waiting to translate..."),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
			)
		case .Running:
			clay.Text(
				translation_status(ui),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
			)
			translation_progress(ui, fmt.tprintf("TranslationProgress%d", index))
		case .Ready:
			micro_button(
				fmt.tprintf("TranslationToggle%d", index),
				tr(result.show ? N_("Show original") : N_("Show translation")),
			)
		case .Failed:
			clay.Text(tr(result.error), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
			micro_button(fmt.tprintf("TranslationRetry%d", index), tr("Try again"))
		case .Cancelled:
			micro_button(fmt.tprintf("TranslationRetry%d", index), tr("Translate"))
		}
		if result.phase == .Queued || result.phase == .Running {
			micro_button(fmt.tprintf("TranslationCancel%d", index), tr("Cancel translation"))
		}
	}
}

@(private)
translation_action :: proc(ui: ^Ui_State, msg: Msg_Ui, index: u32) -> bool {
	result := translation_lookup(ui, msg)
	if result == nil {return false}
	if clicked(fmt.tprintf("TranslationToggle%d", index)) && result.phase == .Ready {
		result.show = !result.show
		translation_reflow(ui, msg.id)
		return true
	}
	if clicked(fmt.tprintf("TranslationRetry%d", index)) {
		ui.translation.paused = false
		translation_request(ui, msg)
		return true
	}
	if clicked(fmt.tprintf("TranslationCancel%d", index)) {
		if ui.translation.active == result {translation_stop(ui)} else {result.phase = .Cancelled}
		return true
	}
	return false
}

// Markdown and plain bodies share a row's 4096-ID band. Their byte offsets
// cannot survive replacing the displayed text with another language.
@(private)
translation_reflow :: proc(ui: ^Ui_State, id: string) {
	for &msg, i in ui.messages {
		if msg.id != id {continue}
		msg.row_height = 0
		if ui.sel_on && ui.sel_block / 4096 == u32(i) {sel_clear(ui)}
		return
	}
}
