package main

import "core:fmt"
import "core:strings"

import marmot "../marmot"
import "nendo"
import rl "sdlrl"

@(private = "file")
DEVICE_MODAL_W :: 460
@(private = "file")
DEVICE_MODAL_PAD :: 18
@(private = "file")
DEVICE_SCROLL_GUTTER :: 8

@(private = "file")
device_copy :: proc(text: string, color: nendo.Color = TEXT_DIM) {
	nendo.text(text, {font = FONT_BODY, size = 13, color = color})
}

@(private = "file")
device_roster_ready :: proc(profile: ^Device_Profile) -> bool {
	return profile != nil && .Roster in profile.known && .Roster not_in profile.stale
}

@(private = "file")
device_attempt :: proc(profile: ^Device_Profile) -> ^marmot.New_Device_Link_State {
	return profile != nil && profile.view.link != nil ? profile.view.link.new_device : nil
}

@(private = "file")
device_attempt_live :: proc(attempt: ^marmot.New_Device_Link_State) -> bool {
	return attempt != nil && attempt.tag != .ENDED && attempt.tag != .LINKED
}

@(private = "file")
device_prompts :: proc(profile: ^Device_Profile) -> []marmot.Device_Link_Prompt {
	if profile == nil || profile.view.link == nil || profile.view.link.prompts == nil {return nil}
	return profile.view.link.prompts[:profile.view.link.prompts_len]
}

@(private = "file")
device_request_list :: proc(ui: ^Ui_State, draw: bool) -> bool {
	current := device_current(ui)
	index: u32
	for asking_other in ([2]bool{false, true}) {
		heading := false
		count := asking_other ? len(ui.accounts) : 1
		for i in 0 ..< count {
			account := asking_other ? ui.accounts[i].id_hex : ui.account_ref
			if asking_other && account == ui.account_ref {continue}
			profile := asking_other ? ui.devices.profiles[account] : current
			if profile == nil || (asking_other && !profile.signed_in) || profile.revoked {continue}
			for &prompt in device_prompts(profile) {
				if !device_prompt_attention(&prompt) || string(prompt.prompt_id) == "" {continue}
				if draw {
					if !heading {
						device_heading(asking_other ? tr("Other profiles") : tr("Link requests"))
						heading = true
					}
					if nendo.box(nendo.id("DeviceRequest", index))(
					{
						width = nendo.grow(),
						height = nendo.fit(min = settings_tap_size(48)),
						padding = nendo.pad(12),
						align = {y = .Center},
						gap = 8,
						color = hovered() ? HOVER : mix_color(CARD, ACCENT, 0.09),
						radius = rr(9),
					},
					) {
						row_labels(
							asking_other ? account_label(ui, account) : tr("Review request"),
							device_prompt_text(&prompt.state),
							ACCENT,
						)
						nendo.text("›", {font = FONT_TITLE, size = 18, color = ACCENT})
						if hovered() {cursor_raise(.Pointer)}
					}
				} else if clicked_indexed("DeviceRequest", index) {
					devices_show(
						ui,
						asking_other ? .Other_Profile : .Approve,
						account,
						string(prompt.prompt_id),
					)
					return true
				}
				index += 1
			}
		}
	}
	return false
}

@(private = "file")
device_section :: proc() -> nendo.Box {
	return {width = nendo.grow(), direction = .Column, gap = 8}
}

@(private = "file")
device_list :: proc() -> nendo.Box {
	return {
		width = nendo.grow(),
		direction = .Column,
		color = mix_color(CARD, TEXT, 0.065),
		radius = rr(10),
		border = {color = FIELD_BORDER, width = {between = 1}},
	}
}

@(private = "file")
device_list_row :: proc() -> nendo.Box {
	return {
		width = nendo.grow(),
		height = nendo.fit(min = settings_tap_size(48)),
		padding = {left = 12, right = 12, top = 8, bottom = 8},
		gap = 10,
		align = {y = .Center},
		color = hovered() ? HOVER : {},
		radius = rr(8),
	}
}

@(private = "file")
device_heading :: proc(label: string) {
	nendo.text(label, {font = FONT_TITLE, size = 14, color = TEXT})
}

@(private)
device_emblem :: proc(icon: string, ink: nendo.Color, size: f32 = 32) {
	if nendo.box(nendo.id_local("DeviceEmblem"))(
	{
		width = nendo.fixed(size),
		height = nendo.fixed(size),
		align = {x = .Center, y = .Center},
		color = mix_color(CARD, ink, 0.14),
		radius = rr(8),
	},
	) {
		nendo.text(icon, {font = FONT_ICON, size = 15, color = ink})
	}
}

@(private)
devices_pane :: proc(ui: ^Ui_State) {
	if !devices_visible(ui) {return}
	if ui.devices.unavailable {
		device_copy(tr("Device linking isn't available in this session."))
		return
	}
	profile := device_current(ui)
	device_warnings(profile)
	device_request_list(ui, true)
	if nendo.box(nendo.id("DevicesRoster"))(device_section()) {
		device_heading(tr("Your devices"))
		if nendo.box(nendo.id("DeviceRosterList"))(device_list()) {
			if profile != nil &&
			   .Roster in profile.known &&
			   profile.view.roster != nil &&
			   profile.view.roster.len != 0 {
				device_roster_rows(ui, profile, .Draw)
			} else if nendo.box(nendo.id("EmptyDeviceRoster"))(
			{width = nendo.grow(), direction = .Column, padding = nendo.pad(12), gap = 6},
			) {
				if profile == nil ||
				   (.Roster not_in profile.known && .Roster not_in profile.stale) {
					device_copy(tr("Loading linked devices…"))
					busy_bar("DevicesRosterBusy")
				} else if .Roster not_in profile.stale {
					device_copy(tr("No devices are linked to this profile yet."))
				} else {
					device_copy(tr("Couldn't refresh device information."), DANGER)
				}
			}
		}
		if profile != nil {
			if .Closed_Chats in profile.known && profile.view.closed_chats != 0 {
				device_copy(
					fmt.tprintf(
						tr("Chats that can't add linked devices: %d."),
						profile.view.closed_chats,
					),
				)
			}
			if .Leftover_Chats in profile.known && profile.view.leftover_chats != 0 {
				device_copy(
					fmt.tprintf(
						tr(
							"Chats still holding a device you removed: %d. A chat admin can remove it.",
						),
						profile.view.leftover_chats,
					),
				)
			}
			if profile.stale != {} {
				device_copy(
					tr(
						"Couldn't refresh device information. Previously loaded information may be out of date.",
					),
				)
				settings_button("DevicesRetry", tr("Retry"))
			}
			if profile.action_error != "" {device_copy(profile.action_error, DANGER)}
			if action := device_busy(profile); action != .None && ui.devices.panel == .None {
				device_copy(device_busy_text(action)); busy_bar("DevicesPageBusy")
			}
		}
	}
	if nendo.box(nendo.id("DevicesPairing"))(device_section()) {
		device_heading(tr("Link a device"))
		stacked := settings_body_width(ui) < 480
		if nendo.box(nendo.id("DevicesPairingActions"))(
		{width = nendo.grow(), gap = 10, direction = stacked ? .Column : .Row},
		) {
			device_pair_choice(
				"DevicesAdd",
				tr("Add a new device"),
				tr("Approve from the device with your chats."),
				ACCENT,
			)
			device_pair_choice(
				"DevicesNew",
				tr("Link to another device"),
				tr("Bring chats to this device."),
				TEXT,
			)
		}
		device_moves(ui, profile, .Draw)
		if accounts_have_tombstones(
			ui,
		) {settings_button("DevicesUnlinkedProfiles", tr("Review unlinked profiles"))}
	}
	if profile != nil && nendo.box(nendo.id("DevicesSignIns"))(device_section()) {
		device_heading(tr("Sign-ins"))
		if nendo.box(nendo.id("DevicesSignInList"))(
			device_list(),
		) {device_sign_ins(ui, profile, .Draw)}
	}
}

