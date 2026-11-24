package main

import marmot "../marmot"
import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "nendo"
import rl "sdlrl"

@(test)
forward_picker_subject :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "forward_picker_subject" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 700, "Forward picker")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	set_locale("en")
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {nendo.set_context(previous); delete(memory)}
	ui := Ui_State {
		selected   = 0,
		fwd_msg    = "wanted",
		fwd_source = "source",
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "source"}, Chat_Row_Ui{title = "Destination"})
	append(&ui.messages, Msg_Ui{id = "neighbor", body = "Wrong message"}, Msg_Ui{id = "wanted"})
	defer {delete(ui.chats); delete(ui.messages[1].attachments); delete(ui.messages)}
	old_ui, old_prefs := g_ui, g_prefs
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = old_ui, old_prefs}
	append(&ui.messages[1].attachments, Att_Slot{})
	for sample, i in ([]struct {
			body, name, expected: string,
			state:                Att_State,
		}{{"First line\nSecond line", "", "First line", .Ready}, {"", "photo.png", "photo.png", .Ready}, {"", "report.pdf", "report.pdf", .Loading}, {"日本語のメッセージ", "", "日本語のメッセージ", .Ready}}) {
		ui.messages[1].body = sample.body
		ui.messages[1].attachments[0] = {
			name  = sample.name,
			state = sample.state,
		}
		for kind in ([]Fwd_Kind{.Message, .Theme, .Add_Member}) {
			ui.fwd_kind = kind
			nendo.begin()
			forward_modal(&ui)
			commands := nendo.end(0)
			subject := nendo.element(nendo.id("FwdSubject"))
			testing.expect_value(t, subject.found, kind == .Message)
			if kind != .Message {continue}
			found := false
			for command in commands {
				if command.kind != .Text {continue}
				text := command.text.text
				shown := text
				testing.expect(t, shown != "Wrong message" && shown != "Second line")
				if shown != sample.expected {continue}
				found = true
				box, card := command.rect, subject.rect
				testing.expect(t, box.x >= card.x && box.x + box.width <= card.x + card.width)
				testing.expect(t, box.y >= card.y && box.y + box.height <= card.y + card.height)
			}
			testing.expect(t, found, sample.expected)
			rl.BeginDrawing()
			draw_frame(commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-forward-picker-%d.png", i))
			rl.EndDrawing()
		}
	}
}

@(test)
forward_picker_virtual_rows :: proc(t: ^testing.T) {
	if !test_isolated("forward_picker_virtual_rows") {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(390, 560, "Forward destination picker")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts(); load_themes(); apply_theme(0, 0); set_locale("en")
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {390, 560})
	defer {nendo.set_context(previous); delete(memory)}

	CHATS :: 256
	TARGET :: 137
	ui := Ui_State {
		selected   = 0,
		fwd_open   = true,
		fwd_msg    = "wanted",
		fwd_source = "source",
		focus      = .Fwd,
	}
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs = nil, nil
		for &p in ui.pending {free_pending(&p)}
		delete(ui.pending); delete(ui.messages); delete(ui.chats); delete(ui.fwd_filter)
	}
	for i in 0 ..< CHATS {append(&ui.chats, Chat_Row_Ui{title = fmt.tprintf("Chat %03d", i)})}
	ui.chats[0].group_id = "source"
	ui.chats[TARGET] = {
		title    = "Nord Öst",
		group_id = "expected-target",
	}
	append(&ui.messages, Msg_Ui{id = "wanted", body = "Forward this"})
	frame := proc(ui: ^Ui_State, wheel: f32 = 0) -> []nendo.Render_Command {
		anim_tick(1.0 / 60)
		open_now(nendo.id("FwdModal"), true)
		nendo.update_scroll(.Off, {0, wheel}, 1.0 / 60)
		nendo.begin()
		forward_modal(ui)
		return nendo.end(0)
	}
	frame(&ui)
	list_id := nendo.id("FwdList")
	list := nendo.element(list_id).rect
	mounted := 0
	for i in 0 ..< CHATS {if nendo.element(nendo.id("FwdRow", u32(i))).found {mounted += 1}}
	testing.expect(
		t,
		mounted > 0 && mounted <= 10,
		"Only rows near the viewport should be mounted",
	)
	nendo.set_pointer({list.x + 20, list.y + 20}, .Up)
	frame(&ui, -100000)
	last := nendo.element(nendo.id("FwdRow", CHATS - 1))
	testing.expect(
		t,
		last.found && abs(last.rect.y + last.rect.height - (list.y + list.height)) < 1,
	)

	ed_set(&ui, &ui.fwd_filter, "ÖST")
	commands := frame(&ui)
	row := nendo.element(nendo.id("FwdRow", TARGET))
	list = nendo.element(list_id).rect
	if !testing.expect(
		t,
		row.found && abs(row.rect.y - list.y) < 1,
		"The first filtered frame must show the match",
	) {return}
	rl.BeginDrawing(); draw_frame(commands)
	rl.TakeScreenshot("/tmp/wn-forward-filtered.png")
	rl.EndDrawing()
	nendo.set_pointer({row.rect.x + row.rect.width / 2, row.rect.y + row.rect.height / 2}, .Up)
	forced_release = true
	handle_forward(&ui, nil)
	forced_release = false
	testing.expect(t, !ui.fwd_open)
	if testing.expect_value(t, len(ui.pending), 1) {
		testing.expect_value(t, ui.pending[0].group_id, "expected-target")
	}
}

