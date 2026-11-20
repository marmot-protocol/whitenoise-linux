package main

import "core:strings"
import "core:sync"
import "core:thread"

import marmot "../marmot"

@(private)
Device_Job :: struct {
	worker:                  ^thread.Thread,
	client:                  ^marmot.Client,
	account:                 string, // profile key; the profile outlives the worker
	generation, incarnation: u64,
	active:                  bool,
	roster_event:            u64,
	reads, failed:           Device_Parts,
	chat_review_cancel:      bool,
	unavailable:             bool,
	data:                    Device_View,
	command:                 Device_Command,
	status:                  marmot.Status,
	detail:                  string,
	follow_up:               Device_Parts,
}

@(private)
Device_Inventory :: struct {
	worker:   ^thread.Thread,
	client:   ^marmot.Client,
	revision: u64,
	status:   marmot.Status,
	accounts: ^marmot.Account_Summary_List,
}

@(private)
device_refusal :: proc(status: marmot.Status, detail: string) -> string {
	PREFIX :: "marmot runtime error: device group refused: "
	if status != .RUNTIME || !strings.has_prefix(detail, PREFIX) {
		return ""
	}
	rest := detail[len(PREFIX):]
	for i in 0 ..< len(rest) {
		c := rest[i]
		if !(('a' <= c && c <= 'z') || ('0' <= c && c <= '9') || c == '_') {
			return rest[:i]
		}
	}
	return rest
}

@(private = "file")
device_read_status :: proc(job: ^Device_Job, part: Device_Part, status: marmot.Status) {
	if status == .OK {return}
	job.failed += {part}
	detail := marmot.last_error()
	defer delete(detail)
	reason := device_refusal(status, detail)
	job.unavailable ||= reason == "pairing_unsupported" || reason == "roster_unsupported"
}

@(private = "file")
device_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer frame_wake()
	defer free_all(context.temp_allocator)
	job := (^Device_Job)(t.data)
	client, account, view :=
		job.client, strings.clone_to_cstring(job.account, context.temp_allocator), &job.data
	if job.command.kind != .None {
		device_mutate(job, account)
		return
	}
	for part in Device_Part {
		if part not_in job.reads {continue}
		status: marmot.Status
		switch part {
		case .Link:
			status = marmot.device_link_snapshot(client, account, &view.link)
		case .Roster:
			status = marmot.linked_devices(client, account, &view.roster)
			if status == .OK {view.roster_labels = device_roster_labels(view.roster)}
		case .Started_Fresh:
			status = marmot.started_fresh(client, account, &view.started_fresh)
		case .Closed_Chats:
			status = marmot.chats_closed_to_linked_devices(client, account, &view.closed_chats)
		case .Leftover_Chats:
			status = marmot.removed_device_leftover_chats(client, account, &view.leftover_chats)
		case .Sign_Ins:
			status = marmot.unrecognized_sign_ins(client, account, &view.sign_ins)
		case .Warning:
			status = marmot.compromise_warning(client, account, &view.warning)
		case .Overdue:
			status = marmot.key_package_refresh_overdue(client, account, &view.overdue)
		case .History:
			status = marmot.chat_history_imports(client, account, &view.history)
			if status == .OK {
				view.history_by_group = device_history_index(view.history)
				for _, item in view.history_by_group {
					if item.state.tag == .RECEIVING {view.history_receiving += 1}
				}
			}
		case .Unlinked:
			continue
		case .Chat_Review:
			if !sync.atomic_load(&job.chat_review_cancel) {
				status = device_read_chat_review(
					client,
					account,
					&view.chat_review,
					&job.chat_review_cancel,
				)
			}
		}
		device_read_status(job, part, status)
	}
}

@(private)
device_read_pending :: proc(profile: ^Device_Profile, part: Device_Part) -> bool {
	if profile == nil || part in profile.dirty {return true}
	job := profile.job
	return job != nil && job.command.kind == .None && part in job.reads
}

@(private)
device_checking_link :: proc(profile: ^Device_Profile) -> bool {
	return device_read_pending(profile, .Link)
}

@(private)
device_busy :: proc(profile: ^Device_Profile) -> Device_Action {
	if profile == nil {return .None}
	if profile.queued.kind != .None {return profile.queued.kind}
	return profile.job == nil ? .None : profile.job.command.kind
}