@(private = "file")
device_pair_choice :: proc(id, title, sub: string, ink: nendo.Color) {
	if nendo.box(nendo.id(id))(
	{
		width = nendo.grow(),
		height = nendo.fit(min = settings_tap_size(66)),
		padding = nendo.pad(12),
		align = {y = .Center},
		gap = 8,
		color = hovered() ? HOVER : mix_color(CARD, TEXT, 0.065),
		radius = rr(9),
		border = kb_focus == id ? kb_ring(ACCENT) : nendo.Border{color = ink == ACCENT ? ACCENT : FIELD_BORDER, width = bw()},
	},
	) {
		row_labels(title, sub, ink)
		nendo.text("›", {font = FONT_TITLE, size = 18, color = ink})
		if hovered() {cursor_raise(.Pointer)}
	}
}

@(private)
handle_devices :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	if !devices_visible(ui) || ui.devices.unavailable {return false}
	profile := device_current(ui)
	if device_busy(profile) != .None {return true}
	if clicked("DevicesRetry") {
		if profile != nil {profile.dirty += profile.stale}
		devices_refresh_open(ui)
		return true
	}
	if clicked("DevicesAdd") {devices_show(ui, .Add); return true}
	if clicked("DevicesNew") {devices_show(ui, .New); return true}
	if clicked("DevicesUnlinkedProfiles") {return devices_open_unlinked(ui)}
	if clicked("DeviceCheckSignIns") {return device_queue(ui, {kind = .Check_Sign_Ins})}
	if clicked("DeviceDismissWarning") &&
	   device_has_warning(profile) {return device_queue(ui, {kind = .Dismiss_Warning})}
	if profile != nil &&
	   clicked("DeviceStartFresh") &&
	   device_can_start_fresh(profile, ui.prefs.sign_ins_recognized[profile.account]) {
		confirm_ask(ui, .Device_Start_Fresh, "")
		return true
	}
	if profile != nil &&
	   clicked("DeviceReset") &&
	   device_command_current(profile, {kind = .Reset}) {
		confirm_ask(ui, .Reset_Devices, "", account_label(ui, profile.account))
		return true
	}
	if device_roster_rows(ui, profile, .Input) || device_moves(ui, profile, .Input) {return true}
	return device_request_list(ui, false) || device_sign_ins(ui, profile, .Input)
}

@(private = "file")
device_end_text :: proc(reason: marmot.Device_Link_End_Reason) -> string {
	switch reason {
	case .CANCELLED:
		return tr("Linking was cancelled.")
	case .CANCELLED_ELSEWHERE:
		return tr("The other device cancelled linking.")
	case .CODES_DIFFER:
		return tr("The codes didn't match. Only link devices whose codes match exactly.")
	case .VERIFICATION_FAILED:
		return tr("White Noise couldn't verify the other device.")
	case .TIMED_OUT:
		return tr("The link request expired.")
	case .ANSWERED_ELSEWHERE:
		return tr("This request was answered on another device.")
	case .CANNOT_LINK:
		return tr("This device can't be linked.")
	case .REJECTED:
		return tr("The other device declined the request.")
	case .LINK_FAILED:
		return tr("White Noise couldn't finish linking the device.")
	}
	return tr("Linking ended.")
}

@(private = "file")
device_prompt_text :: proc(state: ^marmot.Device_Link_Prompt_State) -> string {
	switch state.tag {
	case .PREPARING:
		return tr("Preparing the link request…")
	case .COMPARING:
		return tr("Compare the codes on both devices")
	case .COMPETING_REQUESTS:
		return tr("Several devices are trying to link. Cancel the other attempts to continue.")
	case .RATE_LIMITED:
		return tr("Too many recent attempts. Try again later.")
	case .CANNOT_LINK:
		return tr(
			"This device can't link because it doesn't support everything this profile needs.",
		)
	case .TOO_MANY_DEVICES:
		return tr(
			"This profile has reached its device limit. Unlink an existing device before trying again.",
		)
	case .LINKING:
		return tr("Linking the other device…")
	case .LINKED:
		return tr("Device linked")
	case .ADDED_ELSEWHERE:
		return tr("Another device approved this request.")
	case .ENDED:
		return device_end_text(state.body.ended.reason)
	}
	return tr("Unknown link request state.")
}

@(private = "file")
device_render_code :: proc(code: marmot.Device_Link_Code) -> bool {
	if !device_code_valid(code) {
		device_copy(
			tr("The comparison code is missing or invalid. Don't approve this request."),
			DANGER,
		)
		return false
	}
	if nendo.box(nendo.id("DeviceComparison"))(
	{
		width = nendo.grow(),
		direction = .Column,
		padding = nendo.pad(10),
		gap = 8,
		color = mix_color(CARD, ACCENT, 0.09),
		radius = rr(10),
	},
	) {
		device_heading(tr("Compare the codes on both devices"))
		device_copy(tr("Only link if both screens show the same seven emoji in the same order."))
		glyph_size := modal_w(nendo.id("DeviceModal"), DEVICE_MODAL_W) >= 350 ? f32(40) : f32(32)
		for row in 0 ..< 2 {
			if nendo.box(nendo.id("DeviceCodeRow", u32(row)))(
			{width = nendo.grow(), gap = 6, align = {x = .Center}},
			) {
				for index in (4 * row) ..< min(4 * row + 4, 7) {
					entry := &code.code[index]
					if nendo.box(nendo.id("DeviceCodeEmoji", u32(index)))(
					{
						width = nendo.grow(max = 80),
						padding = {top = 8, bottom = 8, left = 3, right = 3},
						direction = .Column,
						align = {x = .Center},
						gap = 5,
						color = CARD,
						radius = rr(7),
					},
					) {
						nendo.text(
							fmt.tprintf("%d", index + 1),
							{font = FONT_TITLE, size = 11, color = TEXT_DIM},
						)
						emoji := string(entry.emoji)
						if tex := emoji_tex(emoji); tex != nil {
							if nendo.box(nendo.id_local("Glyph"))(
							{width = nendo.fixed(glyph_size), aspect = 1, image = tex},
							) {}
						} else {
							nendo.text(
								emoji,
								{font = FONT_BODY, size = u16(glyph_size - 4), color = TEXT},
							)
						}
						nendo.text(
							string(entry.description),
							{font = FONT_BODY, size = 11, color = TEXT},
						)
					}
				}
			}
		}
	}
	return true
}

