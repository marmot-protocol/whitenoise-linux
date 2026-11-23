package main

import "core:strings"
import "core:sync"
import "core:thread"

import marmot "../marmot"
import "nendo"

@(private)
Activation_Key :: struct {
	account, group: string,
}

@(private)
activation_epoch: u64

@(private)
Activation_Advisory :: enum {
	None,
	Undelivered,
}

@(private)
Activation_Pending :: struct {
	key:      Activation_Key,
	ticket:   int,
	revision: u64,
	settling: bool,
	baseline: map[string]bool,
}

@(private)
Activation_Read :: struct {
	worker:         ^thread.Thread,
	client:         ^marmot.Client,
	account, group: cstring,
	revision:       u64,
	status:         marmot.Status,
	eligibility:    marmot.Account_Devices_Activation,
	report:         ^marmot.Account_Devices_Report,
	ticket:         int,
	failures:       map[string]bool,
}

@(private)
Chat_Activation :: struct {
	key:                          Activation_Key,
	revision:                     u64,
	known, dirty, reread_refusal: bool,
	eligibility:                  marmot.Account_Devices_Activation,
	report:                       ^marmot.Account_Devices_Report,
	notice:                       string, // gettext msgid
	advisory:                     Activation_Advisory,
	acknowledged:                 bit_set[Activation_Advisory],
	pending:                      map[Activation_Key]Activation_Pending,
	read:                         ^Activation_Read,
}

@(private = "file")
activation_key :: proc(ui: ^Ui_State) -> Activation_Key {
	if ui.account_ref == "" || ui.selected < 0 || ui.selected >= len(ui.chats) {return {}}
	return {ui.account_ref, ui.chats[ui.selected].group_id}
}

@(private = "file")
activation_key_free :: proc(key: Activation_Key) {
	delete(key.account)
	delete(key.group)
}

@(private)
activation_reset :: proc(ui: ^Ui_State) {
	a := &ui.activation
	activation_key_free(a.key)
	a.key = {}
	if a.report != nil {marmot.account_devices_report_free(a.report); a.report = nil}
	sync.atomic_add(&activation_epoch, 1)
	a.revision = sync.atomic_load(&activation_epoch)
	a.known, a.dirty, a.reread_refusal = false, false, false
	a.notice, a.advisory, a.acknowledged = "", .None, {}
	if activation_confirmation(ui.confirm.kind) {confirm_close(ui)}
}

@(private)
activation_refresh :: proc(ui: ^Ui_State) {
	key := activation_key(ui)
	if key.group == "" {return}
	a := &ui.activation
	if a.key != key {
		activation_reset(ui)
		a.key = {strings.clone(key.account), strings.clone(key.group)}
	}
	a.dirty = true
}

@(private)
activation_focus :: proc(ui: ^Ui_State) {
	if activation_key(ui) in ui.activation.pending {activation_refresh(ui)}
}

@(private)
activation_confirmation :: proc(kind: Confirm_Kind) -> bool {
	return kind == .Enable_Account_Devices || kind == .Activation_Undelivered
}

@(private)
activation_wait :: proc(ui: ^Ui_State) {
	if !activation_confirmation(ui.confirm.kind) {return}
	ui.activation.advisory, ui.activation.acknowledged = .None, {}
}

@(private)
activation_can_submit :: proc(ui: ^Ui_State, c: Confirm) -> bool {
	if ui.page != .Chats || !ui.show_members || c.account == "" || c.arg == "" {return false}
	key := Activation_Key{c.account, c.arg}
	a := &ui.activation
	if key != activation_key(ui) ||
	   key != a.key ||
	   key in a.pending ||
	   account_revoked(ui, key.account) {return false}
	#partial switch c.kind {
	case .Enable_Account_Devices:
		return a.advisory == .None && a.known && a.eligibility == .ELIGIBLE
	case .Activation_Undelivered:
		return a.advisory == .Undelivered && .Undelivered not_in a.acknowledged
	}
	return false
}

