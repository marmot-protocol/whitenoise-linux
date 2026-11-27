package main

import "core:sync"
import "core:testing"

import marmot "../marmot"
import "nendo"
import rl "sdlrl"

// Up in an empty composer edits the newest own message the current view
// shows, skipping agent items, other senders, tombstones and other threads.
@(test)
compose_up_edits_latest_own :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {
		nendo.set_context(previous)
		delete(memory)
	}

	ui := Ui_State {
		account_ref = "account",
		selected    = 0,
		row_menu    = -1,
		focus       = .Compose,
	}
	defer {
		delete(ui.accounts)
		delete(ui.chats)
		delete(ui.drafts)
		delete(ui.messages)
		delete(ui.compose)
		delete(ui.thread_stack)
	}
	append(&ui.accounts, Account_Row_Ui{name = "Test"})
	append(&ui.chats, Chat_Row_Ui{group_id = "g"})
	append(
		&ui.messages,
		Msg_Ui{id = "a", body = "older", mine = true},
		Msg_Ui{id = "b", body = "latest", mine = true},
		Msg_Ui{id = "agent", body = "checking", mine = true, kind = KIND_AGENT_ITEM},
		Msg_Ui{id = "c", body = "theirs"},
		Msg_Ui{id = "d", mine = true, deleted = true},
		Msg_Ui{id = "e", body = "in thread", mine = true, thread_of = "b"},
	)
	client: marmot.Client
	press_up :: proc(ui: ^Ui_State, client: ^marmot.Client) {
		rl.PushKey(.UP, true)
		handle_chat(ui, client)
		rl.PushKey(.UP, false)
	}

	// A draft in the composer keeps Up as a caret key.
	append(&ui.compose, 'x')
	press_up(&ui, &client)
	testing.expect_value(t, ui.editing, "")

	clear(&ui.compose)
	press_up(&ui, &client)
	testing.expect_value(t, ui.editing, "b")
	testing.expect_value(t, string(ui.compose[:]), "latest")

	// Inside thread b, the only own row is e.
	ui.editing = ""
	clear(&ui.compose)
	append(&ui.thread_stack, "b")
	press_up(&ui, &client)
	testing.expect_value(t, ui.editing, "e")
	testing.expect_value(t, string(ui.compose[:]), "in thread")
}

// Reply and Edit from the context menu hand the keyboard to the composer.
@(test)
ctx_reply_edit_focus :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	rl.InitWindow(800, 600, "Message action focus")
	defer rl.CloseWindow()
	old_zoom := UI_ZOOM
	UI_ZOOM = 1
	defer {UI_ZOOM = old_zoom}
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {
		nendo.set_context(previous)
		delete(memory)
		forced_release = false
	}

	ui := Ui_State {
		row_menu = -1,
	}
	defer {
		close_msg_menu(&ui)
		delete(ui.ctx_items)
		delete(ui.chats)
		delete(ui.messages)
		delete(ui.compose)
		delete(ui.reply_hint)
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "test"})
	append(&ui.messages, Msg_Ui{id = "m", sender = "you", body = "hello", mine = true})
	client: marmot.Client

	for item in ([]string{"CtxReply", "CtxEdit"}) {
		ui.focus = .Search
		open_msg_menu(&ui, "m", .Pointer)
		ui.ctx_x, ui.ctx_y = 24, 24
		nendo.begin()
		context_menu(&ui, ui.messages[0])
		nendo.end(0)
		box := nendo.element(nendo.id(item)).rect
		nendo.set_pointer({box.x + 4, box.y + 4}, .Up)
		// A menu row acts only when the press also landed on it.
		menu_press = {}
		forced_press = true
		nendo.begin()
		context_menu(&ui, ui.messages[0])
		nendo.end(0)
		forced_press = false
		forced_release = true
		handle_ctx_menu(&ui, &client)
		forced_release = false
		testing.expect_value(t, ui.focus, Focus.Compose)
	}
	testing.expect_value(t, ui.replying, "m")
	testing.expect_value(t, ui.editing, "m")
	testing.expect_value(t, string(ui.compose[:]), "hello")

	append(&ui.thread_stack, "m")
	defer delete(ui.thread_stack)
	open_msg_menu(&ui, "m", .Pointer)
	nendo.begin()
	context_menu(&ui, ui.messages[0])
	nendo.end(0)
	testing.expect(t, nendo.element(nendo.id("CtxCopy")).found)
	testing.expect(t, !nendo.element(nendo.id("CtxThread")).found)
}

// Escape closes the chat filter or drops a reply, and never takes the
// unsent draft with it.
@(test)
escape_keeps_draft :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {
		nendo.set_context(previous)
		delete(memory)
	}

	ui := Ui_State {
		account_ref = "account",
		selected    = 0,
		row_menu    = -1,
		focus       = .Filter,
	}
	defer {
		delete(ui.accounts)
		delete(ui.chats)
		delete(ui.compose)
		delete(ui.sidebar_filter)
	}
	append(&ui.accounts, Account_Row_Ui{name = "Test"})
	append(&ui.chats, Chat_Row_Ui{group_id = "g"})
	append(&ui.compose, "draft")
	client: marmot.Client
	press_escape :: proc(ui: ^Ui_State, client: ^marmot.Client) {
		rl.PushKey(.ESCAPE, true)
		handle_chat(ui, client)
		rl.PushKey(.ESCAPE, false)
	}

	press_escape(&ui, &client)
	testing.expect_value(t, ui.focus, Focus.Compose)
	testing.expect_value(t, string(ui.compose[:]), "draft")

	ui.replying = "m"
	press_escape(&ui, &client)
	testing.expect_value(t, ui.replying, "")
	testing.expect_value(t, string(ui.compose[:]), "draft")
}