@(private = "file")
device_busy_text :: proc(action: Device_Action) -> string {
	switch action {
	case .None:
		return ""
	case .Start:
		return tr("Starting device linking…")
	case .Confirm:
		return tr("Confirming that the codes match…")
	case .Cancel:
		return tr("Cancelling the link attempt…")
	case .Link:
		return tr("Approving the other device…")
	case .Decline:
		return tr("Declining the link request…")
	case .Rename, .Rename_Own:
		return tr("Saving the device name…")
	case .Settings:
		return tr("Saving the device setting…")
	case .Remove_Sibling:
		return tr("Removing the linked device…")
	case .Dismiss_Sibling:
		return tr("Dismissing the device hint…")
	case .Reset:
		return tr("Resetting the device list and publishing a key package…")
	case .Check_Sign_Ins:
		return tr("Checking for sign-ins…")
	case .Answer_Sign_In:
		return tr("Updating the sign-in…")
	case .Start_Fresh:
		return tr("Starting fresh on this device…")
	case .Dismiss_Warning:
		return tr("Dismissing the warning on this device…")
	}
	return ""
}

@(private = "file")
device_modal_title :: proc(panel: Device_Panel) -> string {
	switch panel {
	case .None:
		return ""
	case .Add:
		return tr("Add a new device")
	case .New:
		return tr("Link to another device")
	case .Approve, .Other_Profile:
		return tr("Link a new device?")
	case .Detail:
		return tr("Device details")
	case .Unlinked:
		return tr("Device unlinked")
	case .Auth_Unlinked:
		return tr("Remove unlinked profile?")
	case .Wipe_Report:
		return tr("Sign-out and wipe report")
	case .Offer:
		return tr("Signed in on another device?")
	}
	return ""
}

@(private = "file")
device_panel_prompt :: proc(
	ui: ^Ui_State,
	profile: ^Device_Profile,
) -> ^marmot.Device_Link_Prompt {
	if profile == nil ||
	   ui.devices.panel_account != ui.account_ref ||
	   ui.devices.panel_prompt == "" {return nil}
	return device_find_prompt(profile, ui.devices.panel_prompt)
}

@(private = "file")
device_panel_attempt :: proc(
	ui: ^Ui_State,
	profile: ^Device_Profile,
) -> ^marmot.New_Device_Link_State {
	attempt := device_attempt(profile)
	if attempt != nil &&
	   attempt.tag == .LINKED &&
	   device_move_pending(profile.view.link) {return nil}
	return ui.devices.show_attempt || device_attempt_live(attempt) ? attempt : nil
}

@(private = "file")
device_prepare_move :: proc(profile: ^Device_Profile) -> bool {
	return(
		device_roster_ready(profile) &&
		profile.view.roster != nil &&
		profile.view.roster.len != 0 \
	)
}

@(private = "file")
device_edit_own_name :: proc(profile: ^Device_Profile) -> bool {
	if !device_roster_ready(profile) {return false}
	if own := device_own_slot(profile);
	   own != nil {return strings.trim_space(string(own.label)) == ""}
	return !device_prepare_move(profile)
}

@(private = "file")
device_can_start :: proc(profile: ^Device_Profile) -> bool {
	return device_roster_ready(profile) && .Link in profile.known && .Link not_in profile.stale
}

@(private = "file")
device_can_decline :: proc(prompt: ^marmot.Device_Link_Prompt) -> bool {
	if prompt == nil {return false}
	switch prompt.state.tag {
	case .PREPARING,
	     .COMPARING,
	     .COMPETING_REQUESTS,
	     .RATE_LIMITED,
	     .CANNOT_LINK,
	     .TOO_MANY_DEVICES:
		return true
	case .LINKING, .LINKED, .ADDED_ELSEWHERE, .ENDED:
		return false
	}
	return false
}

@(private = "file")
device_modal_new :: proc(ui: ^Ui_State, profile: ^Device_Profile) {
	attempt := device_panel_attempt(ui, profile)
	moving := attempt == nil && profile != nil && device_live_attempt(profile.view.link)
	if attempt != nil {
		switch attempt.tag {
		case .WAITING_FOR_ANSWER:
			device_copy(
				tr(
					"Waiting for the other device to answer. Open White Noise there to review the request.",
				),
			)
		case .COMPARING:
			if device_render_code(attempt.body.comparing) {
				settings_button(
					"DeviceMatch",
					tr("They match"),
					ACCENT,
					.Link not_in profile.stale ? .Enabled : .Disabled,
				)
				settings_button("DeviceMismatch", tr("They don't match"), DANGER)
			}
		case .WAITING_FOR_OTHER_DEVICE:
			device_copy(
				tr("You confirmed the code. Waiting for the other device to approve the request."),
			)
		case .JOINING:
			device_copy(tr("Joining the other device…"))
			busy_bar("DeviceJoining")
		case .LINKED:
			device_copy(tr("Device linked"), TEXT)
			if device_roster_ready(profile) && device_own_slot(profile) != nil {
				settings_button("DeviceNameThis", tr("Rename this device"))
			}
		case .ENDED:
			device_copy(device_end_text(attempt.body.ended.reason))
		}
	} else if moving {
		device_copy(tr("Waiting to join the other device group…"))
		busy_bar("DeviceMoving")
	} else if ui.devices.show_attempt {
		device_copy(tr("The link attempt ended."))
	} else {
		device_copy(
			tr(
				"Open White Noise on the device that has your chats. Keep both devices online so you can compare the codes they show.",
			),
		)
	}
	if ui.devices.mismatch && !moving && !device_attempt_live(attempt) {
		device_copy(
			tr(
				"If the codes don't match, don't link. Only try again if you control both devices.",
			),
			DANGER,
		)
	}
	if device_attempt_live(attempt) {
		settings_button("DeviceCancel", tr("Cancel linking"))
		if attempt.tag != .COMPARING {settings_button("DeviceClose", tr("Close"))}
		return
	}
	if !moving && (attempt == nil || attempt.tag == .ENDED) {
		if device_prepare_move(profile) {
			device_copy(
				tr(
					"Linking moves only this device. The other devices stay in their current device group.",
				),
			)
			for &prompt in device_prompts(profile) {
				if prompt.state.tag == .LINKING {
					device_copy(
						tr(
							"Another device is still linking. Let it finish before moving this device.",
						),
						DANGER,
					)
					break
				}
			}
			if !ui.devices.move_consent {
				settings_button(
					"DeviceMoveConsent",
					tr("Continue with moving this device"),
					DANGER,
				)
			}
		}
		if !device_prepare_move(profile) || ui.devices.move_consent {
			settings_button(
				"DeviceStart",
				ui.devices.show_attempt ? tr("Try again") : tr("Start linking"),
				ACCENT,
				device_can_start(profile) ? .Enabled : .Disabled,
			)
		}
	}
	settings_button("DeviceClose", tr("Close"))
}

@(private = "file")
device_choice :: proc(id, toggle_id, label: string, on: bool, hint: string = "") {
	if nendo.box(nendo.id(id))(
	{
		width = nendo.grow(),
		height = nendo.fit(min = settings_tap_size(30)),
		padding = {left = 12, right = 12, top = 8, bottom = 8},
		gap = 12,
		align = {y = .Center},
		color = hovered() ? HOVER : {},
		radius = rr(6),
	},
	) {
		if nendo.box(nendo.id_local("ChoiceCopy"))(
		{width = nendo.grow(), direction = .Column, gap = 3},
		) {
			device_copy(label, TEXT)
			if hint != "" {device_copy(hint)}
		}
		toggle(toggle_id, on)
	}
}

@(private = "file")
Device_Pass :: enum {
	Draw,
	Input,
}

@(private = "file")
device_notice :: proc(color: nendo.Color) -> nendo.Box {
	return {
		width = nendo.grow(),
		direction = .Column,
		padding = nendo.pad(12),
		gap = 6,
		color = mix_color(CARD, color, 0.13),
		radius = rr(10),
	}
}

