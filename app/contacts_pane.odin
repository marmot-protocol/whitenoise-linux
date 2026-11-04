package main

import "core:fmt"
import "core:strings"
import "nendo"
import rl "sdlrl"

// What the contact pane says with no contact open. An empty list has
// nothing to select, and a collapsed one is not on screen to select from.
@(private)
Contact_Note :: enum {
	Pick,
	No_Contacts,
	Collapsed,
}

@(private)
contact_note :: proc(contacts: int, collapsed: bool) -> Contact_Note {
	if contacts == 0 {
		return .No_Contacts
	}
	if collapsed {
		return .Collapsed
	}
	return .Pick
}

// Why the rail's contact list shows no rows: a search that matched no
// one is not the same as having no contacts.
@(private)
Contacts_Empty :: enum {
	None,
	No_Contacts,
	No_Matches,
}

@(private)
contacts_empty :: proc(total, shown, query_len: int) -> Contacts_Empty {
	if shown > 0 {
		return .None
	}
	if query_len > 0 {
		return .No_Matches
	}
	if total == 0 {
		return .No_Contacts
	}
	return .None
}

@(private)
contact_saved :: proc(ui: ^Ui_State, hex: string) -> bool {
	for contact in ui.contacts {if contact.id_hex == hex {return true}}
	return false
}

@(private)
contact_query_hex :: proc(ui: ^Ui_State) -> string {
	hex := nc_address_hex(ui, string(ui.sidebar_filter[:]))
	if contact_saved(ui, hex) {return ""}
	return hex
}

// Contact placeholders use the same round shape as their eventual photo.
@(private)
contact_picture :: proc(contact: Contact_Ui) -> ^rl.Texture2D {
	if photo := url_pic(contact.pic_url); photo != nil {return photo}
	return url_pic(fmt.tprintf("crop-round:%s", contact.id_hex))
}

// The rail's contacts in display order, narrowed by its search box.
@(private)
contact_rail_matches :: proc(ui: ^Ui_State) -> []Contact_Order {
	filter := strings.to_lower(string(ui.sidebar_filter[:]), context.temp_allocator)
	all := contact_order(ui, ui.contacts[:])
	if len(filter) == 0 {
		return all
	}
	shown := 0
	for order in all {
		if strings.contains(order.key, filter) {
			all[shown] = order
			shown += 1
		}
	}
	return all[:shown]
}

// centered_note with one action under it.
@(private = "file")
contact_action_note :: proc(id_str, title, sub, button_id, button: string) {
	if nendo.box(nendo.id(id_str))(
	{
		width = nendo.grow(),
		height = nendo.grow(),
		direction = .Column,
		align = {x = .Center, y = .Center},
		gap = 8,
	},
	) {
		nendo.text(title, {font = FONT_TITLE, size = 24, color = TEXT_DIM})
		nendo.text(sub, {font = FONT_BODY, size = 14, color = TEXT_DIM})
		micro_button(button_id, button)
	}
}

