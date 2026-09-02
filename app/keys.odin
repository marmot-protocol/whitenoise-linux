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

import clay "../vendor/clay/bindings/odin/clay-odin"

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
	if marmot.account_key_packages(client, ref, raw_data(DEFAULT_RELAYS), uint(len(DEFAULT_RELAYS)), &list) != .OK {
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
	kp_rows_free(&ui.kp_list)
	ui.kp_fetched = true
	if !kp_rows(client, ui.account_ref, &ui.kp_list) {
		ui.client_status = fmt.aprintf("Couldn't read your key packages. %s", marmot.last_error())
	}
}

// One-line summary above the list: what exists and where it lives.
kp_status_line :: proc(ui: ^Ui_State) -> string {
	if !ui.kp_fetched {
		return tr("Not loaded yet. Click Refresh.")
	}
	local, published, relays: int
	for row in ui.kp_list {
		if row.local {
			local += 1
		}
		if row.relay {
			published += 1
			relays = max(relays, len(row.relay_urls))
		}
	}
	if local == 0 && published == 0 {
		return tr("No key package yet. Publish one so people can invite you.")
	}
	if published == 0 {
		return tr("Stored on this device, not published to any relay yet.")
	}
	return fmt.tprintf(tr("%d published, %d on this device, seen on %d relays."), published, local, relays)
}

// Publish (republish the cached package) or rotate (mint a fresh one).
// Both write the accepting-relay count.
Kp_Publish :: enum {
	Republish,
	Fresh,
}

publish_key_package :: proc(ui: ^Ui_State, client: ^marmot.Client, kind: Kp_Publish) {
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	accepted: u64
	status :=
		kind == .Fresh \
		? marmot.publish_new_key_package(client, account, &accepted) \
		: marmot.republish_key_package(client, account, &accepted)
	if status != .OK {
		ui.client_status = fmt.aprintf(tr("Couldn't publish the key package. %s"), marmot.last_error())
		return
	}
	fetch_key_packages(ui, client)
	ui.client_status = fmt.aprintf(tr("Key package accepted by %d relays."), accepted)
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
	ui.keys_confirm = ""
}

reveal_nsec :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	nsec: cstring
	if marmot.reveal_nsec(client, account, &nsec) != .OK || nsec == nil {
		ui.client_status = fmt.aprintf(tr("Couldn't reveal your private key. %s"), marmot.last_error())
		return
	}
	ui.keys_nsec = strings.clone(string(nsec))
	ui.keys_nsec_show = false
	marmot.string_free(nsec)
}

close_export :: proc(ui: ^Ui_State) {
	ui.export_open = false
	mem.zero_slice(ui.export_pw[:])
	clear(&ui.export_pw)
	delete(ui.export_result)
	ui.export_result = ""
	ui.focus = .Compose
}

// marmot seals the key under the entered passphrase (NIP-49); the raw
// nsec never enters this process.
do_export :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	pw := strings.clone_to_cstring(string(ui.export_pw[:]), context.temp_allocator)
	sealed: cstring
	if marmot.export_encrypted_secret_key(client, account, pw, &sealed) != .OK || sealed == nil {
		ui.client_status = fmt.aprintf(tr("Couldn't export the key. %s"), marmot.last_error())
		return
	}
	ui.export_result = strings.clone(string(sealed))
	marmot.string_free(sealed)
}

// ── Page ────────────────────────────────────────────────────────────

