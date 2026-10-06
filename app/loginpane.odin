package main

import "core:math"
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

// Full-width stacked login button.
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

// Indeterminate progress: an accent segment sweeping its track, for
// work with no measurable fraction (a key derivation, the runtime
// start). It never implies a percentage. Reduced motion parks it.
@(private)
busy_bar :: proc(id_str: string) {
	TRACK :: 180
	SEGMENT :: 48
	sweep := f32(0.5)
	if motion_on() {
		sweep = f32(0.5 * (1 + math.sin(rl.GetTime() * 3)))
		anim_moving += 1
	}
	if clay.UI(clay.ID(id_str))(
	{
		layout = {sizing = {clay.SizingFixed(TRACK), clay.SizingFixed(4)}},
		backgroundColor = ROW_BG,
		cornerRadius = rr(2),
	},
	) {
		if clay.UI(clay.ID(id_str, 1))(
		{layout = {sizing = {width = clay.SizingFixed(sweep * (TRACK - SEGMENT))}}},
		) {}
		if clay.UI(clay.ID(id_str, 2))(
		{
			layout = {sizing = {clay.SizingFixed(SEGMENT), clay.SizingFixed(4)}},
			backgroundColor = ACCENT,
			cornerRadius = rr(2),
		},
		) {}
	}
}

@(private = "file")
PAIR_QR_SIZE :: f32(190)

