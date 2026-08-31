// One confirm modal for every destructive action, the slint confirm
// flow: ask before deleting, leaving, blocking, removing a member,
// changing admin rights, declining an invite, or dropping a relay.
//
// Call sites hand over the intent (kind + subject) instead of acting;
// run_confirm performs it once the user says yes. The two-step "arm the
// button" pattern in the Keys / Storage / Advanced pages predates this
// and stays as it is: those rows have no subject to name.
package main

import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

Confirm_Kind :: enum {
	None,
	Delete_All, // delete for everyone
	Delete_Me, // hide locally
	Leave_Group,
	Block,
	Remove_Member,
	Promote,
	Demote,
	Step_Down,
	Decline_Invite,
	Remove_Relay,
	Remove_Inbox,
	Sign_Out,
}

Confirm :: struct {
	kind: Confirm_Kind,
	arg:  string, // message id, member hex, relay url: whatever the kind acts on
	name: string, // what the copy names ("Ana", "wss://relay.example")
	idx:  int, // relay index, for the list removals
}

// Title, body, and the danger button's label per kind.
confirm_copy :: proc(c: Confirm) -> (title, body, action: string) {
	switch c.kind {
	case .None:
		return "", "", ""
	case .Delete_All:
		return N_("Delete this message?"), N_("It disappears for everyone in the chat. This can't be undone."), N_("Delete for everyone")
	case .Delete_Me:
		return N_("Delete for you?"), N_("It stays for everyone else. You won't see it on this device again."), N_("Delete for me")
	case .Leave_Group:
		return N_("Leave this group?"), N_("You stop receiving its messages. Rejoining needs a new invite."), N_("Leave")
	case .Block:
		return N_("Block this contact?"), N_("Their direct chat leaves your list. Nothing is published, and you can undo it here."), N_("Block")
	case .Remove_Member:
		return N_("Remove this member?"), N_("They lose access to new messages in this group."), N_("Remove")
	case .Promote:
		return N_("Make this member an admin?"), N_("Admins can add and remove members and change group details."), N_("Promote")
	case .Demote:
		return N_("Remove admin rights?"), N_("They stay in the group as a regular member."), N_("Demote")
	case .Step_Down:
		return N_("Step down as admin?"), N_("You stay in the group, but another admin has to grant the rights back."), N_("Step down")
	case .Decline_Invite:
		return N_("Decline this invitation?"), N_("The chat leaves your list. Joining later needs a new invite."), N_("Decline")
	case .Remove_Relay, .Remove_Inbox:
		return N_("Remove this relay?"), N_("The updated list is published to your relays."), N_("Remove")
	case .Sign_Out:
		return N_("Sign out of this account?"), N_("Its keys stay in the vault on this device. You can sign in again from the accounts screen."), N_("Sign out")
	}
	return "", "", ""
}

// One clipped line of a message, so the confirm names what it acts on.
// Attachment-only rows have no body and get no subject card.
msg_preview :: proc(msg: Msg_Ui) -> string {
	line := msg.body
	if nl := strings.index_byte(line, '\n'); nl >= 0 {
		line = line[:nl]
	}
	if len(line) > 70 {
		return fmt.tprintf("%s…", line[:rune_snap(line, 70)])
	}
	return line
}

confirm_ask :: proc(ui: ^Ui_State, kind: Confirm_Kind, arg: string, name: string = "", idx: int = -1) {
	// Frees the previous ask's payload, which confirm_close left alone.
	delete(ui.confirm.arg)
	delete(ui.confirm.name)
	ui.confirm = Confirm{kind = kind, arg = strings.clone(arg), name = strings.clone(name), idx = idx}
	confirm_shown = kind
}

// The kind the modal renders while it animates out, after the live
// state says .None.
confirm_shown: Confirm_Kind

confirm_close :: proc(ui: ^Ui_State) {
	// Only the kind is cleared: the modal is still on screen leaving,
	// so its subject text has to outlive the close. The next ask frees
	// it.
	ui.confirm.kind = .None
}

