package main

import "core:encoding/hex"
import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

Row_Chip :: enum {
	Archive,
	Unarchive,
}

chat_row :: proc(index: u32, chat: Chat_Row_Ui, active: bool, chip: Row_Chip) {
	if clay.UI(clay.ID("ChatRow", index))(
	{layout = {sizing = {width = clay.SizingGrow()}}},
	) {
	if clay.UI(clay.ID("ChatRowSlide", index))(
	{
		layout = {sizing = {width = clay.SizingGrow()}, childGap = 0},
		backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
		cornerRadius = rr(12),
	},
	) {
	if clay.UI(clay.ID("ChatRowBar", index))({layout = {sizing = {width = clay.SizingFixed(3), height = clay.SizingGrow()}}, backgroundColor = active ? ACCENT : {}, cornerRadius = rr(2)}) {}
	if clay.UI(clay.ID("ChatRowBody", index))(
	{layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(12), childGap = 5}},
	) {
		// Avatar left; two stacked lines right: title/time then
		// preview/tick, like the slint chat list rows.
		if clay.UI(clay.ID("ChatRowMain", index))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, childAlignment = {y = .Center}}}) {
		avatar("ChatAvatar", index, chat.group_id, chat.title, 42, chat_pic(chat))
		if clay.UI(clay.ID("ChatRowLines", index))({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 4}}) {
			// Reserves the hover chips' height, so the row keeps its size
			// as the pointer crosses it.
			if clay.UI(clay.ID("ChatRowTop", index))(
			{layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFit({min = chip_h()})}, childGap = 8, childAlignment = {y = .Center}}},
			) {
				// One clipped line: a long unbroken name would otherwise
				// push the time and badge out of the row.
				if clay.UI(clay.ID("ChatRowTitleClip", index))({clip = {horizontal = true}}) {
					clay.Text(chat.title, {fontId = FONT_TITLE, fontSize = 14, textColor = TEXT, wrapMode = .None})
				}
				// Row-action markers (rowactions.odin): pinned rows lead
				// the rail, muted rows raise no notification.
				if g_prefs != nil && g_prefs.pinned[chat.group_id] {
					clay.Text(ICON_PIN, {fontId = FONT_ICON, fontSize = 10, textColor = ACCENT_DIM})
				}
				if chat.muted {
					clay.Text(ICON_BELL_OFF, {fontId = FONT_ICON, fontSize = 10, textColor = TEXT_LO})
				}
				if chat.pending {
					clay.Text("INVITE", {fontId = FONT_BODY, fontSize = 10, textColor = ACCENT, letterSpacing = 1})
				}
				if hovered() {
					if chip == .Archive {
						action_chip("ChatArch", index, "Archive")
						action_chip("ChatMenu", index, "···")
					} else {
						action_chip("ChatUnarch", index, "Unarchive")
					}
				}
				if clay.UI(clay.ID("ChatRowGap", index))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
				if chat.unread == 0 && g_prefs != nil && g_prefs.unread_ids[chat.group_id] {
					// Manual "Mark unread" reminder: a dot, no count.
					clay.Text("•", {fontId = FONT_TITLE, fontSize = 16, textColor = ACCENT})
				}
				if chat.unread > 0 {
					// A badge that just went up swells and rocks: the one
					// motion in the rail that has to survive peripheral
					// vision.
					count := fmt.tprintf("%d", chat.unread)
					pop, _, _ := bump(clay.ID("ChatRowBadge", index).id, count)
					pad := bump_pad(pop)
					rock := u16(clamp((pop - 1) * 8, 0, 3))
					if clay.UI(clay.ID("ChatRowBadge", index))(
					{layout = {padding = {left = 7 + pad + rock, right = 7 + pad - min(rock, 7), top = 2, bottom = 2}}, backgroundColor = ACCENT, cornerRadius = rr(9)},
					) {
						// A badge that just went up carries light with it,
						// which is what catches the eye off to the side.
						glow(clay.ID("ChatRowBadge", index), ACCENT, clamp((pop - 1) * 4, 0, 1), 12)
						clay.Text(count, {fontId = FONT_BODY, fontSize = 12, textColor = BG})
					}
				}
				clay.Text(chat.at, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
			}
			if clay.UI(clay.ID("ChatRowPrev", index))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 6, childAlignment = {y = .Center}}}) {
				if len(chat.preview) > 0 {
					// One clipped line. A preview with an emoji, mention
					// or link renders as several inline elements, which
					// clay would otherwise stack down the row; clipping
					// the axis gives them unbounded width instead, so the
					// overflow is cut rather than wrapped.
					if clay.UI(clay.ID("ChatRowPrevClip", index))(
					{layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(16)}, childAlignment = {y = .Center}}, clip = {horizontal = true}},
					) {
						body_line(0xC0000 + index, chat.preview, 12, TEXT_DIM)
					}
				}
				if clay.UI(clay.ID("ChatRowPrevGap", index))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
				// An unacked optimistic send outranks the stored delivery
				// state: the row is mid-send, whatever the last confirmed
				// message says.
				if state := chat_send_state(chat.group_id); state != .Idle {
					send_spinner(index, state)
				} else if chat.tick == .DELIVERED || chat.tick == .PENDING {
					delivery_tick(chat.group_id, index, chat.tick)
				} else if chat.tick == .FAILED {
					clay.Text("!", {fontId = FONT_TITLE, fontSize = 11, textColor = DANGER})
				}
			}
		}
		}
	}
	}
	}
}