@(private)
device_queue :: proc(ui: ^Ui_State, command: Device_Command) -> bool {
	profile := device_current(ui)
	if profile == nil ||
	   ui.devices.unavailable ||
	   profile.revoked ||
	   !profile.signed_in ||
	   device_busy(profile) != .None ||
	   command.kind == .None {return false}
	context.allocator = reload_allocator()
	profile.queued = command
	profile.queued.prompt = strings.clone(command.prompt)
	profile.queued.slot = strings.clone(command.slot)
	profile.queued.move_id = strings.clone(command.move_id)
	profile.queued.name = strings.clone(command.name)
	profile.queued.own_name = strings.clone(command.own_name)
	delete(profile.action_error); profile.action_error = ""
	return true
}

@(private)
device_command_free :: proc(command: ^Device_Command) {
	context.allocator = reload_allocator()
	delete(command.prompt); delete(command.slot); delete(command.move_id)
	delete(command.name); delete(command.own_name)
	command^ = {}
}

@(private)
device_command_current :: proc(profile: ^Device_Profile, command: Device_Command) -> bool {
	link := profile.view.link
	attempt := link == nil ? nil : link.new_device
	link_ready := .Link in profile.known && .Link not_in profile.stale
	roster_ready := .Roster in profile.known && .Roster not_in profile.stale
	switch command.kind {
	case .None:
		return false
	case .Start:
		return link_ready && roster_ready && !device_live_attempt(link)
	case .Confirm:
		return(
			link_ready &&
			attempt != nil &&
			attempt.tag == .COMPARING &&
			device_code_valid(attempt.body.comparing) \
		)
	case .Cancel:
		return link_ready && attempt != nil && attempt.tag < .LINKED
	case .Link, .Decline:
		if !link_ready {return false}
		p := device_find_prompt(profile, command.prompt)
		if !device_prompt_attention(p) || p.state.tag == .LINKING {return false}
		if command.kind == .Decline {return true}
		return(
			roster_ready &&
			p.state.tag == .COMPARING &&
			device_code_valid(p.state.body.comparing) &&
			device_name_valid(command.name) &&
			(command.own_name == "" || device_name_valid(command.own_name)) \
		)
	case .Rename, .Rename_Own, .Settings, .Remove_Sibling:
		row := device_find_slot(profile, command.slot)
		if !roster_ready ||
		   row == nil ||
		   row.status == .LEAVING ||
		   row.removal_pending {return false}
		if command.kind == .Settings {return true}
		if command.kind == .Remove_Sibling {return !row.is_this_device}
		if command.kind == .Rename_Own &&
		   (!row.is_this_device || string(row.label) != "") {return false}
		return command.name == "" || device_name_valid(command.name)
	case .Dismiss_Sibling:
		return link_ready && device_find_move_sibling(profile, command.move_id, command.slot)
	case .Reset:
		return link_ready && link != nil && link.device_group_stalled
	case .Check_Sign_Ins:
		return true
	case .Answer_Sign_In:
		row := device_find_sign_in(profile, command.slot)
		if row == nil || .Sign_Ins in profile.stale {return false}
		switch command.response {
		case .NOT_NOW:
			return row.state == .PROMPT
		case .REJECT:
			return row.state == .PROMPT || row.state == .NOT_NOW
		case .DISMISS:
			return row.state == .LINKED_ELSEWHERE || row.state == .REJECTED_ELSEWHERE
		}
	case .Start_Fresh:
		return device_can_start_fresh(profile)
	case .Dismiss_Warning:
		return device_has_warning(profile) && .Warning not_in profile.stale
	}
	return false
}

@(private = "file")
device_requirements :: proc(kind: Device_Action) -> Device_Parts {
	switch kind {
	case .None, .Check_Sign_Ins:
		return {}
	case .Start, .Link:
		return {.Link, .Roster}
	case .Confirm, .Cancel, .Decline, .Dismiss_Sibling, .Reset:
		return {.Link}
	case .Rename, .Rename_Own, .Settings, .Remove_Sibling:
		return {.Roster}
	case .Answer_Sign_In:
		return {.Sign_Ins}
	case .Start_Fresh:
		return {.Roster, .Started_Fresh, .Sign_Ins}
	case .Dismiss_Warning:
		return {.Warning}
	}
	return {}
}

