package main

import marmot "../marmot"
import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"
import "core:text/edit"
import "core:thread"
import "nendo"
import rl "sdlrl"
import sdl "vendor:sdl3"

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
	if !test_isolated("restore_chat_dispatch") {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("", "wn-restore-chat-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	previous_config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", dir)
	defer os.set_env("XDG_CONFIG_HOME", previous_config)
	previous_home := data_home
	data_home = dir
	defer {vault_lock(); data_home = previous_home}
	if !testing.expect_value(t, vault_create("disposable-test-password"), Vault_Err.None) {return}
	deployment: ^marmot.Deployment
	if !testing.expect_value(t, restore_test_deployment(&deployment), marmot.Status.OK) {return}
	defer marmot.deployment_free(deployment)
	client: ^marmot.Client
	store := vault_secret_store()
	long_relay :: "wss://127.0.0.1:9/a-long-relay-path/for-a-group-that-routes-its-encrypted-messages-through-a-specific-endpoint/keep-the-whole-address"
	relays := []cstring{"wss://127.0.0.1:9", "wss://127.0.0.1:9/", long_relay}
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
	created: ^marmot.Group_Creation_Result
	status = marmot.create_group(
		client,
		strings.clone_to_cstring(account, context.temp_allocator),
		"Restored conversation",
		nil,
		0,
		"",
		&created,
	)
	if !testing.expect(t, status == .OK, marmot.last_error()) {return}
	target := strings.clone(string(created.group_id_hex))
	defer delete(target)
	marmot.group_creation_free(created)
	status = marmot.create_group(
		client,
		strings.clone_to_cstring(account, context.temp_allocator),
		"Other conversation",
		nil,
		0,
		"",
		&created,
	)
	if !testing.expect(t, status == .OK, marmot.last_error()) {return}
	other := strings.clone(string(created.group_id_hex))
	defer delete(other)
	marmot.group_creation_free(created)
	rl.InitWindow(1024, 700, "Restore chat")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts(); load_themes(); apply_theme(0, 0)
	locale := g_prefs != nil ? g_prefs.locale : "en"
	set_locale("en"); defer set_locale(locale)
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {nendo.set_context(previous); delete(memory)}
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
	append(&ui.accounts, Account_Row_Ui{id_hex = account, name = "Offline fixture"})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		archive_press_clear(&ui)
		g_ui, g_prefs = nil, nil
		forced_release, text_field_live = false, false
	}
	// Selecting a chat starts timeline and roster workers; join them before
	// the client is freed, as app shutdown does.
	defer {timeline_stop(); members_stop(); for job in account_jobs {thread.join(job.worker)}
		account_job_drain(&ui)}
	frame :: proc(ui: ^Ui_State) -> string {
		nendo.set_pointer({-100, -100}, .Up)
		anim_tick(1.0 / 60)
		banner_tick(ui)
		commands := build_layout(ui, 0)
		text := make([dynamic]u8, context.temp_allocator)
		for command in commands {
			if command.kind != .Text {continue}
			data := command.text.text
			append(&text, data); append(&text, ' ')
		}
		return string(text[:])
	}
	archive_flag :: proc(
		t: ^testing.T,
		client: ^marmot.Client,
		account, group: string,
		archived: bool,
	) -> bool {
		record: ^marmot.App_Group_Record
		status := marmot.set_group_archived(
			client,
			strings.clone_to_cstring(account, context.temp_allocator),
			strings.clone_to_cstring(group, context.temp_allocator),
			archived,
			&record,
		)
		if !testing.expect(t, status == .OK, marmot.last_error()) {return false}
		marmot.app_group_record_free(record)
		return true
	}
	control_point :: proc(t: ^testing.T, id: nendo.Id) -> (point: nendo.Vector2, ok: bool) {
		data := nendo.element(id)
		if !testing.expect(t, data.found, "Archive control is rendered") {return {}, false}
		b := data.rect
		return {b.x + b.width / 2, b.y + b.height / 2}, true
	}
	mouse_at :: proc(ui: ^Ui_State, client: ^marmot.Client, point: nendo.Vector2, down: bool) {
		rl.WindowShouldClose()
		rl.PushMouseButton(.LEFT, down)
		nendo.set_pointer(point, down ? .Down : .Up)
		anim_tick(1.0 / 60)
		handle_pages(ui, client)
	}
	touch_poll :: proc(ui: ^Ui_State, client: ^marmot.Client) {
		rl.WindowShouldClose()
		nendo.set_pointer(
			archive_pointer_position(ui.page, transmute(nendo.Vector2)rl.GetMousePosition()),
			rl.IsMouseButtonDown(.LEFT) ? .Down : .Up,
		)
		anim_tick(1.0 / 60)
		update_drag_scroll(ui, false)
		handle_pages(ui, client)
	}
	touch_at :: proc(
		ui: ^Ui_State,
		client: ^marmot.Client,
		point: nendo.Vector2,
		phase: rl.Finger_Phase,
	) {
		rl.InjectFinger(phase, point.x, point.y)
		touch_poll(ui, client)
	}

	ui.page = .Archived
	if !archive_flag(t, client, account, target, true) ||
	   !archive_flag(t, client, account, other, true) {return}
	load_archived(client, &ui)
	for job in account_jobs {thread.join(job.worker)}
	account_job_drain(&ui)
	if !testing.expect_value(t, len(ui.archived), 2) {return}
	status_before := ui.client_status
	for control in ([]string{"ChatUnarch", "ArchivedRow"}) {
		if ui.archived[0].group_id != target {
			ui.archived[0], ui.archived[1] = ui.archived[1], ui.archived[0]
		}
		for _ in 0 ..< 3 {frame(&ui)}
		id := nendo.id(control, nendo.id(target).id)
		point, found := control_point(t, id)
		if !found {return}
		mouse_at(&ui, client, point, true)
		if !testing.expect(t, nendo.pointer_over(id), "Press begins on the first chat") {return}
		// Replace the chat rows as a live snapshot would, then show the new order.
		fresh: [dynamic]Chat_Row_Ui
		append(&fresh, chat_clone(ui.archived[1]), chat_clone(ui.archived[0]))
		chats_replace(&ui.archived, fresh)
		chats_collect()
		build_layout(&ui, 0)
		mouse_at(&ui, client, point, false)
		if !testing.expect(
			t,
			nendo.pointer_over(nendo.id(control, nendo.id(other).id)),
			"The other chat takes the same screen position before release",
		) {return}
		if !testing.expect_value(t, ui.page, Page.Archived) ||
		   !testing.expect_value(t, ui.client_status, status_before) {return}
		testing.expect_value(t, ui.selected, -1)
	}
	row_id := nendo.id("ArchivedRow", nendo.id(target).id)
	restore_id := nendo.id("ChatUnarch", nendo.id(target).id)
	row_point, row_found := control_point(t, row_id)
	restore_point, restore_found := control_point(t, restore_id)
	if !row_found || !restore_found {return}
	mouse_at(&ui, client, row_point, true)
	if !testing.expect(t, nendo.pointer_over(row_id) && !nendo.pointer_over(restore_id)) {return}
	mouse_at(&ui, client, restore_point, false)
	if !testing.expect_value(t, ui.client_status, status_before) {return}

	rl.InjectFinger(.Down, row_point.x, row_point.y)
	rl.InjectFinger(.Up, restore_point.x, restore_point.y)
	touch_poll(&ui, client)
	if !testing.expect(t, nendo.pointer_over(restore_id)) ||
	   !testing.expect_value(t, ui.client_status, status_before) {return}

	rl.InjectFinger(.Down, restore_point.x, restore_point.y)
	rl.InjectFinger(.Move, row_point.x, row_point.y)
	rl.InjectFinger(.Up, restore_point.x, restore_point.y)
	touch_poll(&ui, client)
	if !testing.expect_value(t, ui.client_status, status_before) {return}

	touch_at(&ui, client, restore_point, .Down)
	drag_point := restore_point + nendo.Vector2{12, 0}
	touch_at(&ui, client, drag_point, .Move)
	touch_at(&ui, client, drag_point, .Up)
	if !testing.expect(
		t,
		nendo.pointer_over(restore_id),
		"The finger lifts inside Restore",
	) {return}
	if !testing.expect_value(t, ui.client_status, status_before) {return}
	rl.WindowShouldClose()
	update_drag_scroll(&ui, false)
	load_archived(client, &ui)
	for job in account_jobs {thread.join(job.worker)}
	account_job_drain(&ui)
	if !testing.expect_value(t, len(ui.archived), 2) {return}
	if !archive_flag(t, client, account, other, false) {return}

	for other_selected in ([]bool{true, false}) {
		if !archive_flag(t, client, account, target, true) {return}
		ui.page = .Archived
		ui.selected = -1
		// Dismiss without clearing the notice identity. Repeating the same
		// success must explicitly rearm the banner, even after intervening frames.
		ui.banner = ""
		ui.chat_filter = .Unread
		load_chat_list(client, account, &ui)
		load_archived(client, &ui)
		for job in account_jobs {thread.join(job.worker)}
		account_job_drain(&ui)
		if !testing.expect_value(t, len(ui.archived), 1) {return}
		if other_selected {
			testing.expect(t, select_by_id(&ui, client, other))
			ed_set(&ui, &ui.compose, "Keep this draft")
		} else {
			// Opening an archived conversation is not restoration. Its temporary
			// search-only row must not become the identity used after the list reload.
			for _ in 0 ..< 3 {frame(&ui)}
			point, found := control_point(t, nendo.id("ArchivedRow", nendo.id(target).id))
			if !found {return}
			touch_at(&ui, client, point, .Down)
			touch_at(&ui, client, point, .Up)
			if !testing.expect(
				t,
				ui.selected >= 0,
				"A stationary tap opens the archived chat",
			) {return}
			testing.expect_value(t, ui.chats[ui.selected].group_id, target)
			testing.expect(t, ui.chats[ui.selected].search_only)
		}
		ui.page = .Archived
		ed_set(&ui, &ui.sidebar_filter, "Restored")
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
		id := nendo.id("ChatUnarch", nendo.id(target).id)
		point, found := control_point(t, id)
		if !found {return}
		if other_selected {
			selected := ui.selected
			ui.account_ref = "missing-offline-account"
			mouse_at(&ui, client, point, true)
			mouse_at(&ui, client, point, false)
			testing.expect_value(t, ui.page, Page.Archived)
			testing.expect_value(t, ui.chat_filter, Chat_Filter.Unread)
			testing.expect_value(t, string(ui.sidebar_filter[:]), "Restored")
			testing.expect_value(t, ui.selected, selected)
			testing.expect_value(t, len(ui.staged), 1)
			testing.expect_value(t, raw_data(ui.staged), staged)
			testing.expect_value(t, len(ui.staged_drafts[draft_key(account, other)]), 0)
			testing.expect(t, strings.has_prefix(ui.client_status, "Couldn't unarchive."))
			testing.expect_value(t, ui.client_status_kind, Status_Kind.Error)
			for job in account_jobs {thread.join(job.worker)}
			account_job_drain(&ui)
			ui.account_ref = account
			for _ in 0 ..< 3 {frame(&ui)}
			point, found = control_point(t, id)
			if !found {return}
		}
		if !other_selected {
			testing.expect_value(t, ui.client_status, "Chat restored.")
			testing.expect_value(t, ui.banner_seen, "Chat restored.")
			testing.expect_value(t, ui.banner, "")
			rl.InjectFinger(.Down, point.x, point.y)
			rl.InjectFinger(.Up, point.x, point.y)
			rl.InjectFinger(.Move, point.x + 1, point.y)
			touch_poll(&ui, client)
			testing.expect_value(t, rl.GetMousePosition().x, point.x + 1)
		} else {
			mouse_at(&ui, client, point, true)
			mouse_at(&ui, client, point, false)
		}
		// Restore confirms in place: Archive keeps its page, filter and search,
		// and no conversation opens.
		testing.expect_value(t, ui.page, Page.Archived)
		testing.expect_value(t, ui.chat_filter, Chat_Filter.Unread)
		testing.expect_value(t, string(ui.sidebar_filter[:]), "Restored")
		testing.expect_value(t, ui.selected, -1)
		restored := -1
		for chat, i in ui.chats {if chat.group_id == target {restored = i}}
		if testing.expect(t, restored >= 0, "Restore returns the chat to Chats") {
			testing.expect(t, !ui.chats[restored].search_only)
		}
		testing.expect_value(t, ui.client_status, "Chat restored.")
		testing.expect_value(t, ui.client_status_kind, Status_Kind.Info)
		// Files staged in the open conversation stay parked with that chat.
		files := ui.staged_drafts[draft_key(account, other_selected ? other : target)]
		if testing.expect_value(t, len(files), 1) {
			testing.expect_value(t, raw_data(files), staged)
			testing.expect_value(t, files[0].name, "draft.txt")
			testing.expect_value(t, files[0].media_type, "text/plain")
			testing.expect_value(t, raw_data(files[0].data), payload)
			testing.expect_value(t, string(files[0].data), "x")
		}
		testing.expect_value(t, len(ui.staged), 0)
		if other_selected {testing.expect_value(t, len(ui.staged_drafts[draft_key(account, target)]), 0)}
		text := frame(&ui)
		testing.expect(t, strings.contains(text, "Chat restored."), "Success is visibly confirmed")
		timeline_stop()
		for job in account_jobs {thread.join(job.worker)}
		account_job_drain(&ui)
		testing.expect_value(t, len(ui.archived), 0)
		testing.expect_value(t, ui.drafts[draft_key(account, other)], "Keep this draft")
		testing.expect_value(t, ui.selected, -1)
		chats_collect()
		if !other_selected {
			// Opening the restored chat brings back the files staged in it.
			if !testing.expect(t, select_by_id(&ui, client, target)) {return}
			testing.expect_value(t, raw_data(ui.staged), staged)
			testing.expect_value(t, len(ui.staged_drafts[draft_key(account, target)]), 0)
		}
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
	testing.expect_value(t, len(ui.staged_drafts[draft_key(account, target)]), 0)
	testing.expect(t, strings.has_prefix(ui.client_status, "Chat list failed: "))
	testing.expect_value(t, ui.client_status_kind, Status_Kind.Error)
	ui.account_ref = account

	ui.page, ui.chat_filter = .Chats, .Chats
	ui.client_status = ""
	open_group_info(&ui, client, .Settings)
	defer close_group_info(&ui)
	for _ in 0 ..< 3 {frame(&ui)}
	if relay_card := nendo.element(nendo.id("InfoRelaysCard"));
	   testing.expect(t, relay_card.found) {
		view := nendo.id("MembersScroll")
		scroll := nendo.scroll(view)
		scroll.position.y -= max(0, relay_card.rect.y - nendo.element(view).rect.y)
	}
	text := frame(&ui)
	testing.expect(t, strings.contains(text, "Loading relays…"))
	thread.join(members_job.worker)
	members_drain(&ui, client)
	if !testing.expect_value(t, len(ui.members), 1) {return}
	text = frame(&ui)
	testing.expect(t, strings.contains(text, "Group relays"))
	testing.expect(t, strings.contains(text, "keep-the-whole-address"))
	seed := group_relay_seed(&ui)
	if !testing.expect_value(t, len(ui.group_relays), 2) {return}
	testing.expect(t, !nendo.element(nendo.id("wss://127.0.0.1:9/", seed)).found)
	ui.chats[ui.selected].conversation_kind = .DIRECT
	ui.info_tab = .Members
	testing.expect(t, strings.contains(frame(&ui), "Chat relays"))
	if point, ok := control_point(t, nendo.id(long_relay, seed)); ok {
		// Input still uses the prior layout if a refresh reorders the relays.
		ui.group_relays[0], ui.group_relays[1] = ui.group_relays[1], ui.group_relays[0]
		nendo.set_pointer(point, .Up)
		forced_release = true
		handle_chat(&ui, client)
		forced_release = false
		clipboard := sdl.GetClipboardText()
		defer sdl.free(clipboard)
		testing.expect_value(t, string(cstring(clipboard)), long_relay)
	}
	ui.chats[ui.selected].conversation_kind = .GROUP
	ui.info_tab = .Settings
	for _ in 0 ..< 3 {frame(&ui)}
	scroll := nendo.scroll(nendo.id("MembersScroll"))
	if !testing.expect(t, scroll.found) {return}
	scroll.position.y = min(0, scroll.viewport.height - scroll.content.height)
	ui.chats[ui.selected].conversation_kind = .DIRECT
	testing.expect(t, strings.contains(frame(&ui), "Delete group"))
	append(&ui.members, Member_Ui{})
	testing.expect(t, strings.contains(frame(&ui), "Leave chat"))
	ui.chats[ui.selected].conversation_kind = .GROUP
	testing.expect(t, strings.contains(frame(&ui), "Leave group"))
	pop(&ui.members)
	text = frame(&ui)
	testing.expect(t, strings.contains(text, "Delete group"))
	testing.expect(t, !nendo.element(nendo.id("LeaveBtn")).found)
	button := nendo.element(nendo.id("DeleteConversationBtn"))
	if !testing.expect(t, button.found) {return}
	b := button.rect
	nendo.set_pointer({b.x + b.width / 2, b.y + b.height / 2}, .Up)
	forced_release = true
	handle_members(&ui, client)
	forced_release = false
	if !testing.expect_value(t, ui.confirm.kind, Confirm_Kind.Delete_Group) {return}
	testing.expect_value(t, len(ui.staged), 1)
	ui.gs_account = strings.clone(account)
	defer {delete(ui.gs_account); gs_clear_hits(&ui); delete(ui.gs_hits)
		for chat in ui.gs_chats {chat_free(chat)}; delete(ui.gs_chats)}
	for chat in ui.chats {append(&ui.gs_chats, chat_clone(chat))}
	append(
		&ui.gs_hits,
		Gs_Hit{group = strings.clone(target), snippet = strings.clone("Deleted history")},
	)
	append(
		&ui.gs_hits,
		Gs_Hit{group = strings.clone(other), snippet = strings.clone("Kept history")},
	)
	ui.mi_account = strings.clone(account)
	defer {delete(ui.mi_account); mi_clear(&ui); delete(ui.mi_hits)}
	append(&ui.mi_hits, Mention_Hit{group = strings.clone(target), unread = true})
	append(&ui.mi_hits, Mention_Hit{group = strings.clone(other), unread = true})
	run_confirm(&ui, client)
	testing.expect(t, strings.contains(frame(&ui), "Deleting your conversation"))
	for timeline in timeline_retired {thread.join(timeline.worker)}
	account_job_drain(&ui)
	for job in account_jobs {thread.join(job.worker)}
	// A background read can adopt the storage deletion before the account job drains.
	testing.expect(t, refresh_after_action(&ui, client))
	testing.expect_value(t, ui.selected, -1)
	account_job_drain(&ui)

	testing.expect_value(t, ui.client_status, "")
	testing.expect_value(t, ui.selected, -1)
	testing.expect_value(t, len(ui.staged), 0)
	testing.expect(t, load_chat_list(client, account, &ui))
	testing.expect_value(t, len(ui.chats), 1)
	if len(ui.chats) == 1 {testing.expect_value(t, ui.chats[0].group_id, other)}
	if testing.expect_value(
		t,
		len(ui.gs_chats),
		1,
	) {testing.expect_value(t, ui.gs_chats[0].group_id, other)}
	if testing.expect_value(
		t,
		len(ui.gs_hits),
		1,
	) {testing.expect_value(t, ui.gs_hits[0].snippet, "Kept history")}
	testing.expect_value(t, mi_unread_count(&ui), 1)
	if len(ui.mi_hits) == 1 {testing.expect_value(t, ui.mi_hits[0].group, other)}
	testing.expect_value(t, ui.drafts[draft_key(account, other)], "Keep this draft")

	// Closing before the next frame must still remove a committed delete's saved data.
	if !testing.expect(t, select_by_id(&ui, client, other)) {return}
	thread.join(members_job.worker)
	members_drain(&ui, client)
	append(
		&ui.pending,
		Pending_Send {
			account_ref = strings.clone(account),
			group_id = strings.clone(other),
			body = strings.clone("Queued for the group"),
			queued = true,
		},
	)
	defer {for &pending in ui.pending {free_pending(&pending)}; delete(ui.pending)}
	save_offline(&ui)
	_, queue_err := os.read_entire_file(offline_path(), context.temp_allocator)
	if !testing.expect_value(t, queue_err, nil) {return}
	confirm_ask(&ui, .Delete_Group, other)
	run_confirm(&ui, client)
	for timeline in timeline_retired {thread.join(timeline.worker)}
	account_job_drain(&ui)
	account_deletes_finish(&ui)
	_, queue_err = os.read_entire_file(offline_path(), context.temp_allocator)
	testing.expect(t, queue_err != nil)
	_, have_draft := ui.drafts[draft_key(account, other)]
	testing.expect(t, !have_draft)

	for job in account_jobs {thread.join(job.worker)}
	account_job_drain(&ui)
	ui.page, ui.new_chat_open, ui.nc_page = .Chats, true, .Group
	ui.nc_retention = 3600
	ed_set(&ui, &ui.nc_description, "Bring a map")
	// A solo group keeps this founding operation independent of relay discovery.
	job := account_job_new(&ui, client, .Create_Chat)
	if !testing.expect(t, job != nil) {return}
	job.title = strings.clone("Hiking")
	job.description = strings.clone(string(ui.nc_description[:]))
	job.retention = ui.nc_retention
	job.form, job.open_chat = .Group, true
	account_job_start(job)
	thread.join(job.worker)
	if !testing.expect(t, job.error == "" && job.opened_row != nil, job.error) {return}
	founded := strings.clone(job.result)
	defer delete(founded)
	// Lose just the first row read, after the real SDK has committed the group.
	marmot.presented_chat_row_free(job.opened_row)
	job.opened_row = nil
	job.error = strings.clone("First authoritative read failed")
	account_job_drain(&ui)
	frame(&ui)
	point, found := control_point(t, nendo.id("NCRetryOpen"))
	if !found {return}
	nendo.set_pointer(point, .Up)
	forced_release = true
	handle_new_chat(&ui, client)
	forced_release = false
	for retry in account_jobs {thread.join(retry.worker)}
	account_job_drain(&ui)
	if !testing.expect(t, !ui.new_chat_open && ui.selected >= 0) {return}
	testing.expect_value(t, ui.chats[ui.selected].group_id, founded)
	details: ^marmot.Group_Details
	status = marmot.group_details(
		client,
		strings.clone_to_cstring(account, context.temp_allocator),
		strings.clone_to_cstring(founded, context.temp_allocator),
		&details,
	)
	if !testing.expect(t, status == .OK && details != nil, marmot.last_error()) {return}
	defer marmot.group_details_free(details)
	testing.expect_value(t, details.group.disappearing_message_secs, 3600)
	testing.expect_value(t, string(details.group.description), "Bring a map")
}

@(test)
group_relay_identity :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		group_relay_key("WSS://Relay.example:443/"),
		group_relay_key("wss://relay.example"),
	)
	testing.expect_value(
		t,
		group_relay_key("ws://Relay.example:80/?q=1"),
		group_relay_key("ws://relay.example?q=1"),
	)
	testing.expect(
		t,
		group_relay_key("wss://relay.example\\Upper") !=
		group_relay_key("wss://relay.example\\upper"),
	)
	testing.expect(
		t,
		group_relay_key("wss://relay.example/room/") !=
		group_relay_key("wss://relay.example/room"),
	)
}
