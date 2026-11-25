package main

import "core:fmt"
import "core:strings"
import "core:thread"
import rl "sdlrl"

import marmot "../marmot"
import "nendo"

@(private)
Account_Operation :: enum {
	Switch,
	Sign_In, // a signed-out account back on; its key is still in the vault
	Sign_Out,
	Remove,
	Wipe,
	Wipe_Unlinked,
	Profile,
	Outbox,
	Inbox,
	Relays,
	Key_Package,
	Read_Key_Packages,
	Follow,
	Unfollow,
	Read_Contacts,
	Read_Archived,
	Create_Chat,
	Open_DM,
	Accept,
	Decline,
	Leave,
	Delete_Conversation,
	Description,
	Avatar,
}
@(private)
Sign_Out_Intent :: enum {
	User,
	Back,
}

@(private)
Account_Job :: struct {
	client:                                       ^marmot.Client,
	account, group, target, title, result, error: string,
	fields:                                       [4]string,
	pic_data:                                     []u8,
	pic_media:                                    string,
	relays:                                       []cstring,
	kind:                                         Account_Operation,
	sign_out_intent:                              Sign_Out_Intent,
	accounts:                                     ^marmot.Account_Summary_List,
	accounts_revision:                            u64,
	accounts_read:                                bool,
	wipe_report:                                  string,
	wipe_report_error:                            bool,
	fresh, notes, open_chat, departed:            bool,
	form:                                         Maybe(Nc_Page),
	accepted:                                     u64,
	skipped:                                      int, // requested members the create left out
	key_rows:                                     [dynamic]Kp_Row,
	contacts:                                     [dynamic]Contact_Ui,
	chat_list:                                    Chat_List_Work,
	worker:                                       ^thread.Thread,
	signer:                                       ^Nip46_Account,
}
@(private)
account_jobs: [dynamic]^Account_Job

// Requested accounts a create or invite left out: no usable KeyPackage,
// no inbox relay, or a lookup that didn't finish.
@(private)
members_skipped :: proc(outcomes: []marmot.Member_Resolution_Outcome) -> int {
	skipped := 0
	for outcome in outcomes {if outcome.status != .SELECTED {skipped += 1}}
	return skipped
}

@(private)
account_job_new :: proc(
	ui: ^Ui_State,
	client: ^marmot.Client,
	kind: Account_Operation,
	account := "",
	sign_out_intent: Sign_Out_Intent = .User,
) -> ^Account_Job {
	owner := account == "" ? ui.account_ref : account
	if client == nil || owner == "" {return nil}
	revoked := account_revoked(ui, owner)
	if kind == .Wipe_Unlinked {
		if !revoked {return nil}
	} else if revoked ||
	   ((kind == .Switch || kind == .Wipe) && !account_signed_in(ui, owner)) ||
	   (kind == .Sign_In && !account_signed_out(ui, owner)) {
		if kind == .Switch {devices_switch_failed(ui, owner)}
		return nil
	}
	if kind == .Switch {for item in nip46_accounts {item.switch_requested = false}}
	for job in account_jobs {
		if job.account == owner ||
		   (kind == .Switch && job.kind == .Switch) ||
		   (account_wiping(kind) && account_wiping(job.kind)) {
			waiting_for_signer := job.signer != nil && !account_exit(job.kind)
			set_status(
				ui,
				waiting_for_signer ? tr("Your previous account action is still waiting. Check your signer for approval.") : tr("Your previous account action is still running."),
				.Info,
			)
			return nil
		}
	}
	signer := nip46_find(owner)
	if !account_exit(kind) &&
	   kind != .Read_Archived &&
	   signer != nil &&
	   (signer.attach != nil || !signer.registered) {
		if kind == .Switch {signer.switch_requested = true}
		if signer.attach == nil {
			set_status(ui, tr("Allow your signer's permissions to use this account."), .Info)
			return nil
		}
		set_status(
			ui,
			tr(
				"Connecting your remote signer. Approve the connection there before using this account.",
			),
			.Info,
		)
		return nil
	}
	job := new(Account_Job)
	job.client, job.account, job.kind = client, strings.clone(owner), kind
	job.signer, job.sign_out_intent = signer, sign_out_intent
	job.accounts_revision = ui.accounts_revision
	if account_wiping(kind) {
		label: string
		if profile := ui.devices.profiles[owner]; profile != nil {label = profile.unlink_label}
		job.title = strings.clone(label != "" ? label : account_label(ui, owner))
	}
	if ui.selected >= 0 &&
	   ui.selected < len(ui.chats) {job.group = strings.clone(ui.chats[ui.selected].group_id)}
	return job
}
@(private)
account_job_start :: proc(job: ^Account_Job) {
	if job == nil {return}
	append(&account_jobs, job)
	if job.kind == .Delete_Conversation {
		if timeline_job != nil &&
		   string(timeline_job.account) == job.account &&
		   string(timeline_job.group) == job.group {
			timeline_retire()
		}
		return
	}
	account_worker_start(job)
}

