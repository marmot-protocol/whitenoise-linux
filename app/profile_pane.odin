package main

import "core:fmt"
import "core:strings"
import "nendo"

// The Profile page's rail, in place of the chat list: the accounts on
// this device (tap to switch), and the two settings sections that own
// the rest of an identity. A chat filter over "Search messages..."
// makes no sense while you're looking at your own profile.
profile_rail :: proc(ui: ^Ui_State) {
	if nendo.box(nendo.id("PrHead"))({padding = {left = 4, top = 6, bottom = 4}}) {
		nendo.text(
			fmt.tprintf(tr("ACCOUNTS   %d"), len(ui.accounts)),
			{font = FONT_MONO, size = 12, color = TEXT_DIM, spacing = 2},
		)
	}

	for account, i in ui.accounts {
		active := account.id_hex == ui.account_ref
		if nendo.box(nendo.id("PrAcct", u32(i)))(
		{
			width = nendo.grow(),
			padding = nendo.pad(10),
			gap = 10,
			align = {y = .Center},
			color = active ? SELECTED : (hovered() ? HOVER : {}),
			radius = rr(10),
		},
		) {
			avatar("PrAcctAv", u32(i), account.id_hex, account.name, 30, url_pic(account.pic_url))
			if nendo.box(nendo.id("PrAcctCol", u32(i)))(
			{width = nendo.grow(), direction = .Column, gap = 2, clip = {x = true, scroll = true}},
			) {
				nendo.text(
					account.name,
					{font = FONT_TITLE, size = 13, color = active ? TEXT : TEXT_DIM},
				)
				nendo.text(npub_tail(account.npub), {font = FONT_MONO, size = 10, color = TEXT_LO})
				if account.external {nip46_status_ui(ui, account.id_hex, u32(i))}
			}
			scrollbar(nendo.id("PrAcctCol", u32(i)))
			if active {
				nendo.text(tr("ACTIVE"), {font = FONT_MONO, size = 9, color = ACCENT, spacing = 2})
			}
			account_remove_button("PrAcctRemove", u32(i))
		}
	}
	if nendo.box(nendo.id("PrAddRow"))({padding = {left = 4, top = 4, bottom = 8}}) {
		micro_button("PrAddAccount", tr("Add account"))
	}

	if nendo.box(nendo.id("PrRule"))(
	{width = nendo.grow(), height = nendo.fixed(1), color = DIVIDER},
	) {}
	if nendo.box(nendo.id("PrLinksHead"))({padding = {left = 4, top = 8, bottom = 4}}) {
		nendo.text(tr("IDENTITY"), {font = FONT_MONO, size = 12, color = TEXT_DIM, spacing = 2})
	}
	profile_rail_link("PrKeys", ICON_KEY, tr("Keys & identity"))
	profile_rail_link("PrNetwork", ICON_GLOBE, tr("Network & relays"))
}

// One jump row, the settings-sidebar grammar.
@(private = "file")
profile_rail_link :: proc(id_str: string, icon: string, label: string) {
	if nendo.box(nendo.id(id_str))(
	{
		width = nendo.grow(),
		height = nendo.fit(min = settings_tap_size(34)),
		padding = {left = 12, right = 12, top = 9, bottom = 9},
		gap = 10,
		align = {y = .Center},
		color = hovered() ? HOVER : {},
		radius = rr(9),
	},
	) {
		nendo.text(icon, {font = FONT_ICON, size = 13, color = TEXT_DIM})
		nendo.text(label, {font = FONT_TITLE, size = 13, color = TEXT_DIM})
	}
}

// One LABEL · input row of the profile edit form.
form_row :: proc(
	ui: ^Ui_State,
	index: u32,
	label: string,
	box_id: string,
	buf: ^[dynamic]u8,
	placeholder: string,
	active: bool,
) {
	if nendo.box(nendo.id("ProfileFormRow", index))(
	{
		width = nendo.grow(),
		direction = single_pane() ? .Column : .Row,
		gap = 12,
		align = {y = .Center},
	},
	) {
		if nendo.box(nendo.id("ProfileFormLabel", index))({width = nendo.fixed(120)}) {
			nendo.text(label, {font = FONT_MONO, size = 10, color = TEXT_LO, spacing = 2})
		}
		input_box(ui, box_id, buf, placeholder, active, 0)
	}
}

