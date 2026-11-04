// Changing the vault password from Settings > Keys & identity.
//
// vault_rekey re-seals vault.db under a new Argon2id key and keeps the
// blob key already stored in the map. Sealed files stay where they are.
package main

import "core:mem"

import "nendo"
import rl "sdlrl"

Vault_Pw_Field :: enum {
	Current,
	New,
	Confirm,
}

vault_pw_begin :: proc(ui: ^Ui_State) {
	vault_pw_wipe(ui)
	vault_pw_show = false
	vault_pw_height = -1
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
	ui.vault_pw_check = {}
}

// True while one of the three boxes is the buffer being edited, so
// edit_text masks it and a drag selection can't copy it out.
vault_pw_field :: proc(ui: ^Ui_State, buf: ^[dynamic]u8) -> bool {
	if buf == &export_confirm || buf == &backup_confirm {return true}
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
	vault_pw_error_field = .Current

	if !vault_verify(string(ui.vault_pw[.Current][:])) {
		ui.vault_pw_err = tr("That isn't your current password. Double-check it and try again.")
		mem.zero_slice(ui.vault_pw[.Current][:])
		clear(&ui.vault_pw[.Current])
		ui.vault_pw_focus = .Current
		return
	}
	if len(fresh) == 0 {
		vault_pw_error_field = .New
		ui.vault_pw_err = tr("Pick a new password first.")
		ui.vault_pw_focus = .New
		return
	}
	if password_bits(fresh, &ui.vault_pw_check) < PASSWORD_MIN_BITS {
		vault_pw_error_field = .New
		ui.vault_pw_err = tr(
			"This password is too easy to guess. Use unrelated words or a password-manager password.",
		)
		ui.vault_pw_focus = .New
		return
	}
	if fresh != string(ui.vault_pw[.Confirm][:]) {
		vault_pw_error_field = .Confirm
		ui.vault_pw_err = tr("The passwords don't match. Type them again.")
		mem.zero_slice(ui.vault_pw[.Confirm][:])
		clear(&ui.vault_pw[.Confirm])
		ui.vault_pw_focus = .Confirm
		return
	}
	if vault_rekey(fresh) != .None {
		vault_pw_error_field = .Confirm
		ui.vault_pw_err = tr("Couldn't change the password. Please try again.")
		return
	}

	vault_pw_close(ui)
	set_status(ui, tr("Vault password changed."), .Info)
}

// The modal owns input while it is open.
@(private)
vault_pw_height: i32 = -1

@(private = "file")
vault_pw_show: bool
@(private = "file")
vault_pw_error_field: Vault_Pw_Field

@(private)
secure_password_hint :: proc(bits: f64) {
	nendo.text(
		bits >= PASSWORD_MIN_BITS ? tr("Strong enough") : tr("Weak password"),
		{font = FONT_BODY, size = 12, color = bits >= PASSWORD_MIN_BITS ? ACCENT : TEXT_DIM},
	)
	nendo.text(
		tr("Use unrelated words or a password-manager password."),
		{font = FONT_BODY, size = 12, color = TEXT_DIM},
	)
}

handle_vault_pw :: proc(ui: ^Ui_State) {
	previous_focus := ui.vault_pw_focus
	defer {
		if previous_focus != ui.vault_pw_focus || vault_pw_height != rl.GetScreenHeight() {
			ids := [Vault_Pw_Field]string {
				.Current = "VaultPwCurBox",
				.New     = "VaultPwNewBox",
				.Confirm = "VaultPwNew2Box",
			}
			onboard_reveal_field("VaultPwBody", ids[ui.vault_pw_focus])
			vault_pw_height = rl.GetScreenHeight()
		}
	}
	previous_length := len(ui.vault_pw[ui.vault_pw_focus])
	edit_text(ui, &ui.vault_pw[ui.vault_pw_focus])
	if previous_length != len(ui.vault_pw[ui.vault_pw_focus]) &&
	   vault_pw_error_field == ui.vault_pw_focus {ui.vault_pw_err = ""}
	if clicked("VaultPwShow") {vault_pw_show = !vault_pw_show; return}

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
	tab_focus([]Vault_Pw_Field{.Current, .New, .Confirm}, &ui.vault_pw_focus)

	go := clicked("VaultPwGo")
	if !go && !rl.IsKeyPressed(.ENTER) {
		return
	}
	// Enter walks down the three boxes and the last one submits; the
	// button submits from wherever the focus is.
	if !go && ui.vault_pw_focus != .Confirm {
		ui.vault_pw_focus = Vault_Pw_Field(int(ui.vault_pw_focus) + 1)
		return
	}
	vault_pw_apply(ui)
}

