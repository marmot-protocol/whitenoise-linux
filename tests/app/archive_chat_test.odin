package main

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"
import "core:text/edit"
import "core:thread"

import marmot "../marmot"
import "nendo"
import rl "sdlrl"

// SDL and nendo own process globals; run this separately like the other UI tests.
@(test)
archive_chat_dispatch :: proc(t: ^testing.T) {
	if !test_isolated("archive_chat_dispatch") {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("", "wn-archive-chat-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	deployment: ^marmot.Deployment
	if !testing.expect_value(
		t,
		marmot.deployment_white_noise(&deployment),
		marmot.Status.OK,
	) {return}
	defer marmot.deployment_free(deployment)
	client: ^marmot.Client
	store := vault_secret_store()
	if !testing.expect_value(
		t,
		marmot.client_new_with_secret_store(
			strings.clone_to_cstring(dir, context.temp_allocator),
			nil,
			0,
			&store,
			deployment,
			&client,
		),
		marmot.Status.OK,
	) {return}
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
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {nendo.set_context(previous); delete(memory)}
	ui := Ui_State {
		page          = .Chats,
		selected      = 0,
		row_menu      = -1,
		member_menu   = -1,
		audit_scanned = true,
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	append(&ui.accounts, Account_Row_Ui{name = "Offline fixture"})
	defer {chats_replace(&ui.chats, {}); chats_collect()}
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; forced_release = false; text_field_live = false}

	frame :: proc(ui: ^Ui_State) -> string {
		nendo.set_pointer({-100, -100}, .Up)
		anim_tick(1.0 / 60)
		commands := build_layout(ui, 0)
		text := make([dynamic]u8, context.temp_allocator)
		for command in commands {
			if command.kind != .Text {continue}
			data := command.text.text
			append(&text, data)
			append(&text, ' ')
		}
		return string(text[:])
	}
	point :: proc(t: ^testing.T, name: string) -> bool {
		id := nendo.id(name)
		data := nendo.element(id)
		if !testing.expect(t, data.found, "dispatch target exists") {return false}
		b := data.rect
		nendo.set_pointer({b.x + b.width / 2, b.y + b.height / 2}, .Up)
		return testing.expect(t, nendo.pointer_over(id), "dispatch target is reachable")
	}

	ui.account_ref = "0000000000000000000000000000000000000000000000000000000000000000"
	append(
		&ui.chats,
		chat_clone({group_id = "selected-chat", title = "Open conversation"}),
		chat_clone({group_id = "menu-chat", title = "Archive example"}),
	)
	ui.row_menu, ui.row_menu_x, ui.row_menu_y = 1, 100, 80
	for _ in 0 ..< 3 {frame(&ui)}
	if !point(t, "RowArchive") {return}
	menu_press = {}
	forced_press = true
	build_layout(&ui, 0)
	forced_press = false
	forced_release = true
	handle_chat(&ui, client)
	forced_release = false
	text := frame(&ui)
	testing.expect(t, strings.contains(text, "Archiving your chat"))
	testing.expect(t, !nendo.element(nendo.id("ConfirmModal")).found)
	testing.expect(t, !nendo.element(nendo.id("ToastUndo")).found)
	for job in account_jobs {thread.join(job.worker)}
	account_job_drain(&ui)
	banner_tick(&ui)
	text = frame(&ui)
	testing.expect(t, strings.contains(text, "Couldn't archive."))
	testing.expect(t, !nendo.element(nendo.id("ToastUndo")).found)
	testing.expect_value(t, ui.selected, 0)
	testing.expect_value(t, len(ui.chats), 2)
}
