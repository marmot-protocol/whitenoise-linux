package main

import "core:strings"
import "core:sync"
import "core:unicode"
import "core:unicode/utf8"

import marmot "../marmot"
import "nendo"

@(private)
DEVICE_READS :: Device_Parts {
	.Link,
	.Roster,
	.Started_Fresh,
	.Sign_Ins,
	.Warning,
	.Overdue,
	.History,
}

@(private)
DEVICE_COUNTS :: Device_Parts{.Closed_Chats, .Leftover_Chats}

@(private)
Device_Panel :: enum {
	None,
	Add,
	New,
	Approve,
	Other_Profile,
	Detail,
	Unlinked,
	Wipe_Report,
	Auth_Unlinked,
	Offer,
	Chat_Review,
}

@(private)
Device_Action :: enum {
	None,
	Start,
	Confirm,
	Cancel,
	Link,
	Decline,
	Rename,
	Rename_Own,
	Settings,
	Remove_Sibling,
	Dismiss_Sibling,
	Reset,
	Check_Sign_Ins,
	Answer_Sign_In,
	Start_Fresh,
	Dismiss_Warning,
}

@(private)
Device_Setting :: enum {
	Add_To_Chats,
	History,
	Keep,
}

@(private)
Device_Command :: struct {
	kind:                                  Device_Action,
	prompt, slot, move_id, name, own_name: string,
	setting:                               Device_Setting,
	response:                              marmot.Sign_In_Response,
	setting_value:                         bool,
	add_to_all, bring_history, mismatch:   bool,
}

@(private)
Device_View :: struct {
	link:                         ^marmot.Device_Link_Snapshot,
	roster:                       ^marmot.Linked_Device_List,
	sign_ins:                     ^marmot.Unrecognized_Sign_In_List,
	warning:                      ^marmot.Compromise_Warning_Item_List,
	history:                      ^marmot.Chat_History_Import_List,
	// Keys and values borrow from the corresponding list root.
	roster_labels:                map[string]string,
	history_by_group:             map[string]^marmot.Chat_History_Import,
	history_receiving:            int,
	chat_review:                  Device_Chat_Review,
	started_fresh, overdue:       bool,
	closed_chats, leftover_chats: u32,
}

@(private)
Device_Profile :: struct {
	account, unlink_label:                   string,
	signed_in, revoked:                      bool,
	unlink_check:                            bool,
	unlink_notice_seen:                      bool,
	first_import:                            bool,
	link_result_seen:                        bool,
	seen, incarnation:                       u64,
	dirty, known, stale:                     Device_Parts,
	view:                                    Device_View,
	job:                                     ^Device_Job,
	queued:                                  Device_Command,
	action_error:                            string,
	dismissed:                               map[string]bool,
	deferred_name:                           string,
	roster_event, roster_seen, rename_after: u64,
}

@(private)
Devices_State :: struct {
	profiles:                                                        map[string]^Device_Profile,
	active:                                                          string, // borrows the map key until devices_stop
	generation:                                                      u64,
	unavailable:                                                     bool,
	inventory:                                                       ^Device_Inventory,
	inventory_dirty, inventory_stale:                                bool,
	panel:                                                           Device_Panel,
	panel_account, panel_prompt, review_account, error:              string,
	panel_slot, expanded_sign_in:                                    string,
	expanded_sign_in_at:                                             u64,
	chat_review_page:                                                int,
	wipe_report:                                                     string,
	wipe_report_error:                                               bool,
	name, own_name:                                                  [dynamic]u8,
	show_attempt, mismatch, add_to_all, bring_history, move_consent: bool,
}

@(private)
device_profile :: proc(devices: ^Devices_State, account: string) -> ^Device_Profile {
	if profile := devices.profiles[account]; profile != nil {
		return profile
	}
	context.allocator = reload_allocator()
	profile := new(Device_Profile)
	profile.account = strings.clone(account)
	devices.profiles[profile.account] = profile
	return profile
}

