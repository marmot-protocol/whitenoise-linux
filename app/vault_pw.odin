// Changing the vault password from Settings > Keys & identity.
//
// The vault key IS the password (Argon2id over it), and the blob subkey
// is a hash of that key, so a rotation invalidates everything sealed
// under the old one:
//
//   password ──argon2id──► vault key ──► vault.db      re-sealed here
//                              │
//                              └──sha256──► blob key ──► media cache    dropped
//                                                    └─► offline queue  re-sealed
//
// The queue survives because it still exists in Ui_State and can be
// written again; the cache cannot be reproduced without re-downloading,
// so it goes.
package main

import "core:mem"
import "core:os"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

Vault_Pw_Field :: enum {
	Current,
	New,
	Confirm,
}

vault_pw_begin :: proc(ui: ^Ui_State) {
	vault_pw_wipe(ui)
	ui.vault_pw_open = true
	ui.vault_pw_focus = .Current
	ui.vault_pw_err = ""
}

vault_pw_close :: proc(ui: ^Ui_State) {
	vault_pw_wipe(ui)
	ui.vault_pw_open = false
	ui.vault_pw_err = ""
	ui.focus = .Compose
}

@(private = "file")
vault_pw_wipe :: proc(ui: ^Ui_State) {
	for &field in ui.vault_pw {
		mem.zero_slice(field[:])
		clear(&field)
	}
}

// True while one of the three boxes is the buffer being edited, so
// edit_text masks it and a drag selection can't copy it out.
vault_pw_field :: proc(ui: ^Ui_State, buf: ^[dynamic]u8) -> bool {
	for &field in ui.vault_pw {
		if buf == &field {
			return true
		}
	}
	return false
}

@(private = "file")
vault_pw_apply :: proc(ui: ^Ui_State) {
	fresh := string(ui.vault_pw[.New][:])

	if !vault_verify(string(ui.vault_pw[.Current][:])) {
		ui.vault_pw_err = tr("That isn't your current password. Double-check it and try again.")
		mem.zero_slice(ui.vault_pw[.Current][:])
		clear(&ui.vault_pw[.Current])
		ui.vault_pw_focus = .Current
		return
	}
	if len(fresh) == 0 {
		ui.vault_pw_err = tr("Pick a new password first.")
		ui.vault_pw_focus = .New
		return
	}
	if fresh != string(ui.vault_pw[.Confirm][:]) {
		ui.vault_pw_err = tr("The passwords don't match. Type them again.")
		mem.zero_slice(ui.vault_pw[.Confirm][:])
		clear(&ui.vault_pw[.Confirm])
		ui.vault_pw_focus = .Confirm
		return
	}
	if vault_rekey(fresh) != .None {
		ui.vault_pw_err = tr("Couldn't change the password. Please try again.")
		return
	}

	// Both blob stores were keyed off the old password. The queue is
	// still in memory and re-seals; the cache is gone and re-downloads.
	save_offline(ui)
	os.remove_all(media_cache_dir())
	cache_scan(ui)

	vault_pw_close(ui)
	ui.client_status = tr("Vault password changed.")
}

// The modal owns input while it is open.
handle_vault_pw :: proc(ui: ^Ui_State) {
	edit_text(ui, &ui.vault_pw[ui.vault_pw_focus])

	if rl.IsKeyPressed(.ESCAPE) || clicked("VaultPwClose") || clicked("VaultPwCancel") {
		vault_pw_close(ui)
		return
	}
	if clicked("VaultPwCurBox") {
		ui.vault_pw_focus = .Current
	}
	if clicked("VaultPwNewBox") {
		ui.vault_pw_focus = .New
	}
	if clicked("VaultPwNew2Box") {
		ui.vault_pw_focus = .Confirm
	}

	go := clicked("VaultPwGo")
	if !go && !rl.IsKeyPressed(.ENTER) {
		return
	}
	// Enter walks down the three boxes (the shim has no Tab key) and the
	// last one submits; the button submits from wherever the focus is.
	if !go && ui.vault_pw_focus != .Confirm {
		ui.vault_pw_focus = Vault_Pw_Field(int(ui.vault_pw_focus) + 1)
		return
	}
	vault_pw_apply(ui)
}

vault_pw_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("VaultPwModal"))(
	{
		layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(modal_w(clay.ID("VaultPwModal"), 460))}, padding = clay.PaddingAll(18), childGap = 10},
		floating = {attachTo = .Root, zIndex = 12, offset = {0, rise(clay.ID("VaultPwModal"))}, attachment = {element = .CenterCenter, parent = .CenterCenter}},
		backgroundColor = CARD,
		cornerRadius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if clay.UI(clay.ID("VaultPwHead"))({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}}) {
			clay.Text(tr("Change vault password"), {fontId = FONT_TITLE, fontSize = 17, textColor = TEXT})
			if clay.UI(clay.ID("VaultPwHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("VaultPwClose"))({layout = {padding = clay.PaddingAll(6)}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)}) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}

		clay.Text(
			tr("The new password re-encrypts this device's keys. There is still no recovery: forgetting it means starting over from your nsec."),
			{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
		)

		eyebrow("CURRENT PASSWORD")
		gate_field(ui, "VaultPwCurBox", &ui.vault_pw[.Current], ui.vault_pw_focus == .Current, "Your current password")
		eyebrow("NEW PASSWORD")
		gate_field(ui, "VaultPwNewBox", &ui.vault_pw[.New], ui.vault_pw_focus == .New, "Your new password")
		eyebrow("CONFIRM NEW PASSWORD")
		gate_field(ui, "VaultPwNew2Box", &ui.vault_pw[.Confirm], ui.vault_pw_focus == .Confirm, "Your new password")

		if len(ui.vault_pw_err) > 0 {
			clay.Text(ui.vault_pw_err, {fontId = FONT_BODY, fontSize = 12, textColor = DANGER})
		}

		if clay.UI(clay.ID("VaultPwBtns"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, padding = {top = 8}}}) {
			if clay.UI(clay.ID("VaultPwCancel"))(
			{layout = {padding = {left = 22, right = 22, top = 9, bottom = 9}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(9), border = {color = FIELD_BORDER, width = bw()}},
			) {
				clay.Text(tr("Cancel"), {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
			}
			if clay.UI(clay.ID("VaultPwBtnsGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("VaultPwGo"))(
			{layout = {padding = {left = 22, right = 22, top = 9, bottom = 9}}, backgroundColor = ACCENT, cornerRadius = rr(9)},
			) {
				clay.Text(tr("Change password"), {fontId = FONT_TITLE, fontSize = 13, textColor = ON_ACCENT})
			}
		}
	}
}