confirm_modal :: proc(ui: ^Ui_State) {
	shown := ui.confirm
	if shown.kind == .None {
		shown.kind = confirm_shown
	}
	title, body, action := confirm_copy(shown)
	if clay.UI(clay.ID("ConfirmModal"))(
	{
		layout = {sizing = {width = clay.SizingFixed(modal_w(clay.ID("ConfirmModal"), 400))}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 10},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {attachTo = .Root, zIndex = 16, offset = {0, rise(clay.ID("ConfirmModal"))}, attachment = {element = .CenterCenter, parent = .CenterCenter}},
	},
	) {
		clay.Text(tr(title), {fontId = FONT_TITLE, fontSize = 18, textColor = TEXT})
		if len(ui.confirm.name) > 0 {
			if clay.UI(clay.ID("ConfirmSubject"))(
			{layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(10)}, backgroundColor = ROW_BG, cornerRadius = rr(8), border = {color = FIELD_BORDER, width = bw()}},
			) {
				clay.Text(ui.confirm.name, {fontId = FONT_BODY, fontSize = 13, textColor = TEXT})
			}
		}
		clay.Text(tr(body), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})

		if clay.UI(clay.ID("ConfirmActions"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, padding = {top = 6}}}) {
			if clay.UI(clay.ID("ConfirmCancel"))(
			{layout = {padding = {left = 16, right = 16, top = 9, bottom = 9}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(9), border = {color = FIELD_BORDER, width = bw()}},
			) {
				clay.Text(tr("Cancel"), {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
			}
			if clay.UI(clay.ID("ConfirmGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("ConfirmGo"))(
			{layout = {padding = {left = 16, right = 16, top = 9, bottom = 9}}, backgroundColor = hovered() ? DANGER : ROW_BG, cornerRadius = rr(9), border = {color = DANGER, width = bw()}},
			) {
				clay.Text(tr(action), {fontId = FONT_TITLE, fontSize = 13, textColor = hovered() ? BG : DANGER})
			}
		}
	}
}

// Input while the modal is open; Enter confirms, Escape and the
// backdrop cancel.
handle_confirm :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if rl.IsKeyPressed(.ESCAPE) {
		confirm_close(ui)
		return
	}
	go := rl.IsKeyPressed(.ENTER) || clicked("ConfirmGo")
	if go {
		run_confirm(ui, client)
		return
	}
	if mouse_released() && (clicked("ConfirmCancel") || !clay.PointerOver(clay.ID("ConfirmModal"))) {
		confirm_close(ui)
	}
}

run_confirm :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	c := ui.confirm
	// The action reads c, so the state clears after the switch.
	defer confirm_close(ui)

	switch c.kind {
	case .None:
	case .Delete_All:
		message_op(ui, client, .Delete, c.arg, "")
	case .Delete_Me:
		ui.hidden[strings.clone(c.arg)] = true
		save_hidden(ui)
		load_timeline(client, ui)
	case .Leave_Group:
		leave_group(ui, client)
	case .Block:
		ui.blocked[strings.clone(c.arg)] = true
		save_settings(ui)
	case .Remove_Member:
		admin_op(ui, client, "remove", c.arg)
	case .Promote:
		admin_op(ui, client, "promote", c.arg)
	case .Demote, .Step_Down:
		admin_op(ui, client, "demote", c.arg)
	case .Decline_Invite:
		decline_invite(ui, client)
	case .Remove_Relay:
		set_relays(ui, client, relays_without(ui.profile.nip65[:], c.idx))
	case .Remove_Inbox:
		set_inbox_relays(ui, client, relays_without(ui.profile.inbox[:], c.idx))
	case .Sign_Out:
		sign_out(ui, client)
	}
}

// The relay list minus one entry, as the cstrings the setters take.
relays_without :: proc(relays: []string, skip: int) -> []cstring {
	out := make([dynamic]cstring, context.temp_allocator)
	for relay, i in relays {
		if i != skip {
			append(&out, strings.clone_to_cstring(relay, context.temp_allocator))
		}
	}
	return out[:]
}

leave_group :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if ui.selected < 0 {
		return
	}
	summary: ^marmot.Send_Summary
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	group := strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator)
	if marmot.leave_group(client, account, group, &summary) != .OK {
		ui.client_status = fmt.aprintf("Couldn't leave. %s", marmot.last_error())
		return
	}
	marmot.send_summary_free(summary)
	ui.show_members = false
	ui.selected = -1
	load_chat_list(client, ui.account_ref, ui)
}

decline_invite :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if ui.selected < 0 {
		return
	}
	result: ^marmot.Group_Invite_Decline_Result
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	group := strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator)
	if marmot.decline_group_invite(client, account, group, &result) != .OK {
		ui.client_status = fmt.aprintf("Couldn't decline. %s", marmot.last_error())
		return
	}
	marmot.group_invite_decline_result_free(result)
	ui.selected = -1
	refresh_after_action(ui, client)
}

sign_out :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	outcome: ^marmot.Sign_Out_Outcome
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	if marmot.sign_out(client, account, false, &outcome) != .OK {
		ui.client_status = fmt.aprintf("Couldn't sign out. %s", marmot.last_error())
		return
	}
	marmot.sign_out_outcome_free(outcome)
	ui.page = .Chats
	ui.selected = -1
	after_login(ui, client) // re-snapshot accounts; empty list shows login
}