@(private)
device_view_free :: proc(view: ^Device_View) {
	delete(view.roster_labels)
	delete(view.history_by_group)
	delete(view.chat_review.rows)
	if view.chat_review.chats != nil {marmot.presented_chat_list_free(view.chat_review.chats)}
	if view.link != nil {marmot.device_link_snapshot_free(view.link)}
	if view.roster != nil {marmot.linked_device_list_free(view.roster)}
	if view.sign_ins != nil {marmot.unrecognized_sign_in_list_free(view.sign_ins)}
	if view.warning != nil {marmot.compromise_warning_item_list_free(view.warning)}
	if view.history != nil {marmot.chat_history_import_list_free(view.history)}
	view^ = {}
}

@(private)
devices_select :: proc(ui: ^Ui_State) {
	devices := &ui.devices
	if devices.active == ui.account_ref {return}
	if devices.review_account != ui.account_ref || devices.review_account == "" {
		devices_close(ui)
	}
	if old := devices.profiles[devices.active]; old != nil {
		old.first_import = false
		link := old.view.link
		old.view.link = nil
		device_view_free(&old.view)
		old.view.link = link
		old.known &= {.Link}
		old.stale &= {.Link}
		old.dirty &= {.Link}
		device_command_free(&old.queued)
		delete(old.action_error, reload_allocator()); old.action_error = ""
	}
	devices.generation += 1
	devices.active = ""
	if ui.account_ref != "" {
		profile := device_profile(devices, ui.account_ref)
		if !profile.revoked {
			devices.active = profile.account
			profile.signed_in = true
			profile.dirty += DEVICE_READS
		}
	}
}

@(private)
devices_seed :: proc(ui: ^Ui_State) {
	devices := &ui.devices
	for row in ui.accounts {
		profile := device_profile(devices, row.id_hex)
		if profile.revoked {continue}
		profile.seen = ui.accounts_revision
		if !profile.signed_in {
			profile.dirty += profile.account == devices.active ? DEVICE_READS : {.Link}
		}
		profile.signed_in = true
	}
	for _, profile in devices.profiles {
		if profile.signed_in && profile.seen != ui.accounts_revision {
			profile.signed_in = false
			profile.link_result_seen = false
			profile.incarnation += 1
			device_command_free(&profile.queued)
			delete(profile.deferred_name, reload_allocator()); profile.deferred_name = ""
			device_view_free(&profile.view)
			profile.known, profile.stale, profile.dirty = {}, {}, {}
		}
	}
}

@(private)
devices_mark_unlinked :: proc(ui: ^Ui_State, account, label: string) {
	if account == "" {return}
	profile := device_profile(&ui.devices, account)
	profile.unlink_check = false
	if profile.revoked {return}
	profile.revoked, profile.signed_in = true, false
	profile.unlink_notice_seen = false
	profile.incarnation += 1
	resolved := label
	for row in ui.accounts {if row.id_hex == account && row.name != "" {resolved = row.name; break}}
	profile.unlink_label = strings.clone(resolved, reload_allocator())
	profile.first_import = false
	device_view_free(&profile.view)
	device_command_free(&profile.queued)
	delete(profile.deferred_name, reload_allocator()); profile.deferred_name = ""
	profile.known, profile.stale, profile.dirty = {}, {}, {}
	if ui.devices.panel_account == account {devices_close(ui)}
	ui.devices.inventory_dirty = true
	offline_revoke(ui, profile.account)
	account_departed(ui, nil, profile.account)
}

@(private)
devices_wipe_prefs :: proc(ui: ^Ui_State, account: string) {
	if account in ui.prefs.sign_ins_recognized {
		sign_in_reviews_drop(&ui.prefs, account)
		ui.settings_dirty = true
	}
}

@(private)
devices_wipe_applied :: proc(ui: ^Ui_State, account: string) {
	profile := ui.devices.profiles[account]
	if profile == nil {return}
	profile.revoked, profile.signed_in, profile.first_import = false, false, false
	profile.unlink_check = false
	profile.unlink_notice_seen = true
	profile.link_result_seen = false
	profile.incarnation += 1
	delete(profile.unlink_label, reload_allocator()); profile.unlink_label = ""
	for id in profile.dismissed {delete(id, reload_allocator())}
	clear(&profile.dismissed)
	if ui.devices.panel_account == account {devices_close(ui)}
}

