// The Keys & identity settings section: npub, MLS key-package state
// (local vs relay-published, with the accepting-relay count), the
// publish/rotate/refresh actions, and the danger zone. Every danger
// action arms first and acts on the second click (ui.keys_confirm).
//
// Secrets: the revealed nsec lives in ui.keys_nsec only while the page
// is on screen; keys_forget zeroes and frees it on the way out. The
// ncryptsec export never pulls the raw key into this process, marmot
// seals it under the entered passphrase.
package main

import "core:fmt"
import "core:mem"
import "core:strings"

import "nendo"
import rl "sdlrl"

import marmot "../marmot"

// ── Key-package state ───────────────────────────────────────────────

Kp_Row :: struct {
	id:         string, // event id hex when published, else key-package id
	at:         string, // full date · time
	local:      bool, // held in the local MLS store
	relay:      bool, // found on a relay
	owner:      string, // account hex the package belongs to
	kp_ref:     string, // key_package_ref_hex, the MLS-level identity
	bytes:      u64, // wire size of the package
	relay_urls: []string, // relays this copy was seen on
}

// Read key packages for any account reference (npub or hex): the local
// MLS store plus the relay-published copies visible through the
// bootstrap relays. Appends to `out`, which the caller owns.
kp_rows :: proc(client: ^marmot.Client, account_ref: string, out: ^[dynamic]Kp_Row) -> bool {
	ref := strings.clone_to_cstring(account_ref, context.temp_allocator)
	list: ^marmot.Account_Key_Package_List
	if marmot.account_key_packages(
		   client,
		   ref,
		   raw_data(DEFAULT_RELAYS),
		   uint(len(DEFAULT_RELAYS)),
		   &list,
	   ) !=
	   .OK {
		return false
	}
	defer marmot.account_key_package_list_free(list)

	str :: proc(c: cstring) -> string {
		return c != nil ? string(c) : ""
	}
	for kp in list.items[:list.len] {
		urls := make([]string, kp.source_relays_len)
		for i in 0 ..< kp.source_relays_len {
			urls[i] = strings.clone(str(kp.source_relays[i]))
		}
		id := kp.event_id_hex != nil ? str(kp.event_id_hex) : str(kp.key_package_id)
		append(
			out,
			Kp_Row {
				id = strings.clone(id),
				at = format_full(kp.published_at),
				local = kp.local,
				relay = kp.relay,
				owner = strings.clone(str(kp.account_id_hex)),
				kp_ref = strings.clone(str(kp.key_package_ref_hex)),
				bytes = kp.key_package_bytes,
				relay_urls = urls,
			},
		)
	}
	return true
}

kp_rows_free :: proc(rows: ^[dynamic]Kp_Row) {
	for &row in rows {
		delete(row.id)
		delete(row.at)
		delete(row.owner)
		delete(row.kp_ref)
		for url in row.relay_urls {
			delete(url)
		}
		delete(row.relay_urls)
	}
	clear(rows)
}

// Read the active account's key packages.
fetch_key_packages :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	job := account_job_new(ui, client, .Read_Key_Packages)
	if job != nil {ui.kp_fetched = true; account_job_start(job)}
}

// A package can be stored both locally and on relays.
@(private)
kp_location :: proc(row: Kp_Row) -> string {
	if row.relay {
		if n := len(row.relay_urls); n > 0 {
			if row.local {
				return fmt.tprintf(
					tr(
						n == 1 ? N_("On this device and on %d relay.") : N_("On this device and on %d relays."),
					),
					n,
				)
			}
			return fmt.tprintf(tr(n == 1 ? N_("On %d relay.") : N_("On %d relays.")), n)
		}
		return tr(row.local ? N_("On this device and on relays.") : N_("On relays."))
	}
	if row.local {
		return tr("Stored on this device, not published to any relay yet.")
	}
	return tr("Location unknown.")
}