@(private = "file")
device_warnings :: proc(profile: ^Device_Profile) {
	if profile == nil {return}
	if device_has_warning(profile) {
		if nendo.box(nendo.id("DevicesWarning"))(device_notice(DANGER)) {
			nendo.text(
				tr("Someone may have your private key"),
				{font = FONT_TITLE, size = 16, color = DANGER},
			)
			list := profile.view.warning
			for item in list.items[:list.len] {
				pattern := N_("Unrecognized activity: %s.")
				#partial switch item.reason {
				case .REJECTED_SIGN_IN:
					pattern = N_("A sign-in was marked as not you: %s.")
				case .FOREIGN_OWN_SLOT_KEY_PACKAGE:
					pattern = N_(
						"A key package this device didn't make was found and replaced: %s.",
					)
				}
				device_copy(
					fmt.tprintf(
						tr(pattern),
						timestamp_label(i64(item.occurred_at), .SHORT_DATE_TIME, 0),
					),
				)
			}
			device_copy(tr("Dismissing this warning only affects this device."))
			settings_button(
				"DeviceDismissWarning",
				tr("Dismiss"),
				DANGER,
				.Warning in profile.stale ? .Disabled : .Enabled,
			)
		}
	}
	if device_command_current(profile, {kind = .Reset}) {
		if nendo.box(nendo.id("DevicesStalled"))(device_notice(WARNING)) {
			device_heading(tr("This device can't catch up with your other devices."))
			settings_button("DeviceReset", tr("Reset and link again"), DANGER)
		}
	}
	if .Overdue in profile.known && profile.view.overdue {
		if nendo.box(nendo.id("DevicesOverdue"))(device_notice(WARNING)) {
			nendo.text(
				tr("Key package refresh overdue"),
				{font = FONT_TITLE, size = 15, color = WARNING},
			)
			device_copy(
				tr(
					"Keep White Noise open and online so your devices can sync. If this continues, people may not be able to add this device to chats.",
				),
			)
		}
	}
}

@(private = "file")
device_sign_in_state :: proc(row: marmot.Unrecognized_Sign_In) -> string {
	switch row.state {
	case .PROMPT:
		return row.before_this_device ? tr("Signed in before this device") : tr("New sign-in")
	case .NOT_NOW:
		return tr("Review postponed")
	case .LINKED_ELSEWHERE:
		return tr("Linked on another device")
	case .REJECTED_ELSEWHERE:
		return tr("Rejected on another device")
	}
	return tr("Unrecognized sign-in")
}

@(private = "file")
device_sign_ins :: proc(ui: ^Ui_State, profile: ^Device_Profile, pass: Device_Pass) -> bool {
	if profile == nil {return false}
	items: []marmot.Unrecognized_Sign_In
	if list := profile.view.sign_ins; list != nil {items = list.items[:list.len]}
	d := &ui.devices
	reviewed := ui.prefs.sign_ins_recognized[profile.account]
	for row, i in items {
		client := string(row.client)
		if client == "" {client = tr("Unknown app")}
		unresolved := row.state == .PROMPT || row.state == .NOT_NOW
		slot := string(row.slot_id_hex)
		seen, found := reviewed[slot]
		recognized := unresolved && found && seen == row.appeared_at
		expanded :=
			slot != "" && slot == d.expanded_sign_in && row.appeared_at == d.expanded_sign_in_at
		if pass == .Draw {
			if nendo.box(nendo.id("DeviceSignIn", u32(i)))(device_list_row()) {
				device_emblem(
					recognized ? ICON_CHECK : unresolved ? ICON_KEY : ICON_INFO,
					recognized ? ACCENT : unresolved ? WARNING : TEXT_DIM,
				)
				if nendo.box(nendo.id("DeviceSignInText", u32(i)))(
				{width = nendo.grow(), direction = .Column, gap = 2},
				) {
					device_heading(
						recognized ? tr("Recognized on this device. Not linked.") : device_sign_in_state(row),
					)
					device_copy(
						row.appeared_at == 0 ? client : fmt.tprintf("%s · %s", client, timestamp_label(i64(row.appeared_at), .SHORT_DATE_TIME, 0)),
					)
				}
				if slot !=
				   "" {nendo.text(expanded ? "⌄" : "›", {font = FONT_TITLE, size = 18, color = TEXT_DIM})}
			}
		} else if slot != "" && clicked_indexed("DeviceSignIn", u32(i)) {
			delete(d.expanded_sign_in, reload_allocator())
			d.expanded_sign_in = expanded ? "" : strings.clone(slot, reload_allocator())
			d.expanded_sign_in_at = row.appeared_at
			return true
		}
		if !expanded {continue}
		link, recognize, not_now, reject, dismiss :=
			fmt.tprintf("SignInLink%d", i),
			fmt.tprintf("SignInRecognize%d", i),
			fmt.tprintf("SignInLater%d", i),
			fmt.tprintf("SignInReject%d", i),
			fmt.tprintf("SignInDismiss%d", i)
		if pass == .Draw {
			if nendo.box(nendo.id("SignInActions", u32(i)))(
			{width = nendo.grow(), direction = .Column, padding = nendo.pad(12), gap = 6},
			) {
				if !row.signed_in {device_copy(tr("Signed out"))}
				if row.previously_linked_here {device_copy(tr("Previously linked on this device"))}
				if unresolved {
					settings_button(link, tr("Link this device"))
					if !recognized {
						settings_button(
							recognize,
							tr("This was me, don't link"),
							ACCENT,
							.Sign_Ins in profile.stale ? .Disabled : .Enabled,
						)
						if row.state == .PROMPT {settings_button(not_now, tr("Not now"))}
					}
					settings_button(reject, tr("This wasn't me"), DANGER)
				} else {
					settings_button(dismiss, tr("Dismiss"))
				}
			}
		} else {
			if unresolved && clicked(link) {devices_show(ui, .Add); return true}
			if unresolved && !recognized && .Sign_Ins not_in profile.stale && clicked(recognize) {
				context.allocator = reload_allocator()
				if reviewed == nil {
					ui.prefs.sign_ins_recognized[strings.clone(profile.account)] = make(
						map[string]u64,
					)
				}
				slots := &ui.prefs.sign_ins_recognized[profile.account]
				if !found {slot = strings.clone(slot)}
				slots^[slot] = row.appeared_at
				ui.settings_dirty = true
				return true
			}
			if row.state == .PROMPT &&
			   !recognized &&
			   clicked(
				   not_now,
			   ) {return device_queue(ui, {kind = .Answer_Sign_In, slot = slot, response = .NOT_NOW})}
			if unresolved && clicked(reject) {
				confirm_ask(ui, .Reject_Sign_In, slot, client)
				return true
			}
			if !unresolved &&
			   clicked(
				   dismiss,
			   ) {return device_queue(ui, {kind = .Answer_Sign_In, slot = slot, response = .DISMISS})}
		}
	}
	if pass == .Draw &&
	   nendo.box(nendo.id("DevicesSignInFooter"))(
	   {width = nendo.grow(), direction = .Column, gap = 8, padding = nendo.pad(12)},
	   ) {
		if profile.view.started_fresh {device_copy(tr("Only future invitations will appear here until you link this device."))}
		if nendo.box(nendo.id("DevicesSignInChecks"))(settings_row(stacked = true)) {
			if len(items) == 0 && .Sign_Ins in profile.known && .Sign_Ins not_in profile.stale {
				if nendo.box(nendo.id_local("SignInSummary"))({width = nendo.grow()}) {
					device_copy(tr("No sign-ins to review."))
				}
			}
			settings_button("DeviceCheckSignIns", tr("Check now"))
			if device_can_start_fresh(
				profile,
				reviewed,
			) {settings_button("DeviceStartFresh", tr("No, start fresh"))}
		}
	}
	return false
}