// What the rail row says about this chat's optimistic sends
// (state.odin's Pending_Send overlay).
Send_State :: enum {
	Idle,
	Sending,
	Queued, // waiting for the offline flush
	Failed,
}

chat_send_state :: proc(group_id: string) -> Send_State {
	if g_ui == nil {
		return .Idle
	}
	state := Send_State.Idle
	for p in g_ui.pending {
		if p.group_id != group_id {
			continue
		}
		// Worst news wins: a failure is what the row should say even if
		// another send is still in flight behind it.
		switch {
		case p.failed:
			return .Failed
		case p.queued:
			state = .Queued
		case state == .Idle:
			state = .Sending
		}
	}
	return state
}

// Three dots with one lit, cycling: the rail's counterpart to the
// timeline's grayed "sending…" row.
send_spinner :: proc(index: u32, state: Send_State) {
	if state == .Failed {
		clay.Text("!", {fontId = FONT_TITLE, fontSize = 11, textColor = DANGER})
		return
	}
	// Breathing rather than blinking: each dot rides the same wave a
	// third of a turn behind the one before it, so the light travels
	// along the row instead of stepping between three states.
	color := state == .Queued ? TEXT_LO : ACCENT_DIM
	if clay.UI(clay.ID("ChatRowSending", index))({layout = {childGap = 3, childAlignment = {y = .Center}}}) {
		for i in 0 ..< 3 {
			wave := sin_approx(rl.GetTime() * 4 - f64(i) * 0.7) * 0.5 + 0.5
			if clay.UI(clay.ID("ChatRowSendDot", index * 8 + u32(i)))(
			{layout = {sizing = {width = clay.SizingFixed(3), height = clay.SizingFixed(3)}}, backgroundColor = mix_color(FIELD_BORDER, color, wave), cornerRadius = rr(2)},
			) {}
		}
	}
	anim_moving += 1
}

// One switcher row: avatar, name over npub tail, ACTIVE badge on the
// row you're looking at, chevron hinting the tap.
account_row :: proc(ui: ^Ui_State, index: u32, active: bool) {
	if clay.UI(clay.ID("AccountRow", index))(
	{
		layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 12, right = 14, top = 10, bottom = 10}, childGap = 12, childAlignment = {y = .Center}},
		backgroundColor = hovered() ? HOVER : (active ? ROW_BG : {}),
		cornerRadius = rr(10),
		border = active ? clay.BorderElementConfig{color = ACCENT, width = bw()} : {},
	},
	) {
		avatar("AccountAvatar", index, ui.account_ids[index], ui.accounts[index], 40, url_pic(ui.account_pics[index]))
		if clay.UI(clay.ID("AccountRowCol", index))({layout = {layoutDirection = .TopToBottom, childGap = 2}}) {
			clay.Text(ui.accounts[index], {fontId = FONT_TITLE, fontSize = 14, textColor = TEXT})
			clay.Text(npub_tail(ui.account_npubs[index]), {fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO})
		}
		if clay.UI(clay.ID("AccountRowGap", index))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
		if active {
			clay.Text("ACTIVE", {fontId = FONT_MONO, fontSize = 10, textColor = ACCENT, letterSpacing = 2})
		}
		clay.Text("›", {fontId = FONT_BODY, fontSize = 16, textColor = TEXT_LO})
	}
}

// hex pubkey → npub bech32; "" when the hex is malformed.
hex_npub :: proc(hex_str: string) -> string {
	bytes, ok := hex.decode(transmute([]u8)hex_str, context.temp_allocator)
	if !ok || len(bytes) != 32 {
		return ""
	}
	return bech32_encode("npub", bytes)
}

// Open the peer-profile popup for any avatar (timeline, members panel).
open_peer :: proc(ui: ^Ui_State, client: ^marmot.Client, hex_id: string, name: string, pic_url: string) {
	ui.peer_hex = strings.clone(hex_id)
	ui.peer_name = strings.clone(name)
	ui.peer_pic = strings.clone(pic_url)
	ui.peer_npub = hex_npub(hex_id)
	if len(ui.contacts) == 0 {
		load_contacts(client, ui)
	}
	ui.peer_contact = false
	for contact in ui.contacts {
		if contact.id_hex == hex_id {
			ui.peer_contact = true
			break
		}
	}
	ui.peer_open = true
}