// Count packages once, then describe their overlapping storage locations.
kp_status_line :: proc(ui: ^Ui_State) -> string {
	if !ui.kp_fetched {
		return tr("Not loaded yet. Click Refresh.")
	}
	if len(ui.kp_list) == 0 {
		return tr("No key package yet. Publish one so people can invite you.")
	}
	if len(ui.kp_list) == 1 {
		return fmt.tprintf(tr("1 key package. %s"), kp_location(ui.kp_list[0]))
	}
	local, published: int
	for row in ui.kp_list {
		if row.local {
			local += 1
		}
		if row.relay {
			published += 1
		}
	}
	return fmt.tprintf(
		tr("%d key packages. On this device: %d. On relays: %d."),
		len(ui.kp_list),
		local,
		published,
	)
}

// Publish (republish the cached package) or rotate (mint a fresh one).
// Both write the accepting-relay count.
Kp_Publish :: enum {
	Republish,
	Fresh,
}

publish_key_package :: proc(ui: ^Ui_State, client: ^marmot.Client, kind: Kp_Publish) {
	job := account_job_new(ui, client, .Key_Package); if job == nil {return}
	job.fresh = kind == .Fresh; account_job_start(job)
}

// ── Danger zone secrets ─────────────────────────────────────────────

// Wipe everything the page held: the revealed key, its unmask toggle,
// and any armed confirmation.
keys_forget :: proc(ui: ^Ui_State) {
	if len(ui.keys_nsec) > 0 {
		mem.zero_slice(transmute([]u8)ui.keys_nsec)
		delete(ui.keys_nsec)
		ui.keys_nsec = ""
	}
	ui.keys_nsec_show = false
	keys_reveal_frames = 0
	keys_disarm(ui)
}

reveal_nsec :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if !account_local(ui) {return}
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	nsec: cstring
	if marmot.reveal_nsec(client, account, &nsec) != .OK || nsec == nil {
		set_status(ui, tr("Couldn't reveal your secret key. Please try again."), .Error)
		return
	}
	ui.keys_nsec = strings.clone(string(nsec))
	ui.keys_nsec_show = false
	marmot.string_free(nsec)
}

close_export :: proc(ui: ^Ui_State) {
	mem.zero_slice(export_confirm[:]); clear(&export_confirm)
	export_confirm_focus = false
	delete(export_account); export_account = ""
	export_check = {}
	ui.export_open = false
	ui.export_pw_required = false
	mem.zero_slice(ui.export_pw[:])
	clear(&ui.export_pw)
	delete(ui.export_result)
	ui.export_result = ""
	ui.focus = .Compose
}

// marmot seals the key under the entered passphrase (NIP-49); the raw
// nsec never enters this process.
do_export :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	// Remote-signer keys never leave the signer, whatever was typed.
	if !account_local(ui, export_account) {close_export(ui); return}
	// An empty password gets its own explanation before the strength and
	// confirmation checks the Export button already shows.
	ui.export_pw_required = len(ui.export_pw) == 0
	if ui.export_pw_required {
		ui.focus = .ExportPw
		return
	}
	if !export_valid(ui) {return}
	account := strings.clone_to_cstring(
		export_account != "" ? export_account : ui.account_ref,
		context.temp_allocator,
	)
	pw := strings.clone_to_cstring(string(ui.export_pw[:]), context.temp_allocator)
	sealed: cstring
	if marmot.export_encrypted_secret_key(client, account, pw, &sealed) != .OK || sealed == nil {
		set_status(ui, fmt.aprintf(tr("Couldn't export the key. %s"), marmot.last_error()), .Error)
		return
	}
	ui.export_result = strings.clone(string(sealed))
	marmot.string_free(sealed)
}

// ── Page ────────────────────────────────────────────────────────────

@(private)
export_confirm: [dynamic]u8
@(private = "file")
export_confirm_focus: bool
@(private = "file")
export_account: string
@(private = "file")
export_check: Password_Check
@(private = "file")
keys_reveal_frames: int

@(private)
open_key_export :: proc(ui: ^Ui_State, account: string) {
	close_export(ui)
	keys_disarm(ui)
	export_account = strings.clone(account)
	ui.export_open = true
	ui.focus = .ExportPw
}

