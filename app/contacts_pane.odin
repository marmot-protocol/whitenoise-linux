package main

import "core:fmt"
import "core:strings"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

contacts_pane :: proc(ui: ^Ui_State) {
	contact, found := shown_contact(ui)
	if !found {
		centered_note("PickContact", tr("Contact"), tr("Select a contact from the list."))
		return
	}

	style := profile_style(contact.id_hex)
	body_font, title_font := profile_font(style.fonts[0]), profile_font(style.fonts[1])
	FONT_BODY := body_font != 0 ? body_font : u16(0)
	FONT_TITLE := body_font != 0 ? body_font : u16(1)
	old := profile_palette(profile_colors(style))
	defer profile_palette(old)
	background := profile_background(style)
	if clay.UI(clay.ID("ContactPage"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {left = 24, right = 24, top = 14, bottom = 24},
			childGap = 10,
		},
		backgroundColor = background.customData == nil ? BG : clay.Color{},
		custom = background,
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		// Header strip: icon plate + page title, like the chat header.
		if clay.UI(clay.ID("ContactHead"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 10,
				childAlignment = {y = .Center},
				padding = {bottom = 4},
			},
		},
		) {
			if clay.UI(clay.ID("ContactHeadIcon"))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(28), height = clay.SizingFixed(28)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = ROW_BG,
				cornerRadius = rr(8),
				border = {color = FIELD_BORDER, width = bw()},
			},
			) {
				clay.Text(
					PAGE_ICONS[Page.Contacts],
					{fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM},
				)
			}
			clay.Text(
				tr(ui.selected_contact >= 0 ? N_("Contact") : N_("Profile")),
				{fontId = FONT_TITLE, fontSize = 14, textColor = TEXT},
			)
		}
		if clay.UI(clay.ID("ContactHeadRule"))(
		{
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(1)}},
			backgroundColor = DIVIDER,
		},
		) {}

		if clay.UI(clay.ID("ContactHero"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 14,
				childAlignment = {y = .Center},
				padding = {top = 10, bottom = 6},
			},
		},
		) {
			avatar(
				"ContactHeroAvatar",
				0,
				contact.id_hex,
				contact.name,
				52,
				url_pic(contact.pic_url),
			)
			if clay.UI(clay.ID("ContactHeroCol"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					childGap = 2,
				},
				clip = {horizontal = true},
			},
			) {
				clay.Text(
					contact_label(ui, contact),
					{
						fontId = title_font != 0 ? title_font : FONT_TITLE,
						fontSize = 20,
						textColor = TEXT,
						wrapMode = .None,
					},
				)
				clay.Text(
					npub_tail(contact.npub),
					{fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO, wrapMode = .None},
				)
				if address := profile_info(nil, contact.id_hex).nip05; address != "" {
					clay.Text(address, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
				}
				if contact_label(ui, contact) != contact.name {
					clay.Text(
						fmt.tprintf(tr("aka %s"), contact.name),
						{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO, wrapMode = .None},
					)
				}
			}
			if clay.UI(clay.ID("StartChatBtn"))(
			{
				layout = {
					sizing = {height = clay.SizingFixed(38)},
					padding = {left = 12, right = 12},
					childGap = 8,
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = ACCENT,
				cornerRadius = rr(9),
			},
			) {
				clay.Text(
					PAGE_ICONS[Page.Chats],
					{fontId = FONT_ICON, fontSize = 12, textColor = ON_ACCENT},
				)
				clay.Text(
					tr("Start chat"),
					{fontId = FONT_TITLE, fontSize = 13, textColor = ON_ACCENT, wrapMode = .None},
				)
			}
		}
		// Give the editor its own row so it cannot squeeze the name or action.
		if clay.UI(clay.ID("NickBox"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(36)},
				padding = {left = 12, right = 12},
				childAlignment = {y = .Center},
			},
			backgroundColor = ROW_BG,
			cornerRadius = rr(8),
			border = {color = ui.focus == .Nick ? ACCENT : FIELD_BORDER, width = bw()},
		},
		) {
			field_text(
				ui,
				"NickBox",
				&ui.nick_input,
				tr("Nickname"),
				ui.focus == .Nick,
				12,
				TEXT_LO,
			)
		}

		if clay.UI(clay.ID("IdentityEyebrow"))({layout = {padding = {top = 8}}}) {
			eyebrow(tr("IDENTITY"))
		}
		// One flat card; rows separate with hairlines, values right.
		if clay.UI(clay.ID("IdentityCard"))(
		{
			layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom},
			backgroundColor = ROW_BG,
			cornerRadius = rr(10),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			if clay.UI(clay.ID("NpubRow"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					padding = {left = 16, right = 12, top = 10, bottom = 10},
					childGap = 12,
					childAlignment = {y = .Center},
				},
			},
			) {
				if clay.UI(clay.ID("NpubCol"))(
				{layout = {layoutDirection = .TopToBottom, childGap = 2}},
				) {
					clay.Text("npub", {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})
					clay.Text(
						tr("Public key, safe to share."),
						{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO},
					)
				}
				if clay.UI(clay.ID("NpubRowGap"))(
				{layout = {sizing = {width = clay.SizingGrow()}}},
				) {}
				clay.Text(
					npub_tail(contact.npub),
					{fontId = FONT_MONO, fontSize = 11, textColor = TEXT_DIM},
				)
				micro_button("CopyNpubBtn", tr("Copy"))
			}
			identity_w := clay.GetElementData(clay.ID("IdentityCard")).boundingBox.width
			if identity_w <= 0 {identity_w = page_w(ui) - 48}
			identity_codes(
				"Contact",
				contact.id_hex,
				contact_qr(ui, contact.npub),
				identity_w,
				font = FONT_TITLE,
			)
		}
		micro_button("QrBtn", tr("Show as QR"))

		if clay.UI(clay.ID("KpEyebrow"))({layout = {padding = {top = 8}}}) {
			eyebrow(tr("KEY PACKAGE"))
		}
		if clay.UI(clay.ID("KpCard"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				padding = {left = 16, right = 12, top = 10, bottom = 10},
				childGap = 12,
				childAlignment = {y = .Center},
			},
			backgroundColor = ROW_BG,
			cornerRadius = rr(10),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			state := kp_probes[contact.id_hex]
			if clay.UI(clay.ID("KpCol"))(
			{layout = {layoutDirection = .TopToBottom, childGap = 2}},
			) {
				clay.Text(
					tr(kp_title(state)),
					{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT},
				)
				clay.Text(
					tr(kp_note(state)),
					{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO},
				)
			}
		}

		if clay.UI(clay.ID("RelaysEyebrow"))({layout = {padding = {top = 8}}}) {
			eyebrow(tr("RELAYS IN COMMON"))
		}
		contact_relays_card(FONT_BODY)

		if clay.UI(clay.ID("GroupsEyebrow"))({layout = {padding = {top = 8}}}) {
			eyebrow(tr("GROUPS IN COMMON"))
		}
		// Flat hairline rows, no filled plates.
		if clay.UI(clay.ID("CommonGroups"))(
		{layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom}},
		) {
			for group, i in contact.groups {
				if i > 0 {
					if clay.UI(clay.ID("CommonGroupRule", u32(i)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(1)},
						},
						backgroundColor = DIVIDER,
					},
					) {}
				}
				if clay.UI(clay.ID("CommonGroup", u32(i)))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						padding = {left = 8, right = 8, top = 8, bottom = 8},
						childGap = 10,
						childAlignment = {y = .Center},
					},
					backgroundColor = hovered() ? HOVER : {},
					cornerRadius = rr(8),
				},
				) {
					avatar("CommonGroupAvatar", u32(i), group.id, group.title, 26)
					if clay.UI(clay.ID("CommonGroupCol", u32(i)))(
					{layout = {layoutDirection = .TopToBottom, childGap = 1}},
					) {
						clay.Text(
							group.title,
							{fontId = FONT_TITLE, fontSize = 13, textColor = TEXT},
						)
						clay.Text(
							fmt.tprintf(
								tr(group.members == 1 ? N_("%d member") : N_("%d members")),
								group.members,
							),
							{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO},
						)
					}
				}
			}
		}

		// Local-only block: nothing is published. Their messages collapse
		// behind a Show toggle and a 1:1 chat with them loses its composer.
		if clay.UI(clay.ID("ActionsEyebrow"))({layout = {padding = {top = 8}}}) {
			eyebrow(tr("ACTIONS"))
		}
		if clay.UI(clay.ID("ActionsRow"))({layout = {childGap = 8}}) {
			micro_button(
				"BlockBtn",
				ui.blocked[contact.id_hex] ? tr("Unblock") : tr("Block"),
				DANGER,
			)
			if ui.selected_contact >= 0 {
				micro_button("RemoveContactBtn", tr("Remove contact"), DANGER)
			}
		}

		if open_now(clay.ID("QrModal"), ui.qr_open) && ui.qr_tex != nil {
			qr_modal(ui, contact)
		}
	}
	scrollbar(clay.ID("ContactPage"))
}