@(private = "file")
account_worker_start :: proc(job: ^Account_Job) {
	job.worker = thread.create(account_worker); job.worker.data = job; thread.start(job.worker)
}

@(private)
conversation_deleting :: proc(account, group: string) -> bool {
	for job in account_jobs {
		if job.kind == .Delete_Conversation &&
		   job.account == account &&
		   job.group == group {return true}
	}
	return false
}
@(private = "file")
account_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	job := (^Account_Job)(t.data)
	account := strings.clone_to_cstring(job.account, context.temp_allocator)
	group := strings.clone_to_cstring(job.group, context.temp_allocator)
	target := strings.clone_to_cstring(job.target, context.temp_allocator)
	status: marmot.Status
	summary: ^marmot.Send_Summary
	switch job.kind {
	case .Read_Archived:
		chat_list_read(&job.chat_list)
		if job.chat_list.err != "" {job.error = strings.clone(job.chat_list.err)}
	case .Switch, .Sign_In:
		out: ^marmot.Account_Summary
		status = marmot.sign_in_account(job.client, account, &out)
		if out != nil {marmot.account_summary_free(out)}
	case .Sign_Out, .Remove, .Wipe, .Wipe_Unlinked:
		account_exit_worker(job, account)
	case .Profile:
		optional :: proc(value: string) -> cstring {return(
				value == "" ? nil : strings.clone_to_cstring(value, context.temp_allocator) \
			)}
		name := strings.clone_to_cstring(job.fields[0], context.temp_allocator)
		metadata := marmot.User_Profile_Metadata {
			name         = name,
			display_name = name,
			about        = optional(job.fields[1]),
			nip05        = optional(job.fields[2]),
			lud16        = optional(job.fields[3]),
		}
		cur: ^marmot.User_Profile_Metadata
		if marmot.user_profile(job.client, account, &cur) == .OK && cur != nil {
			if cur.picture !=
			   nil {metadata.picture = strings.clone_to_cstring(string(cur.picture), context.temp_allocator)}
			if cur.banner !=
			   nil {metadata.banner = strings.clone_to_cstring(string(cur.banner), context.temp_allocator)}
			marmot.user_profile_metadata_free(cur)
		}
		out: ^marmot.User_Profile_Metadata
		status = marmot.publish_user_profile(
			job.client,
			account,
			&metadata,
			raw_data(DEFAULT_RELAYS),
			len(DEFAULT_RELAYS),
			raw_data(DEFAULT_RELAYS),
			len(DEFAULT_RELAYS),
			&out,
		)
		if out != nil {marmot.user_profile_metadata_free(out)}
	case .Outbox, .Inbox:
		out: ^marmot.Account_Relay_Lists
		if job.kind ==
		   .Outbox {status = marmot.set_account_nip65_relays(job.client, account, raw_data(job.relays), uint(len(job.relays)), raw_data(DEFAULT_RELAYS), len(DEFAULT_RELAYS), &out)} else {status = marmot.set_account_inbox_relays(job.client, account, raw_data(job.relays), uint(len(job.relays)), raw_data(DEFAULT_RELAYS), len(DEFAULT_RELAYS), &out)}
		if out != nil {marmot.account_relay_lists_free(out)}
	case .Relays:
		status = marmot.publish_relay_lists(
			job.client,
			account,
			raw_data(DEFAULT_RELAYS),
			len(DEFAULT_RELAYS),
			raw_data(DEFAULT_RELAYS),
			len(DEFAULT_RELAYS),
			nil,
			0,
		)
	case .Key_Package:
		// The ABI scalar is the package's byte size, despite its relay-count docs.
		status =
			job.fresh ? marmot.publish_new_key_package(job.client, account, &job.accepted) : marmot.republish_key_package(job.client, account, &job.accepted)
		if status == .OK &&
		   !kp_rows(job.client, job.account, &job.key_rows) {job.error = marmot.last_error()}
		job.accepted = 0
		for row in job.key_rows {
			if row.relay {job.accepted = max(job.accepted, u64(len(row.relay_urls)))}
		}
	case .Read_Key_Packages:
		status = .OK
		if !kp_rows(job.client, job.account, &job.key_rows) {job.error = marmot.last_error()}
	case .Follow:
		out: ^marmot.String_List
		status = marmot.follow_user(job.client, account, target, &out)
		if out != nil {marmot.string_list_free(out)}
	case .Unfollow:
		out: ^marmot.String_List
		status = marmot.unfollow_user(job.client, account, target, &out)
		if out != nil {marmot.string_list_free(out)}
	case .Read_Contacts:
		// The chat picker includes both followed people and conversation peers.
		snapshot := Ui_State {
			account_ref = job.account,
		}
		if !load_contacts(job.client, &snapshot, .Picker) {
			job.error = strings.clone(tr("Couldn't load your contacts. Please try again."))
		}
		job.contacts = snapshot.contacts
		if marmot.presented_chat_list(job.client, account, true, &job.chat_list.rows) == .OK {
			chat_members_fetch(job.client, account, job.chat_list.rows, &job.chat_list.members)
		}
		status = .OK
	case .Open_DM:
		out: cstring
		status = marmot.start_direct_chat(job.client, account, target, &out)
		if out != nil {job.result = strings.clone(string(out)); marmot.string_free(out)}
		if status == .OK {
			chat_list_read(&job.chat_list)
			if job.chat_list.err != "" {job.error = strings.clone(job.chat_list.err)}
		}
	case .Create_Chat:
		members := make([dynamic]cstring, context.temp_allocator)
		seen := make(map[string]bool, context.temp_allocator)
		for peer in strings.split(job.target, "\n", context.temp_allocator) {
			if peer == "" || seen[peer] {continue}
			seen[peer] = true
			append(&members, strings.clone_to_cstring(peer, context.temp_allocator))
		}
		out: ^marmot.Group_Creation_Result
		status = marmot.create_group(
			job.client,
			account,
			strings.clone_to_cstring(job.title, context.temp_allocator),
			raw_data(members),
			uint(len(members)),
			nil,
			&out,
		)
		if out != nil {
			if out.group_id_hex != nil {job.result = strings.clone(string(out.group_id_hex))}
			job.skipped = members_skipped(out.member_outcomes[:out.member_outcomes_len])
			marmot.group_creation_free(out)
		}
		// With no invitable member the runtime creates nothing.
		if status == .OK && job.result == "" {
			job.error = strings.clone(
				tr(
					"Couldn't create the chat. No one you picked has a key package White Noise can use. Ask them to open White Noise, then try again.",
				),
			)
		} else if status == .OK && len(job.pic_data) > 0 {
			group_pic_queue(job.client, job.account, job.result, job.pic_data, job.pic_media)
			job.pic_data = nil
		}
	case .Accept:
		out: ^marmot.App_Group_Record
		status = marmot.accept_group_invite(job.client, account, group, &out)
		if out != nil {marmot.app_group_record_free(out)}
	case .Decline:
		out: ^marmot.Group_Invite_Decline_Result
		status = marmot.decline_group_invite(job.client, account, group, &out)
		if out != nil {marmot.group_invite_decline_result_free(out)}
	case .Leave:
		status = marmot.leave_group(job.client, account, group, &summary)
	case .Delete_Conversation:
		forgotten: bool
		status = marmot.forget_solo_group_local(job.client, account, group, &forgotten)
		if status == .OK && !forgotten {
			job.error = strings.clone(
				tr("Couldn't delete the conversation. Review its members and try again."),
			)
		}
	case .Description:
		status = marmot.update_group_profile(job.client, account, group, nil, target, &summary)
	case .Avatar:
		status = marmot.update_group_avatar_url(
			job.client,
			account,
			group,
			target,
			nil,
			nil,
			&summary,
		)
	}
	if summary != nil {marmot.send_summary_free(summary)}
	if status != .OK {
		reason := marmot.last_error()
		defer delete(reason)
		job.error =
			reason == "" ? strings.clone(tr("Couldn't complete your account action. Please try again.")) : fmt.aprintf(tr("Couldn't complete your account action. Please try again. (%s)"), reason)
	}
}
@(private)
account_exit :: proc(kind: Account_Operation) -> bool {
	return kind == .Sign_Out || kind == .Remove || account_wiping(kind)
}