@(private)
export_buffer :: proc(ui: ^Ui_State) -> ^[dynamic]u8 {
	return export_confirm_focus ? &export_confirm : &ui.export_pw
}

@(private = "file")
export_valid :: proc(ui: ^Ui_State) -> bool {
	return(
		password_bits(string(ui.export_pw[:]), &export_check) >= PASSWORD_MIN_BITS &&
		string(ui.export_pw[:]) == string(export_confirm[:]) \
	)
}

@(private)
export_fields :: proc(ui: ^Ui_State) {
	if field_mouse(
		ui,
		&ui.export_pw,
		"ExportPwBox",
		14,
	) {export_confirm_focus = false; ui.focus = .ExportPw}
	if clicked("ExportConfirmBox") {export_confirm_focus = true; ui.focus = .ExportPw}
	if rl.IsKeyPressed(.TAB) {export_confirm_focus = !export_confirm_focus}
}

@(private)
keys_fields :: proc(ui: ^Ui_State) {
	if keys_reveal_frames > 0 {
		keys_reveal_frames -= 1
		if keys_reveal_frames == 0 {reveal_nsec(ui, g_client)}
	}
	if long_pressed && nendo.pointer_over(nendo.id("NpubInset")) && ui.profile.npub != "" {
		copy_text(ui, ui.profile.npub, tr("npub copied"))
	}
}

