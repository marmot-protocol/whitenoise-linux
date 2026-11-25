package main

import "core:fmt"
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
		border = kb_focus == id_str ? kb_ring(ACCENT) : bevel_border(),
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
	id := nendo.id(id_str)
	enabled := state == .Enabled
	hot := enabled && nendo.pointer_over(id)
	over := anim_to(anim_key(id.id, 3), hot ? 1 : 0, HOVER_RATE)
	down := enabled ? press_down(id) : 0
	fill := primary && state != .Disabled ? ACCENT : ROW_BG
	fill = mix_color(fill, primary ? TEXT : HOVER, over * (primary ? 0.05 : 1))
	if down > 0 {fill = mix_color(fill, primary ? BG : TEXT, 0.07)}
	if nendo.box(id)(
	{
		width = nendo.grow(max = 560),
		height = nendo.fixed(52),
		padding = {top = 2 + down, bottom = 2 - down},
		align = {x = .Center, y = .Center},
		color = fill,
		radius = rr(10),
		border = enabled && kb_focus == id_str ? kb_ring(primary ? ON_ACCENT : ACCENT) : {color = primary && state != .Disabled ? fade(ON_ACCENT, 0.1 + 0.1 * over) : primary ? ACCENT : mix_color(FIELD_BORDER, ACCENT, over * 0.35), width = bw()},
	},
	) {
		if enabled && hot {cursor_raise(.Pointer)}
		if primary && enabled {
			hover_glow(id, ACCENT, hot)
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
busy_bar :: proc(id_str: string, max_width: f32 = 180) {
	track := clamp(max_width, 0, 180)
	segment := min(48, track * 0.5)
	sweep := f32(0.5)
	if motion_on() {
		sweep = f32(0.5 * (1 + math.sin(rl.GetTime() * 3)))
		anim_moving += 1
	}
	if nendo.box(nendo.id(id_str))(
	{width = nendo.fixed(track), height = nendo.fixed(4), color = ROW_BG, radius = rr(2)},
	) {
		if nendo.box(nendo.id(id_str, 1))({width = nendo.fixed(sweep * (track - segment))}) {}
		if nendo.box(nendo.id(id_str, 2))(
		{width = nendo.fixed(segment), height = nendo.fixed(4), color = ACCENT, radius = rr(2)},
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
	if detail != "" {
		nendo.text(nip46_detail(detail), {font = FONT_BODY, size = 12, color = TEXT_DIM})
	}
}

@(private)
starter_focus :: proc() -> string {
	if kb_focus != "" {return kb_focus}
	if !tap_size() || touch_field == nendo.id("LoginInput") {return "LoginInput"}
	return ""
}

@(private = "file")
login_starter :: proc(ui: ^Ui_State, job: ^Auth_Job) {
	heading := nendo.Text_Style {
		font  = FONT_TITLE,
		size  = 17,
		color = TEXT,
	}
	body := nendo.Text_Style {
		font  = FONT_BODY,
		size  = 14,
		color = TEXT_DIM,
	}
	switch job.starter_phase {
	case .Prepare, .Create:
		nendo.text(
			job.starter_phase == .Prepare ? tr("Preparing your starter profile") : tr("Creating your account and publishing your profile"),
			heading,
		)
		busy_bar("LoginBusy")
	case .Review:
		nendo.text(tr("Review your public profile"), heading)
		if nendo.box(nendo.id("LoginStarterProfile"))(
		{width = nendo.grow(), gap = 12, align = {y = .Center}},
		) {
			if nendo.box(nendo.id("LoginStarterPicture"))(
			{
				width = nendo.fixed(64),
				height = nendo.fixed(64),
				image = &job.starter_preview,
				radius = rr(8),
			},
			) {}
			if nendo.box(nendo.id("LoginStarterName"))(
			{width = nendo.grow(), direction = .Column, gap = 4},
			) {
				eyebrow(tr("DISPLAY NAME"))
				gate_field(
					ui,
					"LoginInput",
					&ui.login_input,
					starter_focus() == "LoginInput",
					"",
					.Plain,
				)
			}
		}
		nendo.text(tr("White Noise uploads your picture to this public image server:"), body)
		nendo.text(string(STARTER_BLOSSOM), body)
		nendo.text(
			tr(
				"Your name and a link to your picture go to public Nostr relays so people can recognize you.",
			),
			body,
		)
		nendo.text(tr("This step does not publish your chats."), body)
		if nendo.box(nendo.id("LoginButtons"))(
		{
			width = nendo.grow(),
			gap = 12,
			direction = single_pane() ? .Column : .Row,
			align = {y = .Center},
		},
		) {
			login_button("LoginBack", tr("Back"))
			login_big_button(
				"LoginCreatePublish",
				tr("Create and publish"),
				true,
				strings.trim_space(string(ui.login_input[:])) != "" ? .Enabled : .Disabled,
			)
		}
	case .Result:
		if job.err != "" {
			nendo.text(job.err, heading)
			if job.starter_saved {nendo.text(tr("Your account key was saved on this device."), body)}
			nendo.text(tr("Your starter picture and profile weren't sent."), body)
			login_big_button("LoginCreateRetry", tr("Try again"), true)
			login_button("LoginBack", tr("Back to account options"))
			return
		}
		nendo.text(tr("Your account was created"), heading)
		nendo.text(
			job.pic_url != "" ? tr("Your picture was uploaded.") : tr("Your picture upload wasn't confirmed."),
			body,
		)
		nendo.text(
			job.profile_confirmed ? tr("At least one Nostr relay accepted your profile.") : tr("Your profile publication wasn't confirmed."),
			body,
		)
		login_big_button("LoginCreateContinue", tr("Continue"), true)
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
login_starter_phase: Starter_Phase
@(private = "file")
login_had_error: bool

login_pane :: proc(ui: ^Ui_State) {
	viewport := rl.Vector2{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	starter := auth_job != nil && auth_job.method == .Create
	starter_phase := starter ? auth_job.starter_phase : .Prepare
	if starter_phase != login_starter_phase {
		login_starter_phase = starter_phase
		if scroll := nendo.scroll(nendo.id("LoginCard")); scroll.found {scroll.position.y = 0}
	}
	if (ui.login_error != "") != login_had_error {
		login_had_error = ui.login_error != ""
		login_reveal_frames = 2
	}
	if viewport != login_viewport || ui.login_method != login_form {
		login_viewport, login_form = viewport, ui.login_method
		// The first pass still sees nendo's previous viewport; the next
		// sees the keyboard-reduced layout and reveals the focused box.
		login_reveal_frames = 2
	}
	if login_reveal_frames > 0 && !ui.socks5_login_open {
		if starter_phase == .Review {
			if field := starter_focus(); field != "" {onboard_reveal_field("LoginCard", field)}
			login_reveal_frames -= 1
		} else if auth_job == nil && ui.login_method != .Menu {
			onboard_reveal_field("LoginCard", login_had_error ? "LoginFieldError" : "LoginInput")
			if login_had_error {onboard_reveal_field("LoginCard", "LoginButtons")}
			login_reveal_frames -= 1
		}
	}
	pairing := auth_job != nil && auth_job.method == .Pair && ui.login_uri != ""
	menu := auth_job == nil && ui.login_method == .Menu
	first_account := len(ui.accounts) == 0 && !ui.add_account_open
	if nendo.box(nendo.id("LoginCard"))(
	{
		width = nendo.percent(1, max = first_account && !pairing ? 480 : 660),
		height = nendo.fit(max = modal_h(1200)),
		direction = .Column,
		padding = nendo.pad(
			single_pane() || f32(rl.GetScreenHeight()) / UI_ZOOM < 500 ? 16 : first_account || pairing || menu || starter ? 24 : 50,
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
		if first_account {
			onboard_steps(.Account)
		} else if !ui.socks5_login_open {
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
		} else if starter {
			login_starter(ui, auth_job)
		} else if auth_job != nil && auth_job.reviewing {
			// MDK refuses to pair or connect until these exact grants are approved.
			nendo.text(
				tr("Review signer permissions"),
				{font = FONT_BODY, size = 15, color = TEXT_DIM},
			)
			nendo.text(
				tr(
					"White Noise will ask your signer for these permissions. Your signer may ask you to confirm them too.",
				),
				{font = FONT_BODY, size = 13, color = TEXT_DIM, align = .Center},
			)
			if nendo.box(nendo.id("LoginGrants"))(
			{
				width = nendo.grow(),
				direction = .Column,
				gap = 6,
				padding = nendo.pad(12),
				color = ROW_BG,
				radius = rr(8),
			},
			) {
				nip46_grants_ui(auth_job.grants)
			}
			if nendo.box(nendo.id("LoginRemoteActions"))(
			{
				width = nendo.grow(),
				direction = single_pane() ? .Column : .Row,
				gap = 12,
				align = {y = .Center},
			},
			) {
				login_big_button("LoginAllow", tr("Allow and connect"), true)
				login_big_button("LoginCancel", tr("Cancel connection"), false)
			}
		} else if auth_job != nil {
			// The round trip runs on the sign-in worker; this is the only
			// thing the card offers until drain_auth picks it up.
			remote := auth_job.session != nil
			state, detail := auth_job.signer_state.state, auth_job.signer_state.detail
			// Approval leaves the session "unavailable" until connect starts.
			if remote && (state == "" || (state == "unavailable" && detail == "")) {
				state = "connecting"
			}
			heading := tr("Signing you in")
			if remote &&
			   !(auth_job.remote_login && state == "ready") {heading = nip46_label(state)}
			if auth_job.method == .Pair &&
			   ui.login_uri == "" &&
			   detail == "" {heading = tr("Preparing your pairing code")}
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
			if !remote {nendo.text(tr("Checking your key with the relays. This takes a few seconds."), {font = FONT_BODY, size = 12, color = TEXT_LO})}
		} else if ui.login_method == .Menu {
			nendo.text(
				ui.add_account_open ? tr("Add another account") : first_account ? tr("Import your key, create one, or connect a signer.") : tr("Add your Nostr identity"),
				{font = FONT_BODY, size = 15, color = TEXT_DIM},
			)
			if nendo.box(nendo.id("LoginGapA"))({height = nendo.fixed(10)}) {}
			if ui.account_ref == "" && len(ui.accounts) != 0 {
				login_big_button("LoginChooseAccount", tr("Choose an account"), false)
			}
			if ui.account_ref == "" && accounts_have_tombstones(ui) {
				login_big_button("LoginUnlinkedProfiles", tr("Review unlinked profiles"), false)
			}
			// A signed-out account keeps its key in the vault, so it comes
			// back without the nsec.
			signing_in := account_signing_in()
			for account, i in ui.signed_out_accounts {
				busy := signing_in == account.id_hex
				login_big_button(
					fmt.tprintf("LoginResume%d", i),
					busy ? tr("Signing you in") : fmt.tprintf(tr("Sign in as %s"), account.name),
					false,
					busy ? .Busy : signing_in != "" ? .Disabled : .Enabled,
				)
				if busy {busy_bar("LoginResumeBusy")}
			}
			if nendo.box(nendo.id("LoginLocalMethods"))(
			{
				width = nendo.grow(),
				direction = first_account || single_pane() ? .Column : .Row,
				gap = 14,
			},
			) {
				login_big_button("LoginImportBtn", tr("Import a secret key (nsec)"), false)
				login_big_button("LoginCreate", tr("Generate a new key"), true)
			}
			if nendo.box(nendo.id("LoginRemoteMethods"))(
			{
				width = nendo.grow(),
				direction = first_account || single_pane() ? .Column : .Row,
				gap = 14,
			},
			) {
				login_big_button("LoginBunkerBtn", tr("Connect with a bunker link"), false)
				login_big_button("LoginPairBtn", tr("Pair with a remote signer"), false)
			}
			if nendo.box(nendo.id("LoginGapB"))({height = nendo.fixed(10)}) {}
			if nendo.box(nendo.id("LoginExtras"))({gap = 10}) {
				micro_button("LoginBackup", tr("Import backup"))
				micro_button("LoginProxy", tr("Connection settings (SOCKS5 proxy)"))
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
			if nendo.box(nendo.id("LoginGapC"))({height = nendo.fixed(6)}) {}
			nendo.text(
				tr("After signing in, open Account & devices in Settings to link another device."),
				{font = FONT_BODY, size = 12, color = TEXT_LO, align = .Center},
			)
		}

		if len(ui.login_error) > 0 && (auth_job != nil || ui.login_method == .Menu) {
			nendo.text(nip46_detail(ui.login_error), {font = FONT_BODY, size = 14, color = DANGER})
			if !login_input_error {micro_button("LoginErrorCopy", tr("Copy error"))}
		}
		// Floats to the root; the settings page hosts the same modal.
		if open_now(nendo.id("BackupModal"), ui.backup_mode != .None) {
			backup_modal(ui)
		}
	}
}
