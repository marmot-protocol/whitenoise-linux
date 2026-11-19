package main

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:text/edit"

import marmot "../marmot"
import "nendo"
import rl "sdlrl"

@(test)
devices_event_dispatch :: proc(t: ^testing.T) {
	live: Live
	defer {
		for account, change in live.dirty_devices {
			delete(account)
			delete(change.unlink_label)
		}
		delete(live.dirty_devices)
		for change in live.dirty_groups {delete(change.group); delete(change.account)}
		delete(live.dirty_groups)
	}

	event: marmot.Runtime_Event
	// A non-nil word beyond the account prefix must not be read as a group.
	event.body.group.group = "not-a-group"
	event.body.account.account = "account-a"
	event.body.account.label = "Profile A"
	event.tag = .Device_Link_Changed
	testing.expect_value(t, queue_live_event(&live, &event), MULTI_DEVICE)
	event.tag = .Linked_Devices_Changed
	testing.expect_value(t, queue_live_event(&live, &event), MULTI_DEVICE)
	event.tag = .Recovery_Status_Changed
	testing.expect(t, !queue_live_event(&live, &event))
	event.tag = .Device_Unlinked
	testing.expect_value(t, queue_live_event(&live, &event), MULTI_DEVICE)

	testing.expect_value(t, len(live.dirty_groups), 0)
	if MULTI_DEVICE {
		testing.expect_value(t, len(live.dirty_devices), 1)
		change := live.dirty_devices["account-a"]
		testing.expect_value(
			t,
			change.parts,
			Device_Parts{.Link, .Roster, .Started_Fresh, .Unlinked},
		)
		testing.expect_value(t, change.unlink_label, "Profile A")
	} else {
		testing.expect_value(t, len(live.dirty_devices), 0)
	}

	event.tag = .Group_Event
	event.body.group_event.account = "account-a"
	event.body.group_event.group = "older-dm"
	event.body.group_event.event.tag = .QUEUED_INTENT_REFUSED
	event.body.group_event.event.body.failure.intent_kind = "enable_account_devices"
	testing.expect(t, queue_live_event(&live, &event))
	testing.expect_value(t, live.dirty_groups[0].activation_failure, MULTI_DEVICE)
	event.body.group_event.event.tag = .GROUP_CHANGE_NOT_DELIVERED
	testing.expect(t, queue_live_event(&live, &event))
	testing.expect_value(t, live.dirty_groups[1].activation_failure, MULTI_DEVICE)
	event.body.group_event.event.body.failure.intent_kind = "remove_member"
	testing.expect(t, queue_live_event(&live, &event))
	testing.expect(t, !live.dirty_groups[2].activation_failure)
	event.body.group_event.event.body.failure.intent_kind = "enable_account_devices"
	event.tag = .Group_Change_Superseded
	testing.expect(t, queue_live_event(&live, &event))
	testing.expect(t, !live.dirty_groups[3].activation_failure)
}

@(test)
devices_snapshot_scope :: proc(t: ^testing.T) {
	if !MULTI_DEVICE {return}
	ui: Ui_State
	defer devices_stop(&ui)
	ui.account_ref = "account-a"
	devices_select(&ui)
	profile := ui.devices.profiles["account-a"]
	first := Device_Job {
		account = profile.account,
		active = true,
		generation = ui.devices.generation,
		reads = {.Started_Fresh},
		data = {started_fresh = true},
	}
	device_apply(&ui.devices, profile, &first)
	testing.expect(t, profile.view.started_fresh)

	failed := first
	failed.failed = {.Started_Fresh}
	failed.data.started_fresh = false
	device_apply(&ui.devices, profile, &failed)
	testing.expect(t, profile.view.started_fresh)
	testing.expect(t, .Started_Fresh in profile.known && .Started_Fresh in profile.stale)

	ui.account_ref = "account-b"
	devices_select(&ui)
	ui.account_ref = "account-a"
	devices_select(&ui)
	device_apply(&ui.devices, profile, &first)
	testing.expect(t, !profile.view.started_fresh && .Started_Fresh not_in profile.known)

	first.generation = ui.devices.generation
	ui.account_ref = "account-b"
	devices_select(&ui)
	devices_mark_unlinked(&ui, "account-a", "A")
	device_apply(&ui.devices, profile, &first)
	testing.expect(t, profile.revoked && profile.known == {} && !profile.view.started_fresh)
}