@(private)
devices_open_unlinked :: proc(ui: ^Ui_State, mode: Device_Unlink_Mode = .Manual) -> bool {
	best: ^Device_Profile
	for _, profile in ui.devices.profiles {
		if !(profile.revoked || profile.unlink_check) ||
		   (mode == .Automatic && profile.unlink_notice_seen) {continue}
		if best == nil || profile.account < best.account {best = profile}
	}
	if best == nil {return false}
	ui.accounts_open = false
	devices_show(ui, .Unlinked, best.account)
	best.unlink_notice_seen = true
	return true
}

@(private)
Device_Unlink_Mode :: enum {
	Manual,
	Automatic,
}

@(private)
devices_notice_closed :: proc(ui: ^Ui_State) {
	devices_close(ui)
	if ui.account_ref == "" && auth_job == nil && len(ui.accounts) != 0 {
		ui.accounts_open = true
	}
}

@(private)
devices_first_import :: proc(ui: ^Ui_State) {
	if profile := device_current(ui); profile != nil {
		ui.page = .Chats
		profile.first_import = device_queue(ui, {kind = .Check_Sign_Ins})
	}
}

@(private)
device_earlier_sign_in :: proc(ui: ^Ui_State, profile: ^Device_Profile) -> bool {
	if profile == nil ||
	   !device_can_start_fresh(profile, ui.prefs.sign_ins_recognized[profile.account]) ||
	   .Link not_in profile.known ||
	   .Link in profile.stale {return false}
	return profile.view.link == nil || profile.view.link.new_device == nil
}

@(private)
device_can_start_fresh :: proc(profile: ^Device_Profile, reviews: map[string]u64 = nil) -> bool {
	NEEDED :: Device_Parts{.Roster, .Started_Fresh, .Sign_Ins}
	if profile == nil ||
	   (profile.known & NEEDED) != NEEDED ||
	   (profile.stale & NEEDED) != {} {return false}
	view := &profile.view
	if view.started_fresh ||
	   view.sign_ins == nil ||
	   (view.roster != nil && view.roster.len != 0) {return false}
	for row in view.sign_ins.items[:view.sign_ins.len] {
		if !row.before_this_device || row.state != .PROMPT {continue}
		seen, recognized := reviews[string(row.slot_id_hex)]
		if !recognized || seen != row.appeared_at {return true}
	}
	return false
}

@(private)
device_find_sign_in :: proc(
	profile: ^Device_Profile,
	slot: string,
) -> ^marmot.Unrecognized_Sign_In {
	if profile == nil || profile.view.sign_ins == nil || slot == "" {return nil}
	sign_ins := profile.view.sign_ins
	for &row in sign_ins.items[:sign_ins.len] {
		if string(row.slot_id_hex) == slot {return &row}
	}
	return nil
}

@(private)
device_has_warning :: proc(profile: ^Device_Profile) -> bool {
	return profile != nil && profile.view.warning != nil && profile.view.warning.len != 0
}

@(private)
devices_reconcile :: proc(ui: ^Ui_State) {
	ui.devices.inventory_dirty = true
	if devices_open_now(ui) {devices_refresh_open(ui)} else {devices_refresh_reads(ui)}
}

@(private)
devices_refresh_reads :: proc(ui: ^Ui_State) {
	for _, profile in ui.devices.profiles {
		if profile.signed_in {
			profile.dirty += profile.account == ui.devices.active ? DEVICE_READS : {.Link}
		}
	}
}

@(private)
devices_visible :: proc(ui: ^Ui_State) -> bool {
	if ui.account_ref == "" {return false}
	profile := ui.devices.profiles[ui.account_ref]
	return profile == nil || !(profile.revoked || profile.unlink_check)
}

@(private)
device_current :: proc(ui: ^Ui_State) -> ^Device_Profile {
	if !devices_visible(ui) {return nil}
	return ui.devices.profiles[ui.account_ref]
}