@(private = "file")
device_status_text :: proc(row: ^marmot.Linked_Device) -> string {
	if row.removal_pending {return tr("Removal pending")}
	if row.inactive && row.status == .ACTIVE {return tr("Inactive")}
	switch row.status {
	case .ACTIVE:
		return tr("Active")
	case .INACTIVE:
		return tr("Inactive")
	case .LEAVING:
		return tr("Signing out")
	case .MOVED:
		return tr("Moved to another device group")
	}
	return ""
}

@(private = "file")
device_roster_rows :: proc(ui: ^Ui_State, profile: ^Device_Profile, pass: Device_Pass) -> bool {
	if profile == nil || profile.view.roster == nil {return false}
	roster := profile.view.roster
	for own in ([2]bool{true, false}) {
		for &row, i in roster.items[:roster.len] {
			if row.is_this_device != own {continue}
			index := u32(i)
			keep :=
				!own &&
				(row.inactive || row.status == .INACTIVE) &&
				!row.keep_while_inactive &&
				!row.removal_pending
			if pass == .Draw {
				if nendo.box(nendo.id("DeviceRosterRow", index))(device_list_row()) {
					device_emblem(
						device_hardware_icon(string(row.platform)),
						own ? ACCENT : TEXT_DIM,
					)
					if nendo.box(nendo.id("DeviceRosterText", index))(
					{width = nendo.grow(), direction = .Column, gap = 2},
					) {
						device_heading(device_label(&row))
						status := device_status_text(&row)
						if row.status == .ACTIVE && !row.inactive && !row.removal_pending {
							if own {
								if platform := string(row.platform);
								   platform != "" {status = platform}
							} else if row.has_last_active_at {
								status = fmt.tprintf(
									tr("Last active: %s"),
									timestamp_label(i64(row.last_active_at), .SHORT_DATE_TIME, 0),
								)
							}
						}
						device_copy(status)
					}
					if own {
						if nendo.box(nendo.id_local("ThisDeviceBadge"))(
						{
							padding = {left = 8, right = 8, top = 3, bottom = 3},
							color = mix_color(CARD, ACCENT, 0.14),
							radius = rr(9),
						},
						) {
							nendo.text(
								tr("This device"),
								{font = FONT_TITLE, size = 10, color = ACCENT},
							)
						}
					}
					if keep {settings_button(fmt.tprintf("DeviceKeep%d", i), tr("Keep"))}
					nendo.text("›", {font = FONT_TITLE, size = 18, color = TEXT_DIM})
					if hovered() {cursor_raise(.Pointer)}
				}
			} else if keep &&
			   clicked(fmt.tprintf("DeviceKeep%d", i)) &&
			   device_roster_ready(profile) {
				return device_queue(
					ui,
					{
						kind = .Settings,
						slot = string(row.slot_id_hex),
						setting = .Keep,
						setting_value = true,
					},
				)
			} else if clicked_indexed("DeviceRosterRow", index) {
				devices_show_detail(ui, &row)
				return true
			}
		}
	}
	return false
}

@(private = "file")
device_hardware_icon :: proc(platform: string) -> string {
	return(
		strings.equal_fold(platform, "Android") || strings.equal_fold(platform, "iOS") ? "\uf10b" : "\uf108" \
	)
}

@(private = "file")
device_moves :: proc(ui: ^Ui_State, profile: ^Device_Profile, pass: Device_Pass) -> bool {
	if profile == nil || profile.view.link == nil {return false}
	link := profile.view.link
	if pass == .Draw && link.moves_len != 0 {device_heading(tr("Moving this device"))}
	index := 0
	for move in link.moves[:link.moves_len] {
		if pass == .Draw {
			#partial switch move.state {
			case .WAITING_FOR_WELCOME:
				device_copy(tr("Waiting to join your other device group."))
			case .JOINING:
				device_copy(tr("Joining your other device group…"))
			case .MADE:
				device_copy(tr("Moved to your other device group."), TEXT)
			case .FAILED:
				device_copy(
					tr("Couldn't move to your other device group. Try linking again."),
					DANGER,
				)
			}
		}
		for sibling in move.old_siblings[:move.old_siblings_len] {
			if !sibling.question_suppressed {continue}
			id := fmt.tprintf("DeviceDismissMove%d", index)
			if pass == .Draw {
				label := string(sibling.label)
				if label == "" {label = tr("Unnamed device")}
				device_copy(
					fmt.tprintf(
						tr("%s is still in your old device list. Link it from that device."),
						label,
					),
				)
				settings_button(id, tr("Dismiss"))
			} else if clicked(id) {
				return device_queue(
					ui,
					{
						kind = .Dismiss_Sibling,
						move_id = string(move.move_id),
						slot = string(sibling.slot_id_hex),
					},
				)
			}
			index += 1
		}
	}
	return false
}

@(private = "file")
device_detail :: proc(ui: ^Ui_State, profile: ^Device_Profile, row: ^marmot.Linked_Device) {
	if row == nil {
		device_copy(tr("This device is no longer in your device list."))
		settings_button("DeviceClose", tr("Close"))
		return
	}
	if row.is_this_device {device_copy(tr("This device"))}
	platform, client := string(row.platform), string(row.client)
	if platform != "" && client != "" && platform != client {
		device_copy(fmt.tprintf("%s · %s", platform, client))
	} else if platform != "" || client != "" {
		device_copy(platform != "" ? platform : client)
	}
	device_copy(device_status_text(row))
	if row.has_last_active_at {
		device_copy(
			fmt.tprintf(
				tr("Last active: %s"),
				timestamp_label(i64(row.last_active_at), .SHORT_DATE_TIME, 0),
			),
		)
	}
	if row.linked_at !=
	   0 {device_copy(fmt.tprintf(tr("Linked: %s"), timestamp_label(i64(row.linked_at), .SHORT_DATE_TIME, 0)))}
	if by := device_find_slot(profile, string(row.linked_by_slot_id_hex)); by != nil {
		device_copy(fmt.tprintf(tr("Linked by: %s"), device_label(by)))
	}
	editable := device_roster_ready(profile) && row.status != .LEAVING && !row.removal_pending
	if !editable {
		if !device_roster_ready(profile) {settings_button("DeviceModalRetry", tr("Retry"))}
		settings_button("DeviceClose", tr("Close"))
		return
	}
	device_copy(tr("Device name"), TEXT)
	gate_field(
		ui,
		"DeviceName",
		&ui.devices.name,
		ui.focus == .Device_Name,
		tr("Unnamed device"),
		.Plain,
	)
	name := strings.trim_space(string(ui.devices.name[:]))
	if name != "" &&
	   !device_name_valid(
			   name,
		   ) {device_copy(tr("Use at most 64 bytes for the device name."), DANGER)}
	valid := name != string(row.label) && (name == "" || device_name_valid(name))
	settings_button("DeviceSaveName", tr("Save name"), ACCENT, valid ? .Enabled : .Disabled)
	if nendo.box(nendo.id("DeviceDetailOptions"))(device_list()) {
		device_choice(
			"DeviceDetailAdd",
			"DeviceDetailAddToggle",
			tr("Add to all chats"),
			row.add_to_all_chats,
			tr("Turning this off doesn't leave any chats."),
		)
		device_choice(
			"DeviceDetailHistory",
			"DeviceDetailHistoryToggle",
			tr("Bring chat history"),
			row.bring_history,
			tr("Turning this on doesn't bring history to chats this device already joined."),
		)
		device_choice(
			"DeviceDetailKeep",
			"DeviceDetailKeepToggle",
			tr("Keep while inactive"),
			row.keep_while_inactive,
		)
	}
	if !row.is_this_device {settings_button("DeviceRemoveSibling", tr("Remove device"), DANGER)}
	settings_button("DeviceClose", tr("Close"))
}