contacts_pane :: proc(ui: ^Ui_State) {
	contact, found := shown_contact(ui)
	if !found {
		switch contact_note(len(ui.contacts), !single_pane() && rail_narrow(ui)) {
		case .No_Contacts:
			contact_action_note(
				"NoContacts",
				tr("People you follow show up here."),
				tr(
					"Starting a chat does not add someone to People. You can also import a contacts CSV or JSON export.",
				),
				"NoContactsImport",
				tr("Import contacts"),
			)
		case .Collapsed:
			contact_action_note(
				"ContactsCollapsed",
				tr("Contact list collapsed"),
				tr("Open it again with › in the left column or the button below."),
				"ContactsShowList",
				tr("Show contact list"),
			)
		case .Pick:
			centered_note("PickContact", tr("Contact"), tr("Select a contact from the list."))
		}
		return
	}

	style := profile_style(contact.id_hex)
	body_font, title_font := profile_font(style.fonts[0]), profile_font(style.fonts[1])
	FONT_BODY := body_font != 0 ? body_font : u16(0)
	FONT_TITLE := body_font != 0 ? body_font : u16(1)
	old := profile_palette(profile_colors(style))
	defer profile_palette(old)
	background := profile_background(style)
	compact := single_pane()
	if nendo.box(nendo.id("ContactPage"))(
	{
		width = nendo.grow(),
		height = nendo.grow(),
		direction = .Column,
		padding = {left = compact ? 12 : 24, right = compact ? 12 : 24, top = 14, bottom = 24},
		gap = 10,
		color = background == nil ? BG : nendo.Color{},
		custom = background,
		clip = {y = true, scroll = true},
	},
	) {
		// Header strip: icon plate + page title, like the chat header.
		if !compact {
			if nendo.box(nendo.id("ContactHead"))(
			{width = nendo.grow(), gap = 10, align = {y = .Center}, padding = {bottom = 4}},
			) {
				if nendo.box(nendo.id("ContactHeadIcon"))(
				{
					width = nendo.fixed(28),
					height = nendo.fixed(28),
					align = {x = .Center, y = .Center},
					color = ROW_BG,
					radius = rr(8),
					border = {color = FIELD_BORDER, width = bw()},
				},
				) {
					nendo.text(
						PAGE_ICONS[Page.Contacts],
						{font = FONT_ICON, size = 12, color = TEXT_DIM},
					)
				}
				nendo.text(
					tr(ui.selected_contact >= 0 ? N_("Contact") : N_("Profile")),
					{font = FONT_TITLE, size = 14, color = TEXT},
				)
			}
			if nendo.box(nendo.id("ContactHeadRule"))(
			{width = nendo.grow(), height = nendo.fixed(1), color = DIVIDER},
			) {}
		}

		if nendo.box(nendo.id("ContactHero"))(
		{
			width = nendo.grow(),
			direction = compact ? .Column : .Row,
			gap = 14,
			align = {y = .Center},
			padding = {top = 10, bottom = 6},
		},
		) {
			photo := contact_picture(contact)
			avatar(
				"ContactHeroAvatar",
				0,
				photo == nil ? contact.npub : contact.id_hex,
				contact.name,
				52,
				photo,
			)
			if nendo.box(nendo.id("ContactHeroCol"))(
			{width = nendo.grow(), direction = .Column, gap = 2, clip = {x = true}},
			) {
				name_font := title_font != 0 ? title_font : FONT_TITLE
				name_w := nendo.element(nendo.id("ContactHeroCol")).rect.width
				if name_w <= 0 {name_w = max(1, page_w(ui) - (compact ? 48 : 240))}
				nendo.text(
					text_ellipsis(contact_label(ui, contact), name_w, name_font, 20),
					{font = name_font, size = 20, color = TEXT, wrap = .None},
				)
				if ui.blocked[contact.id_hex] {
					nendo.text(tr("Blocked"), {font = FONT_TITLE, size = 12, color = DANGER})
				}
				nendo.text(
					npub_tail(contact.npub),
					{font = FONT_MONO, size = 10, color = TEXT_LO, wrap = .None},
				)
				if address := profile_info(nil, contact.id_hex).nip05; address != "" {
					nendo.text(address, {font = FONT_BODY, size = 12, color = TEXT_DIM})
				}
				if contact_label(ui, contact) != contact.name {
					nendo.text(
						text_ellipsis(
							fmt.tprintf(tr("aka %s"), contact.name),
							name_w,
							FONT_BODY,
							11,
						),
						{font = FONT_BODY, size = 11, color = TEXT_LO, wrap = .None},
					)
				}
			}
			if nendo.box(nendo.id("StartChatBtn"))(
			{
				height = nendo.fixed(tap_size() ? tap_min() : 38),
				padding = {left = 12, right = 12},
				gap = 8,
				align = {x = .Center, y = .Center},
				color = ACCENT,
				radius = rr(9),
			},
			) {
				nendo.text(
					PAGE_ICONS[Page.Chats],
					{font = FONT_ICON, size = 12, color = ON_ACCENT},
				)
				nendo.text(
					tr("Start chat"),
					{font = FONT_TITLE, size = 13, color = ON_ACCENT, wrap = .None},
				)
			}
		}
		// Give the editor its own row so it cannot squeeze the name or action.
		if nendo.box(nendo.id("NickBox"))(
		{
			width = nendo.grow(),
			height = nendo.fixed(tap_size() ? tap_min() : 36),
			padding = {left = 12, right = 12},
			align = {y = .Center},
			color = ROW_BG,
			radius = rr(8),
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

		if nendo.box(nendo.id("IdentityEyebrow"))({padding = {top = 8}}) {
			eyebrow(tr("IDENTITY"))
		}
		// One flat card; rows separate with hairlines, values right.
		if nendo.box(nendo.id("IdentityCard"))(
		{
			width = nendo.grow(),
			direction = .Column,
			color = ROW_BG,
			radius = rr(10),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			if nendo.box(nendo.id("NpubRow"))(
			{
				width = nendo.grow(),
				direction = compact ? .Column : .Row,
				padding = {left = 16, right = 12, top = 10, bottom = 10},
				gap = 12,
				align = {y = .Center},
			},
			) {
				if nendo.box(nendo.id("NpubCol"))({direction = .Column, gap = 2}) {
					nendo.text("npub", {font = FONT_TITLE, size = 12, color = TEXT})
					nendo.text(
						tr("Public key, safe to share."),
						{font = FONT_BODY, size = 10, color = TEXT_LO},
					)
				}
				if nendo.box(nendo.id("NpubRowGap"))({width = nendo.grow()}) {}
				nendo.text(
					npub_tail(contact.npub),
					{font = FONT_MONO, size = 11, color = TEXT_DIM},
				)
				micro_button("CopyNpubBtn", tr("Copy"))
			}
			identity_w := nendo.element(nendo.id("IdentityCard")).rect.width
			if identity_w <= 0 {identity_w = page_w(ui) - (compact ? 24 : 48)}
			identity_codes(
				"Contact",
				contact.id_hex,
				contact_qr(ui, contact.npub),
				identity_w,
				tr("Scan to add this person as a contact."),
				font = FONT_TITLE,
			)
		}

		if nendo.box(nendo.id("KpEyebrow"))({padding = {top = 8}}) {
			eyebrow(tr("KEY PACKAGE"))
		}
		if nendo.box(nendo.id("KpCard"))(
		{
			width = nendo.grow(),
			padding = {left = 16, right = 12, top = 10, bottom = 10},
			gap = 12,
			align = {y = .Center},
			color = ROW_BG,
			radius = rr(10),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			state := kp_probes[contact.id_hex]
			if nendo.box(nendo.id("KpCol"))({width = nendo.grow(), direction = .Column, gap = 2}) {
				nendo.text(tr(kp_title(state)), {font = FONT_TITLE, size = 12, color = TEXT})
				nendo.text(tr(kp_note(state)), {font = FONT_BODY, size = 10, color = TEXT_LO})
			}
		}

		if nendo.box(nendo.id("RelaysEyebrow"))({padding = {top = 8}}) {
			eyebrow(tr("RELAYS IN COMMON"))
		}
		contact_relays_card(FONT_BODY)

		if nendo.box(nendo.id("GroupsEyebrow"))({padding = {top = 8}}) {
			eyebrow(tr("GROUPS IN COMMON"))
		}
		// Flat hairline rows, no filled plates.
		if nendo.box(nendo.id("CommonGroups"))({width = nendo.grow(), direction = .Column}) {
			if len(contact.groups) == 0 {
				nendo.text(
					tr("No groups in common."),
					{font = FONT_BODY, size = 12, color = TEXT_DIM},
				)
			}
			for group, i in contact.groups {
				if i > 0 {
					if nendo.box(nendo.id("CommonGroupRule", u32(i)))(
					{width = nendo.grow(), height = nendo.fixed(1), color = DIVIDER},
					) {}
				}
				if nendo.box(nendo.id("CommonGroup", u32(i)))(
				{
					width = nendo.grow(),
					height = nendo.fit(min = tap_size() ? tap_min() : 0),
					padding = {left = 8, right = 8, top = 8, bottom = 8},
					gap = 10,
					align = {y = .Center},
					color = hovered() ? HOVER : {},
					radius = rr(8),
				},
				) {
					avatar("CommonGroupAvatar", u32(i), group.id, group.title, 26)
					if nendo.box(nendo.id("CommonGroupCol", u32(i)))(
					{width = nendo.grow(), direction = .Column, gap = 1},
					) {
						nendo.text(group.title, {font = FONT_TITLE, size = 13, color = TEXT})
						nendo.text(
							fmt.tprintf(
								tr(group.members == 1 ? N_("%d member") : N_("%d members")),
								group.members,
							),
							{font = FONT_BODY, size = 10, color = TEXT_LO},
						)
					}
				}
			}
		}

		// Local-only block: nothing is published. Their messages collapse
		// behind a Show toggle. Unblocking is a neutral, reversible action.
		if nendo.box(nendo.id("ActionsEyebrow"))({padding = {top = 8}}) {
			eyebrow(tr("ACTIONS"))
		}
		if nendo.box(nendo.id("ActionsRow"))({direction = compact ? .Column : .Row, gap = 8}) {
			micro_button(
				"BlockBtn",
				ui.blocked[contact.id_hex] ? tr("Unblock") : tr("Block"),
				ui.blocked[contact.id_hex] ? TEXT_DIM : DANGER,
			)
			if ui.selected_contact >= 0 {
				micro_button("RemoveContactBtn", tr("Remove contact"), DANGER)
			}
		}

		if open_now(nendo.id("QrModal"), ui.qr_open) && ui.qr_tex != nil {
			qr_modal(ui, contact)
		}
	}
	scrollbar(nendo.id("ContactPage"))
}

// The contact's published relays, the ones you share accented: sharing
// one means your events meet there instead of taking a longer path.
// Capped to keep long published relay lists compact.
RELAY_ROWS_MAX :: 6

@(private = "file")
contact_relays_card :: proc(font: u16 = FONT_BODY) {
	FONT_BODY := font
	FONT_TITLE := font == 0 ? u16(1) : font
	if nendo.box(nendo.id("RelaysCard"))(
	{
		width = nendo.grow(),
		direction = .Column,
		padding = {left = 16, right = 12, top = 10, bottom = 10},
		gap = 6,
		color = ROW_BG,
		radius = rr(10),
		border = {color = FIELD_BORDER, width = bw()},
	},
	) {
		if rel_state == .Checking {
			nendo.text(tr("Checking..."), {font = FONT_BODY, size = 11, color = TEXT_LO})
			return
		}
		if len(rel_list) == 0 {
			nendo.text(
				tr("They haven't published a relay list."),
				{font = FONT_BODY, size = 11, color = TEXT_LO},
			)
			return
		}

		nendo.text(
			fmt.tprintf(tr("%d of %d shared with you"), rel_mutual, len(rel_list)),
			{font = FONT_TITLE, size = 12, color = TEXT},
		)
		for relay, i in rel_list {
			if i >= RELAY_ROWS_MAX {
				nendo.text(
					fmt.tprintf(tr("+%d more"), len(rel_list) - RELAY_ROWS_MAX),
					{font = FONT_BODY, size = 10, color = TEXT_LO},
				)
				break
			}
			if nendo.box(nendo.id("RelayShareRow", u32(i)))(
			{
				width = nendo.grow(),
				gap = 8,
				align = {y = .Center},
				clip = {x = single_pane(), scroll = true},
			},
			) {
				nendo.text(
					relay.url,
					{font = FONT_MONO, size = 11, color = relay.mutual ? ACCENT : TEXT_DIM},
				)
				if nendo.box(nendo.id("RelayShareGap", u32(i)))({width = nendo.grow()}) {}
				if relay.inbox {
					nendo.text(tr("inbox"), {font = FONT_BODY, size = 10, color = TEXT_LO})
				}
			}
			if single_pane() {scrollbar(nendo.id("RelayShareRow", u32(i)))}
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
	width := modal_w(nendo.id("QrModal"), 300)
	qr_side := max(1, min(260, width - 40, modal_h(420) - 140))
	if nendo.box(nendo.id("QrModal"))(
	{
		width = nendo.fixed(width),
		height = nendo.fit(max = modal_h(420)),
		direction = .Column,
		padding = nendo.pad(20),
		gap = 12,
		align = {x = .Center},
		color = CARD,
		radius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {
			attach_to = .Root,
			z = 13,
			offset = {0, rise(nendo.id("QrModal"))},
			attach = {element = .Center_Center, parent = .Center_Center},
		},
	},
	) {
		nendo.text(
			text_ellipsis(contact.name, width - 40, FONT_TITLE, 15),
			{font = FONT_TITLE, size = 15, color = TEXT},
		)
		if nendo.box(nendo.id("QrImage"))(
		{
			width = nendo.fixed(qr_side),
			height = nendo.fixed(qr_side),
			image = ui.qr_tex,
			radius = rr(8),
		},
		) {}
		nendo.text(npub_tail(ui.qr_npub), {font = FONT_MONO, size = 11, color = TEXT_LO})
		micro_button("QrClose", tr("Close"))
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