@(private = "file")
device_test_ui :: proc(ui: ^Ui_State, memory: ^[]u8) -> ^nendo.Context {
	sync.lock(&nendo_test_mutex)
	old := nendo.current_context()
	rl.InitWindow(1140, 840, "Device flow")
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	set_locale("en")
	init_layout(memory, 32768, {1140, 840})
	ui^ = Ui_State {
		page          = .Settings,
		selected      = -1,
		row_menu      = -1,
		member_menu   = -1,
		audit_scanned = true,
	}
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	ui.account_ref = "account-a"
	append(&ui.accounts, Account_Row_Ui{id_hex = "account-a", name = "Profile A", local = true})
	edit.init(&ui.ed, context.allocator, context.allocator)
	g_ui, g_prefs = ui, &ui.prefs
	devices_select(ui)
	return old
}

@(private = "file")
device_test_finish :: proc(ui: ^Ui_State, memory: []u8, old: ^nendo.Context) {
	devices_stop(ui)
	delete(ui.accounts)
	delete(ui.settings_search)
	session_media_clear()
	g_ui, g_prefs = nil, nil
	nendo.set_context(old)
	delete(memory)
	rl.CloseWindow()
	sync.unlock(&nendo_test_mutex)
}

@(private = "file")
device_test_frame :: proc(ui: ^Ui_State) -> string {
	nendo.set_pointer({-100, -100}, .Up)
	anim_tick(1.0 / 60)
	commands := build_layout(ui, 0)
	text := make([dynamic]u8, context.temp_allocator)
	for cmd in commands {
		if cmd.kind == .Text {append(&text, cmd.text.text); append(&text, ' ')}
	}
	return string(text[:])
}