settings_keys :: proc(ui: ^Ui_State) {
	body_width := settings_body_width(ui) - 24
	account_busy := settings_account_busy(ui)
	if ui.settings_tab == 0 {
		if nendo.box(nendo.id("KeysIdentityGroup"))(settings_box()) {
			settings_group(tr("Keys & identity"))
			if nendo.box(nendo.id("KeysProfile"))(settings_row()) {
				name :=
					len(ui.profile.name) > 0 ? ui.profile.name : profile_label(nil, ui.account_ref)
				avatar("KeysAvatar", 0, ui.account_ref, name, 44, url_pic(ui.my_pic_url))
				if nendo.box(nendo.id("KeysProfileName"))(
				{width = nendo.grow(), clip = {x = true}},
				) {
					nendo.text(name, {font = FONT_TITLE, size = 16, color = TEXT})
				}
			}
			public_row := settings_row()
			public_row.direction = body_width < 220 ? .Column : .Row
			if nendo.box(nendo.id("NpubRow"))(public_row) {
				nendo.text(tr("Public key (npub)"), {font = FONT_TITLE, size = 13, color = TEXT})
				settings_button("SettingsCopyNpub", tr("Copy"))
			}
			if nendo.box(nendo.id("NpubInset"))(
			{
				width = nendo.grow(),
				padding = nendo.pad(10),
				color = CARD,
				border = {color = FIELD_BORDER, width = {1, 1, 1, 1, 0}},
				radius = rr(2),
			},
			) {
				keys_key_lines(
					"NpubCol",
					len(ui.profile.npub) > 0 ? ui.profile.npub : tr("(unknown)"),
					body_width - 20,
				)
			}
			nendo.text(
				tr("Safe to share. This is how people find you."),
				{font = FONT_BODY, size = 11, color = TEXT_DIM},
			)
			identity_note := settings_row()
			identity_note.direction = .Row
			identity_note.align.y = .Top
			if nendo.box(nendo.id("RowSovereign"))(identity_note) {
				nendo.text(ICON_LOCK, {font = FONT_ICON, size = 13, color = ACCENT})
				row_labels(
					tr("Your key stays on this device"),
					tr(
						"Your secret key stays on this device or in your connected signer. Never share it.",
					),
				)
			}
		}
		return
	}

	action_row := settings_row()
	action_row.direction = .Column
	action_row.gap = 6
	if ui.settings_tab == 1 {
		if nendo.box(nendo.id("KpStatus"))(settings_box()) {
			settings_group(tr("Key packages"))
			nendo.text(kp_status_line(ui), {font = FONT_BODY, size = 12, color = TEXT})
			if nendo.box(nendo.id("KpStatusActions"))(
			{direction = body_width < 260 ? .Column : .Row, gap = 6},
			) {
				settings_button(
					"KpPublish",
					tr("Publish"),
					ACCENT,
					account_busy ? .Disabled : .Enabled,
				)
				settings_button(
					"KpRefresh",
					tr("Refresh"),
					{},
					account_busy ? .Disabled : .Enabled,
				)
			}
			nendo.text(
				tr(
					"Key packages let people invite you. Refresh checks the app's default relays for published copies.",
				),
				{font = FONT_BODY, size = 11, color = TEXT_DIM},
			)
			for row, i in ui.kp_list {
				if nendo.box(nendo.id("KpRow", u32(i)))(settings_row()) {
					if nendo.box(nendo.id("KpRowCol", u32(i)))(
					{width = nendo.grow(), direction = .Column, gap = 3},
					) {
						nendo.text(
							row.relay && row.id != "" ? short_hex(row.id) : tr("Not published yet"),
							{font = FONT_MONO, size = 11, color = TEXT_LO},
						)
						nendo.text(row.at, {font = FONT_BODY, size = 11, color = TEXT_DIM})
						nendo.text(
							kp_location(row),
							{font = FONT_BODY, size = 11, color = TEXT_DIM},
						)
					}

				}
			}
		}
		if nendo.box(nendo.id("RowRotate"))(settings_box()) {
			settings_group(tr("Rotate key package now"))
			nendo.text(
				tr("Invalidates the current package and uploads a fresh one to your relays."),
				{font = FONT_BODY, size = 11, color = TEXT_DIM},
			)
			label := ui.keys_confirm == "RotateBtn" ? tr("Tap again to rotate") : tr("Rotate")
			settings_button("RotateBtn", label, DANGER, account_busy ? .Disabled : .Enabled)
		}
		return
	}

	if nendo.box(nendo.id("KeysVaultGroup"))(settings_box()) {
		settings_group(tr("Device vault"))
		if nendo.box(nendo.id("RowVaultPw"))(action_row) {
			row_labels(
				tr("Change vault password"),
				tr(
					"Re-encrypts this device's secrets under a new password. The media cache is cleared, since it was sealed with the old one.",
				),
			)
			settings_button("VaultPwBtn", tr("Change..."))
		}
		if account_local(ui) {
			if nendo.box(nendo.id("RowExport"))(action_row) {
				row_labels(
					tr("Export encrypted key (ncryptsec)"),
					tr(
						"Creates a NIP-49 key encrypted with a password, safe to store or move to another client.",
					),
				)
				settings_button("ExportBtn", tr("Export"))
			}
		}
	}

	security := settings_box()
	security.border = {
		color = DANGER_BORDER,
		width = {left = 2, right = 1, top = 1, bottom = 1},
	}
	if !account_local(ui) {
		nendo.text(
			tr(
				"Your secret key stays in your remote signer. Reveal and export are unavailable on this device.",
			),
			{font = FONT_BODY, size = 12, color = TEXT_DIM},
		)
		return
	}
	if nendo.box(nendo.id("KeysDangerGroup"))(security) {
		settings_group(tr("Security actions"))
		// Reveal: arm, confirm, then a masked plate with copy and unmask.
		if nendo.box(nendo.id("RowReveal"))(action_row) {
			if nendo.box(nendo.id("RevealCol"))(
			{width = nendo.grow(), direction = .Column, gap = 3},
			) {
				nendo.text(
					tr("Reveal secret key (nsec)"),
					{font = FONT_TITLE, size = 13, color = TEXT},
				)
				nendo.text(
					tr("Never share it. It is your identity."),
					{font = FONT_BODY, size = 11, color = TEXT_DIM},
				)
			}
			if len(ui.keys_nsec) > 0 {
				if nendo.box(nendo.id("NsecActions"))(
				{direction = body_width < 180 ? .Column : .Row, gap = 6},
				) {
					settings_button("NsecShow", ui.keys_nsec_show ? tr("Hide") : tr("Show"))
					settings_button("NsecCopy", tr("Copy"))
				}
			} else if keys_reveal_frames > 0 {
				nendo.text(tr("Decrypting..."), {font = FONT_BODY, size = 13, color = TEXT})
				busy_bar("KeysRevealProgress")
			} else {
				label := ui.keys_confirm == "RevealNsecBtn" ? tr("Confirm reveal") : tr("Reveal")
				settings_button("RevealNsecBtn", label, DANGER)
			}
		}
		if len(ui.keys_nsec) > 0 {
			if ui.keys_nsec_show {
				keys_key_lines("NsecValue", ui.keys_nsec, body_width)
			} else {
				nendo.text("****************", {font = FONT_MONO, size = 11, color = TEXT})
			}
		}
	}
}

