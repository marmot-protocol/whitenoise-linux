package main

import "base:runtime"
import "core:strings"
import "core:testing"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// SDL and Clay are process-global; run this test alone with ODIN_TEST_NAMES.
@(test)
mobile_chat_layout_boundaries :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "mobile_chat_layout_boundaries" {return}
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
		issue_setting    = .Enabled,
	}
	ui.prefs.reduce_motion = true
	append(&ui.accounts, "Mobile")
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
	inside :: proc(inner, outer: clay.BoundingBox) -> bool {
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
		clay.SetLayoutDimensions({width, height})
		for _ in 0 ..< 3 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
		pane := clay.GetElementData(clay.ID("ChatPane")).boundingBox
		for id in ([]string{"ChatHeader", "Composer", "ComposeBox", "SendBtn"}) {
			data := clay.GetElementData(clay.ID(id))
			testing.expect(t, data.found && inside(data.boundingBox, pane), id)
		}
		send := clay.GetElementData(clay.ID("SendBtn")).boundingBox
		testing.expect(
			t,
			send.width >= 44 && send.height >= 44,
			"send stays touch-sized and pinned",
		)
		more := clay.GetElementData(clay.ID("MsgMore", 0))
		testing.expect(
			t,
			more.found && more.boundingBox.width >= 44 && more.boundingBox.height >= 44,
			"message actions are present without hover",
		)

		poll_reset(&ui)
		for len(ui.poll_inputs) < POLL_OPTS_CAP {append(&ui.poll_inputs, [dynamic]u8{})}
		for _ in 0 ..< 3 {
			clay.BeginLayout()
			poll_modal(&ui)
			clay.EndLayout(0)
		}
		modal := clay.GetElementData(clay.ID("PollModal")).boundingBox
		testing.expect(
			t,
			modal.width <= width - 23 && modal.height <= height - 23,
			"poll form fits narrow and keyboard-short viewports",
		)
		question := clay.GetElementData(clay.ID("PollQBox")).boundingBox
		testing.expect(
			t,
			question.x >= modal.x && question.x + question.width <= modal.x + modal.width + 0.1,
			"default input width cannot widen a narrow poll",
		)
		scroll := clay.GetScrollContainerData(clay.ID("PollModal"))
		testing.expect(t, scroll.found, "poll form has a scroll container")
		if height < 400 {
			testing.expect(
				t,
				scroll.contentDimensions.height > scroll.scrollContainerDimensions.height,
				"a full poll remains scrollable to its actions on short screens",
			)
		}
		testing.expect(
			t,
			clay.GetElementData(clay.ID("PollCancel")).found &&
			clay.GetElementData(clay.ID("PollCreate")).found,
		)

		for _ in 0 ..< 3 {
			clay.BeginLayout()
			gsearch_modal(&ui)
			clay.EndLayout(0)
		}
		search := clay.GetElementData(clay.ID("GsModal")).boundingBox
		testing.expect(
			t,
			inside(search, {0, 0, width, height}),
			"global search remains within the viewport",
		)
		sender := clay.GetElementData(clay.ID("GsSenderInput")).boundingBox
		known := clay.GetElementData(clay.ID("GsKnownSenderBox")).boundingBox
		testing.expect(
			t,
			known.y >= sender.y + sender.height - 0.1,
			"known-sender action moves below the text field on phones",
		)
		ui.focus = .Compose
	}
}
