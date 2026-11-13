package main

import "core:math"
import "core:strings"

import "nendo"
import rl "sdlrl"

login_button :: proc(id_str: string, label: string, primary: bool = false) {
	if nendo.box(nendo.id(id_str))(
	{
		width = single_pane() ? nendo.grow() : nendo.fit(),
		height = nendo.fit(min = tap_size() ? tap_min() : 0),
		padding = {left = 18, right = 18, top = 10, bottom = 10},
		align = {x = .Center, y = .Center},
		color = hovered() || primary ? ACCENT : ROW_BG,
		radius = rr(8),
		border = bevel_border(),
	},
	) {
		nendo.text(
			label,
			{font = FONT_BODY, size = 16, color = primary ? ON_ACCENT : hovered() ? BG : TEXT},
		)
	}
}

@(private)
Button_State :: enum {
	Enabled,
	Disabled,
	Busy,
}

// Full-width stacked login button.
login_big_button :: proc(
	id_str: string,
	label: string,
	primary: bool,
	state: Button_State = .Enabled,
) {
	if nendo.box(nendo.id(id_str))(
	{
		width = nendo.grow(max = 560),
		height = nendo.fixed(52),
		align = {x = .Center, y = .Center},
		color = primary && state != .Disabled ? ACCENT : ROW_BG,
		radius = rr(10),
		border = primary && state != .Disabled ? {} : nendo.Border{color = primary ? ACCENT : FIELD_BORDER, width = bw()},
	},
	) {
		if primary && state == .Enabled {
			hover_glow(nendo.id(id_str), ACCENT, hovered())
		}
		nendo.text(
			label,
			{
				font = FONT_TITLE,
				size = 16,
				color = state == .Disabled ? TEXT_LO : primary ? ON_ACCENT : TEXT,
			},
		)
	}
}