// Bech32 keys are ASCII. Borrow slices from the existing value rather than
// constructing a second copy of a revealed secret just to insert line breaks.
@(private = "file")
keys_key_lines :: proc(id: string, key: string, width: f32) {
	char_width := max(1, rl.MeasureTextLine(FONT_MONO, 11, "0", 0).x)
	columns := max(1, int(width / char_width))
	if nendo.box(nendo.id(id))(
	{width = nendo.fixed(max(1, width)), direction = .Column, gap = 2},
	) {
		for start := 0; start < len(key); start += columns {
			nendo.text(
				key[start:min(start + columns, len(key))],
				{font = FONT_MONO, size = 11, color = TEXT},
			)
		}
	}
}

// ── Interactions ────────────────────────────────────────────────────

// Bumped whenever an arm is set or consumed. A click that leaves it
// unchanged is "anywhere else" and disarms. See handle_settings.
@(private)
confirm_serial: int

@(private)
confirm_touch :: proc() {
	confirm_serial += 1
}

// Path-keyed confirms ("AuditDelete:/…", "EmojiDelete:file.png") are
// cloned into keys_confirm. Literal button ids are not, and must not
// be freed.
@(private)
confirm_owned :: proc(id: string) -> bool {
	return strings.has_prefix(id, "AuditDelete:") || strings.has_prefix(id, "EmojiDelete:")
}

@(private)
keys_disarm :: proc(ui: ^Ui_State) {
	if confirm_owned(ui.keys_confirm) {
		delete(ui.keys_confirm)
	}
	ui.keys_confirm = ""
}

// Two-step: the first click arms the button, the second acts. Returns
// true once the caller may perform the action.
armed :: proc(ui: ^Ui_State, btn_id: string) -> bool {
	if ui.keys_confirm == btn_id {
		keys_disarm(ui)
		confirm_touch()
		return true
	}
	keys_disarm(ui)
	ui.keys_confirm = btn_id
	confirm_touch()
	return false
}

// Same two-step, but id is a stable subject (a file path or emoji
// filename) that has to outlive this frame's temp strings.
@(private)
owned_arm :: proc(ui: ^Ui_State, id: string) -> bool {
	if ui.keys_confirm == id {
		keys_disarm(ui)
		confirm_touch()
		return true
	}
	keys_disarm(ui)
	ui.keys_confirm = strings.clone(id)
	confirm_touch()
	return false
}