// Peer-profile popup: who they are, their npub, and the jump to the
// full contact page when they're a contact.
peer_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("PeerModal"))(
	{
		layout = {sizing = {width = clay.SizingFixed(modal_w(clay.ID("PeerModal"), 400))}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 14},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {attachTo = .Root, zIndex = 13, offset = {0, rise(clay.ID("PeerModal"))}, attachment = {element = .CenterCenter, parent = .CenterCenter}},
	},
	) {
		if clay.UI(clay.ID("PeerHead"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 14, childAlignment = {y = .Center}}}) {
			avatar("PeerAvatar", 0, ui.peer_hex, ui.peer_name, 56, url_pic(ui.peer_pic))
			if clay.UI(clay.ID("PeerHeadCol"))({layout = {layoutDirection = .TopToBottom, childGap = 3}}) {
				clay.Text(ui.peer_name, {fontId = FONT_TITLE, fontSize = 18, textColor = TEXT})
				clay.Text(npub_tail(ui.peer_npub), {fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO})
			}
			if clay.UI(clay.ID("PeerHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("PeerClose"))(
			{layout = {sizing = {width = clay.SizingFixed(26), height = clay.SizingFixed(26)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(7)},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}

		if clay.UI(clay.ID("PeerActions"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}}) {
			micro_button("PeerCopyNpub", "Copy npub")
			if ui.peer_contact {
				micro_button("PeerViewContact", "View contact")
			}
		}
	}
}

// The slint account-switcher modal, opened from the rail avatar.
accounts_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("AccountsModal"))(
	{
		layout = {sizing = {width = clay.SizingFixed(modal_w(clay.ID("AccountsModal"), 440))}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 12},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {attachTo = .Root, zIndex = 13, offset = {0, rise(clay.ID("AccountsModal"))}, attachment = {element = .CenterCenter, parent = .CenterCenter}},
	},
	) {
		if clay.UI(clay.ID("AcctHead"))({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}}) {
			clay.Text(tr("Accounts"), {fontId = FONT_TITLE, fontSize = 20, textColor = TEXT})
			if clay.UI(clay.ID("AcctHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("AcctClose"))(
			{layout = {sizing = {width = clay.SizingFixed(26), height = clay.SizingFixed(26)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(7)},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}
		clay.Text(tr("All accounts stay connected. Switching only changes which one you're looking at."), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})

		for _, i in ui.accounts {
			account_row(ui, u32(i), ui.account_ids[i] == ui.account_ref)
		}

		if clay.UI(clay.ID("AcctFoot"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, padding = {top = 6}}}) {
			if clay.UI(clay.ID("AcctCloseBtn"))(
			{layout = {padding = {left = 18, right = 18, top = 10, bottom = 10}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(9), border = {color = FIELD_BORDER, width = bw()}},
			) {
				clay.Text(tr("Close"), {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
			}
			if clay.UI(clay.ID("AcctFootGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("AddAccountBtn"))(
			{layout = {padding = {left = 18, right = 18, top = 10, bottom = 10}}, backgroundColor = hovered() ? ACCENT_DIM : ACCENT, cornerRadius = rr(9)},
			) {
				clay.Text(tr("Add account"), {fontId = FONT_TITLE, fontSize = 13, textColor = ON_ACCENT})
			}
		}
	}
}

// Centered placeholder with a title and a sub line.
centered_note :: proc(id_str: string, title: string, sub: string) {
	if clay.UI(clay.ID(id_str))(
	{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, childAlignment = {x = .Center, y = .Center}, childGap = 8}},
	) {
		clay.Text(tr(title), {fontId = FONT_TITLE, fontSize = 24, textColor = TEXT_DIM})
		if len(sub) > 0 {
			clay.Text(tr(sub), {fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM})
		}
	}
}

// Section eyebrow, ALL CAPS like the slint app.
eyebrow :: proc(text: string) {
	// A stencilled theme brackets its captions: [ACTIONS], not ACTIONS.
	label := BRACKET_LABELS ? fmt.tprintf("[%s]", tr(text)) : tr(text)
	clay.Text(label, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM, letterSpacing = 2})
}

// The Profile page's rail, in place of the chat list: the accounts on
// this device (tap to switch), and the two settings sections that own
// the rest of an identity. A chat filter over "Search messages..."
// makes no sense while you're looking at your own profile.
profile_rail :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("PrHead"))({layout = {padding = {left = 4, top = 6, bottom = 4}}}) {
		clay.Text(fmt.tprintf("ACCOUNTS   %d", len(ui.accounts)), {fontId = FONT_MONO, fontSize = 12, textColor = TEXT_DIM, letterSpacing = 2})
	}

	for name, i in ui.accounts {
		active := ui.account_ids[i] == ui.account_ref
		if clay.UI(clay.ID("PrAcct", u32(i)))(
		{
			layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(10), childGap = 10, childAlignment = {y = .Center}},
			backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
			cornerRadius = rr(10),
		},
		) {
			avatar("PrAcctAv", u32(i), ui.account_ids[i], name, 30, url_pic(ui.account_pics[i]))
			if clay.UI(clay.ID("PrAcctCol", u32(i)))({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 2}}) {
				clay.Text(name, {fontId = FONT_TITLE, fontSize = 13, textColor = active ? TEXT : TEXT_DIM})
				clay.Text(npub_tail(ui.account_npubs[i]), {fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO})
			}
			if active {
				clay.Text("ACTIVE", {fontId = FONT_MONO, fontSize = 9, textColor = ACCENT, letterSpacing = 2})
			}
		}
	}
	if clay.UI(clay.ID("PrAddRow"))({layout = {padding = {left = 4, top = 4, bottom = 8}}}) {
		micro_button("PrAddAccount", "Add account")
	}

	if clay.UI(clay.ID("PrRule"))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(1)}}, backgroundColor = DIVIDER}) {}
	if clay.UI(clay.ID("PrLinksHead"))({layout = {padding = {left = 4, top = 8, bottom = 4}}}) {
		clay.Text(tr("IDENTITY"), {fontId = FONT_MONO, fontSize = 12, textColor = TEXT_DIM, letterSpacing = 2})
	}
	profile_rail_link("PrKeys", ICON_KEY, "Keys & identity")
	profile_rail_link("PrNetwork", ICON_GLOBE, "Network & relays")
}

// One jump row, the settings-sidebar grammar.
@(private = "file")
profile_rail_link :: proc(id_str: string, icon: string, label: string) {
	if clay.UI(clay.ID(id_str))(
	{
		layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 12, right = 12, top = 9, bottom = 9}, childGap = 10, childAlignment = {y = .Center}},
		backgroundColor = hovered() ? HOVER : {},
		cornerRadius = rr(9),
	},
	) {
		clay.Text(icon, {fontId = FONT_ICON, fontSize = 13, textColor = TEXT_DIM})
		clay.Text(tr(label), {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT_DIM})
	}
}