vault_pw_modal :: proc(ui: ^Ui_State) {
	bits := password_bits(string(ui.vault_pw[.New][:]), &ui.vault_pw_check)
	if nendo.box(nendo.id("VaultPwModal"))(
	{
		direction = .Column,
		width = nendo.fixed(modal_w(nendo.id("VaultPwModal"), 460)),
		height = nendo.fit(max = modal_h(1200)),
		padding = nendo.pad(18),
		gap = 10,
		floating = {
			attach_to = .Root,
			z = 12,
			offset = {0, rise(nendo.id("VaultPwModal"))},
			attach = {element = .Center_Center, parent = .Center_Center},
		},
		color = CARD,
		radius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if nendo.box(nendo.id("VaultPwHead"))({width = nendo.grow(), align = {y = .Center}}) {
			nendo.text(tr("Change vault password"), {font = FONT_TITLE, size = 17, color = TEXT})
			if nendo.box(nendo.id("VaultPwHeadGap"))({width = nendo.grow()}) {}
			if nendo.box(nendo.id("VaultPwClose"))(
			{
				width = nendo.fixed(tap_size() ? tap_min() : 24),
				height = nendo.fixed(tap_size() ? tap_min() : 24),
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : {},
				radius = rr(6),
			},
			) {
				nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 12, color = TEXT_DIM})
			}
		}

		if nendo.box(nendo.id("VaultPwBody"))(
		{
			width = nendo.grow(),
			height = nendo.fit(max = max(1, modal_h(1200) - (tap_size() ? 150 : 116))),
			direction = .Column,
			gap = 10,
			clip = {y = true, scroll = true},
		},
		) {
			scrollbar(nendo.id("VaultPwBody"), 13)
			nendo.text(
				tr(
					"The new password re-encrypts the vault on this device. White Noise still can't reset it. If you forget it, the only way forward is to delete this vault and start over.",
				),
				{font = FONT_BODY, size = 12, color = TEXT_DIM},
			)

			eyebrow(tr("CURRENT PASSWORD"))
			settings_button(
				"VaultPwShow",
				vault_pw_show ? tr("Hide passwords") : tr("Show passwords"),
			)
			gate_field(
				ui,
				"VaultPwCurBox",
				&ui.vault_pw[.Current],
				ui.vault_pw_focus == .Current,
				tr("Your current password"),
				vault_pw_show ? .Plain : .Masked,
			)
			if ui.vault_pw_err != "" && vault_pw_error_field == .Current {
				nendo.text(ui.vault_pw_err, {font = FONT_BODY, size = 12, color = DANGER})
			}
			eyebrow(tr("NEW PASSWORD"))
			gate_field(
				ui,
				"VaultPwNewBox",
				&ui.vault_pw[.New],
				ui.vault_pw_focus == .New,
				tr("Your new password"),
				vault_pw_show ? .Plain : .Masked,
			)
			if ui.vault_pw_err != "" && vault_pw_error_field == .New {
				nendo.text(ui.vault_pw_err, {font = FONT_BODY, size = 12, color = DANGER})
			}
			password_hint(&ui.vault_pw_check)
			eyebrow(tr("CONFIRM NEW PASSWORD"))
			gate_field(
				ui,
				"VaultPwNew2Box",
				&ui.vault_pw[.Confirm],
				ui.vault_pw_focus == .Confirm,
				tr("Type your new password again"),
				vault_pw_show ? .Plain : .Masked,
			)

			if len(ui.vault_pw_err) > 0 && vault_pw_error_field == .Confirm {
				nendo.text(ui.vault_pw_err, {font = FONT_BODY, size = 12, color = DANGER})
			}
		}

		if nendo.box(nendo.id("VaultPwBtns"))(
		{width = nendo.grow(), gap = 10, padding = {top = 8}},
		) {
			if nendo.box(nendo.id("VaultPwCancel"))(
			{
				width = single_pane() ? nendo.grow() : nendo.fit(),
				height = nendo.fit(min = tap_size() ? tap_min() : 0),
				padding = {left = 16, right = 16, top = 9, bottom = 9},
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : {},
				radius = rr(9),
				border = {color = FIELD_BORDER, width = bw()},
			},
			) {
				nendo.text(tr("Cancel"), {font = FONT_TITLE, size = 13, color = TEXT})
			}
			if !single_pane() {if nendo.box(nendo.id("VaultPwBtnsGap"))({width = nendo.grow()}) {}}
			if nendo.box(nendo.id("VaultPwGo"))(
			{
				width = single_pane() ? nendo.grow() : nendo.fit(),
				height = nendo.fit(min = tap_size() ? tap_min() : 0),
				padding = {left = 16, right = 16, top = 9, bottom = 9},
				align = {x = .Center, y = .Center},
				color = bits >= PASSWORD_MIN_BITS ? ACCENT : ROW_BG,
				radius = rr(9),
			},
			) {
				nendo.text(
					tr("Change password"),
					{
						font = FONT_TITLE,
						size = 13,
						color = bits >= PASSWORD_MIN_BITS ? ON_ACCENT : TEXT_LO,
					},
				)
			}
		}
	}
}