@(test)
devices_visibility :: proc(t: ^testing.T) {
	if !strings.contains(#config(ODIN_TEST_NAMES, ""), "devices_visibility") {return}
	context.allocator = runtime.default_context().allocator
	ui: Ui_State
	memory: []u8
	old := device_test_ui(&ui, &memory)
	defer device_test_finish(&ui, memory, old)

	append(&ui.settings_search, "manage linked devices")
	for _ in 0 ..< 2 {device_test_frame(&ui)}
	index := -1
	for task, i in SETTINGS_TASKS {if task.section == .Devices {index = i; break}}
	if !testing.expect(t, index >= 0) {return}
	result_id := nendo.id("SettingsTask", u32(index))
	result := nendo.element(result_id)
	testing.expect_value(t, result.found, MULTI_DEVICE)
	if result.found {
		r := result.rect
		nendo.set_pointer({r.x + r.width / 2, r.y + r.height / 2}, .Up)
		forced_release = true
		testing.expect(t, settings_handle_navigation(&ui, nil))
		forced_release = false
		testing.expect_value(t, ui.settings_section, Settings_Section.Devices)
		testing.expect_value(t, ui.settings_level, Settings_Level.Sheet)
		testing.expect_value(t, ui.settings_anchor, "DevicesRoster")
		device_test_frame(&ui)
		testing.expect(t, nendo.element(nendo.id("DevicesRoster")).found)
	}
	ui.prefs.page, ui.prefs.settings_section = .Settings, .Devices
	restore_workspace(&ui, nil)
	testing.expect_value(t, ui.settings_section, MULTI_DEVICE ? Settings_Section.Devices : .Home)
	if profile := device_current(&ui); profile != nil {
		ui.page = .Chats
		profile.first_import = true
		profile.known = {.Link, .Roster, .Started_Fresh, .Sign_Ins}
		devices_present(&ui, true)
		testing.expect_value(t, ui.devices.panel, Device_Panel.None)
		signed := marmot.Unrecognized_Sign_In {
			before_this_device = true,
			state              = .PROMPT,
		}
		list := marmot.Unrecognized_Sign_In_List {
			items = &signed,
			len   = 1,
		}
		profile.view.sign_ins = &list
		devices_present(&ui, true)
		text := device_test_frame(&ui)
		testing.expect(t, strings.contains(text, "Signed in on another device?"))
		rl.PushKey(.ESCAPE, true)
		handle_device_modal(&ui, nil)
		rl.PushKey(.ESCAPE, false)
		devices_present(&ui, true)
		testing.expect_value(t, ui.devices.panel, Device_Panel.None)
		testing.expect_value(t, device_busy(profile), Device_Action.None)
		profile.view.sign_ins = nil
	}
	ui.account_ref = ""
	devices_select(&ui)
	restore_workspace(&ui, nil)
	testing.expect_value(t, ui.settings_section, Settings_Section.Home)
}

@(test)
devices_pairing_projection :: proc(t: ^testing.T) {
	if !MULTI_DEVICE ||
	   !strings.contains(#config(ODIN_TEST_NAMES, ""), "devices_pairing_projection") {return}
	context.allocator = runtime.default_context().allocator
	ui: Ui_State
	memory: []u8
	old := device_test_ui(&ui, &memory)
	defer device_test_finish(&ui, memory, old)
	profile := device_current(&ui)
	profile.known = {.Link, .Roster}
	emoji := [?]marmot.Device_Link_Emoji {
		{"🐶", "Dog"},
		{"🔑", "Key"},
		{"🌵", "Cactus"},
		{"🚲", "Bicycle"},
		{"🎸", "Guitar"},
		{"🍎", "Apple"},
		{"⚓", "Anchor"},
	}
	code := marmot.Device_Link_Code{raw_data(emoji[:]), len(emoji)}
	prompt := marmot.Device_Link_Prompt {
		prompt_id = "opaque-request",
		state = {tag = .COMPARING},
	}
	prompt.state.body.comparing = code
	link := marmot.Device_Link_Snapshot {
		prompts     = &prompt,
		prompts_len = 1,
	}
	profile.view.link = &link
	defer profile.view.link = nil
	devices_show(&ui, .Approve, profile.account, "opaque-request")
	text: string
	for _ in 0 ..< 2 {text = device_test_frame(&ui)}
	after := text
	for cell in emoji {
		label := string(cell.description)
		at := strings.index(after, label)
		if !testing.expect(t, at >= 0, label) {break}
		after = after[at + len(label):]
	}
	testing.expect(t, strings.contains(text, "They match, link device"))
	clear(&ui.devices.name)
	for _ in 0 ..< 21 {append(&ui.devices.name, "界")}
	append(&ui.devices.name, "ab")
	testing.expect(t, !device_name_valid(string(ui.devices.name[:])))
	emoji[0].emoji = "dog"
	testing.expect(t, !device_code_valid(code))
	prompt.state.tag = .COMPETING_REQUESTS
	text = device_test_frame(&ui)
	testing.expect(t, !strings.contains(text, "They match, link device"))
	testing.expect(t, strings.contains(text, "Not now"))
	prompt.state.tag = .LINKED
	text = device_test_frame(&ui)
	testing.expect(t, strings.contains(text, "Device linked"))
	testing.expect(t, !strings.contains(text, "Not now"))
	link.prompts_len = 0
	text = device_test_frame(&ui)
	testing.expect(t, strings.contains(text, "This request is no longer active."))
	devices_show(&ui, .Other_Profile, "account-b", "request-b")
	text = device_test_frame(&ui)
	testing.expect(t, !strings.contains(text, "They match, link device"))
}

@(test)
devices_roster_repair :: proc(t: ^testing.T) {
	if !MULTI_DEVICE ||
	   !strings.contains(#config(ODIN_TEST_NAMES, ""), "devices_roster_repair") {return}
	context.allocator = runtime.default_context().allocator
	ui: Ui_State
	memory: []u8
	old := device_test_ui(&ui, &memory)
	defer device_test_finish(&ui, memory, old)
	settings_open(&ui, nil, .Devices)
	profile := device_current(&ui)
	profile.known = {.Link, .Roster}
	row := marmot.Linked_Device {
		slot_id_hex = "sibling",
	}
	roster := marmot.Linked_Device_List {
		items = &row,
		len   = 1,
	}
	profile.view.roster = &roster
	command := Device_Command {
		kind = .Remove_Sibling,
		slot = "sibling",
	}
	testing.expect(t, device_command_current(profile, command))
	row.is_this_device = true
	testing.expect(t, !device_command_current(profile, command))
	row.is_this_device, row.removal_pending = false, true
	testing.expect(t, !device_command_current(profile, command))
	profile.view.roster = nil
	siblings := [?]marmot.Device_Group_Move_Sibling {
		{slot_id_hex = "slot-hint", label = "Old kitchen device", question_suppressed = true},
		{slot_id_hex = "slot-hidden", label = "Not a hint"},
	}
	move := marmot.Device_Group_Move_View {
		move_id          = "move-a",
		state            = .JOINING,
		old_siblings     = raw_data(siblings[:]),
		old_siblings_len = len(siblings),
	}
	link := marmot.Device_Link_Snapshot {
		moves     = &move,
		moves_len = 1,
	}
	profile.view.link = &link
	defer profile.view.link = nil
	text := device_test_frame(&ui)
	testing.expect(t, strings.contains(text, "Old kitchen device is still"))
	testing.expect(t, !strings.contains(text, "Not a hint"))
	testing.expect(t, !strings.contains(text, "Moved to your other device group."))
	testing.expect(t, !nendo.element(nendo.id("DeviceReset")).found)
	testing.expect(
		t,
		device_command_current(
			profile,
			{kind = .Dismiss_Sibling, move_id = "move-a", slot = "slot-hint"},
		),
	)
	testing.expect(
		t,
		!device_command_current(
			profile,
			{kind = .Dismiss_Sibling, move_id = "move-a", slot = "slot-hidden"},
		),
	)
	move.state = .MADE
	link.device_group_stalled = true
	text = device_test_frame(&ui)
	testing.expect(t, strings.contains(text, "Moved to your other device group."))
	testing.expect(t, nendo.element(nendo.id("DeviceReset")).found)
	confirm_ask(&ui, .Reset_Devices, "")
	defer {delete(ui.confirm.arg); delete(ui.confirm.name); delete(ui.confirm.account)}
	ui.account_ref = "account-b"
	run_confirm(&ui, nil)
	testing.expect_value(t, device_busy(profile), Device_Action.None)
	ui.account_ref = "account-a"

	job := Device_Job {
		active = true,
		generation = ui.devices.generation,
		account = profile.account,
		command = {kind = .Reset},
		status = .RUNTIME,
	}
	device_apply(&ui.devices, profile, &job)
	device_finish(&ui, profile, &job)
	testing.expect(t, profile.view.link == &link && profile.view.link.device_group_stalled)
	fresh: marmot.Device_Link_Snapshot
	job.status, job.reads, job.data.link = .PUBLISH, {.Link}, &fresh
	device_apply(&ui.devices, profile, &job)
	device_finish(&ui, profile, &job)
	testing.expect(t, profile.view.link == &fresh && !profile.view.link.device_group_stalled)
	text = device_test_frame(&ui)
	testing.expect(t, strings.contains(text, "Start linking"))
	testing.expect(t, strings.contains(text, "key package couldn't be published"))
	testing.expect_value(t, device_busy(profile), Device_Action.None)
}

@(test)
devices_account_fence :: proc(t: ^testing.T) {
	if !MULTI_DEVICE ||
	   !strings.contains(#config(ODIN_TEST_NAMES, ""), "devices_account_fence") {return}
	context.allocator = runtime.default_context().allocator
	ui: Ui_State
	memory: []u8
	old := device_test_ui(&ui, &memory)
	defer device_test_finish(&ui, memory, old)
	ui.account_ref = strings.clone("account-a")
	ui.accounts[0].id_hex, ui.accounts[0].name = strings.clone("account-a"), strings.clone("A")
	append(
		&ui.accounts,
		Account_Row_Ui{id_hex = strings.clone("account-b"), name = strings.clone("B")},
	)
	ui.accounts_revision = 1
	devices_seed(&ui)
	ui.page = .Chats
	ui.selected = 0
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = strings.clone("chat-a"), title = strings.clone("Chat A")},
	)
	append(&ui.compose, "a draft")
	a := Pending_Send {
		account_ref = "account-a",
		group_id    = "chat-a",
	}
	b := Pending_Send {
		account_ref = "account-b",
		group_id    = "chat-a",
	}
	testing.expect(t, pending_in_workspace(&ui, a, "chat-a"))
	testing.expect(t, !pending_in_workspace(&ui, b, "chat-a"))
	testing.expect(t, pending_send_allowed(&ui, b))
	devices_mark_unlinked(&ui, "account-b", "B")
	testing.expect_value(t, ui.account_ref, "account-a")
	testing.expect_value(t, ui.selected, 0)
	testing.expect_value(t, string(ui.compose[:]), "a draft")
	testing.expect(t, !pending_send_allowed(&ui, b))
	finish_account_switch(&ui, nil, "account-b")
	testing.expect_value(t, ui.account_ref, "account-a")

	devices_mark_unlinked(&ui, "account-a", "A")
	testing.expect_value(t, ui.account_ref, "")
	testing.expect_value(t, ui.selected, -1)
	testing.expect_value(t, len(ui.compose), 0)
	testing.expect(t, !pending_send_allowed(&ui, a))
	finish_account_switch(&ui, nil, "account-a")
	testing.expect_value(t, ui.account_ref, "")
	devices_present(&ui, true)
	text := device_test_frame(&ui)
	testing.expect(t, strings.contains(text, "Device unlinked"))
	testing.expect(t, strings.contains(text, "Remove from this device"))
	devices_notice_closed(&ui)
	devices_present(&ui, true)
	testing.expect(t, ui.devices.panel_account != "account-a")

	remaining := marmot.Account_Summary {
		account_id_hex = "account-a",
		signed_out     = true,
		unlinked       = true,
	}
	accounts := marmot.Account_Summary_List {
		items = &remaining,
		len   = 1,
	}
	exit := Account_Job {
		account       = "account-a",
		kind          = .Wipe,
		accounts_read = true,
		accounts      = &accounts,
	}
	testing.expect(t, !account_exit_confirmed(&exit, .OK, false))
	accounts.len = 0
	testing.expect(t, account_exit_confirmed(&exit, .IO, false))
	accounts.len = 1
	remaining.label = "A"
	testing.expect_value(
		t,
		auth_unlinked_target(
			&accounts,
			.Import,
			"this device was unlinked from the account: A",
			"",
		),
		"account-a",
	)
	testing.expect_value(
		t,
		auth_unlinked_target(
			&accounts,
			.Bunker,
			"this device was unlinked from the account: A",
			"different",
		),
		"",
	)
}

@(test)
devices_sign_in_review :: proc(t: ^testing.T) {
	if !MULTI_DEVICE ||
	   !strings.contains(#config(ODIN_TEST_NAMES, ""), "devices_sign_in_review") {return}
	context.allocator = runtime.default_context().allocator
	ui: Ui_State
	memory: []u8
	old := device_test_ui(&ui, &memory)
	defer device_test_finish(&ui, memory, old)
	profile := device_current(&ui)
	profile.known = DEVICE_READS
	sign_in := marmot.Unrecognized_Sign_In {
		slot_id_hex        = "sign-in-slot",
		state              = .PROMPT,
		before_this_device = true,
		client             = "Fixture client",
	}
	list := marmot.Unrecognized_Sign_In_List {
		items = &sign_in,
		len   = 1,
	}
	profile.view.sign_ins = &list
	warning := marmot.Compromise_Warning_Item {
		reason      = .REJECTED_SIGN_IN,
		occurred_at = 100,
	}
	warnings := marmot.Compromise_Warning_Item_List {
		items = &warning,
		len   = 1,
	}
	profile.view.warning = &warnings
	defer {profile.view.sign_ins = nil; profile.view.warning = nil}
	ui.page = .Chats
	for _ in 0 ..< 3 {device_test_frame(&ui)}
	button := nendo.element(nendo.id("DeviceAttentionBanner"))
	if !testing.expect(t, button.found) {return}
	r := button.rect
	nendo.set_pointer({r.x + r.width / 2, r.y + r.height / 2}, .Up)
	forced_release = true
	testing.expect(t, handle_devices_banner(&ui, nil))
	forced_release = false
	testing.expect_value(t, ui.settings_anchor, "DevicesWarning")
	text := device_test_frame(&ui)
	testing.expect(t, strings.contains(text, "Someone may have your private key"))
	testing.expect(t, strings.contains(text, "A sign-in was marked as not you"))
	roster := nendo.element(nendo.id("DevicesRoster"))
	review := nendo.element(nendo.id("DevicesSignIns"))
	testing.expect(
		t,
		roster.found && review.found && review.rect.y >= roster.rect.y + roster.rect.height,
	)
	testing.expect(t, device_can_start_fresh(profile))
	command := Device_Command {
		kind = .Answer_Sign_In,
		slot = "sign-in-slot",
	}
	testing.expect(t, device_command_current(profile, command))
	sign_in.state = .NOT_NOW
	testing.expect(t, !device_command_current(profile, command))
	testing.expect(t, !device_can_start_fresh(profile))
	command.response = .REJECT
	testing.expect(t, device_command_current(profile, command))
	button = nendo.element(nendo.id("SignInRecognize0"))
	if !testing.expect(t, button.found) {return}
	defer {
		sign_in_reviews_drop(&ui.prefs, profile.account)
		delete(ui.prefs.sign_ins_recognized)
	}
	r = button.rect
	nendo.set_pointer({r.x + r.width / 2, r.y + r.height / 2}, .Up)
	forced_release = true
	testing.expect(t, handle_devices(&ui, nil))
	forced_release = false
	device_test_frame(&ui)
	testing.expect(t, !nendo.element(nendo.id("SignInRecognize0")).found)
	testing.expect(t, nendo.element(nendo.id("SignInReject0")).found)
	testing.expect(t, ui.devices.panel == .None && profile.queued.kind == .None)
	sign_in.appeared_at += 1
	device_test_frame(&ui)
	testing.expect(t, nendo.element(nendo.id("SignInRecognize0")).found)
	sign_in.state = .LINKED_ELSEWHERE
	testing.expect(t, !device_command_current(profile, command))
	command.response = .DISMISS
	testing.expect(t, device_command_current(profile, command))
}

@(test)
devices_chat_activation :: proc(t: ^testing.T) {
	if !MULTI_DEVICE ||
	   !strings.contains(#config(ODIN_TEST_NAMES, ""), "devices_chat_activation") {return}
	context.allocator = runtime.default_context().allocator
	ui: Ui_State
	memory: []u8
	old := device_test_ui(&ui, &memory)
	defer device_test_finish(&ui, memory, old)
	defer {delete(ui.chats); delete(ui.confirm.account); delete(ui.confirm.arg)
		delete(ui.confirm.name)
		confirm_shown = .None}
	defer activation_stop(&ui)
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "older-dm", title = "Older DM", conversation_kind = .DIRECT},
	)
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "new-dm", title = "New DM", conversation_kind = .DIRECT},
	)
	ui.page, ui.selected, ui.show_members, ui.info_tab = .Chats, 0, true, .Settings
	activation_refresh(&ui)
	a := &ui.activation
	read := Activation_Read {
		account     = "account-a",
		group       = "older-dm",
		revision    = a.revision,
		eligibility = .ALREADY_ENABLED,
	}
	activation_apply_read(&ui, &read)
	device_test_frame(&ui)
	testing.expect(t, !nendo.element(nendo.id("EnableAccountDevices")).found)
	read.eligibility = .ELIGIBLE
	activation_apply_read(&ui, &read)
	device_test_frame(&ui)
	button := nendo.element(nendo.id("EnableAccountDevices"))
	if !testing.expect(t, button.found) {return}
	r := button.rect
	nendo.set_pointer({r.x + r.width / 2, r.y + r.height / 2}, .Up)
	forced_release = true
	handle_members(&ui, nil)
	forced_release = false
	testing.expect_value(t, ui.confirm.kind, Confirm_Kind.Enable_Account_Devices)
	first := ui.confirm
	testing.expect(t, activation_can_submit(&ui, first))
	ui.selected = 1
	_, accepted := activation_prepare(&ui, first)
	testing.expect(t, !accepted)
	activation_refresh(&ui)
	activation_apply_read(&ui, &read)
	testing.expect(t, !a.known)
	ui.selected = 0
	activation_refresh(&ui)
	read.revision = a.revision
	activation_apply_read(&ui, &read)
	apply := proc(
		ui: ^Ui_State,
		status: marmot.Status,
		disposition: marmot.Send_Accept_Disposition = .PUBLISHED,
	) {
		a := &ui.activation
		key := Activation_Key{strings.clone(a.key.account), strings.clone(a.key.group)}
		if key not_in a.pending {a.pending[key] = {
				key      = key,
				ticket   = 1,
				revision = a.revision,
			}} else {delete(key.account); delete(key.group)}
		activation_complete(
			ui,
			nil,
			{
				account = strings.clone(a.key.account),
				group = strings.clone(a.key.group),
				ticket = 1,
				activation = {status = status, disposition = disposition},
			},
		)
	}
	for advice in ([?]struct {
			kind:   Confirm_Kind,
			status: marmot.Status,
		}{{.Activation_Catching_Up, .GROUP_CATCHING_UP}, {.Activation_Undelivered, .GROUP_COMMIT_UNDELIVERED}}) {
		apply(&ui, advice.status)
		activation_drain(&ui, nil)
		testing.expect_value(t, ui.confirm.kind, advice.kind)
		for _ in 0 ..< 3 {device_test_frame(&ui)}
		cancel := nendo.element(nendo.id("ConfirmCancel"))
		if !testing.expect(t, cancel.found) {return}
		r := cancel.rect
		nendo.set_pointer({r.x + r.width / 2, r.y + r.height / 2}, .Up)
		forced_release = true
		handle_confirm(&ui, nil)
		forced_release = false
		testing.expect_value(t, a.advisory, Activation_Advisory.None)
		testing.expect_value(t, ui.confirm.kind, Confirm_Kind.None)
		apply(&ui, advice.status)
		activation_drain(&ui, nil)
		status, ok := activation_prepare(&ui, ui.confirm)
		testing.expect(t, ok)
		testing.expect_value(t, status, advice.status)
		confirm_close(&ui)
		apply(&ui, advice.status)
		activation_drain(&ui, nil)
		testing.expect_value(t, ui.confirm.kind, Confirm_Kind.None)
		testing.expect(t, strings.contains(a.notice, "Couldn't turn on linked devices"))
	}
	apply(&ui, .ACCOUNT_DEVICES_ACTIVATION_REFUSED)
	read.eligibility = .MEMBERS_NEED_UPDATE
	activation_apply_read(&ui, &read)
	testing.expect(t, strings.contains(a.notice, "Some members need to update"))
	device_test_frame(&ui)
	testing.expect(t, !nendo.element(nendo.id("EnableAccountDevices")).found)
	for verdict in ([?]marmot.Account_Devices_Activation{.ELIGIBLE, .ALREADY_ENABLED}) {
		key := Activation_Key{strings.clone(a.key.account), strings.clone(a.key.group)}
		a.pending[key] = {
			key      = key,
			ticket   = 1,
			revision = a.revision,
		}
		activation_live(
			&ui,
			{
				group = key.group,
				account = key.account,
				activation_signal = true,
				activation_failure = true,
			},
		)
		apply(&ui, .OK, .ACCEPTED_PENDING)
		testing.expect(t, a.pending[key].settling)
		text := device_test_frame(&ui)
		testing.expect(t, strings.contains(text, "Waiting for the linked devices change"))
		read.ticket, read.eligibility = 1, verdict
		activation_apply_read(&ui, &read)
		testing.expect_value(t, len(a.pending), 0)
		want := verdict == .ELIGIBLE ? "weren't turned on" : "are turned on"
		testing.expect(t, strings.contains(a.notice, want))
	}
}