// The contact's published relays, the ones you share accented: sharing
// one means your events meet there instead of taking a longer path.
// Capped to keep long published relay lists compact.
RELAY_ROWS_MAX :: 6

@(private = "file")
contact_relays_card :: proc(font: u16 = FONT_BODY) {
	FONT_BODY := font
	FONT_TITLE := font == 0 ? u16(1) : font
	if clay.UI(clay.ID("RelaysCard"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {left = 16, right = 12, top = 10, bottom = 10},
			childGap = 6,
		},
		backgroundColor = ROW_BG,
		cornerRadius = rr(10),
		border = {color = FIELD_BORDER, width = bw()},
	},
	) {
		if rel_state == .Checking {
			clay.Text(tr("Checking..."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
			return
		}
		if len(rel_list) == 0 {
			clay.Text(
				tr("They haven't published a relay list."),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
			)
			return
		}

		clay.Text(
			fmt.tprintf(tr("%d of %d shared with you"), rel_mutual, len(rel_list)),
			{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT},
		)
		for relay, i in rel_list {
			if i >= RELAY_ROWS_MAX {
				clay.Text(
					fmt.tprintf(tr("+%d more"), len(rel_list) - RELAY_ROWS_MAX),
					{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO},
				)
				break
			}
			if clay.UI(clay.ID("RelayShareRow", u32(i)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					childGap = 8,
					childAlignment = {y = .Center},
				},
			},
			) {
				clay.Text(
					relay.url,
					{
						fontId = FONT_MONO,
						fontSize = 11,
						textColor = relay.mutual ? ACCENT : TEXT_DIM,
					},
				)
				if clay.UI(clay.ID("RelayShareGap", u32(i)))(
				{layout = {sizing = {width = clay.SizingGrow()}}},
				) {}
				if relay.inbox {
					clay.Text(
						tr("inbox"),
						{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO},
					)
				}
			}
		}
	}
}