@(private = "file")
account_wiping :: proc(kind: Account_Operation) -> bool {
	return kind == .Wipe || kind == .Wipe_Unlinked
}

@(private)
account_exit_confirmed :: proc(
	job: ^Account_Job,
	status: marmot.Status,
	local_completed: bool,
) -> bool {
	if local_completed || (job.kind == .Remove && status == .OK) {return true}
	if !job.accounts_read {return false}
	if job.accounts != nil {
		for row in job.accounts.items[:job.accounts.len] {
			if string(row.account_id_hex) ==
			   job.account {return job.kind == .Sign_Out && row.signed_out}
		}
	}
	return true
}

@(private = "file")
account_exit_worker :: proc(job: ^Account_Job, account: cstring) {
	if signer := job.signer; signer != nil && signer.attach != nil {
		if !signer.attach_joined {thread.join(signer.attach)}
		signer.attach_joined = true
	}

	status: marmot.Status
	local: marmot.Local_Cleanup_Report
	issues := strings.builder_make(context.temp_allocator)
	append_issue :: proc(out: ^strings.Builder, text: string) {
		if text != "" {fmt.sbprintfln(out, "%s", text)}
	}
	wipe: ^marmot.Wipe_Outcome
	signed_out: ^marmot.Sign_Out_Outcome
	attempted := true
	#partial switch job.kind {
	case .Wipe:
		status = marmot.sign_out_and_wipe(job.client, account, &wipe)
	case .Wipe_Unlinked:
		attempted = false
		status = marmot.list_accounts(job.client, &job.accounts)
		job.accounts_read = status == .OK
		if job.accounts_read && job.accounts != nil {
			for row in job.accounts.items[:job.accounts.len] {
				if string(row.account_id_hex) != job.account {continue}
				attempted = row.signed_out && row.unlinked
				break
			}
		}
		if attempted {
			marmot.account_summary_list_free(job.accounts); job.accounts = nil
			status = marmot.remove_account(job.client, account)
			local.completed = status == .OK
		} else if status == .OK {
			append_issue(&issues, tr("This profile is no longer unlinked."))
		}
	case .Sign_Out:
		delete_packages := u8(job.sign_out_intent == .User)
		status = marmot.sign_out(job.client, account, delete_packages, &signed_out)
	case .Remove:
		status = marmot.remove_account(job.client, account)
	case:
		return
	}
	if status != .OK {
		detail := marmot.last_error()
		append_issue(&issues, detail != "" ? detail : tr("Couldn't complete the account action."))
		delete(detail)
	}
	defer if wipe != nil {marmot.wipe_outcome_free(wipe)}
	defer if signed_out != nil {marmot.sign_out_outcome_free(signed_out)}

	if wipe != nil {
		local = wipe.local_cleanup
		for failure in wipe.group_leave_failures[:wipe.group_leave_failures_len] {
			fmt.sbprintfln(
				&issues,
				tr("Couldn't leave chat %s: %s"),
				string(failure.group_id_hex),
				string(failure.reason),
			)
		}
		for failure in wipe.key_package_failures[:wipe.key_package_failures_len] {
			fmt.sbprintfln(
				&issues,
				tr("Couldn't delete key package %s from relays: %s"),
				string(failure.event_id_hex),
				string(failure.reason),
			)
		}
		if wipe.siblings_not_reached {
			append_issue(&issues, tr("Other linked devices could not be reached for cleanup."))
		}
	} else if signed_out != nil {
		local = signed_out.local_cleanup
		for failure in signed_out.key_package_failures[:signed_out.key_package_failures_len] {
			fmt.sbprintfln(
				&issues,
				tr("Couldn't delete this device's key package from relays: %s"),
				string(failure.reason),
			)
		}
	}

	if attempted {job.accounts_read = marmot.list_accounts(job.client, &job.accounts) == .OK}
	job.departed = attempted && account_exit_confirmed(job, status, local.completed)
	if local.reason != nil && string(local.reason) != "" {
		fmt.sbprintfln(&issues, tr("Local cleanup reported a problem: %s"), string(local.reason))
	} else if (wipe != nil || signed_out != nil) && !local.completed {
		append_issue(&issues, tr("Local cleanup did not report completion."))
	}
	if !job.departed {
		append_issue(
			&issues,
			job.kind == .Sign_Out ? tr("Sign-out on this device could not be confirmed.") : tr("Removal from this device could not be confirmed."),
		)
	} else {
		if vault_remove(fmt.tprintf("nip46:%s", job.account)) != .None {
			append_issue(
				&issues,
				tr("The signer record could not be removed from the encrypted vault."),
			)
		}
		if job.signer != nil {
			job.signer.registered = false
			marmot.nip46_logout(job.signer.handle)
		}
	}

	problems := strings.trim_space(strings.to_string(issues))
	if account_wiping(job.kind) {
		report := strings.builder_make(context.temp_allocator)
		if job.departed {
			fmt.sbprintfln(&report, tr("%s was removed from this device."), job.title)
		} else {
			fmt.sbprintfln(&report, tr("Profile: %s"), job.title)
		}
		if wipe != nil {
			fmt.sbprintfln(
				&report,
				tr(
					"Chats left or asked to leave: %d. Chats handed off to other linked devices: %d.",
				),
				wipe.groups_left,
				wipe.groups_left_to_siblings,
			)
			fmt.sbprintfln(&report, tr("Key packages deleted: %d."), wipe.key_packages_deleted)
		}
		append_issue(&report, problems)
		job.wipe_report = strings.clone(strings.trim_space(strings.to_string(report)))
		job.wipe_report_error = problems != ""
	} else if problems != "" {
		job.error = strings.clone(problems)
	}
}