contacts_pane :: proc(ui: ^Ui_State) {
	if ui.selected_contact < 0 || ui.selected_contact >= len(ui.contacts) {
		centered_note("PickContact", "Contact", "Select a contact from the list.")
		return
	}
	contact := ui.contacts[ui.selected_contact]

	if clay.UI(clay.ID("ContactPage"))(
	{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = {left = 24, right = 24, top = 14, bottom = 24}, childGap = 10}},
	) {
		// Header strip: icon plate + page title, like the chat header.
		if clay.UI(clay.ID("ContactHead"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, childAlignment = {y = .Center}, padding = {bottom = 4}}}) {
			if clay.UI(clay.ID("ContactHeadIcon"))(
			{layout = {sizing = {width = clay.SizingFixed(28), height = clay.SizingFixed(28)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = ROW_BG, cornerRadius = rr(8), border = {color = FIELD_BORDER, width = bw()}},
			) {
				clay.Text(PAGE_ICONS[Page.Contacts], {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
			clay.Text("Contact", {fontId = FONT_TITLE, fontSize = 14, textColor = TEXT})
		}
		if clay.UI(clay.ID("ContactHeadRule"))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(1)}}, backgroundColor = DIVIDER}) {}

		if clay.UI(clay.ID("ContactHero"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 14, childAlignment = {y = .Center}, padding = {top = 10, bottom = 6}}}) {
			avatar("ContactHeroAvatar", 0, contact.id_hex, contact.name, 52, url_pic(contact.pic_url))
			if clay.UI(clay.ID("ContactHeroCol"))({layout = {layoutDirection = .TopToBottom, childGap = 2}}) {
				clay.Text(contact_label(ui, contact), {fontId = FONT_TITLE, fontSize = 20, textColor = TEXT})
				clay.Text(npub_tail(contact.npub), {fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO})
			}
			if clay.UI(clay.ID("ContactHeroGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			// A nicknamed contact keeps their published name visible,
			// the slint "aka" line beside the nickname field.
			if contact_label(ui, contact) != contact.name {
				clay.Text(fmt.tprintf("aka %s", contact.name), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
			}
			// Private local nickname, saved on Enter; never published.
			if clay.UI(clay.ID("NickBox"))(
			{layout = {sizing = {width = clay.SizingFixed(fit_w(320, 40)), height = clay.SizingFixed(36)}, padding = {left = 12, right = 12}, childAlignment = {y = .Center}}, backgroundColor = ROW_BG, cornerRadius = rr(8), border = {color = ui.focus == .Nick ? ACCENT : FIELD_BORDER, width = bw()}},
			) {
				field_text(ui, "NickBox", &ui.nick_input, "Nickname", ui.focus == .Nick, 12, TEXT_LO)
			}
			// Start chat fills the remaining hero width, the slint
			// wide accent button.
			if clay.UI(clay.ID("StartChatBtn"))(
			{layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(38)}, childGap = 8, childAlignment = {x = .Center, y = .Center}}, backgroundColor = ACCENT, cornerRadius = rr(9)},
			) {
				clay.Text(PAGE_ICONS[Page.Chats], {fontId = FONT_ICON, fontSize = 12, textColor = ON_ACCENT})
				clay.Text(tr("Start chat"), {fontId = FONT_TITLE, fontSize = 13, textColor = ON_ACCENT})
			}
		}

		if clay.UI(clay.ID("IdentityEyebrow"))({layout = {padding = {top = 8}}}) {
			eyebrow("IDENTITY")
		}
		// One flat card; rows separate with hairlines, values right.
		if clay.UI(clay.ID("IdentityCard"))(
		{layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom}, backgroundColor = ROW_BG, cornerRadius = rr(10), border = {color = FIELD_BORDER, width = bw()}},
		) {
			if clay.UI(clay.ID("NpubRow"))(
			{layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 16, right = 12, top = 10, bottom = 10}, childGap = 12, childAlignment = {y = .Center}}},
			) {
				if clay.UI(clay.ID("NpubCol"))({layout = {layoutDirection = .TopToBottom, childGap = 2}}) {
					clay.Text("npub", {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})
					clay.Text(tr("Public key, safe to share."), {fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO})
				}
				if clay.UI(clay.ID("NpubRowGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
				clay.Text(npub_tail(contact.npub), {fontId = FONT_MONO, fontSize = 11, textColor = TEXT_DIM})
				micro_button("CopyNpubBtn", "Copy")
			}
		}
		micro_button("QrBtn", "Show as QR")

		if clay.UI(clay.ID("KpEyebrow"))({layout = {padding = {top = 8}}}) {
			eyebrow("KEY PACKAGE")
		}
		if clay.UI(clay.ID("KpCard"))(
		{layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 16, right = 12, top = 10, bottom = 10}, childGap = 12, childAlignment = {y = .Center}}, backgroundColor = ROW_BG, cornerRadius = rr(10), border = {color = FIELD_BORDER, width = bw()}},
		) {
			state := kp_probes[contact.id_hex]
			if clay.UI(clay.ID("KpCol"))({layout = {layoutDirection = .TopToBottom, childGap = 2}}) {
				clay.Text(tr(kp_title(state)), {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})
				clay.Text(tr(kp_note(state)), {fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO})
			}
		}

		if clay.UI(clay.ID("RelaysEyebrow"))({layout = {padding = {top = 8}}}) {
			eyebrow("RELAYS IN COMMON")
		}
		contact_relays_card()

		if clay.UI(clay.ID("GroupsEyebrow"))({layout = {padding = {top = 8}}}) {
			eyebrow("GROUPS IN COMMON")
		}
		// Flat hairline rows, no filled plates.
		if clay.UI(clay.ID("CommonGroups"))(
		{layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom}},
		) {
			for group, i in contact.groups {
				if i > 0 {
					if clay.UI(clay.ID("CommonGroupRule", u32(i)))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(1)}}, backgroundColor = DIVIDER}) {}
				}
				if clay.UI(clay.ID("CommonGroup", u32(i)))(
				{layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 8, right = 8, top = 8, bottom = 8}, childGap = 10, childAlignment = {y = .Center}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(8)},
				) {
					avatar("CommonGroupAvatar", u32(i), group.title, group.title, 26)
					if clay.UI(clay.ID("CommonGroupCol", u32(i)))({layout = {layoutDirection = .TopToBottom, childGap = 1}}) {
						clay.Text(group.title, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
						clay.Text(fmt.tprintf("%d members", group.members), {fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO})
					}
				}
			}
		}

		// Local-only block, the slint contact action: nothing is
		// published; the 1:1 chat leaves the rail while blocked.
		if clay.UI(clay.ID("ActionsEyebrow"))({layout = {padding = {top = 8}}}) {
			eyebrow("ACTIONS")
		}
		if clay.UI(clay.ID("ActionsRow"))({layout = {childGap = 8}}) {
			micro_button("BlockBtn", ui.blocked[contact.id_hex] ? "Unblock" : "Block", DANGER)
			// Only a published follow can be taken back; a contact
			// known from a shared group has nothing to remove.
			if contact.followed {
				micro_button("RemoveContactBtn", "Remove contact", DANGER)
			}
		}

		if open_now(clay.ID("QrModal"), ui.qr_open) && ui.qr_tex != nil {
			qr_modal(ui, contact)
		}
	}
}