@(private)
activation_prepare :: proc(ui: ^Ui_State, c: Confirm) -> (marmot.Status, bool) {
	if !activation_can_submit(ui, c) {return .OK, false}
	a := &ui.activation
	advisory: marmot.Status
	switch a.advisory {
	case .None:
		a.acknowledged = {}; advisory = .OK
	case .Undelivered:
		advisory = .GROUP_COMMIT_UNDELIVERED
	}
	if a.advisory != .None {a.acknowledged += {a.advisory}}
	a.advisory, a.notice, a.known, a.reread_refusal = .None, "", false, false
	return advisory, true
}

@(private)
activation_confirm :: proc(ui: ^Ui_State, client: ^marmot.Client, c: Confirm) {
	if client == nil {return}
	advisory, ok := activation_prepare(ui, c)
	if !ok {return}
	a := &ui.activation
	key := Activation_Key{strings.clone(c.account), strings.clone(c.arg)}
	a.pending[key] = {
		key      = key,
		ticket   = spawn_op(ui, client, .Enable_Account_Devices, "", "", advisory = advisory),
		revision = a.revision,
	}
}

@(private = "file")
activation_remove :: proc(a: ^Chat_Activation, key: Activation_Key) {
	pending, found := a.pending[key]
	if !found {return}
	delete_key(&a.pending, key)
	activation_free_failures(pending.baseline)
	activation_key_free(pending.key)
}

@(private)
activation_departed :: proc(ui: ^Ui_State, account: string) {
	a := &ui.activation
	if a.key.account == account {activation_reset(ui)}
	keys := make([dynamic]Activation_Key, context.temp_allocator)
	for key in a.pending {if key.account == account {append(&keys, key)}}
	for key in keys {activation_remove(a, key)}
}

@(private)
activation_live :: proc(ui: ^Ui_State, group: Live_Change) {
	if !group.activation_signal {return}
	key := Activation_Key{group.account, group.group}
	a := &ui.activation
	if a.key == key && activation_key(ui) == key {a.dirty = true}
}

@(private)
activation_complete :: proc(ui: ^Ui_State, client: ^marmot.Client, done: Op_Done) {
	defer delete(done.account)
	defer delete(done.group)
	result := done.activation
	a := &ui.activation
	key := Activation_Key{done.account, done.group}
	pending, found := &a.pending[key]
	if !found || pending.ticket != done.ticket {
		activation_free_failures(result.baseline)
		return
	}
	current := activation_key(ui) == key && a.key == key
	consent_scope := current && a.revision == pending.revision && ui.show_members
	if current {
		a.dirty = true
		if ui.show_members && client != nil {load_members(client, ui)}
	}
	if result.status == .OK && result.disposition != .PUBLISHED {
		pending.settling = true
		pending.baseline = result.baseline
		return
	}
	activation_free_failures(result.baseline)
	activation_remove(a, key)
	if !current {return}
	#partial switch result.status {
	case .OK:
		if result.published > 0 {
			a.notice = N_("Linked devices are turned on for this chat.")
			return
		}
	case .ACCOUNT_DEVICES_ACTIVATION_REFUSED:
		a.reread_refusal = true
		return
	case .CLOSED:
		if !consent_scope {return}
	case .GROUP_CATCHING_UP:
		a.notice = N_("Wait for this chat to finish catching up, then try again.")
		return
	case .GROUP_COMMIT_UNDELIVERED:
		if !consent_scope {return}
		if .Undelivered not_in a.acknowledged {
			a.advisory = .Undelivered
			return
		}
	case:
	}
	a.notice = N_("Couldn't turn on linked devices. Please try again.")
}

@(private = "file")
activation_blocker :: proc(result: marmot.Account_Devices_Activation) -> string {
	switch result {
	case .ELIGIBLE:
		return N_("Couldn't turn on linked devices. Please try again.")
	case .NOT_ADMIN:
		return N_("Only a chat admin can turn on linked devices.")
	case .ALREADY_ENABLED:
		return N_("Linked devices are turned on for this chat.")
	case .LEGACY_GROUP:
		return N_("This chat doesn't support linked devices.")
	case .MEMBERS_NEED_UPDATE:
		return N_(
			"Not every device in this chat has reported support for linked devices. If everyone's app is up to date, keep the apps online so the chat can sync.",
		)
	case .DEVICES_NEED_REPLACEMENT:
		return N_("Some devices need to be replaced before linked devices can be turned on.")
	case .DEVICE_LIMIT_EXCEEDED:
		return N_("This chat exceeds the device limit.")
	}
	return ""
}