@(private)
device_history_index :: proc(
	list: ^marmot.Chat_History_Import_List,
) -> map[string]^marmot.Chat_History_Import {
	if list == nil || list.len == 0 {return nil}
	by_group := make(map[string]^marmot.Chat_History_Import, int(list.len), reload_allocator())
	for &item in list.items[:list.len] {
		if group := string(item.group_id_hex); group != "" {by_group[group] = &item}
	}
	return by_group
}

@(private)
device_roster_labels :: proc(list: ^marmot.Linked_Device_List) -> map[string]string {
	if list == nil || list.len == 0 {return nil}
	labels := make(map[string]string, int(list.len), reload_allocator())
	for &item in list.items[:list.len] {
		if slot := string(item.slot_id_hex); slot != "" {labels[slot] = string(item.label)}
	}
	return labels
}

@(private)
devices_open_now :: proc(ui: ^Ui_State) -> bool {
	return ui.page == .Settings && ui.settings_section == .Devices
}

@(private)
devices_refresh_open :: proc(ui: ^Ui_State) {
	devices_refresh_reads(ui)
	if profile := device_current(ui); profile != nil {
		profile.dirty += DEVICE_COUNTS
	}
}

@(private)
device_find_prompt :: proc(profile: ^Device_Profile, id: string) -> ^marmot.Device_Link_Prompt {
	if profile == nil || id == "" || profile.view.link == nil {return nil}
	link := profile.view.link
	for &prompt in link.prompts[:link.prompts_len] {
		if string(prompt.prompt_id) == id {return &prompt}
	}
	return nil
}

@(private)
device_prompt_attention :: proc(prompt: ^marmot.Device_Link_Prompt) -> bool {
	return prompt != nil && prompt.prompt_id != nil && prompt.state.tag <= .LINKING
}

@(private)
device_live_attempt :: proc(link: ^marmot.Device_Link_Snapshot) -> bool {
	if link == nil {return false}
	if link.new_device != nil && link.new_device.tag < .LINKED {return true}
	return device_move_pending(link)
}

@(private)
device_move_pending :: proc(link: ^marmot.Device_Link_Snapshot) -> bool {
	if link == nil {return false}
	for move in link.moves[:link.moves_len] {
		if move.state == .WAITING_FOR_WELCOME || move.state == .JOINING {return true}
	}
	return false
}

@(private)
device_code_valid :: proc(code: marmot.Device_Link_Code) -> bool {
	if code.code == nil || code.code_len != 7 {return false}
	for cell in code.code[:code.code_len] {
		glyph, description := string(cell.emoji), string(cell.description)
		r, n := utf8.decode_rune_in_string(glyph)
		if n == 0 ||
		   !unicode.is_emoji_extended_pictographic(r) ||
		   (glyph[n:] != "" && glyph[n:] != "\ufe0f") ||
		   strings.trim_space(description) == "" ||
		   !utf8.valid_string(description) {
			return false
		}
	}
	return true
}

@(private)
device_name_valid :: proc(name: string) -> bool {
	return(
		0 < len(name) &&
		len(name) <= 64 &&
		utf8.valid_string(name) &&
		strings.index_byte(name, 0) == -1 \
	)
}

@(private)
device_label :: proc(row: ^marmot.Linked_Device) -> string {
	if row != nil {
		for label in ([3]cstring{row.label, row.platform, row.client}) {
			if value := string(label); value != "" {return value}
		}
	}
	return tr("Unnamed device")
}

@(private)
device_own_slot :: proc(profile: ^Device_Profile) -> ^marmot.Linked_Device {
	if profile != nil && profile.view.roster != nil {
		for &row in profile.view.roster.items[:profile.view.roster.len] {
			if row.is_this_device {return &row}
		}
	}
	return nil
}

@(private)
device_find_slot :: proc(profile: ^Device_Profile, id: string) -> ^marmot.Linked_Device {
	if id == "" || profile == nil || profile.view.roster == nil {return nil}
	for &row in profile.view.roster.items[:profile.view.roster.len] {
		if string(row.slot_id_hex) == id {return &row}
	}
	return nil
}

