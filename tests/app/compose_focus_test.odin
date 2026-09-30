package main

import "core:sync"
import "core:testing"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Up in an empty composer edits the newest own message the current view
// shows: not someone else's, not a tombstone, not another thread's row.
@(test)
compose_up_edits_latest_own :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {
		clay.SetCurrentContext(previous)
		delete(memory)
	}

	ui := Ui_State {
		selected = 0,
		row_menu = -1,
		focus    = .Compose,
	}
	defer {
		delete(ui.accounts)
		delete(ui.chats)
		delete(ui.drafts)
		delete(ui.messages)
		delete(ui.compose)
		delete(ui.thread_stack)
	}
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "g"})
	append(
		&ui.messages,
		Msg_Ui{id = "a", body = "older", mine = true},
		Msg_Ui{id = "b", body = "latest", mine = true},
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
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {
		clay.SetCurrentContext(previous)
		delete(memory)
		forced_release = false
	}

	ui := Ui_State {
		selected = -1,
		row_menu = -1,
	}
	defer {
		delete(ui.messages)
		delete(ui.compose)
		delete(ui.reply_hint)
	}
	append(&ui.messages, Msg_Ui{id = "m", sender = "you", body = "hello", mine = true})
	client: marmot.Client

	for item in ([]string{"CtxReply", "CtxEdit"}) {
		ui.focus = .Search
		ui.ctx_open = true
		clay.BeginLayout()
		context_menu(&ui)
		clay.EndLayout(0)
		box := clay.GetElementData(clay.ID(item)).boundingBox
		clay.SetPointerState({box.x + 4, box.y + 4}, false)
		forced_release = true
		handle_ctx_menu(&ui, &client)
		forced_release = false
		testing.expect_value(t, ui.focus, Focus.Compose)
	}
	testing.expect_value(t, ui.replying, "m")
	testing.expect_value(t, ui.editing, "m")
	testing.expect_value(t, string(ui.compose[:]), "hello")
}