@(private)
activation_apply_read :: proc(ui: ^Ui_State, work: ^Activation_Read) {
	a := &ui.activation
	key := Activation_Key{string(work.account), string(work.group)}
	if a.revision != work.revision || a.key != key || activation_key(ui) != key {return}
	if a.report != nil {marmot.account_devices_report_free(a.report); a.report = nil}
	a.known = work.status == .OK
	if !a.known {
		a.reread_refusal = false
		return
	}
	a.eligibility = work.eligibility
	a.report, work.report = work.report, nil
	if pending, found := &a.pending[key]; found && pending.settling {
		if work.eligibility == .ALREADY_ENABLED {
			activation_remove(a, key)
			a.notice = activation_blocker(.ALREADY_ENABLED)
			return
		}
		if pending.ticket == work.ticket {
			for id in work.failures {
				if id in pending.baseline {continue}
				activation_remove(a, key)
				a.notice = N_("Linked devices weren't turned on for this chat.")
				return
			}
		}
	}
	if a.reread_refusal {
		a.notice = activation_blocker(work.eligibility)
		a.reread_refusal = false
	} else if work.eligibility == .ALREADY_ENABLED && (a.notice != "" || a.advisory != .None) {
		a.notice = activation_blocker(.ALREADY_ENABLED)
		a.advisory = .None
		if activation_confirmation(ui.confirm.kind) {confirm_close(ui)}
	} else if work.eligibility != .ALREADY_ENABLED &&
	   a.notice == activation_blocker(.ALREADY_ENABLED) {
		a.notice = ""
	}
}

@(private)
activation_component_required :: proc(state: marmot.Group_Mls_State_Head) -> bool {
	ACCOUNT_DEVICES_COMPONENT :: 0x800d
	for component in state.required_app_components[:state.required_app_components_len] {
		if component == ACCOUNT_DEVICES_COMPONENT {return true}
	}
	return false
}

@(private = "file")
activation_read_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer frame_wake()
	work := (^Activation_Read)(t.data)
	state: ^marmot.Group_Mls_State_Head
	work.status = marmot.group_mls_state(work.client, work.account, work.group, &state)
	defer if state != nil {marmot.app_group_mls_state_free(state)}
	if work.status != .OK {return}
	if state == nil {work.status = .RUNTIME; return}
	if activation_component_required(state^) {
		work.eligibility = .ALREADY_ENABLED
		return
	}
	work.status = marmot.account_devices_report(
		work.client,
		work.account,
		work.group,
		&work.report,
	)
	if work.status != .OK {return}
	if work.report == nil {work.status = .RUNTIME; return}
	work.eligibility = work.report.eligibility
	if work.eligibility != .ALREADY_ENABLED && work.ticket != 0 {
		work.status = activation_failures(work.client, work.account, work.group, &work.failures)
	}
}

@(private = "file")
activation_read_free :: proc(work: ^Activation_Read) {
	thread.join(work.worker)
	thread.destroy(work.worker)
	delete(work.account)
	delete(work.group)
	if work.report != nil {marmot.account_devices_report_free(work.report)}
	activation_free_failures(work.failures)
	free(work)
}

@(private)
activation_drain :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	a := &ui.activation
	if a.key.group != "" && a.key != activation_key(ui) {activation_reset(ui)}
	if work := a.read; work != nil && thread.is_done(work.worker) {
		if !a.dirty {activation_apply_read(ui, work)}
		activation_read_free(work)
		a.read = nil
	}
	if a.advisory != .None && ui.page == .Chats && ui.show_members && ui.confirm.kind == .None {
		confirm_ask(ui, .Activation_Undelivered, a.key.group)
	}
	if !a.dirty || a.read != nil || client == nil || account_revoked(ui, a.key.account) {return}
	pending := a.pending[a.key]
	work := new(Activation_Read)
	work.client = client
	work.account = strings.clone_to_cstring(a.key.account)
	work.group = strings.clone_to_cstring(a.key.group)
	work.revision = a.revision
	if pending.settling {work.ticket = pending.ticket}
	work.worker = thread.create(activation_read_worker)
	work.worker.data = work
	a.read, a.dirty = work, false
	thread.start(work.worker)
}