@(private)
device_find_move_sibling :: proc(profile: ^Device_Profile, move_id, slot: string) -> bool {
	if profile == nil || profile.view.link == nil || move_id == "" || slot == "" {return false}
	link := profile.view.link
	for move in link.moves[:link.moves_len] {
		if string(move.move_id) != move_id {continue}
		for row in move.old_siblings[:move.old_siblings_len] {
			if row.question_suppressed && string(row.slot_id_hex) == slot {return true}
		}
	}
	return false
}

@(private)
devices_show_detail :: proc(ui: ^Ui_State, row: ^marmot.Linked_Device) {
	if row == nil || string(row.slot_id_hex) == "" {return}
	context.allocator = reload_allocator()
	devices_show(ui, .Detail, slot = string(row.slot_id_hex))
	append(&ui.devices.name, string(row.label))
}

@(private)
devices_close :: proc(ui: ^Ui_State) {
	context.allocator = reload_allocator()
	d := &ui.devices
	if d.panel == .Chat_Review {
		if profile := d.profiles[d.panel_account]; profile != nil {
			profile.dirty -= {.Chat_Review}
			if job := profile.job; job != nil && .Chat_Review in job.reads {
				sync.atomic_store(&job.chat_review_cancel, true)
			}
		}
	}
	delete(d.panel_account); delete(d.panel_prompt); delete(d.review_account); delete(d.error)
	delete(d.panel_slot); d.panel_slot = ""
	delete(d.expanded_sign_in); d.expanded_sign_in = ""
	d.panel_account, d.panel_prompt, d.review_account, d.error = "", "", "", ""
	d.panel = .None
	d.chat_review_page = 0
	d.show_attempt, d.mismatch, d.move_consent = false, false, false
	clear(&d.name); clear(&d.own_name)
	if ui.focus == .Device_Name || ui.focus == .Device_Own_Name {ui.focus = .Compose}
}

@(private)
devices_show :: proc(
	ui: ^Ui_State,
	panel: Device_Panel,
	account: string = "",
	prompt: string = "",
	slot: string = "",
) {
	context.allocator = reload_allocator()
	owner := strings.clone(account == "" ? ui.account_ref : account)
	id := strings.clone(prompt)
	owner_slot := strings.clone(slot)
	devices_close(ui)
	d := &ui.devices
	d.panel, d.panel_account, d.panel_prompt = panel, owner, id
	d.panel_slot = owner_slot
	profile := d.profiles[owner]
	d.show_attempt = panel == .New && profile != nil && device_live_attempt(profile.view.link)
	if panel == .Add && profile != nil && !device_checking_link(profile) {profile.dirty += {.Link}}
	if panel == .Chat_Review && profile != nil {profile.dirty += {.Chat_Review, .Closed_Chats}}
	if panel == .Approve {
		append(&d.name, ..transmute([]u8)tr("New device"))
		append(&d.own_name, DEVICE_PLATFORM == "" ? tr("This device") : DEVICE_PLATFORM)
		d.add_to_all, d.bring_history = true, false
	}
	kb_focus = ""
	if nendo.current_context() != nil {
		if box := nendo.scroll(nendo.id("DeviceModalBody")); box.found {box.position^ = {}}
	}
}

@(private)
devices_put_away :: proc(ui: ^Ui_State) {
	context.allocator = reload_allocator()
	d := &ui.devices
	if profile := d.profiles[d.panel_account]; profile != nil {
		if d.panel_prompt != "" && d.panel_prompt not_in profile.dismissed {
			profile.dismissed[strings.clone(d.panel_prompt)] = true
		}
	}
	devices_close(ui)
}

@(private)
device_latest_prompt :: proc(
	profile: ^Device_Profile,
	slot: string = "",
) -> ^marmot.Device_Link_Prompt {
	if profile == nil ||
	   !profile.signed_in ||
	   profile.revoked ||
	   profile.view.link == nil ||
	   .Link in profile.stale {return nil}
	best: ^marmot.Device_Link_Prompt
	link := profile.view.link
	for &prompt in link.prompts[:link.prompts_len] {
		if !device_prompt_attention(&prompt) ||
		   (slot != "" && string(prompt.slot_id_hex) != slot) ||
		   string(prompt.prompt_id) in profile.dismissed {continue}
		if best == nil || prompt.requested_at > best.requested_at {best = &prompt}
	}
	return best
}