handle_keys :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if clicked("VaultPwBtn") {
		vault_pw_begin(ui)
		return
	}
	if clicked("SettingsCopyNpub") && len(ui.profile.npub) > 0 {
		copy_text(ui, ui.profile.npub, tr("npub copied"))
		return
	}
	if clicked("KpRefresh") {
		if settings_account_busy(ui) {return}
		fetch_key_packages(ui, client)
		return
	}
	if clicked("KpPublish") {
		if settings_account_busy(ui) {return}
		publish_key_package(ui, client, .Republish)
		return
	}
	if clicked("RotateBtn") {
		if settings_account_busy(ui) {return}
		if armed(ui, "RotateBtn") {
			publish_key_package(ui, client, .Fresh)
		}
		return
	}
	if clicked("RevealNsecBtn") && account_local(ui) {
		if armed(ui, "RevealNsecBtn") {
			keys_reveal_frames = 3
		}
		return
	}
	if clicked("NsecShow") && account_local(ui) {
		ui.keys_nsec_show = !ui.keys_nsec_show
		return
	}
	if clicked("NsecCopy") && account_local(ui) && len(ui.keys_nsec) > 0 {
		copy_text(ui, ui.keys_nsec, tr("Secret key copied"))
		return
	}
	if clicked("ExportBtn") && account_local(ui) {
		open_key_export(ui, ui.account_ref)
		return
	}
	ui.keys_confirm = "" // a click anywhere else disarms
	handle_profile(ui, client)
}

// ── Export modal ────────────────────────────────────────────────────