@(private)
Account_Join :: enum {
	Pending,
	Joined,
}

@(private)
account_job_free :: proc(job: ^Account_Job, join: Account_Join = .Pending) {
	if job.worker != nil {
		if join == .Pending {thread.join(job.worker)}
		thread.destroy(job.worker)
	}
	for text in ([]string{job.account, job.group, job.target, job.title, job.result, job.error}) {delete(text)}
	delete(job.wipe_report)
	if job.accounts != nil {marmot.account_summary_list_free(job.accounts)}
	for text in job.fields {delete(text)}
	for relay in job.relays {delete(relay)}
	kp_rows_free(&job.key_rows); delete(job.key_rows)
	nc_contacts_free(&job.contacts)
	chat_list_free(&job.chat_list)
	delete(job.relays); delete(job.pic_data); free(job)
}
@(private)
account_jobs_stop :: proc() {
	for job in account_jobs {account_job_free(job)}
	delete(account_jobs); account_jobs = {}
}

@(private)
account_deletes_finish :: proc(ui: ^Ui_State) {
	#reverse for job, i in account_jobs {
		if job.kind != .Delete_Conversation {continue}
		if job.worker != nil {
			thread.join(job.worker)
			if job.error == "" {conversation_deleted_persist(ui, job)}
		}
		ordered_remove(&account_jobs, i)
		account_job_free(job, .Joined)
	}
}

