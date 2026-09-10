package main

import "core:testing"
import marmot "../marmot"

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
