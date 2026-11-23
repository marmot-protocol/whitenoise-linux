package main

import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import "nendo"

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
Translation_Source :: enum {
	Body,
	Transcript,
}

@(private)
Translation_Key :: struct {
	id:         string,
	source:     Translation_Source,
	attachment: int,
}

@(private)
Translation_Result :: struct {
	key:            Translation_Key,
	original, text: string,
	error:          string, // static gettext key
	phase:          Translation_Phase,
	show:           bool,
	current:        bool,
	order:          u64,
}

@(private)
Translation_Model_Action :: enum {
	None,
	Check,
	Download,
	Remove,
}

@(private)
Translation_Model_State :: enum {
	Unknown,
	Missing,
	Partial,
	Ready,
	CheckFailed,
}

@(private)
Translation_State :: struct {
	child:                          os.Process,
	file:                           ^Helper_Ipc,
	status, model, percent:         u8,
	model_action:                   Translation_Model_Action,
	model_state:                    Translation_Model_State,
	account, group, source, target: string,
	active:                         ^Translation_Result,
	results:                        map[Translation_Key]^Translation_Result,
	auto_cancelled:                 map[string]bool,
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
translation_text :: proc(msg: Msg_Ui, source: Translation_Source, attachment: int) -> string {
	if source == .Body {return msg.body}
	view := msg_audio(msg, attachment)
	if view == nil || !view.transcript_done {return ""}
	return view.transcript
}

@(private)
translation_eligible :: proc(
	ui: ^Ui_State,
	msg: Msg_Ui,
	source: Translation_Source = .Body,
	attachment: int = 0,
) -> bool {
	when !TRANSLATION_AVAILABLE {return false}
	text := translation_text(msg, source, attachment)
	return(
		ui != nil &&
		ui.prefs.translation_enabled &&
		msg.id != "" &&
		!msg.deleted &&
		!msg.system &&
		len(msg.secrets) == 0 &&
		msg.theme_name == "" &&
		!ui.blocked[msg.sender_id] &&
		len(text) < TRANSLATION_TEXT_CAP &&
		strings.trim_space(text) != "" &&
		!strings.contains(text, "\x00") \
	)
}

@(private)
translation_model_dir :: proc() -> string {
	return fmt.tprintf("%s/translation/%s", data_home, TRANSLATION_MODEL_DIR)
}

@(private)
translation_settings_open :: proc(ui: ^Ui_State) -> bool {
	return(
		ui.page == .Settings &&
		ui.settings_section == .General &&
		ui.settings_tab == 1 &&
		!ui.add_account_open &&
		!ui.new_chat_open &&
		!settings_on_menu(ui) \
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
		s.model_action, s.model_state = .None, .Unknown
	}
	s.status, s.model, s.percent = 0, 0, 0
}

@(private)
translation_cancel_queued :: proc(ui: ^Ui_State) {
	for _, result in ui.translation.results {
		if result.phase != .Queued {continue}
		result.phase = .Cancelled
		translation_reflow(ui, result.key.id)
	}
}

@(private)
translation_clear_auto :: proc(s: ^Translation_State) {
	for id in s.auto_cancelled {delete(id)}
	delete(s.auto_cancelled)
	s.auto_cancelled = nil
}

@(private)
translation_cancel :: proc(ui: ^Ui_State) {
	if ui.translation.model_action == .Download {
		// Keep visible messages from immediately restarting a cancelled download.
		translation_clear_auto(&ui.translation)
		translation_visible(ui, .Remember)
		translation_cancel_queued(ui)
	}
	translation_stop(ui)
}

@(private)
translation_free :: proc(result: ^Translation_Result) {
	for value in ([]string{result.key.id, result.original, result.text}) {
		mem.zero_slice(transmute([]u8)value)
		delete(value)
	}
	free(result)
}

@(private)
translation_clear :: proc(ui: ^Ui_State) {
	s := &ui.translation
	if s.active != nil {translation_stop(ui)}
	if len(s.results) > 0 {sel_clear(ui)}
	for _, result in s.results {translation_free(result)}
	delete(s.results)
	translation_clear_auto(s)
	for value in ([]string{s.account, s.group, s.source, s.target}) {delete(value)}
	s.results, s.order, s.language_choice, s.paused = nil, 0, 0, false
	s.account, s.group, s.source, s.target = "", "", "", ""
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
	s.results = make(map[Translation_Key]^Translation_Result)
}

@(private)
translation_lookup :: proc(
	ui: ^Ui_State,
	msg: Msg_Ui,
	source: Translation_Source = .Body,
	attachment: int = 0,
) -> ^Translation_Result {
	if !translation_eligible(ui, msg, source, attachment) {return nil}
	result := ui.translation.results[Translation_Key{msg.id, source, attachment}]
	if result != nil &&
	   result.original == translation_text(msg, source, attachment) {return result}
	return nil
}

@(private)
translation_request :: proc(
	ui: ^Ui_State,
	msg: Msg_Ui,
	source: Translation_Source = .Body,
	attachment: int = 0,
) {
	if !translation_eligible(ui, msg, source, attachment) {return}
	translation_bind(ui)
	s := &ui.translation
	key := Translation_Key{msg.id, source, attachment}
	text := translation_text(msg, source, attachment)
	if old := s.results[key]; old != nil {
		if old.original == text &&
		   (old.phase == .Queued || old.phase == .Running || old.phase == .Ready) {return}
		if s.active == old {translation_stop(ui)}
		delete_key(&s.results, old.key)
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
		delete_key(&s.results, oldest.key)
		translation_reflow(ui, oldest.key.id)
		translation_free(oldest)
	}
	s.order += 1
	result := new(Translation_Result)
	result^ = {
		key      = {strings.clone(msg.id), source, attachment},
		original = strings.clone(text),
		phase    = .Queued,
		show     = true,
		order    = s.order,
	}
	s.results[result.key] = result
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
translation_model_error :: proc(ui: ^Ui_State, action: Translation_Model_Action) {
	text: string
	switch action {
	case .Check:
		ui.translation.model_state = .CheckFailed
		return
	case .Remove:
		text = tr("Couldn't remove the translation model. Please try again.")
	case .Download:
		text = tr(
			"Couldn't download the translation model. Check your connection and available disk space, then try again.",
		)
	case .None:
		return
	}
	set_status(ui, text, .Error)
}

@(private)
translation_launch :: proc(
	ui: ^Ui_State,
	result: ^Translation_Result,
	action := Translation_Model_Action.None,
) {
	s := &ui.translation
	source, target := s.source, s.target
	switch action {
	case .None:
	case .Check:
		source, target = "check", ""
	case .Download:
		source, target = "download", ""
	case .Remove:
		source, target = "remove", ""
	}
	file := wn_ipc_create(TRANSLATION_IPC_SIZE)
	ok := false
	start_error: string
	defer if !ok {
		if file != nil {wn_ipc_close(file)}
		if result != nil {
			translation_fail(ui, result, 2)
			if start_error != "" {result.error = start_error}
		} else {
			translation_model_error(ui, action)
		}
	}
	if file == nil || helper_write_at(file, []u8{'G', 0, 0, 0, 0, 0, 0, 0}) != 8 {
		return
	}
	if result != nil &&
	   (helper_write_at(file, transmute([]u8)result.original, 8) != len(result.original) ||
			   helper_write_at(file, []u8{0}, uint(8 + len(result.original))) != 1) {
		return
	}
	child, err := os.process_start(
		{
			command = {
				helper_path("wn-translate"),
				translation_model_dir(),
				fmt.tprintf("%d", os.get_pid()),
				source,
				target,
				string(wn_ipc_name(file)),
				fmt.tprintf("%d", TRANSLATION_IPC_SIZE),
			},
		},
	)
	if err != nil {
		start_error = N_("Couldn't start translation. Reinstall White Noise and try again.")
		return
	}
	ok = true
	s.child, s.file, s.active, s.status = child, file, result, 'G'
	s.model_action = action
	if result != nil {result.phase = .Running}
	if action == .Remove {
		// A queued request must not immediately download what Remove just deleted.
		translation_cancel_queued(ui)
	}
}

@(private)
translation_tick :: proc(ui: ^Ui_State) {
	s := &ui.translation
	if !ui.prefs.translation_enabled {
		if s.file != nil {translation_stop(ui)}
		if s.results != nil {translation_clear(ui)}
		s.model_state = .Unknown
		return
	}
	translation_bind(ui)
	show_model := translation_settings_open(ui)
	defer if !show_model {s.model_state = .Unknown}
	if show_model && s.model_state == .Unknown && s.file == nil {
		translation_launch(ui, nil, .Check)
		return
	}
	for _, result in s.results {result.current = false}
	for msg in ui.messages {
		for source in Translation_Source {
			count := source == .Body ? 1 : len(msg.attachments)
			for attachment in 0 ..< count {
				result := s.results[Translation_Key{msg.id, source, attachment}]
				if result == nil {continue}
				result.current =
					result.original == translation_text(msg, source, attachment) &&
					translation_eligible(ui, msg, source, attachment)
			}
		}
	}
	for _, result in s.results {
		if result.current {continue}
		if s.active == result {translation_stop(ui)}
		delete_key(&s.results, result.key)
		translation_reflow(ui, result.key.id)
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
		if result == nil {
			wn_ipc_close(s.file)
			action := s.model_action
			s.file, s.child, s.model_action = nil, {}, .None
			if err != nil || state.exit_code != 0 {
				s.model_state = .Unknown
				translation_model_error(ui, action)
				return
			}
			switch action {
			case .Check:
				if !finished {header[0] = 0}
				switch header[0] {
				case 'R':
					s.model_state = .Ready
				case 'P':
					s.model_state = .Partial
				case 'M':
					s.model_state = .Missing
				case:
					translation_model_error(ui, action)
				}
			case .Download:
				s.model_state, s.paused = .Ready, false
			case .Remove:
				s.model_state = .Missing
			case .None:
			}
			return
		}
		s.model_state = .Unknown
		if err == nil && state.exit_code == 0 && finished && header[0] == 'R' {
			s.model_state = .Ready
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
		translation_reflow(ui, result.key.id)
	}
	if s.paused {return}
	translation_visible(ui, .Queue)
	next: ^Translation_Result
	for _, result in s.results {
		if result.phase == .Queued && (next == nil || result.order < next.order) {next = result}
	}
	if next != nil {translation_launch(ui, next)}
}

@(private)
Translation_Viewport_Action :: enum {
	Queue,
	Remember,
}

// Consider only measured rows in the viewport, not the whole conversation.
@(private)
translation_visible :: proc(ui: ^Ui_State, action: Translation_Viewport_Action) {
	if !ui.prefs.translation_auto ||
	   ui.page != .Chats ||
	   ui.show_members ||
	   ui.add_account_open ||
	   ui.new_chat_open ||
	   ui.selected < 0 ||
	   ui.selected >= len(ui.chats) {return}
	view := nendo.scroll(nendo.id("Timeline"))
	if !view.found {return}
	s := &ui.translation
	if action == .Remember {s.auto_cancelled = make(map[string]bool)}
	thread := thread_cur(ui)
	for msg in ui.messages {
		y := msg.row_top + view.position.y
		if msg.mine ||
		   (msg.thread_of != thread && msg.id != thread) ||
		   msg.row_height <= 0 ||
		   y + msg.row_height < 0 ||
		   y > view.viewport.height {continue}
		if s.auto_cancelled[msg.id] {continue}
		if action == .Remember {
			s.auto_cancelled[strings.clone(msg.id)] = true
			continue
		}
		if s.results[Translation_Key{id = msg.id}] == nil {translation_request(ui, msg)}
		for _, attachment in msg.attachments {
			audio := msg_audio(msg, attachment)
			if audio == nil || !audio.transcript_open {continue}
			key := Translation_Key{msg.id, .Transcript, attachment}
			if s.results[key] == nil {translation_request(ui, msg, .Transcript, attachment)}
		}
	}
}

@(private)
translation_status :: proc(ui: ^Ui_State) -> string {
	if ui.translation.file == nil {return ""}
	if ui.translation.model_action == .Check {return tr("Verifying download...")}
	if ui.translation.model_action == .Remove {return tr("Removing…")}
	switch ui.translation.status {
	case 'D':
		return tr("Downloading translation model...")
	case 'T':
		return tr("Translating on your device...")
	case:
		if ui.translation.model_action == .Download {return tr("Preparing download...")}
		return tr("Preparing translation model...")
	}
}

@(private)
translation_controls :: proc(
	ui: ^Ui_State,
	index: u32,
	msg: Msg_Ui,
	source: Translation_Source = .Body,
	attachment: int = 0,
) {
	result := translation_lookup(ui, msg, source, attachment)
	if result == nil {return}
	prefix := source == .Body ? "Translation" : "TranscriptTranslation"
	if nendo.box(
		nendo.id(source == .Body ? "TranslationControls" : "TranscriptTranslationControls", index),
	)(
		{width = nendo.grow(), direction = .Column, gap = 4},
	) {
		switch result.phase {
		case .Queued:
			nendo.text(
				tr("Waiting to translate..."),
				{font = FONT_BODY, size = 11, color = TEXT_DIM},
			)
		case .Running:
			nendo.text(translation_status(ui), {font = FONT_BODY, size = 11, color = TEXT_DIM})
			translation_progress(ui, fmt.tprintf("%sProgress%d", prefix, index))
		case .Ready:
			micro_button(
				fmt.tprintf("%sToggle%d", prefix, index),
				tr(result.show ? N_("Show original") : N_("Show translation")),
			)
		case .Failed:
			nendo.text(tr(result.error), {font = FONT_BODY, size = 11, color = TEXT_DIM})
			micro_button(fmt.tprintf("%sRetry%d", prefix, index), tr("Try again"))
		case .Cancelled:
			micro_button(fmt.tprintf("%sRetry%d", prefix, index), tr("Translate"))
		}
		if result.phase == .Queued || result.phase == .Running {
			micro_button(fmt.tprintf("%sCancel%d", prefix, index), tr("Cancel translation"))
		}
	}
}

@(private)
translation_action :: proc(
	ui: ^Ui_State,
	msg: Msg_Ui,
	index: u32,
	source: Translation_Source = .Body,
	attachment: int = 0,
) -> bool {
	prefix := source == .Body ? "Translation" : "TranscriptTranslation"
	if source == .Transcript &&
	   clicked(fmt.tprintf("%sStart%d", prefix, index)) &&
	   translation_eligible(ui, msg, source, attachment) {
		ui.translation.paused = false
		translation_request(ui, msg, source, attachment)
		return true
	}
	result := translation_lookup(ui, msg, source, attachment)
	if result == nil {return false}
	if clicked(fmt.tprintf("%sToggle%d", prefix, index)) && result.phase == .Ready {
		result.show = !result.show
		translation_reflow(ui, msg.id)
		return true
	}
	if clicked(fmt.tprintf("%sRetry%d", prefix, index)) {
		ui.translation.paused = false
		translation_request(ui, msg, source, attachment)
		return true
	}
	if clicked(fmt.tprintf("%sCancel%d", prefix, index)) {
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