@(private = "file")
handle_device_detail :: proc(ui: ^Ui_State, profile: ^Device_Profile) {
	row := device_find_slot(profile, ui.devices.panel_slot)
	if row == nil ||
	   !device_roster_ready(profile) ||
	   row.status == .LEAVING ||
	   row.removal_pending {return}
	if field_mouse(ui, &ui.devices.name, "DeviceName", 15) ||
	   rl.IsKeyPressed(.TAB) {ui.focus = .Device_Name}
	if ui.focus == .Device_Name {edit_text(ui, &ui.devices.name)}
	slot := ui.devices.panel_slot
	if clicked("DeviceRemoveSibling") && !row.is_this_device {
		confirm_ask(ui, .Remove_Linked_Device, slot, device_label(row))
	} else if clicked("DeviceSaveName") {
		name := strings.trim_space(string(ui.devices.name[:]))
		if name != string(row.label) && (name == "" || device_name_valid(name)) {
			device_queue(ui, {kind = .Rename, slot = slot, name = name})
		}
	} else if clicked("DeviceDetailAdd") {
		device_queue(
			ui,
			{
				kind = .Settings,
				slot = slot,
				setting = .Add_To_Chats,
				setting_value = !row.add_to_all_chats,
			},
		)
	} else if clicked("DeviceDetailHistory") {
		device_queue(
			ui,
			{
				kind = .Settings,
				slot = slot,
				setting = .History,
				setting_value = !row.bring_history,
			},
		)
	} else if clicked("DeviceDetailKeep") {
		device_queue(
			ui,
			{
				kind = .Settings,
				slot = slot,
				setting = .Keep,
				setting_value = !row.keep_while_inactive,
			},
		)
	}
}

@(private = "file")
device_modal_approve :: proc(
	ui: ^Ui_State,
	profile: ^Device_Profile,
	prompt: ^marmot.Device_Link_Prompt,
) {
	if prompt == nil {
		device_copy(tr("This request is no longer active."))
		settings_button("DeviceClose", tr("Close"))
		return
	}
	state := &prompt.state
	if state.tag != .COMPARING {device_copy(device_prompt_text(state), TEXT)}
	#partial switch state.tag {
	case .COMPARING:
		if device_render_code(state.body.comparing) {
			device_copy(tr("New device name"))
			gate_field(
				ui,
				"DeviceName",
				&ui.devices.name,
				ui.focus == .Device_Name,
				tr("New device"),
				.Plain,
			)
			own_name := device_edit_own_name(profile)
			if own_name {
				device_copy(tr("Name for this device"))
				gate_field(
					ui,
					"DeviceOwnName",
					&ui.devices.own_name,
					ui.focus == .Device_Own_Name,
					tr("This device"),
					.Plain,
				)
			}
			if nendo.box(nendo.id("DeviceApproveOptions"))(device_list()) {
				device_choice(
					"DeviceAddToChats",
					"DeviceAddToChatsToggle",
					tr("Add to all chats"),
					ui.devices.add_to_all,
				)
				device_choice(
					"DeviceBringHistory",
					"DeviceBringHistoryToggle",
					tr("Bring chat history"),
					ui.devices.bring_history,
				)
			}
			names_valid :=
				device_name_valid(strings.trim_space(string(ui.devices.name[:]))) &&
				(!own_name ||
						device_name_valid(strings.trim_space(string(ui.devices.own_name[:]))))
			if !names_valid {device_copy(tr("Enter a name of 1 to 64 UTF-8 bytes for each device."), DANGER)}
			device_copy(
				tr(
					"A different code can mean someone else is trying to link. Don't approve unless both codes match exactly.",
				),
			)
			later, mismatch, match :=
				tr("Not now"), tr("They don't match"), tr("They match, link device")
			gap :: 8
			width :=
				modal_w(nendo.id("DeviceModal"), DEVICE_MODAL_W) -
				2 * DEVICE_MODAL_PAD -
				DEVICE_SCROLL_GUTTER
			button_w :: proc(label: string) -> f32 {return max(
					56,
					24 + rl.MeasureTextLine(FONT_BODY, 12, label, 0).x,
				)}
			secondary_w := button_w(later) + gap + button_w(mismatch)
			stacked := secondary_w + gap + button_w(match) > width
			enabled :=
				names_valid && device_can_start(profile) ? Settings_Control_State.Enabled : .Disabled
			if nendo.box(nendo.id("DeviceApprovalActions"))(
			{
				width = nendo.grow(),
				gap = gap,
				direction = stacked ? .Column : .Row,
				align = {x = .Right},
			},
			) {
				if stacked {settings_button("DeviceLink", match, ACCENT, enabled)}
				if nendo.box(nendo.id_local("Secondary"))(
				{
					gap = gap,
					direction = secondary_w > width ? .Column : .Row,
					align = {x = .Right},
				},
				) {
					settings_button("DeviceDecline", later)
					settings_button("DeviceMismatch", mismatch, DANGER)
				}
				if !stacked {settings_button("DeviceLink", match, ACCENT, enabled)}
			}
			return
		}
	case .RATE_LIMITED:
		if retry := state.body.rate_limited.retry_at; retry != 0 {
			device_copy(
				fmt.tprintf(
					tr("Try again after %s."),
					timestamp_label(i64(retry), .LONG_DATE_TIME, 0),
				),
			)
		}
	case .CANNOT_LINK:
		if missing := state.body.cannot_link; missing.missing != nil && missing.missing_len != 0 {
			device_copy(tr("Missing capabilities:"))
			for capability in missing.missing[:missing.missing_len] {device_copy(string(capability))}
		}
	case .LINKING:
		busy_bar("DeviceApprovalLinking")
	case .ADDED_ELSEWHERE:
		elsewhere := state.body.added_elsewhere
		device := string(elsewhere.device_label)
		by := string(elsewhere.added_by_label)
		if device == "" {device = tr("Unnamed device")}
		if by == "" {by = tr("Unnamed device")}
		device_copy(fmt.tprintf(tr("%s was linked by %s."), device, by))
	}
	if ui.devices.mismatch && !device_can_decline(prompt) {
		device_copy(
			tr(
				"If the codes don't match, don't link. Only try again if you control both devices.",
			),
			DANGER,
		)
	}
	if device_can_decline(prompt) {
		settings_button("DeviceDecline", tr("Not now"))
	} else {
		settings_button("DeviceClose", tr("Close"))
	}
}

@(private = "file")
device_root_panel :: proc(panel: Device_Panel) -> bool {
	return panel == .Unlinked || panel == .Auth_Unlinked || panel == .Wipe_Report
}

