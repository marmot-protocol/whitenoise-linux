package main

import "core:fmt"
import "core:strings"
import "core:thread"
import rl "sdlrl"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"

@(private)
Account_Operation :: enum {
	Switch,
	Sign_Out,
	Remove,
	Profile,
	Outbox,
	Inbox,
	Relays,
	Key_Package,
	Read_Key_Packages,
	Unfollow,
	Read_Contacts,
	Create_Chat,
	Accept,
	Decline,
	Leave,
	Description,
	Avatar,
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
	fresh, notes, form, open_chat, departed:      bool,
	accepted:                                     u64,
	key_rows:                                     [dynamic]Kp_Row,
	contacts:                                     [dynamic]Contact_Ui,
	worker:                                       ^thread.Thread,
	signer:                                       ^Nip46_Account,
}
@(private)
account_jobs: [dynamic]^Account_Job

@(private)
account_job_new :: proc(
	ui: ^Ui_State,
	client: ^marmot.Client,
	kind: Account_Operation,
	account := "",
) -> ^Account_Job {
	owner := account == "" ? ui.account_ref : account
	if client == nil || owner == "" {return nil}
	if kind == .Switch {for item in nip46_accounts {item.switch_requested = false}}
	for job in account_jobs {
		if job.account == owner ||
		   (kind == .Switch &&
				   job.kind ==
					   .Switch) {set_status(ui, job.signer == nil ? tr("Your previous account action is still running.") : tr("Your previous account action is still waiting. Check your signer for approval."), .Info); return nil}
	}
	signer := nip46_find(owner)
	// Leaving an account never waits on its signer: a dead one is a reason to remove it.
	leaving := kind == .Sign_Out || kind == .Remove
	if !leaving && signer != nil && (signer.attach != nil || !signer.registered) {
		if kind ==
		   .Switch {signer.switch_requested = true; if signer.attach == nil {nip46_attach_start(signer)}}
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
	job.signer = nip46_find(owner)
	if ui.selected >= 0 &&
	   ui.selected < len(ui.chats) {job.group = strings.clone(ui.chats[ui.selected].group_id)}
	return job
}
@(private)
account_job_start :: proc(job: ^Account_Job) {
	if job == nil {return}
	append(&account_jobs, job)
	job.worker = thread.create(account_worker); job.worker.data = job; thread.start(job.worker)
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
	case .Switch:
		out: ^marmot.Account_Summary
		status = marmot.sign_in_account(job.client, account, &out)
		if out != nil {marmot.account_summary_free(out)}
	case .Sign_Out, .Remove:
		if job.signer != nil &&
		   job.signer.attach !=
			   nil {thread.join(job.signer.attach); job.signer.attach_joined = true}
		// A descriptor writer must finish before deletion, never resurrect it.
		if job.signer != nil &&
		   job.signer.persist !=
			   nil {thread.join(job.signer.persist); job.signer.persist_joined = true}
		if job.kind == .Remove {
			status = marmot.remove_account(job.client, account)
		} else {
			out: ^marmot.Sign_Out_Outcome
			status = marmot.sign_out(job.client, account, false, &out)
			if out != nil {marmot.sign_out_outcome_free(out)}
		}
		if status == .OK {
			job.departed = true
			if job.signer != nil {job.signer.registered = false}
			removed := vault_remove(fmt.tprintf("nip46:%s", job.account))
			if job.signer != nil {marmot.nip46_logout(job.signer.handle)}
			if removed != .None {
				message := tr(
					"You are signed out, but your signer record could not be removed from the encrypted vault.",
				)
				if job.kind == .Remove {
					message = tr(
						"Your account is removed, but its signer record couldn't be removed from the encrypted vault.",
					)
				}
				job.error = strings.clone(message)
			}
		}
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
		status =
			job.fresh ? marmot.publish_new_key_package(job.client, account, &job.accepted) : marmot.republish_key_package(job.client, account, &job.accepted)
		if status == .OK &&
		   !kp_rows(job.client, job.account, &job.key_rows) {job.error = marmot.last_error()}
	case .Read_Key_Packages:
		status = .OK
		if !kp_rows(job.client, job.account, &job.key_rows) {job.error = marmot.last_error()}
	case .Unfollow:
		out: ^marmot.String_List
		status = marmot.unfollow_user(job.client, account, target, &out)
		if out != nil {marmot.string_list_free(out)}
	case .Read_Contacts:
		// The picker needs saved people, not every group's membership.
		snapshot := Ui_State {
			account_ref = job.account,
		}
		if !load_contacts(job.client, &snapshot, .Picker) {
			job.error = strings.clone(tr("Couldn't load your contacts. Please try again."))
		}
		job.contacts = snapshot.contacts
		status = .OK
	case .Create_Chat:
		members: []cstring
		if job.target != "" {members = []cstring{target}}
		out: cstring
		status = marmot.create_group(
			job.client,
			account,
			strings.clone_to_cstring(job.title, context.temp_allocator),
			raw_data(members),
			uint(len(members)),
			nil,
			&out,
		)
		if out != nil {job.result = strings.clone(string(out)); marmot.string_free(out)}
		if status == .OK && len(job.pic_data) > 0 {
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
Account_Join :: enum {
	Pending,
	Joined,
}

@(private)
account_job_free :: proc(job: ^Account_Job, join: Account_Join = .Pending) {
	if join == .Pending {thread.join(job.worker)}
	thread.destroy(job.worker)
	for text in ([]string{job.account, job.group, job.target, job.title, job.result, job.error}) {delete(text)}
	for text in job.fields {delete(text)}
	for relay in job.relays {delete(relay)}
	kp_rows_free(&job.key_rows); delete(job.key_rows)
	nc_contacts_free(&job.contacts)
	delete(job.relays); delete(job.pic_data); free(job)
}
@(private)
account_jobs_stop :: proc() {
	for job in account_jobs {account_job_free(job)}
	delete(account_jobs); account_jobs = {}
}
@(private)
account_job_drain :: proc(ui: ^Ui_State) {
	for i := len(account_jobs) - 1; i >= 0; i -= 1 {
		job := account_jobs[i]
		if !thread.is_done(job.worker) {continue}
		thread.join(job.worker)
		if job.error != "" {set_status(ui, strings.clone(job.error), .Error)}
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
		if job.departed {
			if job.signer != nil {
				item := job.signer
				for candidate, n in nip46_accounts {if candidate == item {ordered_remove(&nip46_accounts, n); break}}
				nip46_account_free(item)
			}
			if ui.account_ref ==
			   job.account {ui.page = .Chats; ui.selected = -1; keys_forget(ui); close_export(ui); after_login(ui, job.client)} else {after_login(ui, job.client, ui.account_ref)}
		} else if job.error == "" {
			if job.kind == .Switch {
				finish_account_switch(ui, job.client, job.account)
				if ui.page == .Profile || ui.page == .Settings {load_profile(job.client, ui)}
			} else if ui.account_ref == job.account {
				switch job.kind {
				case .Profile:
					reload_profile(ui, job.client); ui.profile.editing = false
				case .Outbox, .Inbox:
					reload_profile(ui, job.client)
				case .Key_Package, .Read_Key_Packages:
					kp_rows_free(&ui.kp_list); delete(ui.kp_list); ui.kp_list = job.key_rows
					job.key_rows = {}
					ui.kp_fetched = true
					delete(ui.kp_own_json)
					ui.kp_own_json = ""
					if job.kind ==
					   .Key_Package {set_status(ui, fmt.aprintf(tr("Key package accepted by %d relays."), job.accepted), .Info)}
				case .Relays:
					set_status(ui, tr("Relay lists republished."), .Info)
				case .Unfollow:
					load_contacts(job.client, ui, .Details)
					ui.selected_contact = min(ui.selected_contact, len(ui.contacts) - 1)
				case .Read_Contacts:
					nc_contacts_free(&ui.nc_contacts)
					ui.nc_contacts = job.contacts
					job.contacts = {}
				case .Create_Chat:
					if job.notes {delete(ui.prefs.notes_group); ui.prefs.notes_group = strings.clone(job.result); ui.prefs.pinned[strings.clone(job.result)] = true; save_settings(ui)}
					load_chat_list(job.client, job.account, ui)
					if job.open_chat {if job.form {clear(&ui.nc_member); clear(&ui.nc_name)}; ui.focus = .Compose; ui.page = .Chats; ui.new_chat_open = false; select_by_id(ui, job.client, job.result)}
				case .Leave, .Decline:
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
				case .Switch, .Sign_Out, .Remove:
				}
			}
		}
		ordered_remove(&account_jobs, i); account_job_free(job, .Joined)
	}
}
@(private)
account_pending_label :: proc(kind: Account_Operation) -> string {
	switch kind {
	case .Switch:
		return tr("Switching your account")
	case .Sign_Out:
		return tr("Signing out and removing your signer session")
	case .Remove:
		return tr("Removing your account from this device")
	case .Profile:
		return tr("Publishing your profile")
	case .Outbox, .Inbox, .Relays:
		return tr("Publishing your relay lists")
	case .Key_Package:
		return tr("Publishing your key package")
	case .Read_Key_Packages:
		return tr("Loading your key packages")
	case .Unfollow:
		return tr("Updating your contacts")
	case .Read_Contacts:
		return tr("Loading your contacts")
	case .Create_Chat:
		return tr("Creating your chat")
	case .Accept:
		return tr("Accepting your invitation")
	case .Decline:
		return tr("Declining your invitation")
	case .Leave:
		return tr("Leaving your group")
	case .Description, .Avatar:
		return tr("Publishing your group profile")
	}
	return ""
}
@(private)
account_pending_ui :: proc(ui: ^Ui_State) {
	for job, i in account_jobs {
		if clay.UI(clay.ID("AccountPending", u32(i)))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				padding = clay.PaddingAll(8),
				childGap = 10,
				childAlignment = {y = .Center},
			},
			backgroundColor = STATUS_BAR,
		},
		) {
			clay.Text(
				fmt.tprintf(
					"%s · %s",
					account_label(ui, job.account),
					account_pending_label(job.kind),
				),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
			)
			busy_bar(fmt.tprintf("AccountPendingBusy%d", i))
		}
	}
	for item, i in nip46_accounts {
		if item.state.state == "approval" ||
		   item.state.state == "connecting" ||
		   item.attach != nil {
			if clay.UI(clay.ID("SignerPending", u32(i)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					padding = clay.PaddingAll(8),
					childGap = 10,
					childAlignment = {y = .Center},
				},
				backgroundColor = STATUS_BAR,
			},
			) {
				clay.Text(
					fmt.tprintf(
						"%s · %s",
						account_label(ui, item.account),
						nip46_label(item.state.state == "" ? "connecting" : item.state.state),
					),
					{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
				)
				busy_bar(fmt.tprintf("SignerPendingBusy%d", i))
				if item.state.auth_url !=
				   "" {if clay.UI(clay.ID("SignerApproval", u32(i)))({layout = {padding = clay.PaddingAll(5)}, backgroundColor = ROW_BG}) {clay.Text(tr("Review signer approval link"), {fontId = FONT_BODY, fontSize = 12, textColor = ACCENT})}}
			}
		}
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
		if job.account == account && (job.kind == .Sign_Out || job.kind == .Remove) {return true}
	}
	return false
}