@(test)
add_peer_destinations :: proc(t: ^testing.T) {
	ui := Ui_State {
		fwd_kind = .Add_Member,
	}
	append(
		&ui.chats,
		Chat_Row_Ui{title = "A person", conversation_kind = .DIRECT},
		Chat_Row_Ui{title = "Two person group", conversation_kind = .GROUP},
		Chat_Row_Ui{title = "Pending group", conversation_kind = .GROUP, pending = true},
		Chat_Row_Ui{title = "Unresolved", conversation_kind = .UNKNOWN},
	)
	defer {delete(ui.chats); delete(ui.fwd_filter)}
	ui.selected = 0
	testing.expect(t, slice.equal(fwd_destinations(&ui), []int{1}))
	append(&ui.fwd_filter, "PERSON GROUP")
	testing.expect(t, slice.equal(fwd_destinations(&ui), []int{1}))
	ed_set(&ui, &ui.fwd_filter, "other")
	testing.expect_value(t, len(fwd_destinations(&ui)), 0)
	clear(&ui.fwd_filter)
	ui.fwd_kind = .Message
	testing.expect(t, slice.equal(fwd_destinations(&ui), []int{1, 3}))
	ui.fwd_kind = .Theme
	testing.expect(t, slice.equal(fwd_destinations(&ui), []int{0, 1, 3}))
}