settings_keys :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("RowSovereign"))(srow()) {
		clay.Text(ICON_LOCK, {fontId = FONT_ICON, fontSize = 13, textColor = ACCENT})
		row_labels("Your identity is sovereign", "White Noise never sees your private key. It lives only on this device and any signer you connect.")
	}

	eyebrow("IDENTITY")
	if clay.UI(clay.ID("NpubRow"))(srow()) {
		if clay.UI(clay.ID("NpubCol"))({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 3}}) {
			clay.Text("Public key (npub)", {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
			clay.Text("Safe to share. This is how people find you.", {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
			clay.Text(len(ui.profile.npub) > 0 ? ui.profile.npub : "(unknown)", {fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO})
		}
		micro_button("SettingsCopyNpub", "Copy")
	}

	eyebrow("KEY PACKAGES (PUBLISHED TO YOUR KIND-10051 RELAY LIST)")
	if clay.UI(clay.ID("KpStatus"))(srow()) {
		if clay.UI(clay.ID("KpStatusCol"))({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 3}}) {
			clay.Text(tr("Key package"), {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
			clay.Text(kp_status_line(ui), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
		}
		micro_button("KpPublish", tr("Publish"))
		micro_button("KpRefresh", tr("Refresh"))
	}
	for row, i in ui.kp_list {
		if clay.UI(clay.ID("KpRow", u32(i)))(srow()) {
			if clay.UI(clay.ID("KpRowCol", u32(i)))({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 3}}) {
				clay.Text(fmt.tprintf("0x%s...", row.id[:min(len(row.id), 16)]), {fontId = FONT_MONO, fontSize = 12, textColor = TEXT})
				clay.Text(row.at, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
			}
			tag := row.relay ? (len(row.relay_urls) > 0 ? fmt.tprintf("RELAY · %d", len(row.relay_urls)) : "RELAY") : "LOCAL"
			clay.Text(tag, {fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO, letterSpacing = 2})
		}
	}

	eyebrow("LINKED DEVICES")
	if clay.UI(clay.ID("RowLinked"))(srow()) {
		row_labels("Multi-device isn't available yet", "Your identity lives only on this device for now. When device linking ships, the devices signed into your key will appear here.")
	}

	eyebrow("DEVICE VAULT")
	if clay.UI(clay.ID("RowVaultPw"))(srow()) {
		row_labels(
			"Change vault password",
			"Re-encrypts this device's secrets under a new password. The media cache is cleared, since it was sealed with the old one.",
		)
		micro_button("VaultPwBtn", "Change...")
	}

	eyebrow("DANGER ZONE")
	danger_row(
		ui,
		"RowRotate",
		"Rotate key package now",
		"Invalidates the current package and uploads a fresh one to your relays.",
		"RotateBtn",
		"Rotate",
	)

	// Reveal: arm, confirm, then a masked plate with copy and unmask.
	if clay.UI(clay.ID("RowReveal"))(danger_plate()) {
		if clay.UI(clay.ID("RevealCol"))({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 3}}) {
			clay.Text(tr("Reveal private key (nsec)"), {fontId = FONT_TITLE, fontSize = 13, textColor = DANGER})
			clay.Text(tr("Never share it. It is your identity."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
			if len(ui.keys_nsec) > 0 {
				shown := ui.keys_nsec_show ? ui.keys_nsec : strings.repeat("*", min(len(ui.keys_nsec), 63), context.temp_allocator)
				clay.Text(shown, {fontId = FONT_MONO, fontSize = 11, textColor = TEXT})
			}
		}
		if len(ui.keys_nsec) > 0 {
			micro_button("NsecShow", ui.keys_nsec_show ? tr("Hide") : tr("Show"))
			micro_button("NsecCopy", tr("Copy"))
		} else {
			micro_button("RevealNsecBtn", ui.keys_confirm == "RevealNsecBtn" ? tr("Confirm reveal") : tr("Reveal"), DANGER)
		}
	}

	danger_row(
		ui,
		"RowExport",
		"Export encrypted key (ncryptsec)",
		"Creates a NIP-49 key encrypted with a password, safe to store or move to another client.",
		"ExportBtn",
		"Export",
	)

}

danger_plate :: proc() -> clay.ElementDeclaration {
	return {
		layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(12), childGap = 10, childAlignment = {y = .Center}},
		backgroundColor = ROW_BG,
		cornerRadius = rr(8),
		border = {color = DANGER, width = bw()},
	}
}

danger_row :: proc(ui: ^Ui_State, row_id: string, title: string, sub: string, btn_id: string, btn_label: string) {
	if clay.UI(clay.ID(row_id))(danger_plate()) {
		row_labels(title, sub, DANGER)
		micro_button(btn_id, ui.keys_confirm == btn_id ? tr("Confirm") : btn_label, DANGER)
	}
}

// ── Interactions ────────────────────────────────────────────────────

// Two-step: the first click arms the button, the second acts. Returns
// true once the caller may perform the action.
armed :: proc(ui: ^Ui_State, btn_id: string) -> bool {
	if ui.keys_confirm == btn_id {
		ui.keys_confirm = ""
		return true
	}
	ui.keys_confirm = btn_id
	return false
}

handle_keys :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if clicked("VaultPwBtn") {
		vault_pw_begin(ui)
		return
	}
	if clicked("SettingsCopyNpub") && len(ui.profile.npub) > 0 {
		copy_text(ui, ui.profile.npub, "npub copied")
		return
	}
	if clicked("KpRefresh") {
		fetch_key_packages(ui, client)
		return
	}
	if clicked("KpPublish") {
		publish_key_package(ui, client, .Republish)
		return
	}
	if clicked("RotateBtn") {
		if armed(ui, "RotateBtn") {
			publish_key_package(ui, client, .Fresh)
		}
		return
	}
	if clicked("RevealNsecBtn") {
		if armed(ui, "RevealNsecBtn") {
			reveal_nsec(ui, client)
		}
		return
	}
	if clicked("NsecShow") {
		ui.keys_nsec_show = !ui.keys_nsec_show
		return
	}
	if clicked("NsecCopy") && len(ui.keys_nsec) > 0 {
		copy_text(ui, ui.keys_nsec, "Secret key copied")
		return
	}
	if clicked("ExportBtn") {
		if armed(ui, "ExportBtn") {
			ui.export_open = true
			clear(&ui.export_pw)
			ui.focus = .ExportPw
		}
		return
	}
	ui.keys_confirm = "" // a click anywhere else disarms
	handle_profile(ui, client)
}

// ── Export modal ────────────────────────────────────────────────────

export_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("ExportModal"))(
	{
		layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(modal_w(clay.ID("ExportModal"), 440))}, padding = clay.PaddingAll(18), childGap = 10},
		floating = {attachTo = .Root, zIndex = 11, offset = {0, rise(clay.ID("ExportModal"))}, attachment = {element = .CenterCenter, parent = .CenterCenter}},
		backgroundColor = CARD,
		cornerRadius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if clay.UI(clay.ID("ExportHead"))({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}}) {
			clay.Text("Export encrypted key", {fontId = FONT_TITLE, fontSize = 17, textColor = TEXT})
			if clay.UI(clay.ID("ExportHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("ExportClose"))({layout = {padding = clay.PaddingAll(6)}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)}) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}

		if len(ui.export_result) == 0 {
			// Step 1: password.
			clay.Text(tr("Pick a password to encrypt the key with. You will need it to import the key anywhere else."), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
			eyebrow("PASSWORD")
			if clay.UI(clay.ID("ExportPwBox"))(
			{layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(38)}, padding = {left = 12, right = 12}, childAlignment = {y = .Center}}, backgroundColor = ROW_BG, cornerRadius = rr(9), border = {color = ui.focus == .ExportPw ? ACCENT : FIELD_BORDER, width = bw()}},
			) {
				if len(ui.export_pw) == 0 {
					clay.Text(tr("Your password"), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_LO})
				} else {
					clay.Text(strings.repeat("*", min(len(ui.export_pw), 48), context.temp_allocator), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT})
				}
				if ui.focus == .ExportPw {
					caret(15)
				}
			}
			if clay.UI(clay.ID("ExportBtns"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, padding = {top = 8}}}) {
				if clay.UI(clay.ID("ExportCancel"))(
				{layout = {padding = {left = 22, right = 22, top = 9, bottom = 9}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(9), border = {color = FIELD_BORDER, width = bw()}},
				) {
					clay.Text("Cancel", {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
				}
				if clay.UI(clay.ID("ExportBtnsGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
				if clay.UI(clay.ID("ExportGo"))(
				{layout = {padding = {left = 22, right = 22, top = 9, bottom = 9}}, backgroundColor = DANGER, cornerRadius = rr(9)},
				) {
					clay.Text("Export key", {fontId = FONT_TITLE, fontSize = 13, textColor = ON_ACCENT})
				}
			}
		} else {
			// Step 2: the sealed key.
			clay.Text(tr("This is your secret key, encrypted with the password you entered. Whoever holds this string and that password controls your identity."), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
			eyebrow("ENCRYPTED KEY (NCRYPTSEC)")
			if clay.UI(clay.ID("ExportKeyPlate"))(
			{layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(10), layoutDirection = .TopToBottom, childGap = 2}, backgroundColor = ROW_BG, cornerRadius = rr(9), border = {color = FIELD_BORDER, width = bw()}},
			) {
				// One unbroken token: clay wraps on words only, so chunk
				// it into fixed slices or the plate blows past the modal.
				key := ui.export_result
				for len(key) > 0 {
					n := min(len(key), 52)
					clay.Text(key[:n], {fontId = FONT_MONO, fontSize = 11, textColor = TEXT})
					key = key[n:]
				}
			}
			if clay.UI(clay.ID("ExportCopyRow"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}}) {
				if clay.UI(clay.ID("ExportCopyGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
				micro_button("ExportSave", tr("Save file"))
				micro_button("ExportCopy", "Copy")
			}
			clay.Text(tr("Store it somewhere safe and close this dialog. Anyone who imports it will need the password you just entered to decrypt it."), {fontId = FONT_BODY, fontSize = 11, textColor = DANGER})
			if clay.UI(clay.ID("ExportDoneRow"))({layout = {padding = {top = 8}}}) {
				if clay.UI(clay.ID("ExportDone"))(
				{layout = {padding = {left = 22, right = 22, top = 9, bottom = 9}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(9), border = {color = FIELD_BORDER, width = bw()}},
				) {
					clay.Text("Done", {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
				}
			}
		}
	}
}
