package main

import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

login_button :: proc(id_str: string, label: string) {
	if clay.UI(clay.ID(id_str))(
	{
		layout = {padding = {left = 18, right = 18, top = 10, bottom = 10}},
		backgroundColor = hovered() ? ACCENT : ROW_BG,
		cornerRadius = rr(8),
		border = bevel_border(),
	},
	) {
		clay.Text(label, {fontId = FONT_BODY, fontSize = 16, textColor = hovered() ? BG : TEXT})
	}
}

@(private)
Button_State :: enum {
	Enabled,
	Disabled,
}

// Full-width stacked login button, the slint sign-in card style.
login_big_button :: proc(
	id_str: string,
	label: string,
	primary: bool,
	state: Button_State = .Enabled,
) {
	if clay.UI(clay.ID(id_str))(
	{
		layout = {
			sizing = {width = clay.SizingGrow({max = 560}), height = clay.SizingFixed(52)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = primary && state == .Enabled ? ACCENT : ROW_BG,
		cornerRadius = rr(10),
		border = primary ? {} : clay.BorderElementConfig{color = FIELD_BORDER, width = bw()},
	},
	) {
		if primary && state == .Enabled {
			hover_glow(clay.ID(id_str), ACCENT, hovered())
		}
		clay.Text(
			label,
			{
				fontId = FONT_TITLE,
				fontSize = 16,
				textColor = state == .Disabled ? TEXT_LO : primary ? ON_ACCENT : TEXT,
			},
		)
	}
}

// Three dots cycling on the accent: the busy indicator for work that
// blocks a pane rather than a row.
progress_dots :: proc(id_str: string) {
	if clay.UI(clay.ID(id_str))({layout = {childGap = 9, childAlignment = {y = .Center}}}) {
		lit := int(rl.GetTime() * 3) % 3
		for i in 0 ..< 3 {
			if clay.UI(clay.ID(id_str, u32(i + 1)))(
			{
				layout = {sizing = {width = clay.SizingFixed(10), height = clay.SizingFixed(10)}},
				backgroundColor = i == lit ? ACCENT : ROW_BG,
				cornerRadius = rr(5),
			},
			) {}
		}
	}
}

// Sign-in card: menu of entry options, or the nsec import form.
login_pane :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("LoginCard"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(fit_w(660))},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(50),
			childGap = 14,
			childAlignment = {x = .Center},
		},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		clay.Text("///", {fontId = FONT_TITLE, fontSize = 34, textColor = ACCENT})
		clay.Text("White Noise", {fontId = FONT_TITLE, fontSize = 28, textColor = TEXT})

		if auth_job != nil {
			// The round trip runs on the sign-in worker; this is the only
			// thing the card offers until drain_auth picks it up.
			minting := len(auth_job.nsec) == 0
			clay.Text(
				minting ? tr("Generating your key") : tr("Signing you in"),
				{fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM},
			)
			if clay.UI(clay.ID("LoginGapA"))(
			{layout = {sizing = {height = clay.SizingFixed(10)}}},
			) {}
			progress_dots("LoginDots")
			if clay.UI(clay.ID("LoginGapB"))(
			{layout = {sizing = {height = clay.SizingFixed(10)}}},
			) {}
			clay.Text(
				minting ? tr("Publishing your profile to the relays. This takes a few seconds.") : tr("Checking your key with the relays. This takes a few seconds."),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
			)
		} else if !ui.login_import {
			clay.Text(
				tr("Sign in to your Nostr identity"),
				{fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM},
			)
			if clay.UI(clay.ID("LoginGapA"))(
			{layout = {sizing = {height = clay.SizingFixed(10)}}},
			) {}
			login_big_button("LoginImportBtn", tr("I have an nsec"), true)
			login_big_button("LoginCreate", tr("Generate a new key"), false)
			if clay.UI(clay.ID("LoginGapB"))(
			{layout = {sizing = {height = clay.SizingFixed(10)}}},
			) {}
			clay.Text(
				tr("Your key never leaves this device."),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
			)
			micro_button("LoginBackup", tr("Import backup"))
		} else {
			clay.Text(
				tr("Import a key"),
				{fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM},
			)
			if clay.UI(clay.ID("LoginGapA"))(
			{layout = {sizing = {height = clay.SizingFixed(10)}}},
			) {}
			eyebrow("NSEC")
			if clay.UI(clay.ID("LoginInput"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow({max = 560}), height = clay.SizingFixed(46)},
					padding = {left = 14, right = 14},
					childAlignment = {y = .Center},
				},
				backgroundColor = ROW_BG,
				cornerRadius = rr(10),
				border = {color = ACCENT, width = bw()},
			},
			) {
				if len(ui.login_input) == 0 {
					clay.Text(
						"nsec1...",
						{fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM},
					)
				} else {
					masked := strings.repeat(
						"*",
						min(len(ui.login_input), 48),
						context.temp_allocator,
					)
					clay.Text(masked, {fontId = FONT_BODY, fontSize = 15, textColor = TEXT})
				}
			}
			if clay.UI(clay.ID("LoginGapB"))(
			{layout = {sizing = {height = clay.SizingFixed(6)}}},
			) {}
			if clay.UI(clay.ID("LoginButtons"))({layout = {childGap = 12}}) {
				login_button("LoginBack", tr("Back"))
				login_button("LoginGo", tr("Continue"))
			}
		}

		if len(ui.login_error) > 0 {
			clay.Text(ui.login_error, {fontId = FONT_BODY, fontSize = 14, textColor = DANGER})
		}
		// Floats to the root; the settings page hosts the same modal.
		if open_now(clay.ID("BackupModal"), ui.backup_mode != .None) {
			backup_modal(ui)
		}
	}
}