// One label-left / value-right hairline row in the PROFILE card.
// Read-only; the explicit Edit profile button opens the form.
profile_kv :: proc(
	index: u32,
	label: string,
	value: string,
	last := false,
	font: u16 = FONT_BODY,
) {
	FONT_BODY := font
	FONT_TITLE := font == 0 ? u16(1) : font
	if nendo.box(nendo.id("ProfileKv", index))(
	{
		width = nendo.grow(),
		direction = single_pane() ? .Column : .Row,
		padding = {left = 16, right = 16, top = 12, bottom = 12},
		align = {y = .Center},
		gap = 10,
	},
	) {
		nendo.text(label, {font = FONT_TITLE, size = 12, color = TEXT})
		if nendo.box(nendo.id("ProfileKvGap", index))({width = nendo.grow()}) {}
		if nendo.box(nendo.id("ProfileKvValue", index))(
		{
			width = single_pane() ? nendo.grow() : nendo.fit(max = g_ui == nil ? 400 : max(1, page_w(g_ui) - 240)),
			clip = {x = true, scroll = true},
		},
		) {
			nendo.text(
				len(value) > 0 ? value : tr("Not set"),
				{font = FONT_BODY, size = 12, color = TEXT_DIM, wrap = .None},
			)
		}
		scrollbar(nendo.id("ProfileKvValue", index))
	}
	if !last {
		if nendo.box(nendo.id("ProfileKvRule", index))(
		{width = nendo.grow(), height = nendo.fixed(1), color = DIVIDER},
		) {}
	}
}