@(private = "file")
account_wipe_prefs :: proc(ui: ^Ui_State, account, prefix: string) {
	if ui.prefs.last_account == account {
		delete(ui.prefs.last_account); ui.prefs.last_account = ""
		ui.settings_dirty = true
	}
	devices_wipe_prefs(ui, account)
	drafts_wipe(ui, prefix)
	keys := make([dynamic]string, context.temp_allocator)
	for key in ui.reading_places {
		if strings.has_prefix(key, prefix) {append(&keys, key)}
	}
	for key in keys {
		owned, place := delete_key(&ui.reading_places, key)
		delete(place.message); delete(owned)
	}
}

@(private)
account_wipes_finish :: proc(ui: ^Ui_State) {
	for i := len(account_jobs) - 1; i >= 0; i -= 1 {
		job := account_jobs[i]
		if !account_wiping(job.kind) {continue}
		thread.join(job.worker)
		if job.departed {
			account_wipe_prefs(ui, job.account, fmt.tprintf("%s:", job.account))
			offline_wipe_persist(ui, job.account)
		}
		ordered_remove(&account_jobs, i)
		account_job_free(job, .Joined)
	}
}

@(private = "file")
account_exit_apply :: proc(ui: ^Ui_State, job: ^Account_Job) {
	if job.accounts_read && job.accounts_revision == ui.accounts_revision {
		accounts_adopt(ui, job.client, job.accounts)
	} else {
		ui.devices.inventory_dirty = true
	}
	if job.departed {
		if ui.photo.account == job.account {photo_cancel(ui)}
		if item := job.signer; item != nil {
			for candidate, i in nip46_accounts {
				if candidate == item {ordered_remove(&nip46_accounts, i); break}
			}
			nip46_account_free(item)
		}
		account_departed(ui, job.client, job.account)
	}
	if !account_wiping(job.kind) {
		if job.error != "" {set_status(ui, strings.clone(job.error), .Error)}
		return
	}
	if job.departed {
		devices_wipe_applied(ui, job.account)
		prefix := fmt.tprintf("%s:", job.account)
		account_wipe_prefs(ui, job.account, prefix)
		staged_drafts_wipe(ui, prefix)
		offline_wipe(ui, job.account)
	}
	delete(ui.devices.wipe_report, reload_allocator())
	ui.devices.wipe_report, job.wipe_report = job.wipe_report, ""
	ui.devices.wipe_report_error = job.wipe_report_error
	auth_wipe_finished(ui, job.client, job.account, job.departed)
	if job.kind == .Wipe_Unlinked &&
	   !job.departed &&
	   ui.account_ref == "" &&
	   auth_job == nil &&
	   !accounts_have_tombstones(ui) {
		ui.accounts_open = len(ui.accounts) != 0
	}
}

@(private = "file")
conversation_deleted_persist :: proc(ui: ^Ui_State, job: ^Account_Job) {
	key := draft_key(job.account, job.group)
	ui.settings_dirty |= draft_delete(ui, key)
	queue_changed := false
	for &p in ui.pending {
		if p.account_ref != job.account || p.group_id != job.group {continue}
		p.purged = true
		queue_changed = true
	}
	if queue_changed {save_offline(ui)}
	if ui.account_ref != job.account {return}
	if ui.prefs.last_chat == job.group {delete(ui.prefs.last_chat); ui.prefs.last_chat = ""}
	if ui.prefs.notes_group == job.group {delete(ui.prefs.notes_group); ui.prefs.notes_group = ""}
	owned, _ := delete_key(&ui.prefs.pinned, job.group)
	delete(owned)
	ui.settings_dirty = true
}

@(private = "file")
conversation_deleted :: proc(ui: ^Ui_State, job: ^Account_Job) {
	current_account := ui.account_ref == job.account
	// live_apply can drop the row before the delete job returns, without clearing its composer.
	open :=
		current_account &&
		(ui.selected < 0 ? ui.prefs.last_chat == job.group : ui.chats[ui.selected].group_id == job.group)
	conversation_deleted_persist(ui, job)
	staged_files_free(staged_draft_take(ui, draft_key(job.account, job.group)))
	#reverse for p, i in ui.pending {
		if p.account_ref == job.account && p.group_id == job.group {discard_pending(ui, i)}
	}
	gs_forget_chat(ui, job.client, job.account, job.group)
	if ui.mi_account == job.account {
		#reverse for hit, i in ui.mi_hits {
			if hit.group != job.group {continue}
			mi_free_hit(hit)
			ordered_remove(&ui.mi_hits, i)
		}
	}
	if !current_account {return}
	if ui.messages_account == job.account && ui.messages_group == job.group {
		timeline_clear_content(ui)
		delete(ui.messages_group)
		ui.messages_group = ""
	}
	if ui.photo.account == job.account && ui.photo.group == job.group {photo_cancel(ui)}
	if open {
		voice_cancel()
		thread_clear(ui)
		staged_files_free(ui.staged)
		ui.staged = nil
		ed_set(ui, &ui.compose, "")
		ui.selected = -1
		close_group_info(ui)
	}
	for chat, i in ui.chats {
		if chat.group_id != job.group {continue}
		if ui.selected > i {ui.selected -= 1}
		append(&retired_chats, chat)
		ordered_remove(&ui.chats, i)
		refresh_filter_hits(job.client, ui)
		break
	}
	for chat, i in ui.archived {
		if chat.group_id != job.group {continue}
		append(&retired_chats, chat)
		ordered_remove(&ui.archived, i)
		break
	}
	clear(&ui.rail_rows)
}

