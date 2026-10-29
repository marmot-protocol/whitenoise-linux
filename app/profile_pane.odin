package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:fmt"
import "core:strings"

// The Profile page's rail, in place of the chat list: the accounts on
// this device (tap to switch), and the two settings sections that own
// the rest of an identity. A chat filter over "Search messages..."
// makes no sense while you're looking at your own profile.
profile_rail :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("PrHead"))({layout = {padding = {left = 4, top = 6, bottom = 4}}}) {
		clay.Text(
			fmt.tprintf(tr("ACCOUNTS   %d"), len(ui.accounts)),
			{fontId = FONT_MONO, fontSize = 12, textColor = TEXT_DIM, letterSpacing = 2},
		)
	}

	for name, i in ui.accounts {
		active := ui.account_ids[i] == ui.account_ref
		if clay.UI(clay.ID("PrAcct", u32(i)))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				padding = clay.PaddingAll(10),
				childGap = 10,
				childAlignment = {y = .Center},
			},
			backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
			cornerRadius = rr(10),
		},
		) {
			avatar("PrAcctAv", u32(i), ui.account_ids[i], name, 30, url_pic(ui.account_pics[i]))
			if clay.UI(clay.ID("PrAcctCol", u32(i)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					childGap = 2,
				},
				clip = {horizontal = true, childOffset = clay.GetScrollOffset()},
			},
			) {
				clay.Text(
					name,
					{fontId = FONT_TITLE, fontSize = 13, textColor = active ? TEXT : TEXT_DIM},
				)
				clay.Text(
					npub_tail(ui.account_npubs[i]),
					{fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO},
				)
				if i < len(ui.account_signing) &&
				   ui.account_signing[i].external {nip46_status_ui(ui, ui.account_ids[i], u32(i))}
			}
			scrollbar(clay.ID("PrAcctCol", u32(i)))
			if active {
				clay.Text(
					tr("ACTIVE"),
					{fontId = FONT_MONO, fontSize = 9, textColor = ACCENT, letterSpacing = 2},
				)
			}
			account_remove_button("PrAcctRemove", u32(i))
		}
	}
	if clay.UI(clay.ID("PrAddRow"))({layout = {padding = {left = 4, top = 4, bottom = 8}}}) {
		micro_button("PrAddAccount", tr("Add account"))
	}

	if clay.UI(clay.ID("PrRule"))(
	{
		layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(1)}},
		backgroundColor = DIVIDER,
	},
	) {}
	if clay.UI(clay.ID("PrLinksHead"))({layout = {padding = {left = 4, top = 8, bottom = 4}}}) {
		clay.Text(
			tr("IDENTITY"),
			{fontId = FONT_MONO, fontSize = 12, textColor = TEXT_DIM, letterSpacing = 2},
		)
	}
	profile_rail_link("PrKeys", ICON_KEY, tr("Keys & identity"))
	profile_rail_link("PrNetwork", ICON_GLOBE, tr("Network & relays"))
}

