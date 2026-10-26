package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"
import "core:text/edit"
import "core:thread"
import rl "sdlrl"

// Neutral deployment keeps this generated fixture off public infrastructure.
@(default_calling_convention = "c")
foreign _ {
	@(link_name = "marmot_deployment_neutral")
	restore_test_deployment :: proc(out: ^^marmot.Deployment) -> marmot.Status ---
	@(link_name = "marmot_create_identity_with_profile")
	restore_test_identity :: proc(client: ^marmot.Client, relays: [^]cstring, relays_len: uint, bootstrap: [^]cstring, bootstrap_len: uint, inbox: [^]cstring, inbox_len: uint, out: ^rawptr) -> marmot.Status ---
	@(link_name = "marmot_identity_creation_result_free")
	restore_test_identity_free :: proc(result: rawptr) ---
}

@(test)
restore_chat_dispatch :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "restore_chat_dispatch" {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("", "wn-restore-chat-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	previous_home := data_home
	data_home = dir
	defer {vault_lock(); data_home = previous_home}
	if !testing.expect_value(t, vault_create("disposable-test-password"), Vault_Err.None) {return}
	deployment: ^marmot.Deployment
	if !testing.expect_value(t, restore_test_deployment(&deployment), marmot.Status.OK) {return}
	defer marmot.deployment_free(deployment)
	client: ^marmot.Client
	store := vault_secret_store()
	relays := []cstring{"wss://127.0.0.1:9"}
	options := marmot.Client_Options {
		store        = &store,
		relay_policy = 1,
	}
	if !testing.expect_value(
		t,
		marmot.client_new_with_configuration(
			strings.clone_to_cstring(dir, context.temp_allocator),
			raw_data(relays),
			uint(len(relays)),
			&options,
			deployment,
			&client,
		),
		marmot.Status.OK,
	) {return}
	defer {marmot.client_free(client)}
	// Never start networking. Local-ready identity creation persists its key and
	// relay list; any background bootstrap can reach only the closed loopback port.
	result: rawptr
	status := restore_test_identity(
		client,
		raw_data(relays),
		uint(len(relays)),
		nil,
		0,
		nil,
		0,
		&result,
	)
	if !testing.expect(t, status == .OK, marmot.last_error()) {return}
	account := strings.clone(string((^marmot.Account_Summary)(result).label))
	defer delete(account)
	restore_test_identity_free(result)
	// Reopen without starting the runtime, so setup retries cannot race the
	// local group fixture or add network-dependent waits to UI assertions.
	marmot.client_shutdown(client)
	marmot.client_free(client)
	client = nil
	if !testing.expect_value(
		t,
		marmot.client_new_with_configuration(
			strings.clone_to_cstring(dir, context.temp_allocator),
			raw_data(relays),
			uint(len(relays)),
			&options,
			deployment,
			&client,
		),
		marmot.Status.OK,
	) {return}
	group: cstring
	status = marmot.create_group(
		client,
		strings.clone_to_cstring(account, context.temp_allocator),
		"Restored conversation",
		nil,
		0,
		"",
		&group,
	)
	if !testing.expect(t, status == .OK, marmot.last_error()) {return}
	target := strings.clone(string(group))
	defer delete(target)
	marmot.string_free(group)
	status = marmot.create_group(
		client,
		strings.clone_to_cstring(account, context.temp_allocator),
		"Other conversation",
		nil,
		0,
		"",
		&group,
	)
	if !testing.expect(t, status == .OK, marmot.last_error()) {return}
	other := strings.clone(string(group))
	defer delete(other)
	marmot.string_free(group)
	rl.InitWindow(1024, 700, "Restore chat")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts(); load_themes(); apply_theme(0, 0)
	locale := g_prefs != nil ? g_prefs.locale : "en"
	set_locale("en"); defer set_locale(locale)
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui := Ui_State {
		selected      = -1,
		row_menu      = -1,
		member_menu   = -1,
		audit_scanned = true,
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer {
		for file in ui.staged {delete(file.name); delete(file.data)}
		delete(ui.staged)
		for key, files in ui.staged_drafts {
			for file in files {delete(file.name); delete(file.data)}
			delete(files); delete(key)
		}
		delete(ui.staged_drafts)
	}
	ui.prefs = default_prefs(); ui.prefs.reduce_motion = true
	ui.account_ref = account
	append(&ui.accounts, "Offline fixture")
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; forced_release = false; text_field_live = false}
	defer {timeline_stop(); for job in account_jobs {thread.join(job.worker)}
		account_job_drain(&ui)}
	frame :: proc(ui: ^Ui_State, reset_pointer := true) -> string {
		if reset_pointer {clay.SetPointerState({-100, -100}, false)}
		anim_tick(1.0 / 60)
		banner_tick(ui)
		commands := build_layout(ui, 0)
		text := make([dynamic]u8, context.temp_allocator)
		for command in commands.internalArray[:commands.length] {
			if command.commandType != .Text {continue}
			data := command.renderData.text.stringContents
			append(&text, ..data.chars[:data.length]); append(&text, ' ')
		}
		return string(text[:])
	}
	for settings in ([]bool{true, false}) {
		record: ^marmot.App_Group_Record
		if !testing.expect_value(
			t,
			marmot.set_group_archived(
				client,
				strings.clone_to_cstring(account, context.temp_allocator),
				strings.clone_to_cstring(target, context.temp_allocator),
				true,
				&record,
			),
			marmot.Status.OK,
		) {return}
		marmot.app_group_record_free(record)
		ui.page = settings ? .Archived : .Chats
		ui.selected = -1
		// Dismiss without clearing the notice identity. Repeating the same
		// success must explicitly rearm the banner, even after intervening frames.
		ui.banner = ""
		ui.chat_filter = settings ? .Unread : .Archived
		ed_set(&ui, &ui.sidebar_filter, "Restored")
		load_chat_list(client, account, &ui)
		load_archived(client, &ui)
		for job in account_jobs {thread.join(job.worker)}
		account_job_drain(&ui)
		if !testing.expect_value(t, len(ui.archived), 1) {return}
		if settings {
			testing.expect(t, select_by_id(&ui, client, other))
			ed_set(&ui, &ui.compose, "Keep this draft")
		} else {
			// Opening an archived conversation is not restoration. Its temporary
			// search-only row must not become the identity used after the list reload.
			select_archived_chat(&ui, client, 0)
			testing.expect_value(t, ui.chats[ui.selected].group_id, target)
			testing.expect(t, ui.chats[ui.selected].search_only)
		}
		append(
			&ui.staged,
			Staged_File {
				name = strings.clone("draft.txt"),
				media_type = "text/plain",
				data = make([]u8, 1),
			},
		)
		ui.staged[0].data[0] = 'x'
		staged := raw_data(ui.staged)
		payload := raw_data(ui.staged[0].data)
		for _ in 0 ..< 3 {frame(&ui)}
		if !settings {
			row := clay.GetElementData(clay.ID("ChatRow", 0))
			if !testing.expect(t, row.found, "Archived rail row exists") {return}
			b := row.boundingBox
			clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
			frame(&ui, false)
		}
		id := clay.ID("ChatUnarch", 0)
		data := clay.GetElementData(id)
		if !testing.expect(t, data.found, "Restore is rendered") {return}
		b := data.boundingBox
		clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
		if !testing.expect(t, clay.PointerOver(id), "Restore is reachable") {return}
		if settings {
			selected := ui.selected
			ui.account_ref = "missing-offline-account"
			forced_release = true
			handle_pages(&ui, client)
			forced_release = false
			testing.expect_value(t, ui.page, Page.Archived)
			testing.expect_value(t, ui.chat_filter, Chat_Filter.Unread)
			testing.expect_value(t, string(ui.sidebar_filter[:]), "Restored")
			testing.expect_value(t, ui.selected, selected)
			testing.expect_value(t, len(ui.staged), 1)
			testing.expect_value(t, raw_data(ui.staged), staged)
			testing.expect_value(t, len(ui.staged_drafts[other]), 0)
			testing.expect(t, strings.has_prefix(ui.client_status, "Couldn't unarchive."))
			testing.expect_value(t, ui.client_status_kind, Status_Kind.Error)
			for job in account_jobs {thread.join(job.worker)}
			account_job_drain(&ui)
			ui.account_ref = account
			for _ in 0 ..< 3 {frame(&ui)}
			clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
		}
		if !settings {
			testing.expect_value(t, ui.client_status, "Chat restored.")
			testing.expect_value(t, ui.banner_seen, "Chat restored.")
			testing.expect_value(t, ui.banner, "")
		}
		forced_release = true
		if settings {handle_pages(&ui, client)} else {handle_chat(&ui, client)}
		forced_release = false
		testing.expect_value(t, ui.page, Page.Chats)
		testing.expect_value(t, ui.chat_filter, Chat_Filter.Chats)
		testing.expect_value(t, len(ui.sidebar_filter), 0)
		if testing.expect(
			t,
			ui.selected >= 0 && ui.selected < len(ui.chats),
			"Restore selects a conversation",
		) {
			testing.expect_value(t, ui.chats[ui.selected].group_id, target)
			testing.expect(t, !ui.chats[ui.selected].search_only)
		}
		testing.expect_value(t, ui.client_status, "Chat restored.")
		testing.expect_value(t, ui.client_status_kind, Status_Kind.Info)
		files := settings ? ui.staged_drafts[other] : ui.staged
		if testing.expect_value(t, len(files), 1) {
			testing.expect_value(t, raw_data(files), staged)
			testing.expect_value(t, files[0].name, "draft.txt")
			testing.expect_value(t, files[0].media_type, "text/plain")
			testing.expect_value(t, raw_data(files[0].data), payload)
			testing.expect_value(t, string(files[0].data), "x")
		}
		testing.expect_value(t, len(ui.staged), settings ? 0 : 1)
		testing.expect_value(t, len(ui.staged_drafts[target]), 0)
		text := frame(&ui)
		testing.expect(t, strings.contains(text, "Chat restored."), "Success is visibly confirmed")
		timeline_stop()
		for job in account_jobs {thread.join(job.worker)}
		account_job_drain(&ui)
		testing.expect_value(t, len(ui.archived), 0)
		testing.expect_value(t, ui.drafts[other], "Keep this draft")
		chats_collect()
		if ui.selected >= 0 &&
		   ui.selected <
			   len(ui.chats) {testing.expect_value(t, ui.chats[ui.selected].group_id, target)}
	}
	// Exercise a real C API read failure without a mock or production hook.
	// The failed refresh must retain the old rows, selection, and actual error.
	selected := ui.selected
	rows := raw_data(ui.chats)
	count := len(ui.chats)
	staged := raw_data(ui.staged)
	ui.page = .Archived
	ui.account_ref = "missing-offline-account"
	testing.expect(t, !refresh_after_action(&ui, client))
	testing.expect_value(t, raw_data(ui.chats), rows)
	testing.expect_value(t, len(ui.chats), count)
	testing.expect_value(t, ui.selected, selected)
	testing.expect_value(t, ui.page, Page.Archived)
	if testing.expect_value(t, len(ui.staged), 1) {
		testing.expect_value(t, raw_data(ui.staged), staged)
		testing.expect_value(t, ui.staged[0].name, "draft.txt")
		testing.expect_value(t, string(ui.staged[0].data), "x")
	}
	testing.expect_value(t, len(ui.staged_drafts[target]), 0)
	testing.expect(t, strings.has_prefix(ui.client_status, "Chat list failed: "))
	testing.expect_value(t, ui.client_status_kind, Status_Kind.Error)
	ui.account_ref = account
}