@(private = "file")
device_mutate :: proc(job: ^Device_Job, account: cstring) {
	client, command, out := job.client, job.command, &job.data.link
	prompt := strings.clone_to_cstring(command.prompt, context.temp_allocator)
	slot := strings.clone_to_cstring(command.slot, context.temp_allocator)
	changed: Device_Parts = {.Link}
	switch command.kind {
	case .None:
		return
	case .Start:
		job.status = marmot.start_device_link(client, account, out)
		if job.status != .OK {
			job.detail = marmot.last_error()
			if device_refusal(job.status, job.detail) != "key_package_not_published" {break}
			delete(job.detail); job.detail = ""
			if out^ != nil {marmot.device_link_snapshot_free(out^); out^ = nil}
			relays: u64
			job.status = marmot.rotate_key_package(client, account, &relays)
			if job.status == .OK {job.status = marmot.start_device_link(client, account, out)}
		}
	case .Confirm:
		job.status = marmot.confirm_device_link_match(client, account, out)
	case .Cancel:
		job.status = marmot.cancel_device_link(client, account, out)
	case .Link:
		name := strings.clone_to_cstring(command.name, context.temp_allocator)
		job.status = marmot.link_device(
			client,
			account,
			prompt,
			name,
			u8(command.add_to_all),
			u8(command.bring_history),
			out,
		)
	case .Decline:
		job.status = marmot.decline_device_link(client, account, prompt, out)
	case .Rename, .Rename_Own:
		changed = {}
		job.status = marmot.rename_linked_device(
			client,
			account,
			slot,
			strings.clone_to_cstring(command.name, context.temp_allocator),
		)
		if job.status == .OK {job.follow_up = {.Roster}}
	case .Settings:
		changed = {}
		value := u8(command.setting_value)
		job.status = marmot.update_linked_device_settings(
			client,
			account,
			slot,
			u8(command.setting == .Add_To_Chats),
			value,
			u8(command.setting == .History),
			value,
			u8(command.setting == .Keep),
			value,
		)
		if job.status == .OK {job.follow_up = {.Roster}}
	case .Dismiss_Sibling:
		move := strings.clone_to_cstring(command.move_id, context.temp_allocator)
		job.status = marmot.dismiss_device_group_move_sibling(client, account, move, slot, out)
	case .Remove_Sibling:
		changed = {}
		job.status = marmot.remove_linked_device(client, account, slot)
		if job.status == .OK {job.follow_up = {.Roster, .Leftover_Chats}}
	case .Reset:
		job.status = marmot.reset_device_group_for_repair(client, account, out)
		if job.status == .OK {
			job.reads = {.Link}
			job.follow_up = {.Roster, .Started_Fresh, .Sign_Ins, .Overdue, .History}
			relays: u64
			job.status = marmot.rotate_key_package(client, account, &relays)
			if job.status != .OK {job.detail = marmot.last_error()}
			return
		}
	case .Check_Sign_Ins:
		changed = {.Sign_Ins}
		job.status = marmot.check_sign_ins(client, account, &job.data.sign_ins)
	case .Answer_Sign_In:
		changed = {}
		job.status = marmot.answer_sign_in(client, account, slot, command.response)
		job.follow_up = {.Sign_Ins}
		if job.status == .OK && command.response == .REJECT {job.follow_up += {.Warning}}
	case .Start_Fresh:
		changed = {}
		job.status = marmot.start_fresh(client, account)
		job.follow_up = {.Started_Fresh, .Roster, .Sign_Ins}
	case .Dismiss_Warning:
		changed = {}
		job.status = marmot.dismiss_compromise_warning(client, account)
		if job.status == .OK {job.follow_up = {.Warning}}
	}
	if job.status == .OK {
		job.reads = changed
		return
	}
	if job.detail == "" {job.detail = marmot.last_error()}
	reason := device_refusal(job.status, job.detail)
	job.unavailable = reason == "pairing_unsupported" || reason == "roster_unsupported"
	switch reason {
	case "unknown_prompt",
	     "link_expired",
	     "link_in_progress",
	     "no_link_in_progress",
	     "link_unavailable",
	     "pairing_in_progress",
	     "too_many_devices",
	     "device_already_linked":
		job.follow_up = {.Link}
	case "unknown_device", "no_device_group", "roster_unavailable":
		job.follow_up = {.Roster}
	}
}

