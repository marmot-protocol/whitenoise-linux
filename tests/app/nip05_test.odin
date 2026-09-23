package main

import "core:strings"
import "core:testing"

@(test)
nip05 :: proc(t: ^testing.T) {
	key :: "b0635d6a9851d3aed0cd6c495b282167acf761729078d975fc341b22650b07b9"
	name, domain := nip05_parts(" bob@Example.com ")
	testing.expect_value(t, name, "bob")
	testing.expect_value(t, domain, "Example.com")
	name, domain = nip05_parts("_@example.com")
	testing.expect_value(t, name, "_")
	for ref in ([]string{"bob", "@example.com", "bob@", "bob@@example.com", "bob@host/path", "bob@host:443", "bob@host?x", "bob@host#x", "bob@-host.com", "bob@host-.com", "bob@host..com", "bob@host.", "bob&x@host.com", "bob\n@host.com"}) {
		name, _ = nip05_parts(ref)
		testing.expect(t, name == "", ref)
	}
	body := `{"names":{"bob":"` + key + `","other":"bad"}}`
	parsed := nip05_parse(transmute([]u8)body, "bob")
	testing.expect_value(t, parsed, key)
	delete(parsed)
	for invalid in ([]string{"null", "[]", "{", `{"names":[]}`, `{"names":{"bob":123}}`, `{"names":{"bob":"npub1bad"}}`, `{"names":{"other":"` + key + `"}}`, `{"names":{"bob":"G0635d6a9851d3aed0cd6c495b282167acf761729078d975fc341b22650b07b9"}}`}) {
		testing.expect_value(t, nip05_parse(transmute([]u8)invalid, "bob"), "")
	}
	// Both forms adopt only their own unchanged request; errors preserve input.
	ui := Ui_State {
		account_ref   = "account",
		page          = .Chats,
		new_chat_open = true,
		selected      = -1,
	}
	defer delete(ui.nc_member)
	defer delete(ui.invite_input)
	defer delete(ui.client_status)
	for scenario in 0 ..< 7 {
		ui.nip05_ticket = 1
		ui.new_chat_open = scenario < 4
		ui.show_members = true
		ui.selected = ui.new_chat_open ? -1 : 0
		append(&ui.chats, Chat_Row_Ui{group_id = "group"})
		buf := ui.new_chat_open ? &ui.nc_member : &ui.invite_input
		ed_set(&ui, buf, "bob@example.com")
		done := Op_Done {
			ticket  = 1,
			account = strings.clone(scenario == 1 ? "other" : "account"),
			group   = strings.clone(ui.new_chat_open ? "" : scenario == 5 ? "other" : "group"),
			target  = strings.clone(scenario == 2 ? "old@example.com" : "bob@example.com"),
			content = strings.clone(scenario == 3 ? "" : key),
		}
		if scenario == 6 {ui.nip05_ticket = 2}
		nip05_complete(&ui, done)
		testing.expect_value(
			t,
			string(buf[:]),
			scenario == 0 || scenario == 4 ? key : "bob@example.com",
		)
		clear(&ui.chats)
	}
	delete(ui.chats)
}