@(private = "file")
device_root_content :: proc(ui: ^Ui_State) {
	d := &ui.devices
	if d.panel == .Wipe_Report {
		device_copy(d.wipe_report, d.wipe_report_error ? WARNING : TEXT)
		settings_button("DeviceClose", tr("Close"))
		return
	}
	if account_departing(d.panel_account) {
		device_copy(tr("Removing the profile from this device…"), TEXT)
		busy_bar("UnlinkedProfileBusy")
		return
	}
	profile := d.profiles[d.panel_account]
	name :=
		profile == nil || profile.unlink_label == "" ? short_hex(d.panel_account) : profile.unlink_label
	if d.panel == .Auth_Unlinked {
		device_copy(
			fmt.tprintf(
				tr(
					"%s was unlinked from this device. Remove its local keys and chats before signing in again. Other devices keep their chats.",
				),
				name,
			),
		)
		settings_button("DeviceWipeSignIn", tr("Remove and sign in"), DANGER)
		settings_button("DeviceClose", tr("Cancel"))
	} else {
		device_copy(
			fmt.tprintf(
				tr(
					"Another device removed this one from %s. This device no longer gets that profile's messages.",
				),
				name,
			),
		)
		if account_revoked(
			ui,
			d.panel_account,
		) {settings_button("DeviceWipe", tr("Remove from this device"), DANGER)}
		settings_button("DeviceClose", tr("Later"))
	}
}

@(private = "file")
handle_device_root :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	d := &ui.devices
	if account_departing(d.panel_account) {return}
	close := clicked("DeviceClose") || rl.IsKeyPressed(.ESCAPE)
	#partial switch d.panel {
	case .Unlinked:
		if close {devices_notice_closed(ui); return}
		if clicked("DeviceWipe") && account_revoked(ui, d.panel_account) {
			label := d.profiles[d.panel_account].unlink_label
			confirm_ask(ui, .Wipe_Unlinked, d.panel_account, label)
		}
	case .Auth_Unlinked:
		if close {auth_unlink_cancel(ui); return}
		if clicked("DeviceWipeSignIn") {auth_wipe_start(ui, client)}
	case .Wipe_Report:
		if close {
			delete(d.wipe_report, reload_allocator()); d.wipe_report = ""
			devices_notice_closed(ui)
		}
	case:
	}
}

@(private)
devices_modal :: proc(ui: ^Ui_State) {
	panel := ui.devices.panel
	if !MULTI_DEVICE ||
	   panel == .None ||
	   (!devices_visible(ui) && !device_root_panel(panel)) {return}
	profile := device_current(ui)
	detail := panel == .Detail ? device_find_slot(profile, ui.devices.panel_slot) : nil
	if nendo.box(nendo.id("DeviceModal"))(
	{
		direction = .Column,
		width = nendo.fixed(modal_w(nendo.id("DeviceModal"), DEVICE_MODAL_W)),
		height = nendo.fit(max = modal_h(1200)),
		padding = nendo.pad(DEVICE_MODAL_PAD),
		gap = 10,
		floating = {
			attach_to = .Root,
			z = 12,
			offset = {0, rise(nendo.id("DeviceModal"))},
			attach = {element = .Center_Center, parent = .Center_Center},
		},
		color = CARD,
		radius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if nendo.box(nendo.id_local("Header"))(
		{width = nendo.grow(), gap = 10, align = {y = .Center}},
		) {
			icon, color := "\uf0c1", ACCENT
			if detail != nil {icon = device_hardware_icon(string(detail.platform))}
			if device_root_panel(panel) {icon, color = ICON_INFO, WARNING}
			device_emblem(icon, color)
			if nendo.box(nendo.id_local("Title"))({width = nendo.grow()}) {
				nendo.text(
					detail != nil ? device_label(detail) : device_modal_title(panel),
					{font = FONT_TITLE, size = 18, color = TEXT},
				)
			}
		}
		if nendo.box(nendo.id("DeviceModalBody"))(
		{
			width = nendo.grow(),
			height = nendo.fit(max = max(1, modal_h(1200) - 80)),
			direction = .Column,
			gap = 10,
			padding = {right = DEVICE_SCROLL_GUTTER},
			clip = {y = true, scroll = true},
		},
		) {
			scrollbar(nendo.id("DeviceModalBody"), 13)
			if ui.devices.error != "" {device_copy(ui.devices.error, DANGER)}
			if device_root_panel(panel) {
				device_root_content(ui)
			} else if ui.devices.unavailable {
				device_copy(tr("Device linking isn't available in this session."))
				settings_button("DeviceClose", tr("Close"))
			} else if panel == .Other_Profile {
				device_copy(
					fmt.tprintf(
						tr("A device is asking to link to %s."),
						account_label(ui, ui.devices.panel_account),
					),
				)
				if ui.devices.review_account != "" {
					device_copy(tr("Switching profiles and checking the request…"))
					busy_bar("DeviceReviewBusy")
				} else {
					settings_button("DeviceReview", tr("Review"), ACCENT)
					settings_button("DeviceClose", tr("Not now"))
				}
			} else if ui.devices.panel_account != ui.account_ref {
				device_copy(tr("This request is no longer active."))
				settings_button("DeviceClose", tr("Close"))
			} else if action := device_busy(profile); action != .None {
				device_copy(device_busy_text(action), TEXT)
				busy_bar("DeviceActionBusy")
			} else {
				if profile != nil &&
				   profile.action_error != "" {device_copy(profile.action_error, DANGER)}
				if profile != nil && (panel == .New || panel == .Approve) {
					if .Link in profile.stale || .Roster in profile.stale {
						device_copy(tr("Couldn't refresh device information."), DANGER)
						settings_button("DeviceModalRetry", tr("Retry"))
					} else if !device_can_start(profile) {
						device_copy(tr("Checking device information…"))
						busy_bar("DeviceChecking")
					}
				}
				#partial switch panel {
				case .Add:
					device_copy(
						tr(
							"Linking starts on the new device. Keep White Noise open here while you set it up.",
						),
					)
					if nendo.box(nendo.id("DeviceSetupSteps"))(device_notice(ACCENT)) {
						device_copy(
							tr(
								"1. Install White Noise on the other device and sign in to this profile.",
							),
							TEXT,
						)
						device_copy(
							tr(
								"2. Open Settings → Devices there and choose Link to another device.",
							),
							TEXT,
						)
						device_copy(
							tr(
								"3. When the request appears here, check that both screens show the same emoji.",
							),
							TEXT,
						)
					}
					if account_local(
						ui,
					) {settings_button("DeviceShowKeys", tr("Show this profile's keys"))}
					if device_checking_link(profile) {
						device_copy(tr("Checking device information…"))
						busy_bar("DeviceChecking")
					} else if .Link in profile.stale {
						device_copy(tr("Couldn't refresh device information."), DANGER)
						settings_button("DeviceCheckRequest", tr("Retry"))
					} else {
						device_copy(tr("Waiting for a link request…"))
						settings_button("DeviceCheckRequest", tr("Check now"))
					}
					settings_button("DeviceClose", tr("Close"))
				case .New:
					device_modal_new(ui, profile)
				case .Approve:
					device_modal_approve(ui, profile, device_panel_prompt(ui, profile))
				case .Detail:
					device_detail(ui, profile, detail)
				case .Offer:
					device_copy(
						tr(
							"Link this device to the one that has your chats. You’ll compare the same seven emoji on both screens.",
						),
					)
					if device_earlier_sign_in(
						ui,
						profile,
					) {settings_button("DeviceLinkOffer", tr("Link this device"), ACCENT)}
					settings_button("DeviceClose", tr("Not now"))
				}
			}
		}
	}
}