@(private = "file")
device_action_error :: proc(command: Device_Action, reason: string) -> string {
	switch reason {
	case "unknown_prompt", "link_expired":
		return tr("This request is no longer active.")
	case "device_group_busy":
		return tr("Another device change is still in progress. Wait a moment and try again.")
	case "too_many_devices":
		return tr("This profile has too many linked devices. Remove a device and try again.")
	case "sign_in_rejected":
		return tr("This sign-in was rejected on one of your devices.")
	}
	switch command {
	case .None:
		return ""
	case .Start:
		return tr("Couldn't start linking. Please try again.")
	case .Confirm:
		return tr("Couldn't confirm the emoji code. Please try again.")
	case .Cancel:
		return tr("Couldn't cancel linking. Please try again.")
	case .Link:
		return tr("Couldn't link the device. Please try again.")
	case .Decline:
		return tr("Couldn't decline the request. Please try again.")
	case .Rename, .Rename_Own:
		return tr("Couldn't rename the device. Please try again.")
	case .Settings:
		return tr("Couldn't save the device setting. Please try again.")
	case .Remove_Sibling:
		return tr("Couldn't remove the device. Please try again.")
	case .Dismiss_Sibling:
		return tr("Couldn't dismiss the device hint. Please try again.")
	case .Reset:
		return tr("Couldn't reset the device list. Please try again.")
	case .Check_Sign_Ins:
		return tr("Couldn't check for sign-ins. Check your relay settings and try again.")
	case .Answer_Sign_In:
		return tr("Couldn't update that sign-in. Please try again.")
	case .Start_Fresh:
		return tr("Couldn't start fresh. Check for sign-ins and try again.")
	case .Dismiss_Warning:
		return tr("Couldn't dismiss the warning. Please try again.")
	}
	return ""
}

@(private)
device_apply :: proc(devices: ^Devices_State, profile: ^Device_Profile, job: ^Device_Job) {
	if profile.revoked || !profile.signed_in || job.incarnation != profile.incarnation {return}
	if job.active &&
	   (job.generation != devices.generation || job.account != devices.active) {return}
	if !job.active && job.account == devices.active {return}
	if job.unavailable {devices.unavailable = true; return}
	if sync.atomic_load(&job.chat_review_cancel) {
		job.reads -= {.Chat_Review}
		job.failed -= {.Chat_Review}
	}
	ready := job.reads - job.failed
	profile.known += ready
	profile.stale = (profile.stale - ready) + job.failed
	view, data := &profile.view, &job.data
	if .Link in ready {
		if data.link != nil &&
		   data.link.new_device != nil &&
		   data.link.new_device.tag == .LINKED &&
		   (view.link == nil ||
				   view.link.new_device == nil ||
				   view.link.new_device.tag != .LINKED) {
			profile.dirty += {.History}
		}
		if device_move_pending(view.link) &&
		   !device_move_pending(data.link) {profile.dirty += {.Roster}}
		view.link, data.link = data.link, view.link
	}
	if .Roster in ready && (view.roster == nil || !device_move_pending(view.link)) {
		view.roster, data.roster = data.roster, view.roster
		view.roster_labels, data.roster_labels = data.roster_labels, view.roster_labels
		profile.roster_seen = job.roster_event
	}
	if .Sign_Ins in ready {view.sign_ins, data.sign_ins = data.sign_ins, view.sign_ins}
	if .Warning in ready {view.warning, data.warning = data.warning, view.warning}
	if .History in ready {
		view.history, data.history = data.history, view.history
		view.history_by_group, data.history_by_group = data.history_by_group, view.history_by_group
		view.history_receiving = data.history_receiving
	}
	if .Started_Fresh in ready {view.started_fresh = data.started_fresh}
	if .Overdue in ready {view.overdue = data.overdue}
	if .Closed_Chats in ready {view.closed_chats = data.closed_chats}
	if .Leftover_Chats in ready {view.leftover_chats = data.leftover_chats}
	if .Chat_Review in
	   ready {view.chat_review, data.chat_review = data.chat_review, view.chat_review}
}