@(private = "file")
login_progress :: proc(job: ^Auth_Job, detail: string) {
	progress_dots("LoginDots")
	busy_bar("LoginBusy")
	if job.session == nil {return}
	clay.Text(
		tr("Keep your signer open. Approve the connection and requested signatures there."),
		{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
	)
	if detail != "" {
		clay.Text(nip46_detail(detail), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
	}
}

// Sign-in forms and pending work; pairing keeps its code beside the progress.
login_pane :: proc(ui: ^Ui_State) {
	pairing := auth_job != nil && auth_job.session != nil && auth_job.method == .Pair
	menu := auth_job == nil && ui.login_method == .Menu
	if clay.UI(clay.ID("LoginCard"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(fit_w(660))},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(pairing || menu ? 24 : 50),
			childGap = 14,
			childAlignment = {x = .Center},
		},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		if !pairing {logo_mark()}
		clay.Text("White Noise", {fontId = FONT_TITLE, fontSize = 28, textColor = TEXT})

		if auth_job != nil {
			// The round trip runs on the sign-in worker; this is the only
			// thing the card offers until drain_auth picks it up.
			minting := auth_job.method == .Create
			remote := auth_job.session != nil
			state, detail := auth_job.signer_state.state, auth_job.signer_state.detail
			if remote && (state == "" || detail == "remote signer not connected") {
				state, detail = "connecting", "connecting to remote signer"
			}
			heading := minting ? tr("Generating your key") : tr("Signing you in")
			if remote &&
			   !(auth_job.remote_login && state == "ready") {heading = nip46_label(state)}
			clay.Text(heading, {fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM})
			if pairing {
				if clay.UI(clay.ID("LoginPairBody"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow({})},
						childGap = 20,
						childAlignment = {y = .Center},
					},
				},
				) {
					if clay.UI(clay.ID("LoginPairWork"))(
					{
						layout = {
							sizing = {width = clay.SizingGrow({})},
							layoutDirection = .TopToBottom,
							childGap = 14,
							childAlignment = {x = .Center},
						},
					},
					) {
						login_progress(auth_job, detail)
					}
					if clay.UI(clay.ID("LoginPairCode"))(
					{
						layout = {
							sizing = {width = clay.SizingFixed(PAIR_QR_SIZE)},
							layoutDirection = .TopToBottom,
							childGap = 14,
							childAlignment = {x = .Center},
						},
					},
					) {
						if ui.login_qr != nil {
							if clay.UI(clay.ID("LoginPairQR"))(
							{
								layout = {
									sizing = {
										clay.SizingFixed(PAIR_QR_SIZE),
										clay.SizingFixed(PAIR_QR_SIZE),
									},
								},
								image = {imageData = ui.login_qr},
							},
							) {}
						} else {
							clay.Text(
								tr(
									"This pairing link is too long for a QR code. Use Copy pairing link.",
								),
								{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
							)
						}
						clay.Text(
							tr(
								"Scan this pairing code in your signer, or copy the nostrconnect link.",
							),
							{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
						)
					}
				}
			} else {
				if clay.UI(clay.ID("LoginGapA"))(
				{layout = {sizing = {height = clay.SizingFixed(10)}}},
				) {}
				login_progress(auth_job, detail)
			}
			if remote {
				if auth_job.signer_state.auth_url !=
				   "" {micro_button("LoginApproval", tr("Review signer approval link"))}
				if clay.UI(clay.ID("LoginRemoteActions"))(
				{layout = {childGap = 12, childAlignment = {y = .Center}}},
				) {
					if pairing {micro_button("LoginPairCopy", tr("Copy pairing link"))}
					micro_button("LoginCancel", tr("Cancel connection"))
				}
			}
			if !pairing {if clay.UI(clay.ID("LoginGapB"))({layout = {sizing = {height = clay.SizingFixed(10)}}}) {}}
			if !remote {clay.Text(minting ? tr("Publishing your profile to the relays. This takes a few seconds.") : tr("Checking your key with the relays. This takes a few seconds."), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO})}
		} else if ui.login_method == .Menu {
			clay.Text(
				tr("Sign in to your Nostr identity"),
				{fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM},
			)
			if clay.UI(clay.ID("LoginGapA"))(
			{layout = {sizing = {height = clay.SizingFixed(10)}}},
			) {}
			if clay.UI(clay.ID("LoginLocalMethods"))(
			{layout = {sizing = {width = clay.SizingGrow({})}, childGap = 14}},
			) {
				login_big_button("LoginImportBtn", tr("I have an nsec"), true)
				login_big_button("LoginCreate", tr("Generate a new key"), false)
			}
			if clay.UI(clay.ID("LoginRemoteMethods"))(
			{layout = {sizing = {width = clay.SizingGrow({})}, childGap = 14}},
			) {
				login_big_button("LoginBunkerBtn", tr("Connect with a bunker link"), false)
				login_big_button("LoginPairBtn", tr("Pair with a remote signer"), false)
			}
			if clay.UI(clay.ID("LoginGapB"))(
			{layout = {sizing = {height = clay.SizingFixed(10)}}},
			) {}
			micro_button("LoginBackup", tr("Import backup"))
		} else {
			clay.Text(
				ui.login_method == .Bunker ? tr("Connect your remote signer") : ui.login_method == .Pair ? tr("Pair with your remote signer") : tr("Import a key"),
				{fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM},
			)
			if clay.UI(clay.ID("LoginGapA"))(
			{layout = {sizing = {height = clay.SizingFixed(10)}}},
			) {}
			eyebrow(
				ui.login_method == .Bunker ? tr("BUNKER LINK") : ui.login_method == .Pair ? tr("SIGNER RELAY") : "NSEC",
			)
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
						ui.login_method == .Bunker ? "bunker://..." : ui.login_method == .Pair ? "wss://..." : "nsec1...",
						{fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM},
					)
				} else if ui.login_method == .Pair {
					clay.Text(
						string(ui.login_input[:]),
						{fontId = FONT_BODY, fontSize = 15, textColor = TEXT},
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
				login_button(
					"LoginGo",
					ui.login_method == .Pair ? tr("Create pairing link") : tr("Continue"),
				)
			}
		}

		if len(ui.login_error) > 0 {
			clay.Text(
				nip46_detail(ui.login_error),
				{fontId = FONT_BODY, fontSize = 14, textColor = DANGER},
			)
			micro_button("LoginErrorCopy", tr("Copy error"))
		}
		// Floats to the root; the settings page hosts the same modal.
		if open_now(clay.ID("BackupModal"), ui.backup_mode != .None) {
			backup_modal(ui)
		}
	}
}