// One jump row, the settings-sidebar grammar.
@(private = "file")
profile_rail_link :: proc(id_str: string, icon: string, label: string) {
	if clay.UI(clay.ID(id_str))(
	{
		layout = {
			sizing = {
				width = clay.SizingGrow(),
				height = clay.SizingFit({min = settings_tap_size(34)}),
			},
			padding = {left = 12, right = 12, top = 9, bottom = 9},
			childGap = 10,
			childAlignment = {y = .Center},
		},
		backgroundColor = hovered() ? HOVER : {},
		cornerRadius = rr(9),
	},
	) {
		clay.Text(icon, {fontId = FONT_ICON, fontSize = 13, textColor = TEXT_DIM})
		clay.Text(label, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT_DIM})
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
	if clay.UI(clay.ID("ProfileFormRow", index))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = single_pane() ? .TopToBottom : .LeftToRight,
			childGap = 12,
			childAlignment = {y = .Center},
		},
	},
	) {
		if clay.UI(clay.ID("ProfileFormLabel", index))(
		{layout = {sizing = {width = clay.SizingFixed(120)}}},
		) {
			clay.Text(
				label,
				{fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO, letterSpacing = 2},
			)
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
	if clay.UI(clay.ID("ProfileKv", index))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = single_pane() ? .TopToBottom : .LeftToRight,
			padding = {left = 16, right = 16, top = 12, bottom = 12},
			childAlignment = {y = .Center},
			childGap = 10,
		},
	},
	) {
		clay.Text(label, {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})
		if clay.UI(clay.ID("ProfileKvGap", index))(
		{layout = {sizing = {width = clay.SizingGrow()}}},
		) {}
		if clay.UI(clay.ID("ProfileKvValue", index))(
		{
			layout = {
				sizing = {
					width = single_pane() ? clay.SizingGrow() : clay.SizingFit({max = g_ui == nil ? 400 : max(1, page_w(g_ui) - 240)}),
				},
			},
			clip = {horizontal = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			clay.Text(
				len(value) > 0 ? value : tr("Not set"),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM, wrapMode = .None},
			)
		}
		scrollbar(clay.ID("ProfileKvValue", index))
	}
	if !last {
		if clay.UI(clay.ID("ProfileKvRule", index))(
		{
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(1)}},
			backgroundColor = DIVIDER,
		},
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
	if clay.UI(clay.ID("ProfilePage"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {
				left = single_pane() ? 12 : 20,
				right = single_pane() ? 12 : 20,
				top = single_pane() ? 12 : 20,
				bottom = 36,
			},
			childGap = 12,
		},
		backgroundColor = background.customData == nil ? BG : clay.Color{},
		custom = background,
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		// ── Header: title + visibility eyebrow, Edit toggle right ──
		if clay.UI(clay.ID("ProfileHead"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = single_pane() ? .TopToBottom : .LeftToRight,
				childGap = 10,
				childAlignment = {y = .Center},
			},
		},
		) {
			if clay.UI(clay.ID("ProfileHeadCol"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					childGap = 3,
				},
			},
			) {
				clay.Text(
					tr("Your profile"),
					{fontId = FONT_TITLE, fontSize = 22, textColor = TEXT},
				)
				clay.Text(
					ui.profile.editing ? tr("EDITING · BROADCAST TO RELAYS ON PUBLISH") : tr("PUBLIC PROFILE"),
					{fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO, letterSpacing = 2},
				)
			}
			if clay.UI(clay.ID("ProfileHeadGap"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			if clay.UI(clay.ID("EditProfileBtn"))(
			{
				layout = {
					sizing = {height = clay.SizingFit({min = settings_tap_size(32)})},
					padding = {left = 14, right = 14, top = 8, bottom = 8},
					childGap = 8,
					childAlignment = {y = .Center},
				},
				backgroundColor = ui.profile.editing ? (hovered() ? HOVER : ROW_BG) : ACCENT,
				cornerRadius = rr(9),
				border = ui.profile.editing ? clay.BorderElementConfig{color = FIELD_BORDER, width = bw()} : {},
			},
			) {
				if !ui.profile.editing {
					clay.Text(
						ICON_PENCIL,
						{fontId = FONT_ICON, fontSize = 12, textColor = ON_ACCENT},
					)
				}
				clay.Text(
					ui.profile.editing ? tr("Cancel") : tr("Edit profile"),
					{
						fontId = FONT_TITLE,
						fontSize = 13,
						textColor = ui.profile.editing ? TEXT : ON_ACCENT,
					},
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
		if clay.UI(clay.ID("ProfileHero"))(
		{
			layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom},
			backgroundColor = ROW_BG,
			cornerRadius = rr(14),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			if !ui.profile.editing {
				if clay.UI(clay.ID("ProfileBanner"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(88)},
						padding = {right = 24},
						childGap = 10,
						childAlignment = {y = .Center},
					},
					backgroundColor = ACCENT,
					cornerRadius = {topLeft = 14, topRight = 14},
				},
				) {
					// Quiet dot ornament so the band reads designed, not
					// unfinished, on every pack's accent.
					if clay.UI(clay.ID("BannerFill"))(
					{layout = {sizing = {width = clay.SizingGrow()}}},
					) {}
					for size, i in ([3]f32{18, 30, 46}) {
						if clay.UI(clay.ID("BannerDot", u32(i)))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(size),
									height = clay.SizingFixed(size),
								},
							},
							backgroundColor = {255, 255, 255, 28},
							cornerRadius = rr(size / 2),
						},
						) {}
					}
				}
			}

			// The avatar overlaps the banner/body seam. In edit mode
			// the whole circle picks a new picture, badged with ✎.
			if clay.UI(clay.ID("ProfileAvatarPick"))(
			{
				layout = {sizing = {width = clay.SizingFixed(96), height = clay.SizingFixed(96)}},
				floating = {
					attachTo = .Parent,
					clipTo = .AttachedParent,
					zIndex = 5,
					offset = {24, ui.profile.editing ? 16 : 40},
					attachment = {element = .LeftTop, parent = .LeftTop},
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
					if clay.UI(clay.ID("ProfileAvatarBadge"))(
					{
						layout = {
							sizing = {width = clay.SizingFixed(30), height = clay.SizingFixed(30)},
							childAlignment = {x = .Center, y = .Center},
						},
						floating = {
							attachTo = .Parent,
							clipTo = .AttachedParent,
							zIndex = 6,
							offset = {2, 2},
							attachment = {element = .RightBottom, parent = .RightBottom},
						},
						backgroundColor = ACCENT,
						cornerRadius = rr(15),
						border = {color = ROW_BG, width = {2, 2, 2, 2, 0}},
					},
					) {
						clay.Text(
							ICON_PENCIL,
							{fontId = FONT_ICON, fontSize = 12, textColor = ON_ACCENT},
						)
					}
				}
			}

			if clay.UI(clay.ID("ProfileHeroRow"))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow(),
						height = clay.SizingFit({min = ui.profile.editing ? 128 : 0}),
					},
					padding = {
						left = single_pane() ? 16 : 136,
						right = single_pane() ? 16 : 24,
						top = ui.profile.editing ? (single_pane() ? 124 : 28) : (single_pane() ? 60 : 14),
						bottom = 18,
					},
					childGap = 14,
					childAlignment = {y = .Center},
				},
			},
			) {
				if clay.UI(clay.ID("ProfileHeroCol"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						layoutDirection = .TopToBottom,
						childGap = 3,
					},
				},
				) {
					// Only the name previews here so About cannot shift the fields.
					shown_name := ui.profile.editing ? string(ui.name_input[:]) : ui.profile.name
					name_font := title_font != 0 ? title_font : FONT_TITLE
					name_w := clay.GetElementData(clay.ID("ProfileHeroCol")).boundingBox.width
					if name_w <= 0 {name_w = max(1, page_w(ui) - (single_pane() ? 80 : 220))}
					clay.Text(
						text_ellipsis(
							len(shown_name) > 0 ? shown_name : tr("(no display name)"),
							name_w,
							name_font,
							24,
						),
						{fontId = name_font, fontSize = 24, textColor = TEXT, wrapMode = .None},
					)
					clay.Text(
						text_ellipsis(
							len(ui.profile.username) > 0 && ui.profile.username != ui.profile.name ? fmt.tprintf("@%s", ui.profile.username) : npub_tail(ui.profile.npub),
							name_w,
							FONT_BODY,
							12,
						),
						{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO, wrapMode = .None},
					)
					if !ui.profile.editing && len(ui.profile.about) > 0 {
						clay.Text(
							ui.profile.about,
							{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
						)
					}
				}
			}
		}

		// ── Edit form: every kind-0 field the app lets you set ─────
		if ui.profile.editing {
			if clay.UI(clay.ID("FormEyebrow"))({layout = {padding = {top = 6}}}) {
				eyebrow(tr("EDIT PROFILE"))
			}
			if clay.UI(clay.ID("ProfileForm"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					padding = {left = 16, right = 16, top = 14, bottom = 14},
					childGap = 10,
				},
				backgroundColor = ROW_BG,
				cornerRadius = rr(12),
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
					clay.Text(
						tr("Enter a display name."),
						{fontId = FONT_BODY, fontSize = 12, textColor = DANGER},
					)
				}
				eyebrow(tr("ABOUT"))
				issue_editor(ui, &ui.about_input, .About, tr("Not set"), 100)
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
					clay.Text(
						tr("Couldn't use this Nostr address. Double-check it and try again."),
						{fontId = FONT_BODY, fontSize = 12, textColor = DANGER},
					)
				}
				clay.Text(
					tr(
						"Optional Nostr identifier (NIP-05), not your email address. This is public.",
					),
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
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
					clay.Text(
						tr("Couldn't use this Lightning address. Double-check it and try again."),
						{fontId = FONT_BODY, fontSize = 12, textColor = DANGER},
					)
				}
				if clay.UI(clay.ID("ProfileFormActions"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						layoutDirection = single_pane() ? .TopToBottom : .LeftToRight,
						childGap = 10,
						padding = {top = 6},
						childAlignment = {y = .Center},
					},
				},
				) {
					if ppic_busy {
						micro_button("ChangePicBtn", tr("Uploading picture"))
					} else {
						micro_button("ChangePicBtn", tr("Change picture"))
					}
					if clay.UI(clay.ID("FormActionGap"))(
					{layout = {sizing = {width = clay.SizingGrow()}}},
					) {}
					if !single_pane() && !tap_size() {
						clay.Text(
							tr("Enter moves to the next field, Escape cancels."),
							{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO},
						)
					}
					ready := profile_ready(ui)
					if clay.UI(clay.ID("PublishProfileBtn"))(
					{
						layout = {
							sizing = {height = clay.SizingFit({min = settings_tap_size(32)})},
							padding = {left = 16, right = 16, top = 9, bottom = 9},
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = ready ? ACCENT : FIELD_BORDER,
						cornerRadius = rr(9),
					},
					) {
						clay.Text(
							tr("Publish changes"),
							{
								fontId = FONT_TITLE,
								fontSize = 13,
								textColor = ready ? ON_ACCENT : TEXT_LO,
							},
						)
					}
				}
			}
		}

		// ── Identity: copyable npub + inline QR ────────────────────
		if clay.UI(clay.ID("IdEyebrow"))({layout = {padding = {top = 6}}}) {
			eyebrow(tr("IDENTITY"))
		}
		if clay.UI(clay.ID("ProfileIdCard"))(
		{
			layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom},
			backgroundColor = ROW_BG,
			cornerRadius = rr(10),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			if clay.UI(clay.ID("ProfileNpubRow"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = single_pane() ? .TopToBottom : .LeftToRight,
					padding = {left = 16, right = 12, top = 10, bottom = 10},
					childGap = 12,
					childAlignment = {y = .Center},
				},
			},
			) {
				if clay.UI(clay.ID("ProfileNpubCol"))(
				{layout = {layoutDirection = .TopToBottom, childGap = 2}},
				) {
					clay.Text("npub", {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})
					clay.Text(
						tr("Your public key. Safe to share."),
						{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO},
					)
				}
				if clay.UI(clay.ID("ProfileNpubGap"))(
				{layout = {sizing = {width = clay.SizingGrow()}}},
				) {}
				clay.Text(
					npub_tail(ui.profile.npub),
					{fontId = FONT_MONO, fontSize = 11, textColor = TEXT_DIM},
				)
				micro_button("ProfileCopyNpub", tr("Copy"))
			}
			if ui.profile.qr != nil {
				identity_w := clay.GetElementData(clay.ID("ProfileIdCard")).boundingBox.width
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
			if clay.UI(clay.ID("ProfileEyebrow"))({layout = {padding = {top = 6}}}) {
				eyebrow(tr("PROFILE"))
			}
			if clay.UI(clay.ID("ProfileCard"))(
			{
				layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom},
				backgroundColor = ROW_BG,
				cornerRadius = rr(10),
				border = {color = FIELD_BORDER, width = bw()},
			},
			) {
				if ui.profile.username != "" && ui.profile.username != ui.profile.name {
					profile_kv(
						0,
						tr("Username"),
						fmt.tprintf("@%s", ui.profile.username),
						font = FONT_BODY,
					)
				}
				profile_kv(1, tr("Verified address"), ui.profile.nip05, font = FONT_BODY)
				profile_kv(2, tr("Lightning"), ui.profile.lud16, true, font = FONT_BODY)
			}
		}

		if single_pane() {micro_button("ProfileAccounts", tr("Accounts"))}
		if clay.UI(clay.ID("SignOutPad"))({layout = {padding = {top = 6}}}) {
			login_button("SignOutBtn", tr("Sign out"))
		}
		if single_pane() {micro_button("ProfileRemoveAccount", tr("Remove account"), DANGER)}
		if open_now(clay.ID("QrModal"), ui.qr_open) && ui.qr_tex != nil {
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
	scrollbar(clay.ID("ProfilePage"))
}