// The contact's published relays, the ones you share accented: sharing
// one means your events meet there instead of taking a longer path.
// Capped, because a published list has no upper bound and the pane does
// not scroll.
RELAY_ROWS_MAX :: 6

@(private = "file")
contact_relays_card :: proc() {
	if clay.UI(clay.ID("RelaysCard"))(
	{layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = {left = 16, right = 12, top = 10, bottom = 10}, childGap = 6}, backgroundColor = ROW_BG, cornerRadius = rr(10), border = {color = FIELD_BORDER, width = bw()}},
	) {
		if rel_state == .Checking {
			clay.Text(tr("Checking..."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
			return
		}
		if len(rel_list) == 0 {
			clay.Text(tr("They haven't published a relay list."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
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
			if clay.UI(clay.ID("RelayShareRow", u32(i)))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 8, childAlignment = {y = .Center}}}) {
				clay.Text(relay.url, {fontId = FONT_MONO, fontSize = 11, textColor = relay.mutual ? ACCENT : TEXT_DIM})
				if clay.UI(clay.ID("RelayShareGap", u32(i)))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
				if relay.inbox {
					clay.Text(tr("inbox"), {fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO})
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

// Small bordered chip, the slint MicroButton: 11px label, hairline
// border, hover fill. Pass a color to tint border + label (DANGER).
micro_button :: proc(id_str: string, label: string, color: clay.Color = {}) {
	tinted := color.a != 0
	down := press_down(clay.ID(id_str))
	if clay.UI(clay.ID(id_str))(
	{layout = {padding = {left = 10, right = 10, top = 5 + down, bottom = 5 - down}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(7), border = {color = tinted ? color : FIELD_BORDER, width = bw()}},
	) {
		clay.Text(tr(label), {fontId = FONT_BODY, fontSize = 11, textColor = tinted ? color : TEXT_DIM})
	}
}

// Centered QR overlay: the contact's marmot://profile deep link
// rasterized by the in-app encoder (show_contact_qr).
qr_modal :: proc(ui: ^Ui_State, contact: Contact_Ui) {
	if clay.UI(clay.ID("QrModal"))(
	{
		layout = {layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 12, childAlignment = {x = .Center}},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {attachTo = .Root, zIndex = 13, offset = {0, rise(clay.ID("QrModal"))}, attachment = {element = .CenterCenter, parent = .CenterCenter}},
	},
	) {
		clay.Text(contact_label(ui, contact), {fontId = FONT_TITLE, fontSize = 15, textColor = TEXT})
		if clay.UI(clay.ID("QrImage"))(
		{layout = {sizing = {width = clay.SizingFixed(260), height = clay.SizingFixed(260)}}, image = {imageData = ui.qr_tex}, cornerRadius = rr(8)},
		) {}
		clay.Text(npub_tail(ui.qr_npub), {fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO})
	}
}

// Rasterize the contact's marmot:// deep link into a texture (same
// payload as the slint profile_qr_url).
show_contact_qr :: proc(ui: ^Ui_State, contact: Contact_Ui) {
	tex := qr_texture(contact.npub)
	if tex == nil {
		ui.client_status = strings.clone(tr("Couldn't render the QR code. Please try again."))
		return
	}
	if ui.qr_tex != nil {
		rl.UnloadTexture(ui.qr_tex^)
		free(ui.qr_tex)
	}
	ui.qr_tex = tex
	ui.qr_npub = contact.npub
	ui.qr_open = true
}

// marmot://profile deep link for an npub, rasterized to a texture.
// nil when the link is too long for the encoder (qr.odin).
qr_texture :: proc(npub: string) -> ^rl.Texture2D {
	image, ok := qr_image(fmt.tprintf("marmot://profile/%s?from=qr", npub))
	if !ok {
		return nil
	}
	tex := new(rl.Texture2D)
	tex^ = rl.LoadTextureFromImage(image)
	return tex
}

archived_pane :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("ArchivedPage"))(
	{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 8}},
	) {
		clay.Text(tr("Archive"), {fontId = FONT_TITLE, fontSize = 24, textColor = TEXT})
		if len(ui.archived) == 0 {
			clay.Text(tr("No archived chats."), {fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM})
		}
		// Same rows as the chat rail, capped to rail width in the wide
		// card, title-filtered by the sidebar search.
		filter := strings.to_lower(string(ui.sidebar_filter[:]), context.temp_allocator)
		for chat, i in ui.archived {
			if len(filter) > 0 && !strings.contains(strings.to_lower(chat.title, context.temp_allocator), filter) {
				continue
			}
			if clay.UI(clay.ID("ArchivedRowBox", u32(i)))({layout = {sizing = {width = clay.SizingFixed(fit_w(420, 24))}}}) {
				chat_row(u32(i), chat, false, .Unarchive)
			}
		}
	}
}

theme_chip_indexed :: proc(id_str: string, index: u32, label: string, active: bool) {
	if clay.UI(clay.ID(id_str, index))(
	{
		layout = {padding = {left = 14, right = 14, top = 8, bottom = 8}},
		backgroundColor = active ? ACCENT : ROW_BG,
		cornerRadius = rr(8),
		border = active ? {} : clay.BorderElementConfig{color = FIELD_BORDER, width = bw()},
	},
	) {
		clay.Text(label, {fontId = FONT_BODY, fontSize = 14, textColor = active ? ON_ACCENT : TEXT})
	}
}

// theme_chip with a hover tooltip, for the icon-only chat-header
// controls where the glyph is the only label.
header_chip :: proc(id_str: string, glyph: string, active: bool, tip: string) {
	pad := tap_size() ? u16(13) : u16(8)
	if clay.UI(clay.ID(id_str))(
	{
		layout = {padding = {left = 14, right = 14, top = pad, bottom = pad}},
		backgroundColor = active ? ACCENT : ROW_BG,
		cornerRadius = rr(8),
	},
	) {
		if hovered() {
			tooltip(tip)
		}
		clay.Text(glyph, {fontId = FONT_ICON, fontSize = 14, textColor = active ? ON_ACCENT : TEXT})
	}
}

theme_chip :: proc(id_str: string, label: string, active: bool) {
	is_icon := len(label) == 3 && u8(label[0]) >= 0xEE
	if clay.UI(clay.ID(id_str))(
	{
		layout = {padding = {left = 14, right = 14, top = 8, bottom = 8}},
		backgroundColor = active ? ACCENT : ROW_BG,
		cornerRadius = rr(8),
	},
	) {
		clay.Text(label, {fontId = is_icon ? FONT_ICON : FONT_BODY, fontSize = 14, textColor = active ? ON_ACCENT : TEXT})
	}
}

// One LABEL · input row of the profile edit form.
form_row :: proc(ui: ^Ui_State, index: u32, label: string, box_id: string, buf: ^[dynamic]u8, placeholder: string, active: bool) {
	if clay.UI(clay.ID("ProfileFormRow", index))(
	{layout = {sizing = {width = clay.SizingGrow()}, childGap = 12, childAlignment = {y = .Center}}},
	) {
		if clay.UI(clay.ID("ProfileFormLabel", index))({layout = {sizing = {width = clay.SizingFixed(120)}}}) {
			clay.Text(tr(label), {fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO, letterSpacing = 2})
		}
		input_box(ui, box_id, buf, placeholder, active, 0)
	}
}

// One label-left / value-right hairline row in the PROFILE card.
// The whole row is a shortcut into the edit form, so it lights on
// hover like any other actionable row.
profile_kv :: proc(index: u32, label: string, value: string, last := false) {
	if clay.UI(clay.ID("ProfileKv", index))(
	{
		layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 16, right = 16, top = 12, bottom = 12}, childAlignment = {y = .Center}, childGap = 10},
		backgroundColor = hovered() ? HOVER : {},
	},
	) {
		clay.Text(label, {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})
		if clay.UI(clay.ID("ProfileKvGap", index))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
		clay.Text(len(value) > 0 ? value : "—", {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
		if hovered() {
			clay.Text(ICON_PENCIL, {fontId = FONT_ICON, fontSize = 11, textColor = TEXT_LO})
		}
	}
	if !last {
		if clay.UI(clay.ID("ProfileKvRule", index))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(1)}}, backgroundColor = DIVIDER}) {}
	}
}