@(private)
handle_device_modal :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	panel := ui.devices.panel
	if device_root_panel(panel) {handle_device_root(ui, client); return}
	if !devices_visible(ui) || panel == .None {return}
	escape := rl.IsKeyPressed(.ESCAPE)
	close := clicked("DeviceClose")
	if ui.devices.unavailable {
		if close || escape {devices_put_away(ui)}
		return
	}
	if panel == .Other_Profile {
		if ui.devices.review_account != "" {return}
		if clicked("DeviceReview") {devices_review(ui, client)}
		if close || escape {devices_put_away(ui)}
		return
	}
	if ui.devices.panel_account != ui.account_ref {
		if close || escape {devices_put_away(ui)}
		return
	}
	profile := device_current(ui)
	if device_busy(profile) != .None {return}
	if clicked("DeviceModalRetry") {
		if profile != nil {profile.dirty += profile.stale & {.Link, .Roster}}
		return
	}
	#partial switch panel {
	case .Add:
		if !device_checking_link(profile) && clicked("DeviceCheckRequest") {
			profile.dirty += {.Link}
		} else if account_local(ui) && clicked("DeviceShowKeys") {
			devices_put_away(ui)
			settings_open(ui, client, .Keys, anchor = "RowReveal")
		} else if close || escape {devices_put_away(ui)}
	case .New:
		attempt := device_panel_attempt(ui, profile)
		if device_attempt_live(attempt) {
			comparing := attempt.tag == .COMPARING
			mismatch :=
				comparing && device_code_valid(attempt.body.comparing) && clicked("DeviceMismatch")
			if mismatch || clicked("DeviceCancel") {
				device_queue(ui, {kind = .Cancel, mismatch = mismatch})
			} else if comparing &&
			   .Link not_in profile.stale &&
			   device_code_valid(attempt.body.comparing) &&
			   clicked("DeviceMatch") {
				device_queue(ui, {kind = .Confirm})
			} else if !comparing && (close || escape) {
				devices_put_away(ui)
			}
			return
		}
		if close || escape {devices_put_away(ui); return}
		if attempt != nil && attempt.tag == .LINKED {
			if clicked("DeviceNameThis") &&
			   device_roster_ready(profile) {devices_show_detail(ui, device_own_slot(profile))}
			return
		}
		if profile != nil && device_live_attempt(profile.view.link) {return}
		if device_prepare_move(profile) && !ui.devices.move_consent {
			if clicked("DeviceMoveConsent") {ui.devices.move_consent = true}
		} else if device_can_start(profile) && clicked("DeviceStart") {
			device_queue(ui, {kind = .Start})
		}
	case .Detail:
		if close || escape {devices_put_away(ui); return}
		handle_device_detail(ui, profile)
	case .Offer:
		if profile == nil {devices_close(ui); return}
		if close || escape {
			profile.first_import = false
			devices_close(ui)
		} else if clicked("DeviceLinkOffer") &&
		   device_earlier_sign_in(ui, profile) &&
		   device_queue(ui, {kind = .Start}) {
			profile.first_import = false
			devices_show(ui, .New)
		}
	case .Approve:
		prompt := device_panel_prompt(ui, profile)
		if !device_can_decline(prompt) {
			if close || escape {devices_put_away(ui)}
			return
		}
		if clicked("DeviceDecline") {
			device_queue(ui, {kind = .Decline, prompt = ui.devices.panel_prompt})
			return
		}
		if prompt.state.tag != .COMPARING {
			if escape {devices_put_away(ui)}
			return
		}
		if !device_code_valid(prompt.state.body.comparing) {return}
		if clicked("DeviceMismatch") {
			device_queue(ui, {kind = .Decline, prompt = ui.devices.panel_prompt, mismatch = true})
			return
		}
		own_name := device_edit_own_name(profile)
		if !own_name && ui.focus == .Device_Own_Name {ui.focus = .Compose}
		if field_mouse(ui, &ui.devices.name, "DeviceName", 15) {ui.focus = .Device_Name}
		if own_name &&
		   field_mouse(ui, &ui.devices.own_name, "DeviceOwnName", 15) {ui.focus = .Device_Own_Name}
		if rl.IsKeyPressed(.TAB) {
			ui.focus =
				own_name && (ui.focus == .Device_Name || (ui.focus != .Device_Own_Name && shift_down())) ? .Device_Own_Name : .Device_Name
			onboard_reveal_field(
				"DeviceModalBody",
				ui.focus == .Device_Own_Name ? "DeviceOwnName" : "DeviceName",
			)
		}
		#partial switch ui.focus {
		case .Device_Name:
			edit_text(ui, &ui.devices.name)
		case .Device_Own_Name:
			edit_text(ui, &ui.devices.own_name)
		}
		if clicked("DeviceAddToChats") {ui.devices.add_to_all = !ui.devices.add_to_all}
		if clicked("DeviceBringHistory") {ui.devices.bring_history = !ui.devices.bring_history}
		if clicked("DeviceLink") && device_can_start(profile) {
			name := strings.trim_space(string(ui.devices.name[:]))
			own := own_name ? strings.trim_space(string(ui.devices.own_name[:])) : ""
			if device_name_valid(name) && (!own_name || device_name_valid(own)) {
				device_queue(
					ui,
					{
						kind = .Link,
						prompt = ui.devices.panel_prompt,
						name = name,
						own_name = own,
						add_to_all = ui.devices.add_to_all,
						bring_history = ui.devices.bring_history,
					},
				)
			}
		}
	}
}

@(private)
devices_banner :: proc(ui: ^Ui_State) {
	if !devices_visible(ui) || ui.devices.unavailable {return}
	warning := device_has_warning(device_current(ui))
	if !warning && ui.devices.panel != .None {return}
	panel, _, _ := device_attention(ui)
	if !warning && panel == .None {return}
	label := warning ? tr("Someone may have your private key") : device_modal_title(panel)
	if !warning && panel == .New {label = tr("Resume device linking")}
	if nendo.box(nendo.id("DeviceAttentionBanner"))(
	{
		width = nendo.grow(),
		height = nendo.fit(min = settings_tap_size(36)),
		padding = {left = 12, right = 12, top = 6, bottom = 6},
		gap = 8,
		align = {y = .Center},
		color = hovered() ? HOVER : CARD,
	},
	) {
		ink := warning ? DANGER : ACCENT
		device_emblem(warning ? ICON_LOCK : "\uf0c1", ink, 26)
		if nendo.box(nendo.id_local("AttentionLabel"))({width = nendo.grow()}) {
			nendo.text(label, {font = FONT_TITLE, size = 13, color = ink})
		}
		nendo.text("›", {font = FONT_TITLE, size = 17, color = ink})
	}
}

@(private)
handle_devices_banner :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	if !devices_visible(ui) ||
	   ui.devices.unavailable ||
	   ui.devices.panel != .None ||
	   !clicked("DeviceAttentionBanner") {return false}
	if device_has_warning(device_current(ui)) {
		settings_open(ui, client, .Devices, anchor = "DevicesWarning")
		return true
	}
	panel, account, prompt := device_attention(ui)
	if panel == .None {return false}
	devices_show(ui, panel, account, prompt)
	return true
}