// Three dots cycling on the accent: the busy indicator for work that
// blocks a pane rather than a row.
progress_dots :: proc(id_str: string) {
	if nendo.box(nendo.id(id_str))({gap = 9, align = {y = .Center}}) {
		lit := int(rl.GetTime() * 3) % 3
		for i in 0 ..< 3 {
			if nendo.box(nendo.id(id_str, u32(i + 1)))(
			{
				width = nendo.fixed(10),
				height = nendo.fixed(10),
				color = i == lit ? ACCENT : ROW_BG,
				radius = rr(5),
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
	if nendo.box(nendo.id(id_str))(
	{width = nendo.fixed(TRACK), height = nendo.fixed(4), color = ROW_BG, radius = rr(2)},
	) {
		if nendo.box(nendo.id(id_str, 1))({width = nendo.fixed(sweep * (TRACK - SEGMENT))}) {}
		if nendo.box(nendo.id(id_str, 2))(
		{width = nendo.fixed(SEGMENT), height = nendo.fixed(4), color = ACCENT, radius = rr(2)},
		) {}
	}
}

@(private = "file")
PAIR_QR_SIZE :: f32(190)

@(private = "file")
login_progress :: proc(job: ^Auth_Job, detail: string) {
	busy_bar("LoginBusy")
	if job.session == nil {return}
	nendo.text(
		tr("Keep your signer open. Approve the connection and requested signatures there."),
		{font = FONT_BODY, size = 12, color = TEXT_DIM},
	)
	if detail != "" && detail != "connecting to remote signer" {
		nendo.text(nip46_detail(detail), {font = FONT_BODY, size = 12, color = TEXT_DIM})
	}
}

// Sign-in forms and pending work; pairing keeps its code beside the progress.
@(private)
login_viewport: rl.Vector2
@(private)
login_form: Login_Method
@(private)
login_reveal_frames: int

@(private)
login_show: bool
@(private)
login_input_error: bool
@(private = "file")
login_naming: bool
@(private = "file")
login_had_error: bool

login_pane :: proc(ui: ^Ui_State) {
	viewport := rl.Vector2{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	naming := auth_job != nil && auth_job.naming
	if (ui.login_error != "") != login_had_error {
		login_had_error = ui.login_error != ""
		login_reveal_frames = 2
	}
	if viewport != login_viewport || ui.login_method != login_form || naming != login_naming {
		login_viewport, login_form, login_naming = viewport, ui.login_method, naming
		// The first pass still sees nendo's previous viewport; the next
		// sees the keyboard-reduced layout and reveals the focused box.
		login_reveal_frames = 2
	}
	if login_reveal_frames > 0 &&
	   (naming || (auth_job == nil && ui.login_method != .Menu)) &&
	   !ui.socks5_login_open {
		onboard_reveal_field("LoginCard", login_had_error ? "LoginFieldError" : "LoginInput")
		if login_had_error {onboard_reveal_field("LoginCard", "LoginButtons")}
		login_reveal_frames -= 1
	}
	pairing := auth_job != nil && auth_job.session != nil && auth_job.method == .Pair
	menu := auth_job == nil && ui.login_method == .Menu
	if nendo.box(nendo.id("LoginCard"))(
	{
		width = nendo.grow(max = fit_w(660)),
		height = nendo.fit(max = modal_h(1200)),
		direction = .Column,
		padding = nendo.pad(
			single_pane() || f32(rl.GetScreenHeight()) / UI_ZOOM < 500 ? 16 : pairing || menu ? 24 : 50,
		),
		gap = 14,
		align = {x = .Center},
		color = CARD,
		radius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		clip = {y = true, scroll = true},
	},
	) {
		scrollbar(nendo.id("LoginCard"))
		if !ui.socks5_login_open {
			if !pairing {logo_mark()}
			nendo.text("White Noise", {font = FONT_TITLE, size = 28, color = TEXT})
		}

		if ui.socks5_login_open {
			// Reached from the account menu before any identity exists, so
			// say it is optional and that it returns there.
			nendo.text(
				tr(
					"Optional. You can set up a proxy before choosing an account, or later in Network & relays. This does not create an account.",
				),
				{font = FONT_BODY, size = 13, color = TEXT_DIM},
			)
			if nendo.box(nendo.id("LoginProxyHost"))({width = nendo.grow(), direction = .Column}) {
				settings_socks5(ui)
			}
			micro_button("LoginProxyBack", tr("Back to account options"))
		} else if ui.picking_backup {
			nendo.text(tr("Opening file picker…"), {font = FONT_BODY, size = 15, color = TEXT})
			busy_bar("LoginFileBusy")
		} else if naming {
			// A fresh key asks for its public name before it lands.
			nendo.text(
				tr("What should people call you?"),
				{font = FONT_BODY, size = 15, color = TEXT_DIM},
			)
			if nendo.box(nendo.id("LoginGapA"))({height = nendo.fixed(10)}) {}
			eyebrow(tr("DISPLAY NAME"))
			gate_field(ui, "LoginInput", &ui.login_input, true, "", .Plain)
			nendo.text(
				tr("This name is public. You can change it later in your profile."),
				{font = FONT_BODY, size = 12, color = TEXT_LO, align = .Center},
			)
			if ui.login_error != "" {
				if nendo.box(nendo.id("LoginFieldError"))(
				{width = nendo.grow(), direction = .Column, gap = 6},
				) {
					nendo.text(ui.login_error, {font = FONT_BODY, size = 14, color = DANGER})
					micro_button("LoginErrorCopy", tr("Copy error"))
				}
			}
			if nendo.box(nendo.id("LoginGapB"))({height = nendo.fixed(6)}) {}
			if nendo.box(nendo.id("LoginButtons"))({width = nendo.grow(), align = {x = .Center}}) {
				login_big_button(
					"LoginGo",
					tr("Continue"),
					true,
					strings.trim_space(string(ui.login_input[:])) != "" ? .Enabled : .Disabled,
				)
			}
		} else if auth_job != nil {
			// The round trip runs on the sign-in worker; this is the only
			// thing the card offers until drain_auth picks it up.
			minting := auth_job.method == .Create
			remote := auth_job.session != nil
			state, detail := auth_job.signer_state.state, auth_job.signer_state.detail
			if remote && (state == "" || detail == "remote signer not connected") {
				state, detail = "connecting", "connecting to remote signer"
			}
			heading := minting ? tr("Generating your key") : tr("Signing you in")
			if minting && auth_job.name != "" {heading = tr("Publishing your profile")}
			if remote &&
			   !(auth_job.remote_login && state == "ready") {heading = nip46_label(state)}
			nendo.text(heading, {font = FONT_BODY, size = 15, color = TEXT_DIM})
			if pairing {
				if nendo.box(nendo.id("LoginPairBody"))(
				{
					width = nendo.grow(),
					gap = 20,
					direction = single_pane() ? .Column : .Row,
					align = {x = .Center, y = .Center},
				},
				) {
					if nendo.box(nendo.id("LoginPairWork"))(
					{width = nendo.grow(), direction = .Column, gap = 14, align = {x = .Center}},
					) {
						login_progress(auth_job, detail)
					}
					if nendo.box(nendo.id("LoginPairCode"))(
					{
						width = nendo.fixed(PAIR_QR_SIZE),
						direction = .Column,
						gap = 14,
						align = {x = .Center},
					},
					) {
						if ui.login_qr != nil {
							if nendo.box(nendo.id("LoginPairQR"))(
							{
								width = nendo.fixed(PAIR_QR_SIZE),
								height = nendo.fixed(PAIR_QR_SIZE),
								image = ui.login_qr,
							},
							) {}
						} else {
							nendo.text(
								tr(
									"This pairing link is too long for a QR code. Use Copy pairing link.",
								),
								{font = FONT_BODY, size = 12, color = TEXT_DIM},
							)
						}
						nendo.text(
							tr(
								"Scan this pairing code in your signer, or copy the nostrconnect link.",
							),
							{font = FONT_BODY, size = 12, color = TEXT_DIM, align = .Center},
						)
					}
				}
			} else {
				if nendo.box(nendo.id("LoginGapA"))({height = nendo.fixed(10)}) {}
				login_progress(auth_job, detail)
			}
			if remote {
				if auth_job.signer_state.auth_url !=
				   "" {micro_button("LoginApproval", tr("Review signer approval link"))}
				if nendo.box(nendo.id("LoginRemoteActions"))(
				{
					width = nendo.grow(),
					direction = single_pane() ? .Column : .Row,
					gap = 12,
					align = {y = .Center},
				},
				) {
					if pairing {login_big_button("LoginPairCopy", tr("Copy pairing link"), true)}
					login_big_button("LoginCancel", tr("Cancel connection"), false)
				}
			}
			if !pairing {if nendo.box(nendo.id("LoginGapB"))({height = nendo.fixed(10)}) {}}
			if !remote {nendo.text(minting ? tr("Publishing your profile to the relays. This takes a few seconds.") : tr("Checking your key with the relays. This takes a few seconds."), {font = FONT_BODY, size = 12, color = TEXT_LO})}
		} else if ui.login_method == .Menu {
			nendo.text(
				ui.add_account_open ? tr("Add another account") : tr("Create or use an account"),
				{font = FONT_BODY, size = 15, color = TEXT_DIM},
			)
			if nendo.box(nendo.id("LoginGapA"))({height = nendo.fixed(10)}) {}
			if nendo.box(nendo.id("LoginLocalMethods"))(
			{width = nendo.grow(), direction = single_pane() ? .Column : .Row, gap = 14},
			) {
				login_big_button("LoginImportBtn", tr("Import a secret key (nsec)"), false)
				login_big_button("LoginCreate", tr("Generate a new key"), true)
			}
			if nendo.box(nendo.id("LoginRemoteMethods"))(
			{width = nendo.grow(), direction = single_pane() ? .Column : .Row, gap = 14},
			) {
				login_big_button("LoginBunkerBtn", tr("Connect with a bunker link"), false)
				login_big_button("LoginPairBtn", tr("Pair with a remote signer"), false)
			}
			if nendo.box(nendo.id("LoginGapB"))({height = nendo.fixed(10)}) {}
			if nendo.box(nendo.id("LoginExtras"))({gap = 10}) {
				micro_button("LoginBackup", tr("Import backup"))
				micro_button("LoginProxy", tr("SOCKS5 proxy"))
			}
		} else {
			nendo.text(
				ui.login_method == .Bunker ? tr("Connect your remote signer") : ui.login_method == .Pair ? tr("Pair with your remote signer") : tr("Import a key"),
				{font = FONT_BODY, size = 15, color = TEXT_DIM},
			)
			// Remote methods hand signing to another app. Say where the key
			// lives and where approvals happen before any session starts, so
			// "Pair" doesn't read as copying another device's chats.
			if ui.login_method == .Bunker || ui.login_method == .Pair {
				nendo.text(
					tr(
						"Your secret key stays in your signer, and this device only asks it to sign. Approve the connection and each signature there, so keep your signer open. This device can't reveal or export the key, so back it up and recover it through your signer.",
					),
					{font = FONT_BODY, size = 13, color = TEXT_DIM, align = .Center},
				)
			}
			if nendo.box(nendo.id("LoginGapA"))({height = nendo.fixed(10)}) {}
			eyebrow(
				ui.login_method == .Bunker ? tr("BUNKER LINK") : ui.login_method == .Pair ? tr("SIGNER RELAY") : "NSEC",
			)
			gate_field(
				ui,
				"LoginInput",
				&ui.login_input,
				true,
				ui.login_method == .Bunker ? "bunker://..." : ui.login_method == .Pair ? "wss://..." : "nsec1...",
				login_show || ui.login_method == .Pair ? .Plain : .Masked,
			)
			if nendo.box(nendo.id("LoginInputTools"))({width = nendo.grow(), gap = 12}) {
				login_button("LoginPaste", tr("Paste"))
				if ui.login_method !=
				   .Pair {login_button("LoginShow", login_show ? tr("Hide") : tr("Show"))}
			}
			if ui.login_error != "" {
				if nendo.box(nendo.id("LoginFieldError"))(
				{width = nendo.grow(), direction = .Column, gap = 6},
				) {
					nendo.text(
						nip46_detail(ui.login_error),
						{font = FONT_BODY, size = 14, color = DANGER},
					)
					if !login_input_error {micro_button("LoginErrorCopy", tr("Copy error"))}
				}
			}
			if nendo.box(nendo.id("LoginGapB"))({height = nendo.fixed(6)}) {}
			if nendo.box(nendo.id("LoginButtons"))({width = nendo.grow(), gap = 12}) {
				login_button("LoginBack", tr("Back"))
				login_big_button(
					"LoginGo",
					ui.login_method == .Pair ? tr("Create pairing link") : tr("Continue"),
					true,
					len(ui.login_input) > 0 ? .Enabled : .Disabled,
				)
			}
			// Every form here signs in an existing identity. Each installation
			// publishes its own key package and keeps its own MLS state, so a
			// second device starts with none of the first one's chats.
			if nendo.box(nendo.id("LoginGapC"))({height = nendo.fixed(6)}) {}
			nendo.text(
				tr(
					"Multi-device isn't built yet. Each device that signs in with this key keeps its own separate chats. Groups and messages from your other devices won't appear here, and new invites reach only one of your devices.",
				),
				{font = FONT_BODY, size = 12, color = TEXT_LO, align = .Center},
			)
		}

		if len(ui.login_error) > 0 && !naming && (auth_job != nil || ui.login_method == .Menu) {
			nendo.text(nip46_detail(ui.login_error), {font = FONT_BODY, size = 14, color = DANGER})
			if !login_input_error {micro_button("LoginErrorCopy", tr("Copy error"))}
		}
		// Floats to the root; the settings page hosts the same modal.
		if open_now(nendo.id("BackupModal"), ui.backup_mode != .None) {
			backup_modal(ui)
		}
	}
}