// The slint ProfilePage viewer: header + Edit toggle, banner hero,
// IDENTITY (npub + inline QR), PROFILE rows, accounts. Relays and the
// nsec moved to Settings (Network / Keys) and left this page.
profile_pane :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("ProfilePage"))(
	{
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 12},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		// ── Header: title + visibility eyebrow, Edit toggle right ──
		if clay.UI(clay.ID("ProfileHead"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, childAlignment = {y = .Center}}}) {
			if clay.UI(clay.ID("ProfileHeadCol"))({layout = {layoutDirection = .TopToBottom, childGap = 3}}) {
				clay.Text(tr("Your profile"), {fontId = FONT_TITLE, fontSize = 22, textColor = TEXT})
				clay.Text(ui.profile.editing ? "EDITING · BROADCAST TO RELAYS ON PUBLISH" : "VISIBLE TO ANYONE YOU CHAT WITH", {fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO, letterSpacing = 2})
			}
			if clay.UI(clay.ID("ProfileHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("EditProfileBtn"))(
			{
				layout = {padding = {left = 14, right = 14, top = 8, bottom = 8}, childGap = 8, childAlignment = {y = .Center}},
				backgroundColor = ui.profile.editing ? (hovered() ? HOVER : ROW_BG) : ACCENT,
				cornerRadius = rr(9),
				border = ui.profile.editing ? clay.BorderElementConfig{color = FIELD_BORDER, width = bw()} : {},
			},
			) {
				if !ui.profile.editing {
					clay.Text(ICON_PENCIL, {fontId = FONT_ICON, fontSize = 12, textColor = ON_ACCENT})
				}
				clay.Text(ui.profile.editing ? "Cancel" : "Edit profile", {fontId = FONT_TITLE, fontSize = 13, textColor = ui.profile.editing ? TEXT : ON_ACCENT})
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
			if clay.UI(clay.ID("ProfileBanner"))(
			{
				layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(88)}, padding = {right = 24}, childGap = 10, childAlignment = {y = .Center}},
				backgroundColor = ACCENT,
				cornerRadius = {topLeft = 14, topRight = 14},
			},
			) {
				// Quiet dot ornament so the band reads designed, not
				// unfinished, on every pack's accent.
				if clay.UI(clay.ID("BannerFill"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
				for size, i in ([3]f32{18, 30, 46}) {
					if clay.UI(clay.ID("BannerDot", u32(i)))(
					{layout = {sizing = {width = clay.SizingFixed(size), height = clay.SizingFixed(size)}}, backgroundColor = {255, 255, 255, 28}, cornerRadius = rr(size / 2)},
					) {}
				}
			}

			// The avatar overlaps the banner/body seam. In edit mode
			// the whole circle picks a new picture, badged with ✎.
			if clay.UI(clay.ID("ProfileAvatarPick"))(
			{
				layout = {sizing = {width = clay.SizingFixed(96), height = clay.SizingFixed(96)}},
				floating = {attachTo = .Parent, zIndex = 5, offset = {24, 40}, attachment = {element = .LeftTop, parent = .LeftTop}},
			},
			) {
				if ui.profile.editing && hovered() {
					tooltip(tr("Change picture"))
				}
				avatar("ProfileAvatar", 0, ui.account_ref, len(ui.profile.name) > 0 ? ui.profile.name : short_hex(ui.account_ref), 96, url_pic(ui.my_pic_url))
				if ui.profile.editing {
					if clay.UI(clay.ID("ProfileAvatarBadge"))(
					{
						layout = {sizing = {width = clay.SizingFixed(30), height = clay.SizingFixed(30)}, childAlignment = {x = .Center, y = .Center}},
						floating = {attachTo = .Parent, zIndex = 6, offset = {2, 2}, attachment = {element = .RightBottom, parent = .RightBottom}},
						backgroundColor = ACCENT,
						cornerRadius = rr(15),
						border = {color = ROW_BG, width = {2, 2, 2, 2, 0}},
					},
					) {
						clay.Text(ICON_PENCIL, {fontId = FONT_ICON, fontSize = 12, textColor = ON_ACCENT})
					}
				}
			}

			if clay.UI(clay.ID("ProfileHeroRow"))(
			{layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 136, right = 24, top = 14, bottom = 18}, childGap = 14, childAlignment = {y = .Center}}},
			) {
				if clay.UI(clay.ID("ProfileHeroCol"))({layout = {layoutDirection = .TopToBottom, childGap = 3}}) {
					// While editing, the hero previews the drafts live.
					shown_name := ui.profile.editing ? string(ui.name_input[:]) : ui.profile.name
					shown_about := ui.profile.editing ? string(ui.about_input[:]) : ui.profile.about
					clay.Text(len(shown_name) > 0 ? shown_name : "(no display name)", {fontId = FONT_TITLE, fontSize = 24, textColor = TEXT})
					clay.Text(len(ui.profile.username) > 0 ? fmt.tprintf("@%s", ui.profile.username) : npub_tail(ui.profile.npub), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO})
					if len(shown_about) > 0 {
						clay.Text(shown_about, {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
					}
				}
			}
		}

		// ── Edit form: every kind-0 field the app lets you set ─────
		if ui.profile.editing {
			if clay.UI(clay.ID("FormEyebrow"))({layout = {padding = {top = 6}}}) {
				eyebrow("EDIT PROFILE")
			}
			if clay.UI(clay.ID("ProfileForm"))(
			{
				layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = {left = 16, right = 16, top = 14, bottom = 14}, childGap = 10},
				backgroundColor = ROW_BG,
				cornerRadius = rr(12),
				border = {color = FIELD_BORDER, width = bw()},
			},
			) {
				form_row(ui, 0, "DISPLAY NAME", "NameBox", &ui.name_input, tr("Your name"), ui.focus == .Name)
				form_row(ui, 1, "ABOUT", "AboutBox", &ui.about_input, tr("A line about you"), ui.focus == .About)
				form_row(ui, 2, "NIP-05", "Nip05Box", &ui.nip05_input, "name@example.com", ui.focus == .Nip05)
				form_row(ui, 3, "LIGHTNING", "Lud16Box", &ui.lud16_input, "you@wallet.com", ui.focus == .Lud16)
				if clay.UI(clay.ID("ProfileFormActions"))(
				{layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, padding = {top = 6}, childAlignment = {y = .Center}}},
				) {
					if ppic_busy {
						micro_button("ChangePicBtn", "Uploading picture")
					} else {
						micro_button("ChangePicBtn", "Change picture")
					}
					if clay.UI(clay.ID("FormActionGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
					clay.Text(tr("Enter publishes, Escape cancels."), {fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO})
					if clay.UI(clay.ID("PublishProfileBtn"))(
					{
						layout = {padding = {left = 16, right = 16, top = 9, bottom = 9}},
						backgroundColor = ACCENT,
						cornerRadius = rr(9),
					},
					) {
						clay.Text(tr("Publish changes"), {fontId = FONT_TITLE, fontSize = 13, textColor = ON_ACCENT})
					}
				}
			}
		}

		// ── Identity: copyable npub + inline QR ────────────────────
		if clay.UI(clay.ID("IdEyebrow"))({layout = {padding = {top = 6}}}) {
			eyebrow("IDENTITY")
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
			{layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 16, right = 12, top = 10, bottom = 10}, childGap = 12, childAlignment = {y = .Center}}},
			) {
				if clay.UI(clay.ID("ProfileNpubCol"))({layout = {layoutDirection = .TopToBottom, childGap = 2}}) {
					clay.Text("npub", {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})
					clay.Text(tr("Your public key. Safe to share."), {fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO})
				}
				if clay.UI(clay.ID("ProfileNpubGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
				clay.Text(npub_tail(ui.profile.npub), {fontId = FONT_MONO, fontSize = 11, textColor = TEXT_DIM})
				micro_button("ProfileCopyNpub", "Copy")
			}
			if ui.profile.qr != nil {
				if clay.UI(clay.ID("ProfileQrPlate"))(
				{layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = {top = 8, bottom = 16}, childGap = 10, childAlignment = {x = .Center}}},
				) {
					if clay.UI(clay.ID("ProfileQr"))(
					{layout = {sizing = {width = clay.SizingFixed(200), height = clay.SizingFixed(200)}}, image = {imageData = ui.profile.qr}, cornerRadius = rr(8)},
					) {}
					clay.Text(tr("Scan to add this account from another device"), {fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO})
				}
			}
		}

		// ── Profile fields, viewer rows ────────────────────────────
		if clay.UI(clay.ID("ProfileEyebrow"))({layout = {padding = {top = 6}}}) {
			eyebrow("PROFILE")
		}
		if clay.UI(clay.ID("ProfileCard"))(
		{
			layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom},
			backgroundColor = ROW_BG,
			cornerRadius = rr(10),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			profile_kv(0, "Username", len(ui.profile.username) > 0 ? fmt.tprintf("@%s", ui.profile.username) : "")
			profile_kv(1, "NIP-05", ui.profile.nip05)
			profile_kv(2, "Lightning", ui.profile.lud16)
			profile_kv(3, "Picture", ui.profile.pic_set ? "Set" : "Not set", true)
		}

		if clay.UI(clay.ID("SignOutPad"))({layout = {padding = {top = 6}}}) {
			login_button("SignOutBtn", "Sign out")
		}
	}
	scrollbar(clay.ID("ProfilePage"))
}