// What the key-package row says. Marmot answers only whether one can
// be resolved, so the row reports reachability rather than the event
// detail the Keys page shows for your own account.
@(private = "file")
kp_title :: proc(state: Kp_Probe) -> string {
	switch state {
	case .Unknown, .Checking:
		return N_("Checking...")
	case .Published:
		return N_("Published")
	case .Missing:
		return N_("Not found")
	}
	return ""
}

@(private = "file")
kp_note :: proc(state: Kp_Probe) -> string {
	switch state {
	case .Unknown, .Checking:
		return N_("Asking your relays for their key package.")
	case .Published:
		return N_("They can be added to a chat.")
	case .Missing:
		return N_("No key package on your relays, so a chat can't start yet.")
	}
	return ""
}

// Centered QR overlay: the contact's marmot://profile deep link
// rasterized by the in-app encoder (show_contact_qr).
qr_modal :: proc(ui: ^Ui_State, contact: Contact_Ui) {
	if clay.UI(clay.ID("QrModal"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(20),
			childGap = 12,
			childAlignment = {x = .Center},
		},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {
			attachTo = .Root,
			zIndex = 13,
			offset = {0, rise(clay.ID("QrModal"))},
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
	},
	) {
		clay.Text(
			contact_label(ui, contact),
			{fontId = FONT_TITLE, fontSize = 15, textColor = TEXT},
		)
		if clay.UI(clay.ID("QrImage"))(
		{
			layout = {sizing = {width = clay.SizingFixed(260), height = clay.SizingFixed(260)}},
			image = {imageData = ui.qr_tex},
			cornerRadius = rr(8),
		},
		) {}
		clay.Text(npub_tail(ui.qr_npub), {fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO})
	}
}

// Rasterize the contact's marmot:// deep link into a texture.
show_contact_qr :: proc(ui: ^Ui_State, contact: Contact_Ui) {
	if contact_qr(ui, contact.npub) == nil {
		set_status(ui, strings.clone(tr("Couldn't render the QR code. Please try again.")), .Error)
		return
	}
	ui.qr_open = true
}

@(private = "file")
contact_qr :: proc(ui: ^Ui_State, npub: string) -> ^rl.Texture2D {
	if ui.qr_npub == npub {return ui.qr_tex}
	if ui.qr_tex != nil {
		rl.UnloadTexture(ui.qr_tex^)
		free(ui.qr_tex)
	}
	delete(ui.qr_npub)
	ui.qr_npub = strings.clone(npub)
	ui.qr_tex = qr_texture(npub)
	return ui.qr_tex
}