@(private = "file")
device_job_free :: proc(job: ^Device_Job) {
	thread.join(job.worker)
	thread.destroy(job.worker)
	device_view_free(&job.data)
	device_command_free(&job.command)
	delete(job.detail, reload_allocator())
	free(job, reload_allocator())
}

@(private = "file")
device_inventory_worker :: proc(t: ^thread.Thread) {
	defer frame_wake()
	job := (^Device_Inventory)(t.data)
	job.status = marmot.list_accounts(job.client, &job.accounts)
}

@(private = "file")
device_inventory_free :: proc(job: ^Device_Inventory) {
	thread.join(job.worker)
	thread.destroy(job.worker)
	if job.accounts != nil {marmot.account_summary_list_free(job.accounts)}
	free(job, reload_allocator())
}

@(private)
devices_drain :: proc(ui: ^Ui_State, client: ^marmot.Client, live: ^Live) {
	if !MULTI_DEVICE || client == nil {return}
	devices := &ui.devices
	sync.lock(&live.mutex)
	changes := live.dirty_devices
	live.dirty_devices = {}
	sync.unlock(&live.mutex)
	for account, change in changes {
		if .Unlinked in change.parts {
			devices_mark_unlinked(ui, account, change.unlink_label)
		} else if profile := devices.profiles[account]; profile != nil && profile.signed_in {
			if .Roster in change.parts {profile.roster_event += 1}
			profile.dirty += account == devices.active ? change.parts : change.parts & {.Link}
			if account == devices.active &&
			   .Roster in change.parts &&
			   devices_open_now(ui) {profile.dirty += DEVICE_COUNTS}
		}
		delete(account, reload_allocator())
		delete(change.unlink_label, reload_allocator())
	}
	delete(changes)

	if job := devices.inventory; job != nil && thread.is_done(job.worker) {
		if job.revision == ui.accounts_revision {
			devices.inventory_stale = job.status != .OK
			if job.status == .OK {accounts_adopt(ui, client, job.accounts)}
		} else {
			devices.inventory_dirty = true
		}
		device_inventory_free(job)
		devices.inventory = nil
	}
	if devices.inventory_dirty && devices.inventory == nil {
		job := new(Device_Inventory, reload_allocator())
		job.client, job.revision = client, ui.accounts_revision
		job.worker = thread.create(device_inventory_worker)
		job.worker.data = job
		devices.inventory = job
		devices.inventory_dirty = false
		thread.start(job.worker)
	}

	for _, profile in devices.profiles {
		if job := profile.job; job != nil && thread.is_done(job.worker) {
			device_apply(devices, profile, job)
			device_finish(ui, profile, job)
			device_job_free(job)
			profile.job = nil
		}
	}
	if devices.unavailable {return}
	device_try_own_name(ui)
	for _, profile in devices.profiles {
		if profile.job != nil ||
		   !profile.signed_in ||
		   (profile.queued.kind == .None && profile.dirty == {}) {continue}
		parts := device_requirements(profile.queued.kind)
		if profile.queued.kind != .None &&
		   profile.dirty & parts == {} &&
		   !device_command_current(profile, profile.queued) {
			profile.action_error = strings.clone(
				device_action_error(profile.queued.kind, ""),
				reload_allocator(),
			)
			profile.dirty += parts
			device_command_free(&profile.queued)
		}
		job := new(Device_Job, reload_allocator())
		job.client, job.account = client, profile.account
		job.active, job.generation, job.incarnation =
			profile.account == devices.active, devices.generation, profile.incarnation
		job.roster_event = profile.roster_event
		if profile.queued.kind != .None && profile.dirty & parts == {} {
			job.command, profile.queued = profile.queued, {}
		} else {
			job.reads, profile.dirty = profile.dirty, {}
		}
		job.worker = thread.create(device_worker)
		job.worker.data = job
		profile.job = job
		thread.start(job.worker)
	}
}