nav_button :: proc(page: Page, active: bool) {
	// Fixed square + centered glyph: fit-sizing made each button take
	// its icon's advance/height, so the row wobbled per glyph.
	down := press_down(clay.ID("Nav", u32(page)))
	// 42 is what the rail's top strip can spare at its narrowest with
	// the collapse chip gone; ~7mm at phone density, the floor for a
	// fingertip.
	side := tap_size() ? f32(42) : f32(32)
	if clay.UI(clay.ID("Nav", u32(page)))(
	{
		layout = {sizing = {width = clay.SizingFixed(side), height = clay.SizingFixed(side)}, padding = {top = down * 2}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
		cornerRadius = rr(9),
	},
	) {
		if hovered() {
			tooltip(NAV_TIPS[page])
		}
		clay.Text(PAGE_ICONS[page], {fontId = FONT_ICON, fontSize = 15, textColor = active ? ACCENT : TEXT_DIM})
	}
}

NAV_BAR_W :: f32(16)

// Accent underline that slides between nav buttons instead of blinking
// from one to the next. It reads last frame's button box, so it starts
// a frame behind the click, which is exactly what makes the travel
// visible.
nav_indicator :: proc(ui: ^Ui_State) {
	box := clay.GetElementData(clay.ID("Nav", u32(ui.page)))
	if !box.found {
		return
	}
	x := anim_to(clay.ID("NavBarX").id, box.boundingBox.x + (box.boundingBox.width - NAV_BAR_W) / 2, 22)
	y := anim_to(clay.ID("NavBarY").id, box.boundingBox.y + box.boundingBox.height - 3, 22)
	if clay.UI(clay.ID("NavBar"))(
	{
		layout = {sizing = {width = clay.SizingFixed(NAV_BAR_W), height = clay.SizingFixed(2)}},
		floating = {attachTo = .Root, zIndex = 6, offset = {x, y}, attachment = {element = .LeftTop, parent = .LeftTop}},
		backgroundColor = ACCENT,
		cornerRadius = rr(1),
	},
	) {}
}

NAV_TIPS := [Page]string {
	.Chats    = "Chats",
	.Contacts = "People",
	.Archived = "Archive",
	.Settings = "Settings",
	.Profile  = "Your profile",
}

