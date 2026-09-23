package main

import "core:strings"
import "core:testing"

@(test)
profiles_update_live_views :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	hex := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	register_starter_pic(hex, "Before", "", {})
	ui := Ui_State {
		account_ref = hex,
		peer_hex    = hex,
		peer_open   = true,
		member_nick = 0,
	}
	append(&ui.members, Member_Ui{id_hex = hex, name = strings.clone("Before")})
	append(&ui.contacts, Contact_Ui{id_hex = hex, name = strings.clone("Before")})
	ui.profile_contact = Contact_Ui {
		id_hex = hex,
		name   = strings.clone("Before"),
	}
	append(&ui.account_ids, hex)
	append(&ui.accounts, strings.clone("Before"))
	append(&ui.account_pics, "")
	ui.nicknames[hex] = "Local nickname"
	ui.peer_name = strings.clone("Before")

	info := Profile_Info {
		strings.clone("After"),
		strings.clone("https://example.org/new.png"),
		strings.clone("after@example.org"),
	}
	testing.expect(t, update_profile(&ui, hex, info))
	testing.expect_value(t, profile_info(nil, hex).name, "After")
	testing.expect_value(t, profile_info(nil, hex).nip05, "after@example.org")
	testing.expect_value(t, ui.members[0].name, "Local nickname")
	testing.expect_value(t, ui.members[0].pic_url, info.pic_url)
	testing.expect_value(t, ui.member_nick, 0)
	testing.expect_value(t, ui.contacts[0].name, "After")
	testing.expect_value(t, contact_label(&ui, ui.contacts[0]), "Local nickname")
	testing.expect_value(t, ui.contacts[0].pic_url, info.pic_url)
	testing.expect_value(t, ui.profile_contact.name, "After")
	testing.expect_value(t, ui.profile_contact.pic_url, info.pic_url)
	testing.expect_value(t, ui.peer_name, "Local nickname")
	testing.expect_value(t, ui.peer_pic, info.pic_url)
	testing.expect_value(t, ui.my_pic_url, info.pic_url)
	testing.expect_value(t, ui.accounts[0], "After")
	testing.expect_value(t, ui.account_pics[0], info.pic_url)

	// Equal results leave the owned strings in place; clearing a profile is an update.
	before := raw_data(ui.members[0].pic_url)
	testing.expect(
		t,
		!update_profile(
			&ui,
			hex,
			{strings.clone(info.name), strings.clone(info.pic_url), strings.clone(info.nip05)},
		),
	)
	testing.expect_value(t, raw_data(ui.members[0].pic_url), before)
	delete_key(&ui.nicknames, hex)
	testing.expect(t, update_profile(&ui, hex, {}))
	testing.expect_value(t, ui.members[0].name, short_hex(hex))
	testing.expect_value(t, ui.contacts[0].name, short_hex(hex))
	testing.expect_value(t, ui.peer_name, short_hex(hex))
	testing.expect_value(t, ui.members[0].pic_url, "")
	testing.expect_value(t, ui.contacts[0].pic_url, "")
	testing.expect_value(t, ui.profile_contact.pic_url, "")
	testing.expect_value(t, ui.peer_pic, "")
	testing.expect_value(t, ui.my_pic_url, "")
	testing.expect_value(t, profile_info(nil, hex).nip05, "")
}
