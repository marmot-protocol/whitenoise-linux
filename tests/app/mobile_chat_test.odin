package main

import "base:runtime"
import "core:strings"
import "core:testing"
import "core:text/edit"

import marmot "../marmot"
import "nendo"
import rl "sdlrl"

// SDL and nendo are process-global; run this test alone with ODIN_TEST_NAMES.
@(test)
mobile_chat_layout_boundaries :: proc(t: ^testing.T) {
	if !test_isolated("mobile_chat_layout_boundaries") {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(360, 640, "Mobile conversation layouts")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {360, 640})
	defer delete(memory)
	ui := Ui_State {
		page             = .Chats,
		selected         = 0,
		selected_contact = -1,
		row_menu         = -1,
		member_menu      = -1,
		member_nick      = -1,
		prefs            = default_prefs(),
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	ui.prefs.reduce_motion = true
	ed_set(&ui, &ui.compose, "A draft")
	ui.account_ref = "offline-fixture"
	append(&ui.accounts, Account_Row_Ui{name = "Mobile"})
	append(
		&ui.chats,
		Chat_Row_Ui {
			group_id = "mobile-chat",
			title = strings.repeat("LongConversationTitle", 8, context.temp_allocator),
		},
	)
	append(
		&ui.messages,
		Msg_Ui {
			id = "mobile-message",
			sender = "Someone with a very long display name",
			body = "A message with touch-accessible actions.",
		},
	)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	defer {
		delete(ui.accounts)
		delete(ui.chats)
		delete(ui.messages)
		delete(ui.compose)
		delete(ui.mention_cands)
		delete(ui.poll_question)
		for input in ui.poll_inputs {delete(input)}
		delete(ui.poll_inputs)
	}
	inside :: proc(inner, outer: nendo.Rect) -> bool {
		return(
			inner.x >= outer.x - 0.1 &&
			inner.y >= outer.y - 0.1 &&
			inner.x + inner.width <= outer.x + outer.width + 0.1 &&
			inner.y + inner.height <= outer.y + outer.height + 0.1 \
		)
	}
	for size in ([][2]i32{{320, 568}, {360, 640}, {390, 740}, {430, 860}, {360, 332}, {493, 260}}) {
		rl.SetWindowSize(size[0], size[1])
		UI_ZOOM = 1
		refresh_ui_scale()
		width, height := f32(size[0]), f32(size[1])
		nendo.set_dimensions({width, height})
		for _ in 0 ..< 3 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
		pane := nendo.element(nendo.id("ChatPane")).rect
		for id in ([]string{"ChatHeader", "Composer", "ComposeBox", "SendBtn"}) {
			data := nendo.element(nendo.id(id))
			testing.expect(t, data.found && inside(data.rect, pane), id)
		}
		send := nendo.element(nendo.id("SendBtn")).rect
		testing.expect(
			t,
			send.width >= 44 && send.height >= 44,
			"send stays touch-sized and pinned",
		)
		// One header row: back, title, search and the overflow menu.
		header := nendo.element(nendo.id("ChatHeader")).rect
		for id in ([]string{"ChatBack", "SearchBtn", "ChatHeadMore"}) {
			data := nendo.element(nendo.id(id))
			box := data.rect
			testing.expect(
				t,
				data.found && box.width >= 44 && box.height >= 44 && inside(box, header),
				id,
			)
		}
		testing.expect(t, header.height <= 60, "phone header stays one row")

		poll_reset(&ui)
		if height >= 568 {
			for _ in 0 ..< 2 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
			fields := nendo.element(nendo.id("PollFields")).rect
			duration := nendo.element(nendo.id("PollDurationRow"))
			testing.expectf(
				t,
				duration.found && inside(duration.rect, fields),
				"duration controls %v must fit in %v at %dx%d",
				duration.rect,
				fields,
				size[0],
				size[1],
			)
		}
		for len(ui.poll_inputs) < POLL_OPTS_CAP {append(&ui.poll_inputs, [dynamic]u8{})}
		for _ in 0 ..< 3 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
		composer := nendo.element(nendo.id("ComposeBox")).rect
		pane = nendo.element(nendo.id("ChatPane")).rect
		testing.expect(t, inside(composer, pane), "poll composer stays inside the chat")
		fields := nendo.element(nendo.id("PollFields"))
		testing.expect(
			t,
			fields.found && inside(fields.rect, composer),
			"options are in the composer",
		)
		for id in ([]string{"ComposeClip", "PollCancel", "SendBtn"}) {
			control := nendo.element(nendo.id(id))
			testing.expect(t, control.found && inside(control.rect, composer), id)
			testing.expect(t, control.rect.y + control.rect.height <= fields.rect.y, id)
		}
		if height < 400 {
			scroll := nendo.scroll(nendo.id("PollFields"))
			testing.expect(
				t,
				scroll.found && scroll.content.height > scroll.viewport.height,
				"the poll options scroll without taking Send offscreen",
			)
		}
		poll_close(&ui)

		for _ in 0 ..< 3 {
			nendo.begin()
			gsearch_modal(&ui)
			nendo.end(0)
		}
		search := nendo.element(nendo.id("GsModal")).rect
		testing.expect(
			t,
			inside(search, {0, 0, width, height}),
			"global search remains within the viewport",
		)
		sender := nendo.element(nendo.id("GsSenderInput")).rect
		known := nendo.element(nendo.id("GsKnownSenderBox")).rect
		testing.expect(
			t,
			known.y >= sender.y + sender.height - 0.1,
			"known-sender action moves below the text field on phones",
		)
		ui.focus = .Compose
	}

	rl.SetWindowSize(1024, 700)
	for zoom in ([]int{50, 100, 150, 175, 200}) {
		ui.prefs.zoom_pct = zoom
		apply_zoom(&ui)
		refresh_ui_scale()
		viewport := nendo.Rect{0, 0, 1024 / UI_ZOOM, 700 / UI_ZOOM}
		nendo.set_dimensions({viewport.width, viewport.height})
		for _ in 0 ..< 3 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
		timeline := nendo.element(nendo.id("Timeline")).rect
		message := nendo.element(nendo.id("MsgRow", 0))
		send := nendo.element(nendo.id("SendBtn"))
		testing.expectf(
			t,
			message.found && message.rect.height > 0 && inside(message.rect, timeline),
			"at %d%% zoom, message %v must fit in the timeline %v",
			zoom,
			message.rect,
			timeline,
		)
		testing.expect(t, send.found && inside(send.rect, viewport))
		testing.expect(t, timeline.y + timeline.height <= send.rect.y)
	}
	ui.compose_more = true
	for _ in 0 ..< 3 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
	draft := nendo.element(nendo.id("ComposeClip")).rect
	tools := nendo.element(nendo.id("ComposeTools")).rect
	testing.expect(
		t,
		draft.height > 0 && inside(draft, tools),
		"short draft fits beside the tools",
	)
	testing.expect(
		t,
		nendo.element(nendo.id("ComposeTimestampBtn")).found,
		"More tools keeps the unpinned shortcut",
	)
	ui.compose_more = false
	ui.prefs.zoom_pct = 100
	UI_ZOOM = 1
	refresh_ui_scale()

	// The overflow menu opens on a tap, stays on screen, and closes on a
	// tap elsewhere.
	rl.SetWindowSize(360, 640)
	nendo.set_dimensions({360, 640})
	for _ in 0 ..< 3 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
	forced_release = true
	defer forced_release = false
	client: marmot.Client
	more := nendo.element(nendo.id("ChatHeadMore")).rect
	nendo.set_pointer({more.x + 2, more.y + 2}, .Up)
	handle_chat(&ui, &client)
	testing.expect(t, ui.chat_head_menu, "overflow tap opens the menu")
	for _ in 0 ..< 3 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
	menu := nendo.element(nendo.id("ChatHeadMenu"))
	testing.expect(t, menu.found && inside(menu.rect, {0, 0, 360, 640}), "menu on screen")
	for id in ([]string{"FilesBtn", "BellBtn", "MembersBtn"}) {
		testing.expect(t, nendo.element(nendo.id(id)).found, id)
	}
	nendo.set_pointer({20, 600}, .Up)
	handle_chat(&ui, &client)
	testing.expect(t, !ui.chat_head_menu, "a tap elsewhere closes the menu")

	forced_release = false
	ed_set(&ui, &ui.compose, "/poll?")
	rl.PushKey(.BACKSPACE, true)
	handle_chat(&ui, &client)
	rl.PushKey(.BACKSPACE, false)
	testing.expect(
		t,
		!ui.poll_open && string(ui.compose[:]) == "/poll",
		"deleting text does not run a command",
	)

	ed_set(&ui, &ui.compose, "/pol")
	rl.PushChar('l')
	handle_chat(&ui, &client)
	testing.expect(
		t,
		ui.poll_open && len(ui.compose) == 0,
		"typing the last letter opens the poll",
	)
	ed_set(&ui, &ui.poll_question, "Where should we meet?")
	ui.search_open = true
	ui.focus = .Search
	build_layout(&ui, 0)
	testing.expect(t, !nendo.element(nendo.id("PollFields")).found, "search hides the poll form")
	phone_back_action(&ui)
	build_layout(&ui, 0)
	testing.expect(
		t,
		nendo.element(nendo.id("PollFields")).found &&
		string(ui.poll_question[:]) == "Where should we meet?",
		"Back from search resumes the poll draft",
	)

	rl.SetWindowSize(360, 300)
	nendo.set_dimensions({360, 300})
	ui.poll_ticket = 1
	phone_back_action(&ui)
	build_layout(&ui, 0)
	testing.expect(
		t,
		nendo.element(nendo.id("PollBusy")).found && ui.poll_ticket == 1,
		"Back keeps an in-flight publish visible",
	)
	testing.expect(
		t,
		nendo.element(nendo.id("PhoneNavigation")).found,
		"you can switch pages while publishing",
	)
	ui.poll_ticket = 0
	phone_back_action(&ui)
	testing.expect(t, !ui.poll_open, "Back closes a poll that is not sending")
	rl.SetWindowSize(360, 640)
	nendo.set_dimensions({360, 640})

	job := Timeline_Work {
		account = "offline-fixture",
		group   = "mobile-chat",
	}
	previous_job := timeline_job
	timeline_job = &job
	defer {
		thread_clear(&ui)
		timeline_job = previous_job
		delete(job.thread_request.parent)
		delete(ui.thread_stack)
		delete(ui.toast)
	}
	thread_push(&ui, "mobile-message")
	ed_set(&ui, &ui.compose, "/pol")
	build_layout(&ui, 0)
	testing.expect(t, nendo.element(nendo.id("ThreadPlacementBusy")).found)
	testing.expect(t, nendo.element(nendo.id("ComposeClip")).found)
	testing.expect(t, !nendo.element(nendo.id("SendBtn")).found)
	rl.PushChar('l')
	handle_chat(&ui, &client)
	testing.expect(t, !ui.poll_open && string(ui.compose[:]) == "/poll")

	job.thread_result = {job.thread_request.revision, .Ready}
	timeline_drain(&ui, &client)
	perform_composer_action(&ui, .Poll)
	ed_set(&ui, &ui.poll_question, "Where should we meet?")
	append(&ui.poll_inputs[0], "Here")
	append(&ui.poll_inputs[1], "There")
	build_layout(&ui, 0)
	send := nendo.element(nendo.id("SendBtn"))
	if !testing.expect(t, send.found) {return}
	// A stale click can land after the native result changes, before redraw.
	job.thread_result = {job.thread_request.revision, .Unavailable}
	timeline_drain(&ui, &client)
	forced_release = true
	nendo.set_pointer({send.rect.x + send.rect.width / 2, send.rect.y + send.rect.height / 2}, .Up)
	testing.expect(t, handle_poll(&ui, &client))
	forced_release = false
	testing.expect(t, ui.poll_open && ui.poll_ticket == 0)
	testing.expect_value(t, string(ui.poll_question[:]), "Where should we meet?")
	testing.expect_value(t, string(ui.poll_inputs[0][:]), "Here")
	testing.expect_value(t, string(ui.poll_inputs[1][:]), "There")
}