@(test)
forward_snapshot_survives_source_changes :: proc(t: ^testing.T) {
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	old_page := timeline_page
	defer {timeline_page = old_page}
	ui := Ui_State {
		account_ref = "original-account",
		selected    = 0,
		fwd_msg     = "wanted",
		fwd_source  = "source",
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "source"}, Chat_Row_Ui{group_id = "other"})
	append(&ui.messages, Msg_Ui{id = "newer"}, Msg_Ui{id = "wanted"})
	defer {delete(ui.chats); delete(ui.messages)}
	testing.expect_value(t, forward_source(&ui), 1)
	locator := marmot.Media_Locator {
		strings.clone_to_cstring("url"),
		strings.clone_to_cstring("https://example.com/original"),
	}
	media := marmot.Media_Attachment_Outcome {
		tag = .ACCEPTED,
	}
	media.body.accepted.reference = {
		locators         = &locator,
		locators_len     = 1,
		file_name        = strings.clone_to_cstring("original.png"),
		source_epoch     = 7,
		plaintext_sha256 = strings.clone_to_cstring("original-sha"),
		dim              = strings.clone_to_cstring("1024x768"),
	}
	record := marmot.Timeline_Message_Record {
		message_id_hex = "wanted",
		media          = &media,
		media_len      = 1,
	}
	page := marmot.Timeline_Page {
		messages     = &record,
		messages_len = 1,
	}
	timeline_page = &page
	job := forward_snapshot(&ui, nil)
	defer forward_free(job)
	delete(locator.kind); delete(locator.value)
	delete(media.body.accepted.reference.file_name)
	delete(media.body.accepted.reference.plaintext_sha256)
	delete(media.body.accepted.reference.dim)
	timeline_page = nil
	ui.selected = 1
	ui.account_ref = "different-account"
	testing.expect_value(t, forward_source(&ui), -1)
	testing.expect_value(t, string(job.account), "original-account")
	testing.expect_value(t, string(job.source), "source")
	testing.expect_value(t, string(job.refs[0].file_name), "original.png")
	testing.expect_value(t, string(job.refs[0].locators[0].value), "https://example.com/original")
	testing.expect_value(t, string(job.refs[0].plaintext_sha256), "original-sha")
	testing.expect_value(t, string(job.refs[0].dim), "1024x768")
	testing.expect_value(t, job.refs[0].source_epoch, 7)
	testing.expect(t, !job.invalid)
}

@(test)
forward_failure_retry_and_dismissal :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	old_threads := send_threads
	send_threads = {}
	ui := Ui_State {
		account_ref = "account",
	}
	append(&ui.accounts, Account_Row_Ui{id_hex = ui.account_ref})
	defer delete(ui.accounts)
	old_ui := g_ui
	g_ui = &ui
	defer {g_ui = old_ui}
	defer {
		for worker in send_threads {thread.join(worker); thread.destroy(worker)}
		delete(send_threads); send_threads = old_threads
		for &p in ui.pending {free_pending(&p)}
		delete(ui.pending); delete(ui.client_status)
	}
	job := new(Forward_Job)
	job^ = {
		invalid = true,
		done    = true,
	}
	append(
		&ui.pending,
		Pending_Send {
			ticket = 4,
			account_ref = strings.clone(ui.account_ref),
			body = strings.clone("do not send without attachments"),
			forward = job,
		},
	)
	testing.expect(
		t,
		reload_jobs_busy(),
		"a completed preparation still needs its frame-boundary handoff",
	)
	drain_forwards(&ui, nil)
	if !testing.expect_value(t, len(ui.pending), 1) {return}
	testing.expect(t, ui.pending[0].failed)
	testing.expect_value(t, len(send_threads), 0)
	testing.expect(t, ui.pending[0].forward == job, "failure must retain the source for retry")
	ui.pending[0].failed = false
	forward_start(&ui.pending[0])
	ui.pending[0].dismissed = true
	if !testing.expect_value(t, len(send_threads), 1) {return}
	thread.join(send_threads[0])
	thread.destroy(send_threads[0])
	clear(&send_threads)
	drain_forwards(&ui, nil)
	testing.expect(t, len(ui.pending) == 0, "late preparation must not send a dismissed forward")
}