// Profile viewer: header and Edit toggle, banner hero,
// IDENTITY (npub + inline QR), PROFILE rows, accounts. Relays and the
// nsec moved to Settings (Network / Keys) and left this page.
profile_pane :: proc(ui: ^Ui_State) {
	style := profile_style(ui.account_ref)
	body_font, title_font := profile_font(style.fonts[0]), profile_font(style.fonts[1])
	FONT_BODY := body_font != 0 ? body_font : u16(0)
	FONT_TITLE := body_font != 0 ? body_font : u16(1)
	old := profile_palette(profile_colors(style))
	defer profile_palette(old)
	background := profile_background(style)
	if nendo.box(nendo.id("ProfilePage"))(
	{
		width = nendo.grow(),
		height = nendo.grow(),
		direction = .Column,
		padding = {
			left = single_pane() ? 12 : 20,
			right = single_pane() ? 12 : 20,
			top = single_pane() ? 12 : 20,
			bottom = 36,
		},
		gap = 12,
		color = background == nil ? BG : nendo.Color{},
		custom = background,
		clip = {y = true, scroll = true},
	},
	) {
		// ── Header: title + visibility eyebrow, Edit toggle right ──
		if nendo.box(nendo.id("ProfileHead"))(
		{
			width = nendo.grow(),
			direction = single_pane() ? .Column : .Row,
			gap = 10,
			align = {y = .Center},
		},
		) {
			if nendo.box(nendo.id("ProfileHeadCol"))(
			{width = nendo.grow(), direction = .Column, gap = 3},
			) {
				nendo.text(tr("Your profile"), {font = FONT_TITLE, size = 22, color = TEXT})
				nendo.text(
					ui.profile.editing ? tr("EDITING · BROADCAST TO RELAYS ON PUBLISH") : tr("PUBLIC PROFILE"),
					{font = FONT_MONO, size = 10, color = TEXT_LO, spacing = 2},
				)
			}
			if nendo.box(nendo.id("ProfileHeadGap"))({width = nendo.grow()}) {}
			if nendo.box(nendo.id("EditProfileBtn"))(
			{
				height = nendo.fit(min = settings_tap_size(32)),
				padding = {left = 14, right = 14, top = 8, bottom = 8},
				gap = 8,
				align = {y = .Center},
				color = ui.profile.editing ? (hovered() ? HOVER : ROW_BG) : ACCENT,
				radius = rr(9),
				border = ui.profile.editing ? nendo.Border{color = FIELD_BORDER, width = bw()} : {},
			},
			) {
				if !ui.profile.editing {
					nendo.text(ICON_PENCIL, {font = FONT_ICON, size = 12, color = ON_ACCENT})
				}
				nendo.text(
					ui.profile.editing ? tr("Cancel") : tr("Edit profile"),
					{font = FONT_TITLE, size = 13, color = ui.profile.editing ? TEXT : ON_ACCENT},
				)
			}
		}

		// ── Hero: banner, avatar riding the seam, live-draft name ──
		//
		//   ┌───────────────────────────── banner (ACCENT) ──┐
		//   │                                        ○  ○  ◯ │
		//   │  ╭────╮                                        │
		//   └──│ ◉◉ │────────────────────────────────────────┘
		//      │ 96 │✎   Name            (draft-live in edit)
		//      ╰────╯    @handle · about
		if nendo.box(nendo.id("ProfileHero"))(
		{
			width = nendo.grow(),
			direction = .Column,
			color = ROW_BG,
			radius = rr(14),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			if !ui.profile.editing {
				if nendo.box(nendo.id("ProfileBanner"))(
				{
					width = nendo.grow(),
					height = nendo.fixed(88),
					padding = {right = 24},
					gap = 10,
					align = {y = .Center},
					color = ACCENT,
					radius = {top_left = 14, top_right = 14},
				},
				) {
					// Quiet dot ornament so the band reads designed, not
					// unfinished, on every pack's accent.
					if nendo.box(nendo.id("BannerFill"))({width = nendo.grow()}) {}
					for size, i in ([3]f32{18, 30, 46}) {
						if nendo.box(nendo.id("BannerDot", u32(i)))(
						{
							width = nendo.fixed(size),
							height = nendo.fixed(size),
							color = {255, 255, 255, 28},
							radius = rr(size / 2),
						},
						) {}
					}
				}
			}

			// The avatar overlaps the banner/body seam. In edit mode
			// the whole circle picks a new picture, badged with ✎.
			if nendo.box(nendo.id("ProfileAvatarPick"))(
			{
				width = nendo.fixed(96),
				height = nendo.fixed(96),
				floating = {
					attach_to = .Parent,
					clip_to = .Parent,
					z = 5,
					offset = {24, ui.profile.editing ? 16 : 40},
					attach = {element = .Left_Top, parent = .Left_Top},
				},
			},
			) {
				if ui.profile.editing && hovered() {
					tooltip(tr("Change picture"))
				}
				avatar(
					"ProfileAvatar",
					0,
					ui.account_ref,
					len(ui.profile.name) > 0 ? ui.profile.name : profile_label(nil, ui.account_ref),
					96,
					url_pic(ui.my_pic_url),
				)
				if ui.profile.editing {
					if nendo.box(nendo.id("ProfileAvatarBadge"))(
					{
						width = nendo.fixed(30),
						height = nendo.fixed(30),
						align = {x = .Center, y = .Center},
						floating = {
							attach_to = .Parent,
							clip_to = .Parent,
							z = 6,
							offset = {2, 2},
							attach = {element = .Right_Bottom, parent = .Right_Bottom},
						},
						color = ACCENT,
						radius = rr(15),
						border = {color = ROW_BG, width = {2, 2, 2, 2, 0}},
					},
					) {
						nendo.text(ICON_PENCIL, {font = FONT_ICON, size = 12, color = ON_ACCENT})
					}
				}
			}

			if nendo.box(nendo.id("ProfileHeroRow"))(
			{
				width = nendo.grow(),
				height = nendo.fit(min = ui.profile.editing ? 128 : 0),
				padding = {
					left = single_pane() ? 16 : 136,
					right = single_pane() ? 16 : 24,
					top = ui.profile.editing ? (single_pane() ? 124 : 28) : (single_pane() ? 60 : 14),
					bottom = 18,
				},
				gap = 14,
				align = {y = .Center},
			},
			) {
				if nendo.box(nendo.id("ProfileHeroCol"))(
				{width = nendo.grow(), direction = .Column, gap = 3},
				) {
					// Only the name previews here so About cannot shift the fields.
					shown_name := ui.profile.editing ? string(ui.name_input[:]) : ui.profile.name
					name_font := title_font != 0 ? title_font : FONT_TITLE
					name_w := nendo.element(nendo.id("ProfileHeroCol")).rect.width
					if name_w <= 0 {name_w = max(1, page_w(ui) - (single_pane() ? 80 : 220))}
					nendo.text(
						text_ellipsis(
							len(shown_name) > 0 ? shown_name : tr("(no display name)"),
							name_w,
							name_font,
							24,
						),
						{font = name_font, size = 24, color = TEXT, wrap = .None},
					)
					nendo.text(
						text_ellipsis(
							len(ui.profile.username) > 0 ? fmt.tprintf("@%s", ui.profile.username) : npub_tail(ui.profile.npub),
							name_w,
							FONT_BODY,
							12,
						),
						{font = FONT_BODY, size = 12, color = TEXT_LO, wrap = .None},
					)
					if !ui.profile.editing && len(ui.profile.about) > 0 {
						nendo.text(
							ui.profile.about,
							{font = FONT_BODY, size = 13, color = TEXT_DIM},
						)
					}
				}
			}
		}

		// ── Edit form: every kind-0 field the app lets you set ─────
		if ui.profile.editing {
			if nendo.box(nendo.id("FormEyebrow"))({padding = {top = 6}}) {
				eyebrow(tr("EDIT PROFILE"))
			}
			if nendo.box(nendo.id("ProfileForm"))(
			{
				width = nendo.grow(),
				direction = .Column,
				padding = {left = 16, right = 16, top = 14, bottom = 14},
				gap = 10,
				color = ROW_BG,
				radius = rr(12),
				border = {color = FIELD_BORDER, width = bw()},
			},
			) {
				form_row(
					ui,
					0,
					tr("DISPLAY NAME"),
					"NameBox",
					&ui.name_input,
					tr("Not set"),
					ui.focus == .Name,
				)
				if strings.trim_space(string(ui.name_input[:])) == "" {
					nendo.text(
						tr("Enter a display name."),
						{font = FONT_BODY, size = 12, color = DANGER},
					)
				}
				eyebrow(tr("ABOUT"))
				multiline_field(ui, &ui.about_input, .About, tr("Not set"), 100)
				form_row(
					ui,
					2,
					tr("VERIFIED ADDRESS"),
					"Nip05Box",
					&ui.nip05_input,
					tr("Leave empty unless you have one"),
					ui.focus == .Nip05,
				)
				if !profile_addr_valid(string(ui.nip05_input[:])) {
					nendo.text(
						tr("Couldn't use this Nostr address. Double-check it and try again."),
						{font = FONT_BODY, size = 12, color = DANGER},
					)
				}
				nendo.text(
					tr(
						"Optional Nostr identifier (NIP-05), not your email address. This is public.",
					),
					{font = FONT_BODY, size = 11, color = TEXT_DIM},
				)
				form_row(
					ui,
					3,
					tr("LIGHTNING"),
					"Lud16Box",
					&ui.lud16_input,
					tr("Not set"),
					ui.focus == .Lud16,
				)
				if !profile_addr_valid(string(ui.lud16_input[:])) {
					nendo.text(
						tr("Couldn't use this Lightning address. Double-check it and try again."),
						{font = FONT_BODY, size = 12, color = DANGER},
					)
				}
				if nendo.box(nendo.id("ProfileFormActions"))(
				{
					width = nendo.grow(),
					direction = single_pane() ? .Column : .Row,
					gap = 10,
					padding = {top = 6},
					align = {y = .Center},
				},
				) {
					if ppic_busy {
						micro_button("ChangePicBtn", tr("Uploading picture"))
					} else {
						micro_button("ChangePicBtn", tr("Change picture"))
					}
					if nendo.box(nendo.id("FormActionGap"))({width = nendo.grow()}) {}
					if !single_pane() && !tap_size() {
						nendo.text(
							tr("Enter moves to the next field, Escape cancels."),
							{font = FONT_BODY, size = 10, color = TEXT_LO},
						)
					}
					ready := profile_ready(ui)
					if nendo.box(nendo.id("PublishProfileBtn"))(
					{
						height = nendo.fit(min = settings_tap_size(32)),
						padding = {left = 16, right = 16, top = 9, bottom = 9},
						align = {x = .Center, y = .Center},
						color = ready ? ACCENT : FIELD_BORDER,
						radius = rr(9),
					},
					) {
						nendo.text(
							tr("Publish changes"),
							{font = FONT_TITLE, size = 13, color = ready ? ON_ACCENT : TEXT_LO},
						)
					}
				}
			}
		}

		// ── Identity: copyable npub + inline QR ────────────────────
		if nendo.box(nendo.id("IdEyebrow"))({padding = {top = 6}}) {
			eyebrow(tr("IDENTITY"))
		}
		if nendo.box(nendo.id("ProfileIdCard"))(
		{
			width = nendo.grow(),
			direction = .Column,
			color = ROW_BG,
			radius = rr(10),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			if nendo.box(nendo.id("ProfileNpubRow"))(
			{
				width = nendo.grow(),
				direction = single_pane() ? .Column : .Row,
				padding = {left = 16, right = 12, top = 10, bottom = 10},
				gap = 12,
				align = {y = .Center},
			},
			) {
				if nendo.box(nendo.id("ProfileNpubCol"))({direction = .Column, gap = 2}) {
					nendo.text("npub", {font = FONT_TITLE, size = 12, color = TEXT})
					nendo.text(
						tr("Your public key. Safe to share."),
						{font = FONT_BODY, size = 10, color = TEXT_LO},
					)
				}
				if nendo.box(nendo.id("ProfileNpubGap"))({width = nendo.grow()}) {}
				nendo.text(
					npub_tail(ui.profile.npub),
					{font = FONT_MONO, size = 11, color = TEXT_DIM},
				)
				micro_button("ProfileCopyNpub", tr("Copy"))
			}
			if ui.profile.qr != nil {
				identity_w := nendo.element(nendo.id("ProfileIdCard")).rect.width
				if identity_w <= 0 {identity_w = page_w(ui) - 40}
				identity_codes(
					"Profile",
					ui.account_ref,
					ui.profile.qr,
					identity_w,
					tr("Scan to add you as a contact."),
					font = FONT_TITLE,
				)
			}
		}

		// ── Profile fields, viewer rows ────────────────────────────
		if !ui.profile.editing {
			if nendo.box(nendo.id("ProfileEyebrow"))({padding = {top = 6}}) {
				eyebrow(tr("PROFILE"))
			}
			if nendo.box(nendo.id("ProfileCard"))(
			{
				width = nendo.grow(),
				direction = .Column,
				color = ROW_BG,
				radius = rr(10),
				border = {color = FIELD_BORDER, width = bw()},
			},
			) {
				profile_kv(
					0,
					tr("Username"),
					len(ui.profile.username) > 0 ? fmt.tprintf("@%s", ui.profile.username) : "",
					font = FONT_BODY,
				)
				profile_kv(1, tr("Verified address"), ui.profile.nip05, font = FONT_BODY)
				profile_kv(2, tr("Lightning"), ui.profile.lud16, true, font = FONT_BODY)
			}
		}

		if single_pane() {micro_button("ProfileAccounts", tr("Accounts"))}
		if nendo.box(nendo.id("SignOutPad"))({padding = {top = 6}}) {
			login_button("SignOutBtn", tr("Sign out"))
		}
		if single_pane() {micro_button("ProfileRemoveAccount", tr("Remove account"), DANGER)}
		if open_now(nendo.id("QrModal"), ui.qr_open) && ui.qr_tex != nil {
			qr_modal(
				ui,
				Contact_Ui {
					name = ui.profile.name,
					npub = ui.profile.npub,
					id_hex = ui.account_ref,
				},
			)
		}
	}
	scrollbar(nendo.id("ProfilePage"))
}
