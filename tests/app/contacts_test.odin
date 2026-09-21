package main

import "core:testing"
import marmot "../marmot"

@(test)
view_unsaved_profile :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	ui := Ui_State{selected_contact = -1, peer_hex = "visitor", peer_name = "Pepi Testing", peer_npub = "npub-visitor", peer_open = true}
	append(&ui.contacts, Contact_Ui{id_hex = "saved", name = "Saved contact"})
	view_peer_profile(&ui, nil)
	contact, found := shown_contact(&ui)
	testing.expect(t, found && !ui.peer_open && ui.page == .Contacts)
	testing.expect_value(t, contact.id_hex, "visitor")
	testing.expect_value(t, contact.name, "Pepi Testing")
	testing.expect_value(t, len(ui.contacts), 1)
	testing.expect_value(t, ui.selected_contact, -1)
	// Opening another popup cannot replace the profile being viewed underneath it.
	ui.peer_hex = "saved"
	contact, _ = shown_contact(&ui)
	testing.expect_value(t, contact.id_hex, "visitor")
	view_peer_profile(&ui, nil)
	contact, found = shown_contact(&ui)
	testing.expect(t, found && ui.selected_contact == 0 && len(ui.profile_contact.id_hex) == 0)
	testing.expect_value(t, contact.name, "Saved contact")
	ui.account_ref, ui.peer_hex, ui.profile.loaded = "self", "self", true
	view_peer_profile(&ui, nil)
	testing.expect_value(t, ui.page, Page.Profile)
}

@(test)
contacts_named_first :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	ui: Ui_State
	append(&ui.contacts,
		Contact_Ui{id_hex = "0123456789abcdef", name = short_hex("0123456789abcdef")},
		Contact_Ui{id_hex = "alice", name = "Alice"},
		Contact_Ui{id_hex = "number", name = "123"},
		Contact_Ui{id_hex = "emoji", name = "⚡ Dee Kay ⚡"},
		Contact_Ui{id_hex = "nickname", name = "nickname"},
		Contact_Ui{id_hex = "empty"},
	)
	ui.nicknames["nickname"] = "Bob"
	expected := [6]int{2, 1, 4, 3, 5, 0}
	for row, i in contact_order(&ui) {
		testing.expect_value(t, row.idx, expected[i])
	}
	// A fetched profile joins the named section on the next frame.
	ui.contacts[0].name = "Aaron"
	testing.expect_value(t, contact_order(&ui)[1].idx, 0)
}

@(test)
groups_do_not_add_contacts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	ui: Ui_State
	append(&ui.contacts, Contact_Ui{id_hex = "saved"}, Contact_Ui{id_hex = "no-shared-group"})
	indices: map[string]int
	indices["saved"] = 0
	indices["no-shared-group"] = 1
	members := []marmot.Group_Member_Record{
		{member_id_hex = "self", local = true},
		{member_id_hex = "saved"},
		{member_id_hex = "acquaintance"},
		{},
	}
	contact_groups(&ui, Chat_Row_Ui{group_id = "group", title = "Shared"}, members, indices)
	testing.expect_value(t, len(ui.contacts), 2)
	testing.expect_value(t, len(ui.contacts[0].groups), 1)
	testing.expect_value(t, ui.contacts[0].groups[0].title, "Shared")
	testing.expect_value(t, len(ui.contacts[1].groups), 0)

	// A direct chat still supports blocking without making its peer a contact.
	direct := []marmot.Group_Member_Record{members[0], members[2]}
	contact_groups(&ui, Chat_Row_Ui{group_id = "dm"}, direct, indices)
	testing.expect_value(t, len(ui.contacts), 2)
	testing.expect_value(t, ui.dm_peer["dm"], "acquaintance")

	// Removing a follow must not recreate it from a shared group.
	clear(&ui.contacts)
	clear(&indices)
	contact_groups(&ui, Chat_Row_Ui{group_id = "group"}, members, indices)
	testing.expect_value(t, len(ui.contacts), 0)
}