@(test)
forward_success_preserves_destination_and_tags :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	old_threads, old_done, old_ticket := send_threads, sends_done, send_ticket
	send_threads, sends_done = {}, {}
	ui := Ui_State {
		account_ref = "changed-account",
	}
	append(
		&ui.accounts,
		Account_Row_Ui{id_hex = "original-account"},
		Account_Row_Ui{id_hex = ui.account_ref},
	)
	defer delete(ui.accounts)
	defer {
		for worker in send_threads {thread.join(worker); thread.destroy(worker)}
		for done in sends_done {delete(done.err); for id in done.ids {delete(id)}; delete(done.ids)}
		delete(send_threads); delete(sends_done)
		send_threads, sends_done, send_ticket = old_threads, old_done, old_ticket
		for &p in ui.pending {free_pending(&p)}
		delete(ui.pending)
	}
	// Independent completed preparations model repeated clicks, not a singleton
	// result slot. The second destination may finish before the first.
	destinations := []string{"first-target", "second-target"}
	for destination in destinations {
		job := new(Forward_Job)
		job.done, job.ok = true, true
		append(
			&job.atts,
			Pending_Att {
				name = strings.clone("note.txt"),
				media_type = "text/plain",
				data = transmute([]u8)strings.clone("payload"),
			},
		)
		append(&job.images, rl.Image{})
		send_ticket += 1
		append(
			&ui.pending,
			Pending_Send {
				ticket = send_ticket,
				forward = job,
				account_ref = strings.clone("original-account"),
				group_id = strings.clone(destination),
				body = strings.clone("caption"),
				effect = 1,
				sticker = Sticker_Ref{sha = strings.clone("sticker-sha")},
			},
		)
	}
	drain_forwards(&ui, nil)
	testing.expect_value(t, len(ui.pending), 4)
	for destination in destinations {
		texts, albums := 0, 0
		for p in ui.pending {
			if p.group_id != destination {continue}
			testing.expect_value(t, p.account_ref, "original-account")
			testing.expect(t, p.forward == nil)
			if len(p.atts) > 0 {
				albums += 1
				testing.expect_value(t, string(p.atts[0].data), "payload")
				testing.expect_value(t, p.effect, 1)
				testing.expect_value(t, p.sticker.sha, "sticker-sha")
				testing.expect_value(t, p.body, "")
			} else {
				texts += 1
				testing.expect_value(t, p.body, "caption")
				testing.expect_value(t, p.effect, 0)
			}
		}
		testing.expect_value(t, texts, 1)
		testing.expect_value(t, albums, 1)
	}
}

@(test)
forward_completion_is_atomic :: proc(t: ^testing.T) {
	for first in ([]int{0, 1}) {
		for cancelled in ([]int{-1, 0, 1}) {
			ui := Ui_State {
				account_ref = "account",
				toast       = strings.clone("unchanged"),
			}
			append(
				&ui.pending,
				Pending_Send {
					ticket = 10,
					forward_ticket = 10,
					account_ref = "account",
					forward_title = "destination",
				},
				Pending_Send {
					ticket = 11,
					forward_ticket = 10,
					account_ref = "account",
					forward_title = "destination",
				},
			)
			defer {delete(ui.pending); delete(ui.toast)}
			forward_settled(&ui, &ui.pending[first], cancelled == first ? .Cancelled : .Sent)
			testing.expect(
				t,
				ui.toast == "unchanged",
				"one completed part must not confirm the whole action",
			)
			ordered_remove(&ui.pending, first)
			forward_settled(&ui, &ui.pending[0], cancelled == 1 - first ? .Cancelled : .Sent)
			if cancelled >= 0 {
				testing.expect(
					t,
					ui.toast == "unchanged",
					"a cancelled part must suppress full-success feedback",
				)
			} else {
				testing.expect(
					t,
					strings.contains(ui.toast, "destination"),
					"successful completion must identify its destination",
				)
			}
		}
	}
	ui := Ui_State {
		account_ref = "account",
		toast       = strings.clone("unchanged"),
	}
	append(
		&ui.pending,
		Pending_Send {
			ticket = 20,
			forward_ticket = 20,
			account_ref = "account",
			forward_title = "same destination",
		},
		Pending_Send {
			ticket = 21,
			forward_ticket = 21,
			account_ref = "account",
			forward_title = "same destination",
		},
	)
	defer {delete(ui.pending); delete(ui.toast)}
	forward_settled(&ui, &ui.pending[0], .Sent)
	testing.expect(
		t,
		strings.contains(ui.toast, "same destination"),
		"a separate forward to the same chat must not block success",
	)
	delete(ui.toast)
	ui.toast = strings.clone("unchanged")
	ui.account_ref = "another account"
	forward_settled(&ui, &ui.pending[1], .Sent)
	testing.expect(
		t,
		ui.toast == "unchanged",
		"a background account must not overwrite the active account's feedback",
	)
}