export_modal :: proc(ui: ^Ui_State) {
	if nendo.box(nendo.id("ExportModal"))(
	{
		direction = .Column,
		width = nendo.fixed(modal_w(nendo.id("ExportModal"), 440)),
		height = nendo.fit(max = modal_h(1200)),
		padding = nendo.pad(18),
		gap = 10,
		floating = {
			attach_to = .Root,
			z = 11,
			offset = {0, rise(nendo.id("ExportModal"))},
			attach = {element = .Center_Center, parent = .Center_Center},
		},
		color = CARD,
		clip = {y = true, scroll = true},
		radius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if nendo.box(nendo.id("ExportHead"))({width = nendo.grow(), align = {y = .Center}}) {
			nendo.text(tr("Back up your key"), {font = FONT_TITLE, size = 17, color = TEXT})
			if nendo.box(nendo.id("ExportHeadGap"))({width = nendo.grow()}) {}
			if nendo.box(nendo.id("ExportClose"))(
			{
				width = nendo.fixed(settings_tap_size(24)),
				height = nendo.fixed(settings_tap_size(24)),
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : {},
				radius = rr(6),
			},
			) {
				nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 12, color = TEXT_DIM})
			}
		}

		if len(ui.export_result) == 0 {
			// Step 1: password.
			nendo.text(
				tr(
					"Pick a password to encrypt the key with. You will need it to import the key anywhere else.",
				),
				{font = FONT_BODY, size = 12, color = TEXT_DIM},
			)
			eyebrow(tr("PASSWORD"))
			if nendo.box(nendo.id("ExportPwBox"))(
			{
				width = nendo.grow(),
				height = nendo.fixed(settings_tap_size(38)),
				padding = {left = 12, right = 12},
				align = {y = .Center},
				color = ROW_BG,
				clip = {x = true},
				radius = rr(9),
				border = {
					color = ui.focus == .ExportPw && !export_confirm_focus ? ACCENT : FIELD_BORDER,
					width = bw(),
				},
			},
			) {
				if len(ui.export_pw) == 0 {
					if ui.focus == .ExportPw && !export_confirm_focus {
						caret(15)
					}
					nendo.text(tr("Your password"), {font = FONT_BODY, size = 13, color = TEXT_LO})
				} else {
					nendo.text(
						strings.repeat("*", min(len(ui.export_pw), 48), context.temp_allocator),
						{font = FONT_BODY, size = 13, color = TEXT},
					)
					if ui.focus == .ExportPw && !export_confirm_focus {
						caret(15)
					}
				}
			}
			secure_password_hint(password_bits(string(ui.export_pw[:]), &export_check))
			eyebrow(tr("CONFIRM PASSWORD"))
			gate_field(
				ui,
				"ExportConfirmBox",
				&export_confirm,
				ui.focus == .ExportPw && export_confirm_focus,
				tr("Type your password again"),
			)
			if len(export_confirm) > 0 && string(export_confirm[:]) != string(ui.export_pw[:]) {
				nendo.text(
					tr("The passwords don't match. Type them again."),
					{font = FONT_BODY, size = 12, color = DANGER},
				)
			}
			if ui.export_pw_required {
				if nendo.box(nendo.id("ExportPwError"))({width = nendo.grow()}) {
					nendo.text(
						tr("Pick a password first."),
						{font = FONT_BODY, size = 12, color = DANGER},
					)
				}
			}
			if nendo.box(nendo.id("ExportBtns"))(settings_choices(nendo.id("ExportBtns"))) {
				if nendo.box(nendo.id("ExportCancel"))(
				{
					height = nendo.fit(min = settings_tap_size(32)),
					padding = {left = 22, right = 22, top = 9, bottom = 9},
					align = {x = .Center, y = .Center},
					color = hovered() ? HOVER : {},
					radius = rr(9),
					border = {color = FIELD_BORDER, width = bw()},
				},
				) {
					nendo.text(tr("Cancel"), {font = FONT_TITLE, size = 13, color = TEXT})
				}
				if nendo.box(nendo.id("ExportBtnsGap"))({width = nendo.grow()}) {}
				if nendo.box(nendo.id("ExportGo"))(
				{
					height = nendo.fit(min = settings_tap_size(32)),
					padding = {left = 22, right = 22, top = 9, bottom = 9},
					align = {x = .Center, y = .Center},
					color = export_valid(ui) ? ACCENT : ROW_BG,
					radius = rr(9),
				},
				) {
					nendo.text(
						tr("Export key"),
						{
							font = FONT_TITLE,
							size = 13,
							color = export_valid(ui) ? ON_ACCENT : TEXT_DIM,
						},
					)
				}
			}
		} else {
			// Step 2: the sealed key.
			nendo.text(
				tr(
					"This is your secret key, encrypted with the password you entered. Whoever holds this string and that password controls your identity.",
				),
				{font = FONT_BODY, size = 12, color = TEXT_DIM},
			)
			eyebrow(tr("ENCRYPTED KEY (NCRYPTSEC)"))
			if nendo.box(nendo.id("ExportKeyPlate"))(
			{
				width = nendo.grow(),
				padding = nendo.pad(10),
				direction = .Column,
				gap = 2,
				color = ROW_BG,
				radius = rr(9),
				border = {color = FIELD_BORDER, width = bw()},
			},
			) {
				// One unbroken token: nendo wraps on words only, so chunk
				// it into fixed slices or the plate blows past the modal.
				key := ui.export_result
				columns := max(
					1,
					int(
						(modal_w(nendo.id("ExportModal"), 440) - 56) /
						max(1, rl.MeasureTextLine(FONT_MONO, 11, "M", 0).x),
					),
				)
				for len(key) > 0 {
					n := min(len(key), columns)
					nendo.text(key[:n], {font = FONT_MONO, size = 11, color = TEXT})
					key = key[n:]
				}
			}
			if nendo.box(nendo.id("ExportCopyRow"))({width = nendo.grow(), gap = 8}) {
				if nendo.box(nendo.id("ExportCopyGap"))({width = nendo.grow()}) {}
				micro_button("ExportSave", tr("Save file"))
				micro_button("ExportCopy", tr("Copy"))
			}
			nendo.text(
				tr(
					"Store it somewhere safe and close this dialog. Anyone who imports it will need the password you just entered to decrypt it.",
				),
				{font = FONT_BODY, size = 11, color = DANGER},
			)
			if nendo.box(nendo.id("ExportDoneRow"))({padding = {top = 8}}) {
				if nendo.box(nendo.id("ExportDone"))(
				{
					height = nendo.fit(min = settings_tap_size(32)),
					padding = {left = 22, right = 22, top = 9, bottom = 9},
					align = {x = .Center, y = .Center},
					color = hovered() ? HOVER : {},
					radius = rr(9),
					border = {color = FIELD_BORDER, width = bw()},
				},
				) {
					nendo.text(tr("Done"), {font = FONT_TITLE, size = 13, color = TEXT})
				}
			}
		}
	}
	scrollbar(nendo.id("ExportModal"), 12)
}