@(private)
activation_stop :: proc(ui: ^Ui_State) {
	activation_reset(ui)
	a := &ui.activation
	if a.read != nil {activation_read_free(a.read); a.read = nil}
	for key, pending in a.pending {
		activation_free_failures(pending.baseline)
		activation_key_free(key)
	}
	delete(a.pending)
	a.pending = nil
}

@(private = "file")
activation_members :: proc(ui: ^Ui_State, report: ^marmot.Account_Devices_Report) {
	if report == nil || report.blockers_len == 0 {return}
	nendo.text(tr("Members to check"), {font = FONT_TITLE, size = 13, color = TEXT})
	for blocker in report.blockers[:report.blockers_len] {
		id := string(blocker.member_id_hex)
		reason: string
		#partial switch blocker.reason {
		case .MEMBERS_NEED_UPDATE:
			reason = tr("A device hasn't reported support.")
		case .DEVICES_NEED_REPLACEMENT:
			reason = tr("A device needs to be replaced.")
		case .DEVICE_LIMIT_EXCEEDED:
			reason = tr("This member has too many devices in this chat.")
		case:
			continue
		}
		if nendo.box(nendo.id_local(id))(
		{width = nendo.grow(), gap = 8, padding = nendo.pad(8), color = ROW_BG, radius = rr(8)},
		) {
			row_labels(id == ui.account_ref ? tr("You") : dm_title(g_client, id), reason)
			nendo.text(id[:min(len(id), 8)], {font = FONT_MONO, size = 10, color = TEXT_DIM})
		}
	}
}

@(private)
activation_card :: proc(ui: ^Ui_State, card: nendo.Box) {
	a := &ui.activation
	if a.key.group == "" || a.key != activation_key(ui) {return}
	pending, active := a.pending[a.key]
	checking := a.dirty || a.read != nil
	// Blocker details are admin-only. A roster change can revoke access.
	known := a.known && !(a.report != nil && checking)
	ready := known && a.eligibility == .ELIGIBLE && a.advisory == .None
	enabled := known && a.eligibility == .ALREADY_ENABLED
	if nendo.box(nendo.id("InfoLinkedDevices"))(card) {
		if nendo.box(nendo.id_local("Header"))(
		{width = nendo.grow(), gap = 10, align = {y = .Center}},
		) {
			device_emblem(
				enabled && !active ? ICON_CHECK : "\uf0c1",
				ready || enabled ? ACCENT : TEXT_DIM,
			)
			row_labels(
				ready && !active ? tr("Linked devices are ready") : tr("Linked devices"),
				"",
			)
		}
		if active {
			if !pending.settling || checking {
				label :=
					pending.settling ? tr("Checking whether linked devices are on…") : tr("Turning on linked devices…")
				nendo.text(label, {font = FONT_BODY, size = 13, color = TEXT_DIM})
				busy_bar("InfoLinkedDevicesProgress")
			} else {
				text :=
					a.known ? tr("The linked devices change isn't confirmed yet.") : tr("Couldn't check linked devices for this chat. Please try again.")
				nendo.text(text, {font = FONT_BODY, size = 13, color = TEXT_DIM})
				micro_button("RetryAccountDevices", tr("Check status"))
			}
			return
		}
		if !known {
			if checking {
				nendo.text(
					tr("Checking whether this chat supports linked devices…"),
					{font = FONT_BODY, size = 13, color = TEXT_DIM},
				)
				busy_bar("InfoLinkedDevicesProgress")
			} else {
				nendo.text(
					tr("Couldn't check linked devices for this chat. Please try again."),
					{font = FONT_BODY, size = 13, color = TEXT_DIM},
				)
				micro_button("RetryAccountDevices", tr("Retry"))
			}
			return
		}

		status := a.eligibility != .ELIGIBLE ? activation_blocker(a.eligibility) : a.notice
		if status != "" {
			nendo.text(tr(status), {font = FONT_BODY, size = 13, color = TEXT_DIM})
		} else if ready {
			nendo.text(
				tr("Members' linked devices can join without an admin."),
				{font = FONT_BODY, size = 13, color = TEXT_DIM},
			)
		}
		if ready {
			settings_button("EnableAccountDevices", tr("Turn on linked devices"), ACCENT)
		}
		activation_members(ui, a.report)
	}
}