@(private)
device_attention :: proc(ui: ^Ui_State) -> (panel: Device_Panel, account, prompt: string) {
	if !devices_visible(ui) || ui.devices.unavailable {return}
	d := &ui.devices
	if current := device_current(ui); current != nil {
		if p := device_latest_prompt(current);
		   p != nil && !(d.panel == .Approve && d.panel_prompt == string(p.prompt_id)) {
			return .Approve, current.account, string(p.prompt_id)
		}
		if d.panel != .New && device_live_attempt(current.view.link) {
			return .New, current.account, ""
		}
	}
	best: ^marmot.Device_Link_Prompt
	for owner, profile in d.profiles {
		if owner == ui.account_ref {continue}
		p := device_latest_prompt(profile)
		if p == nil ||
		   (d.panel_account == owner && d.panel_prompt == string(p.prompt_id)) {continue}
		if best == nil ||
		   p.requested_at > best.requested_at ||
		   (p.requested_at == best.requested_at && owner < account) {
			best, account = p, owner
		}
	}
	if best != nil {return .Other_Profile, account, string(best.prompt_id)}
	return
}

@(private)
devices_present :: proc(ui: ^Ui_State, focused: bool) {
	if !focused {return}
	d := &ui.devices
	if (d.panel == .None || d.panel == .Unlinked) && ui.confirm.kind == .None && !ui.link_open {
		if d.wipe_report != "" {
			ui.accounts_open = false
			devices_show(ui, .Wipe_Report)
			return
		}
		if d.panel == .None &&
		   !ui.add_account_open &&
		   (ui.accounts_open || !modal_open(ui)) &&
		   devices_open_unlinked(ui, .Automatic) {return}
	}
	if !devices_visible(ui) || ui.add_account_open || ui.devices.unavailable {return}
	if d.panel == .Add && ui.confirm.kind == .None && !ui.link_open {
		profile := device_current(ui)
		if device_checking_link(profile) {return}
		if p := device_latest_prompt(profile, d.panel_slot); p != nil {
			devices_show(ui, .Approve, ui.account_ref, string(p.prompt_id), slot = d.panel_slot)
		}
		return
	}
	if modal_open(ui) {return}
	panel, account, prompt := device_attention(ui)
	if panel != .Approve && ui.page == .Chats {
		profile := device_current(ui)
		if profile != nil &&
		   profile.first_import &&
		   device_busy(profile) == .None &&
		   device_earlier_sign_in(ui, profile) {
			devices_show(ui, .Offer)
			return
		}
	}
	if panel == .Approve || panel == .Other_Profile {
		devices_show(ui, panel, account, prompt)
	}
}

@(private)
devices_review :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	d := &ui.devices
	if d.panel != .Other_Profile || d.review_account != "" {return}
	profile := d.profiles[d.panel_account]
	if profile == nil ||
	   profile.revoked ||
	   !device_prompt_attention(device_find_prompt(profile, d.panel_prompt)) {
		delete(d.error, reload_allocator())
		d.error = strings.clone(tr("This request is no longer active."), reload_allocator())
		return
	}
	if profile.account != ui.account_ref && !switch_account(ui, client, profile.account) {
		delete(d.error, reload_allocator())
		d.error = strings.clone(
			tr("Couldn't switch profiles. Please try again."),
			reload_allocator(),
		)
		return
	}
	delete(d.error, reload_allocator()); d.error = ""
	d.review_account = strings.clone(profile.account, reload_allocator())
	profile.dirty += {.Link}
}

@(private)
devices_switch_failed :: proc(ui: ^Ui_State, account: string) {
	d := &ui.devices
	if d.review_account != account || account == "" {return}
	delete(d.review_account, reload_allocator()); d.review_account = ""
	delete(d.error, reload_allocator())
	d.error = strings.clone(tr("Couldn't switch profiles. Please try again."), reload_allocator())
}
