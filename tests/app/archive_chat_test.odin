package main

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"
import "core:text/edit"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"
import marmot "../marmot"

// SDL and Clay own process globals; run this separately like the other UI tests.
@(test)
archive_chat_dispatch :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "archive_chat_dispatch" {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("", "wn-archive-chat-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	deployment: ^marmot.Deployment
	if !testing.expect_value(t, marmot.deployment_white_noise(&deployment), marmot.Status.OK) {return}
	defer marmot.deployment_free(deployment)
	client: ^marmot.Client
	store := vault_secret_store()
	if !testing.expect_value(t, marmot.client_new_with_secret_store(strings.clone_to_cstring(dir, context.temp_allocator), nil, 0, &store, deployment, &client), marmot.Status.OK) {return}
	defer marmot.client_free(client)
	rl.InitWindow(1024, 700, "Archive chat")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	locale := g_prefs != nil ? g_prefs.locale : "en"
	set_locale("en")
	defer set_locale(locale)
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui := Ui_State {page = .Chats, selected = 0, row_menu = -1, member_menu = -1, audit_scanned = true}
	edit.init(&ui.ed, context.allocator, context.allocator)
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	append(&ui.accounts, "Offline fixture")
	append(&ui.chats,
		Chat_Row_Ui{group_id = "selected-chat", title = "Open conversation"},
		Chat_Row_Ui{group_id = "menu-chat", title = "Archive example"},
	)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; forced_release = false; text_field_live = false}

	frame :: proc(ui: ^Ui_State) -> string {
		clay.SetPointerState({-100, -100}, false)
		anim_tick(1.0 / 60)
		commands := build_layout(ui, 0)
		text := make([dynamic]u8, context.temp_allocator)
		for command in commands.internalArray[:commands.length] {
			if command.commandType != .Text {continue}
			data := command.renderData.text.stringContents
			append(&text, ..data.chars[:data.length])
			append(&text, ' ')
		}
		return string(text[:])
	}
	point :: proc(t: ^testing.T, name: string) -> bool {
		id := clay.ID(name)
		data := clay.GetElementData(id)
		if !testing.expect(t, data.found, "dispatch target exists") {return false}
		b := data.boundingBox
		clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
		return testing.expect(t, clay.PointerOver(id), "dispatch target is reachable")
	}

	// A menu can target a different chat from the selected conversation.
	// Every new action must ask again, including after Cancel or Escape.
	owner :: "0000000000000000000000000000000000000000000000000000000000000000"
	other :: "1111111111111111111111111111111111111111111111111111111111111111"
	for cancel in ([]string{"ConfirmCancel", "escape", "backdrop", "switch-click", "switch-enter", "confirm-click", "confirm-enter"}) {
		delete(ui.account_ref)
		ui.account_ref = strings.clone(owner)
		ui.selected = 0
		ui.row_menu, ui.row_menu_x, ui.row_menu_y = 1, 100, 80
		for _ in 0 ..< 3 {frame(&ui)}
		if !point(t, "RowArchive") {return}
		forced_release = true
		handle_chat(&ui, client)
		forced_release = false
		if !testing.expect(t, ui.confirm.kind != .None, cancel) {return}
		testing.expect_value(t, ui.row_menu, -1)
		testing.expect_value(t, ui.selected, 0)
		testing.expect_value(t, len(ui.chats), 2)
		testing.expect_value(t, ui.confirm.arg, "menu-chat")
		testing.expect_value(t, ui.confirm.name, "Archive example")
		testing.expect_value(t, ui.client_status, "")
		text := frame(&ui)
		testing.expect(t, strings.contains(text, "Archive this chat?"))
		testing.expect(t, strings.contains(text, "Archived"))
		testing.expect(t, strings.contains(text, "restore"))
		testing.expect(t, strings.contains(text, "Archive example"))
		switched := strings.has_prefix(cancel, "switch-")
		if switched {
			previous_account := ui.account_ref
			finish_account_switch(&ui, client, other)
			delete(previous_account)
			testing.expect_value(t, ui.account_ref, other)
			// The nonexistent account fails the real list read. Clear only
			// that error so an archive attempt would produce a new error.
			testing.expect(t, strings.has_prefix(ui.client_status, "Chat list failed:"))
			delete(ui.client_status); ui.client_status = ""
		}
		if cancel == "escape" {
			rl.PushKey(.ESCAPE, true)
			handle_confirm(&ui, client)
			rl.PushKey(.ESCAPE, false)
		} else if cancel == "confirm-enter" || cancel == "switch-enter" {
			rl.PushKey(.ENTER, true)
			handle_confirm(&ui, client)
			rl.PushKey(.ENTER, false)
		} else {
			if cancel == "backdrop" {clay.SetPointerState({1, 1}, false)} else {
				if !point(t, cancel == "confirm-click" || cancel == "switch-click" ? "ConfirmGo" : cancel) {return}
			}
			forced_release = true
			handle_confirm(&ui, client)
			forced_release = false
		}
		testing.expect_value(t, ui.confirm.kind, Confirm_Kind.None)
		testing.expect_value(t, ui.selected, switched ? -1 : 0)
		testing.expect_value(t, len(ui.chats), 2)
		testing.expect_value(t, ui.chats[0].group_id, "selected-chat")
		testing.expect_value(t, ui.chats[1].group_id, "menu-chat")
		if strings.has_prefix(cancel, "confirm-") {
			// Real ABI failure: confirmation must still use the existing error
			// path and never claim success or remove the selected conversation.
			testing.expect(t, strings.has_prefix(ui.client_status, "Couldn't archive."))
			testing.expect_value(t, ui.client_status_kind, Status_Kind.Error)
			delete(ui.client_status); ui.client_status = ""
		} else {testing.expect_value(t, ui.client_status, "")}
		for _ in 0 ..< 3 {frame(&ui)}
	}
}