@(test)
devices_chat_sync :: proc(t: ^testing.T) {
	if !MULTI_DEVICE ||
	   !strings.contains(#config(ODIN_TEST_NAMES, ""), "devices_chat_sync") {return}
	context.allocator = runtime.default_context().allocator
	ui: Ui_State
	memory: []u8
	old := device_test_ui(&ui, &memory)
	defer device_test_finish(&ui, memory, old)
	account :: "abcdef0000000000000000000000000000000000000000000000000000000000"
	ui.account_ref = account
	devices_select(&ui)
	ui.page, ui.selected = .Chats, 0
	append(&ui.chats, Chat_Row_Ui{group_id = "test-group", title = "Synced chat"})
	defer {
		for msg in ui.messages {message_free(msg)}
		delete(ui.messages); delete(ui.chats); delete(ui.pending); delete(ui.hidden)
		delete(ui.messages_account); delete(ui.messages_group)
		messages_collect()
	}
	profile := device_current(&ui)
	entry := marmot.Chat_History_Import {
		group_id_hex = "test-group",
	}
	imports := marmot.Chat_History_Import_List {
		items = &entry,
		len   = 1,
	}
	profile.view.history_by_group = device_history_index(&imports)
	text := device_test_frame(&ui)
	testing.expect(t, strings.contains(text, "Bringing earlier messages from your other device"))
	entry.state.body.receiving.retrying = true
	text = device_test_frame(&ui)
	testing.expect(t, strings.contains(text, "Still trying to bring earlier messages"))
	entry.state.tag = .IMPORTED
	text = device_test_frame(&ui)
	testing.expect(t, !strings.contains(text, "bring earlier messages"))

	append(
		&ui.pending,
		Pending_Send{body = "Same text", group_id = "test-group", account_ref = account},
	)
	legacy := marmot.History_Import_Source {
		device_slot_id_hex = "source",
		device_label       = "Old name",
	}
	provenance: marmot.History_Import_Provenance
	provenance.body.device.device_slot_id_hex = "source"
	backup := marmot.History_Import_Provenance {
		tag = .BACKUP,
	}
	change := marmot.Group_System_Event {
		text = "A member joined",
	}
	event := [?]cstring{"e", "thread-root"}
	tag := marmot.Message_Tag {
		values     = raw_data(event[:]),
		values_len = len(event),
	}
	rows := [?]marmot.Timeline_Message_Record {
		{
			kind = 9,
			message_id_hex = "imported",
			direction = "received",
			sender = "ABCDEF0000000000000000000000000000000000000000000000000000000000",
			plaintext = "Same text",
			imported_from = &legacy,
			history_import_provenance = &provenance,
			timeline_at = 1000,
		},
		{kind = 1210, message_id_hex = "sys", group_system = &change, timeline_at = 1001},
		{
			kind = 9,
			message_id_hex = "hidden",
			direction = "received",
			plaintext = "hidden",
			timeline_at = 1002,
		},
		{
			kind = 1111,
			message_id_hex = "thread",
			direction = "received",
			plaintext = "off-route",
			tags = &tag,
			tags_len = 1,
			history_import_provenance = &backup,
			timeline_at = 1003,
		},
		{
			kind = 9,
			message_id_hex = "local-in-flight",
			direction = "sent",
			plaintext = "Same text",
			timeline_at = 1004,
		},
		{
			kind = 9,
			message_id_hex = "live",
			direction = "sent",
			plaintext = "Confirmed by recipient",
			recipient_confirmed = true,
			timeline_at = 1005,
		},
	}
	ui.hidden["hidden"] = true
	page := marmot.Timeline_Page {
		messages     = raw_data(rows[:]),
		messages_len = len(rows),
	}
	timeline_apply(nil, &ui, &page)
	if !testing.expect_value(t, len(ui.messages), 4) {return}
	testing.expect(t, ui.messages[0].mine)
	testing.expect_value(t, ui.messages[0].delivery, marmot.Delivery_State.NOT_APPLICABLE)
	testing.expect_value(t, ui.messages[3].id, "live")
	testing.expect_value(t, ui.messages[3].delivery, marmot.Delivery_State.DELIVERED)
	testing.expect_value(t, len(ui.pending), 1)
	legacy.device_label = "Changed in native storage"
	text = device_test_frame(&ui)
	testing.expect_value(t, strings.count(text, "Messages above were"), 1)
	testing.expect(t, strings.contains(text, "Messages above were imported from Old name"))
	marker := nendo.id("HistoryImportDivider", nendo.id("live").id)
	testing.expect(t, nendo.element(marker).found)
	baseline := nendo.element(nendo.id("MsgRow", 3)).rect.y
	roster := marmot.Linked_Device {
		slot_id_hex = "source",
		label       = "Renamed device",
	}
	listed := marmot.Linked_Device_List {
		items = &roster,
		len   = 1,
	}
	profile.known += {.Roster}
	profile.view.roster_labels = device_roster_labels(&listed)
	text = device_test_frame(&ui)
	testing.expect(t, strings.contains(text, "Messages above were imported from Renamed device"))
	testing.expect_value(t, nendo.element(nendo.id("MsgRow", 3)).rect.y, baseline)
	clear(&profile.view.roster_labels)
	text = device_test_frame(&ui)
	testing.expect(t, strings.contains(text, "Messages above were imported from another device"))
	rows[0].history_import_provenance = &backup
	rows[5].invalidation_status = "local_publish_failed"
	timeline_apply(nil, &ui, &page)
	text = device_test_frame(&ui)
	testing.expect(t, strings.contains(text, "Messages above were restored from a backup"))
	testing.expect_value(t, ui.messages[3].delivery, marmot.Delivery_State.FAILED)
}