@(private)
account_job_drain :: proc(ui: ^Ui_State, live: ^Live = nil) {
	jobs: for i := len(account_jobs) - 1; i >= 0; i -= 1 {
		job := account_jobs[i]
		if job.worker == nil {
			if account_revoked(ui, job.account) {
				ordered_remove(&account_jobs, i)
				account_job_free(job)
				continue
			}
			// The SDK forget operation must follow cancellation of this group's subscriptions.
			for timeline in timeline_retired {
				if string(timeline.account) == job.account &&
				   string(timeline.group) == job.group &&
				   !thread.is_done(timeline.worker) {
					continue jobs
				}
			}
			account_worker_start(job)
			continue
		}
		if !thread.is_done(job.worker) {continue}
		thread.join(job.worker)
		if account_exit(job.kind) {
			ordered_remove(&account_jobs, i)
			account_exit_apply(ui, job)
			account_job_free(job, .Joined)
			continue
		}
		if job.kind == .Delete_Conversation {
			ordered_remove(&account_jobs, i)
			if job.error == "" {
				if ui.account_ref == job.account {
					chat_list_revision += 1
					search_revision += 1
					if live != nil {live.refresh_dirty = true}
				}
				conversation_deleted(ui, job)
			} else if !account_revoked(ui, job.account) {
				set_status(ui, strings.clone(job.error), .Error)
				if ui.account_ref == job.account &&
				   ui.selected >= 0 &&
				   ui.chats[ui.selected].group_id == job.group {
					load_members(job.client, ui)
					load_timeline(job.client, ui, string(ui.search_input[:]))
				}
			}
			account_job_free(job, .Joined)
			continue
		}
		if account_revoked(ui, job.account) ||
		   (job.kind == .Switch && !account_signed_in(ui, job.account)) {
			if job.kind == .Switch {devices_switch_failed(ui, job.account)}
			ordered_remove(&account_jobs, i)
			account_job_free(job, .Joined)
			continue
		}
		if job.kind == .Switch && job.error != "" {devices_switch_failed(ui, job.account)}
		if job.error != "" {
			// The sign-in card shows its own failure; the banner sits behind it.
			if job.kind == .Sign_In && (ui.account_ref == "" || ui.add_account_open) {
				ui.login_error = strings.clone(job.error)
			} else if job.form == nil ||
			   (job.open_chat &&
					   ui.page == .Chats &&
					   !ui.add_account_open &&
					   ui.new_chat_open &&
					   ui.nc_page == job.form &&
					   ui.account_ref == job.account) {
				set_status(ui, strings.clone(job.error), .Error)
			}
		}
		if job.error != "" &&
		   job.kind == .Create_Chat &&
		   ui.account_ref == job.account &&
		   ui.new_chat_open &&
		   len(job.pic_data) > 0 &&
		   len(ui.nc_pic.data) == 0 {
			ext := strings.clone_to_cstring(
				fmt.tprintf(".%s", strings.trim_prefix(job.pic_media, "image/")),
				context.temp_allocator,
			)
			image := rl.LoadImageFromMemory(ext, raw_data(job.pic_data), i32(len(job.pic_data)))
			if image.data != nil {ui.nc_pic = Pic_Draft {
					data       = job.pic_data,
					media_type = job.pic_media,
					image      = image,
				}; job.pic_data = nil}
		}
		if job.error == "" {
			if job.kind == .Switch {
				finish_account_switch(ui, job.client, job.account)
				if ui.page == .Profile || ui.page == .Settings {load_profile(job.client, ui)}
			} else if job.kind == .Sign_In {
				finish_auth(ui, job.client, job.account)
			} else if ui.account_ref == job.account {
				switch job.kind {
				case .Profile:
					reload_profile(ui, job.client)
					profile_edit_finish(ui)
					set_status(ui, tr("Profile text changes published."), .Info)
				case .Outbox, .Inbox:
					reload_profile(ui, job.client)
				case .Key_Package, .Read_Key_Packages:
					kp_rows_free(&ui.kp_list); delete(ui.kp_list); ui.kp_list = job.key_rows
					job.key_rows = {}
					ui.kp_fetched = true
					delete(ui.kp_own_json)
					ui.kp_own_json = ""
					if job.kind ==
					   .Key_Package {set_status(ui, fmt.aprintf(tr("Key package published and found on %d relays."), job.accepted), .Info)}
				case .Relays:
					set_status(ui, tr("Relay lists republished."), .Info)
				case .Follow, .Unfollow:
					load_contacts(job.client, ui, .Details)
					if job.kind == .Unfollow {
						key, nick := delete_key(&ui.nicknames, job.target)
						delete(key); delete(nick)
						save_settings(ui)
						clear(&ui.sidebar_filter)
						reset_profile_view(ui)
						ui.selected_contact = -1
					} else {
						clear(&ui.sidebar_filter)
						set_status(ui, tr("Contact added."), .Info)
						if ui.profile_contact.id_hex == job.target {
							for contact, n in ui.contacts {if contact.id_hex == job.target {ui.selected_contact = n; break}}
							reset_profile_view(ui)
						}
					}
				case .Read_Contacts:
					nc_contacts_free(&ui.nc_contacts)
					ui.nc_contacts = job.contacts
					job.contacts = {}
					nc_add_chat_peers(ui, job.client, job.chat_list.members)
				case .Read_Archived:
					fresh := make([dynamic]Chat_Row_Ui)
					if rows := job.chat_list.rows; rows != nil {
						for i in 0 ..< rows.rows_len {
							row := &rows.rows[i]
							if !row.row.archived {continue}
							append(
								&fresh,
								row_to_ui(
									job.client,
									row,
									job.account,
									job.chat_list.previews,
									job.chat_list.reading_previews,
									job.chat_list.members,
								),
							)
						}
					}
					chats_replace(&ui.archived, fresh)
					clear(&ui.rail_rows)
				case .Open_DM:
					ui.page, ui.focus = .Chats, .Compose
					gs_keep_open_chat(ui, job.result)
					if !select_by_id(ui, job.client, job.result) && job.chat_list.rows != nil {
						rows := job.chat_list.rows
						for i in 0 ..< rows.rows_len {
							row := &rows.rows[i]
							if string(row.row.group_id_hex) != job.result {continue}
							chat := row_to_ui(
								job.client,
								row,
								job.account,
								job.chat_list.previews,
								job.chat_list.reading_previews,
								job.chat_list.members,
							)
							chat.search_only = row.row.archived
							if chat.search_only {append(&ui.archived, chat_clone(chat))}
							append(&ui.chats, chat)
							select_by_id(ui, job.client, job.result)
							break
						}
					}
				case .Create_Chat:
					if job.notes {delete(ui.prefs.notes_group); ui.prefs.notes_group = strings.clone(job.result); ui.prefs.pinned[strings.clone(job.result)] = true; save_settings(ui)}
					load_chat_list(job.client, job.account, ui)
					if job.open_chat {
						if job.form != nil {close_new_chat(ui)}
						ui.focus = .Compose
						ui.page = .Chats
						ui.new_chat_open = false
						select_by_id(ui, job.client, job.result)
					}
					if job.skipped > 0 {
						set_status(
							ui,
							fmt.aprintf(
								tr(
									job.skipped == 1 ? N_("%d person couldn't be added. Ask them to open White Noise, then invite them again.") : N_("%d people couldn't be added. Ask them to open White Noise, then invite them again."),
								),
								job.skipped,
							),
							.Info,
						)
					}
				case .Leave, .Decline:
					if ui.photo.account == job.account &&
					   ui.photo.group == job.group {photo_cancel(ui)}
					if ui.selected >= 0 &&
					   ui.chats[ui.selected].group_id ==
						   job.group {ui.selected = -1; ui.show_members = false}
					refresh_after_action(ui, job.client)
				case .Accept:
					refresh_after_action(ui, job.client)
				case .Description:
					if ui.selected >= 0 &&
					   ui.chats[ui.selected].group_id ==
						   job.group {ui.desc_editing = false; load_members(job.client, ui)}
				case .Avatar:
					if local, ok := gpic_local[job.group];
					   ok {delete(local); delete_key(&gpic_local, job.group)}
					ui.ov_open = false
					ui.focus = .Invite
					refresh_after_action(ui, job.client)
				case .Switch,
				     .Sign_In,
				     .Sign_Out,
				     .Remove,
				     .Wipe,
				     .Wipe_Unlinked,
				     .Delete_Conversation:
				}
			}
		}
		ordered_remove(&account_jobs, i); account_job_free(job, .Joined)
	}
}
// The signed-out account a running sign-in turns back on, or "".
@(private)
account_signing_in :: proc() -> string {
	for job in account_jobs {if job.kind == .Sign_In {return job.account}}
	return ""
}
@(private)
account_pending_label :: proc(kind: Account_Operation) -> string {
	switch kind {
	case .Switch:
		return tr("Switching your account")
	case .Sign_In:
		return tr("Signing you in")
	case .Sign_Out:
		return tr("Signing out and removing your signer session")
	case .Remove, .Wipe_Unlinked:
		return tr("Removing your account from this device")
	case .Wipe:
		return tr("Signing out and wiping this device's copy of the profile")
	case .Profile:
		return tr("Publishing your profile")
	case .Outbox, .Inbox, .Relays:
		return tr("Publishing your relay lists")
	case .Key_Package:
		return tr("Publishing your key package")
	case .Read_Key_Packages:
		return tr("Loading your key packages")
	case .Follow, .Unfollow:
		return tr("Updating your contacts")
	case .Read_Contacts:
		return tr("Loading your contacts")
	case .Read_Archived:
		return tr("Loading your archived chats")
	case .Create_Chat:
		return tr("Creating your chat")
	case .Open_DM:
		return tr("Opening your chat")
	case .Accept:
		return tr("Accepting your invitation")
	case .Decline:
		return tr("Declining your invitation")
	case .Leave:
		return tr("Leaving your group")
	case .Delete_Conversation:
		return tr("Deleting your conversation")
	case .Description, .Avatar:
		return tr("Publishing your group profile")
	}
	return ""
}
@(private)
account_pending_ui :: proc(ui: ^Ui_State) {
	if owner := profile_pic_owner(); owner != "" {
		account_pending_row(
			nendo.id("ProfilePicturePending"),
			"ProfilePictureBusy",
			account_label(ui, owner),
			tr("Uploading and publishing your picture…"),
		)
	} else if ui.profile_pic_notice != "" {
		if nendo.box(nendo.id("ProfilePictureNotice"))(
		{
			width = nendo.grow(),
			padding = nendo.pad(8),
			gap = 10,
			align = {y = .Center},
			color = STATUS_BAR,
		},
		) {
			nendo.text(
				ui.profile_pic_notice,
				{
					font = FONT_BODY,
					size = 12,
					color = ui.profile_pic_notice_kind == .Error ? DANGER : TEXT,
				},
			)
			micro_button("ProfilePicDismiss", tr("Dismiss"))
		}
	}
	for job, i in account_jobs {
		account_pending_row(
			nendo.id("AccountPending", u32(i)),
			fmt.tprintf("AccountPendingBusy%d", i),
			account_label(ui, job.account),
			account_pending_label(job.kind),
		)
	}
	for item, i in nip46_accounts {
		if account_departing(item.account) || account_revoked(ui, item.account) {continue}
		// A signer saved before MDK owned its credentials needs one approval.
		if item.attach == nil && len(item.grants.grants) > 0 {
			if nendo.box(nendo.id("SignerPending", u32(i)))(
			{
				width = nendo.grow(),
				padding = nendo.pad(8),
				gap = 6,
				direction = .Column,
				color = STATUS_BAR,
			},
			) {
				nendo.text(
					fmt.tprintf(
						"%s · %s",
						account_label(ui, item.account),
						tr("Allow your signer's permissions to keep using this account."),
					),
					{font = FONT_BODY, size = 12, color = TEXT_DIM},
				)
				nip46_grants_ui(item.grants)
				micro_button(fmt.tprintf("SignerAllow%d", i), tr("Allow and connect"))
			}
			continue
		}
		if item.state.state == "approval" ||
		   item.state.state == "connecting" ||
		   item.attach != nil {
			if nendo.box(nendo.id("SignerPending", u32(i)))(
			{
				width = nendo.grow(),
				padding = nendo.pad(8),
				gap = 10,
				align = {y = .Center},
				color = STATUS_BAR,
			},
			) {
				nendo.text(
					fmt.tprintf(
						"%s · %s",
						account_label(ui, item.account),
						nip46_label(item.state.state == "" ? "connecting" : item.state.state),
					),
					{font = FONT_BODY, size = 12, color = TEXT_DIM},
				)
				busy_bar(fmt.tprintf("SignerPendingBusy%d", i))
				if item.state.auth_url !=
				   "" {if nendo.box(nendo.id("SignerApproval", u32(i)))({padding = nendo.pad(5), color = ROW_BG}) {nendo.text(tr("Review signer approval link"), {font = FONT_BODY, size = 12, color = ACCENT})}}
			}
		}
	}
}

@(private = "file")
account_pending_row :: proc(id: nendo.Id, busy_id, owner, action: string) {
	if nendo.box(id)(
	{
		width = nendo.grow(),
		padding = nendo.pad(8),
		gap = 10,
		align = {y = .Center},
		color = STATUS_BAR,
	},
	) {
		nendo.text(
			fmt.tprintf("%s · %s", owner, action),
			{font = FONT_BODY, size = 12, color = TEXT_DIM},
		)
		busy_bar(busy_id)
	}
}
@(private)
account_relays_start :: proc(
	ui: ^Ui_State,
	client: ^marmot.Client,
	relays: []cstring,
	kind: Account_Operation,
) {
	job := account_job_new(ui, client, kind); if job == nil {return}
	job.relays = make([]cstring, len(relays))
	for relay, i in relays {job.relays[i] = strings.clone_to_cstring(string(relay))}
	account_job_start(job)
}

@(private)
account_departing :: proc(account: string) -> bool {
	for job in account_jobs {
		if job.account == account && account_exit(job.kind) {return true}
	}
	return false
}