@(private)
device_finish :: proc(ui: ^Ui_State, profile: ^Device_Profile, job: ^Device_Job) {
	d := &ui.devices
	if !job.active ||
	   job.generation != d.generation ||
	   job.account != d.active ||
	   job.incarnation != profile.incarnation ||
	   profile.revoked ||
	   !profile.signed_in {return}
	context.allocator = reload_allocator()
	if job.command.kind != .None {
		profile.dirty += job.follow_up
		delete(profile.action_error); profile.action_error = ""
		reason := device_refusal(job.status, job.detail)
		if job.command.kind == .Rename_Own {
			if reason == "device_group_busy" {
				profile.rename_after = job.roster_event + 1
				return
			}
			delete(profile.deferred_name); profile.deferred_name = ""
		}
		if job.command.kind == .Reset && .Link in job.reads {
			profile.known -= {.Roster, .Started_Fresh} + DEVICE_COUNTS
			profile.dirty += DEVICE_COUNTS
			delete(profile.deferred_name); profile.deferred_name = ""
			devices_show(ui, .New)
			if job.status != .OK {
				profile.action_error = strings.clone(
					tr(
						"The device list was reset, but the key package couldn't be published. Start linking to try again.",
					),
				)
			}
			return
		}
		if job.status != .OK {
			if job.command.kind == .Check_Sign_Ins {profile.first_import = false}
			profile.action_error = strings.clone(device_action_error(job.command.kind, reason))
			return
		}
		if job.command.kind == .Link && job.command.own_name != "" {
			delete(profile.deferred_name)
			profile.deferred_name = strings.clone(job.command.own_name)
			profile.rename_after = 0
			profile.dirty += {.Roster}
		}
		if d.panel_account == job.account {
			if job.command.kind == .Start && d.panel == .New {
				d.show_attempt = true
				d.mismatch = false
			}
			if job.command.mismatch {d.mismatch = true}
			if job.command.kind == .Decline && !job.command.mismatch {devices_put_away(ui)}
		}
	}

	if d.panel == .Detail &&
	   d.panel_account == job.account &&
	   .Roster in job.reads &&
	   .Roster not_in job.failed &&
	   device_find_slot(profile, d.panel_slot) == nil {
		devices_close(ui)
		set_status(ui, tr("This device is no longer in your device list."), .Info)
	}
	if d.review_account == job.account && .Link in job.reads {
		if .Link not_in job.failed &&
		   device_prompt_attention(device_find_prompt(profile, d.panel_prompt)) {
			devices_show(ui, .Approve, job.account, d.panel_prompt)
		} else {
			delete(d.review_account); d.review_account = ""
			delete(d.error)
			d.error = strings.clone(
				.Link in job.failed ? tr("Couldn't refresh the link request. Please try again.") : tr("This request is no longer active."),
			)
		}
	}
}

@(private = "file")
device_try_own_name :: proc(ui: ^Ui_State) {
	profile := device_current(ui)
	if profile == nil ||
	   profile.deferred_name == "" ||
	   profile.roster_seen < profile.rename_after ||
	   device_busy(profile) != .None ||
	   .Roster not_in profile.known ||
	   .Roster in profile.stale {return}
	row := device_own_slot(profile)
	if row == nil || row.status == .LEAVING || row.removal_pending {return}
	if string(row.label) != "" {
		delete(profile.deferred_name, reload_allocator()); profile.deferred_name = ""
		return
	}
	device_queue(
		ui,
		{kind = .Rename_Own, slot = string(row.slot_id_hex), name = profile.deferred_name},
	)
}

@(private)
devices_stop :: proc(ui: ^Ui_State) {
	context.allocator = reload_allocator()
	devices := &ui.devices
	devices_close(ui)
	if devices.inventory != nil {device_inventory_free(devices.inventory)}
	for _, profile in devices.profiles {
		if profile.job != nil {device_job_free(profile.job)}
		device_command_free(&profile.queued)
		for id in profile.dismissed {delete(id)}
		delete(profile.dismissed)
		delete(profile.action_error)
		delete(profile.deferred_name)
		device_view_free(&profile.view)
		delete(profile.account, reload_allocator())
		delete(profile.unlink_label, reload_allocator())
		free(profile, reload_allocator())
	}
	delete(devices.wipe_report)
	delete(devices.name); delete(devices.own_name)
	delete(devices.profiles)
	devices^ = {}
}
