package main

import "core:strings"
import "core:sync"
import "core:testing"

import "nendo"

@(test)
new_chat_invalid_npub_feedback :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	context.allocator = context.temp_allocator
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	nendo.set_measure_text(
		proc(text: string, config: ^nendo.Text_Style, user: rawptr) -> nendo.Dimensions {
			return {f32(len(text)) * f32(config.size) / 2, f32(config.size)}
		},
		nil,
	)
	defer {nendo.set_context(previous); delete(memory)}
	nendo.set_pointer({-1, -1}, .Up)

	render :: proc(ui: ^Ui_State) -> string {
		nendo.begin()
		new_chat_pane(ui)
		commands := nendo.end(0)
		text: [dynamic]u8
		for command in commands {
			if command.kind != .Text {continue}
			data := command.text.text
			append(&text, data)
			append(&text, ' ')
		}
		return string(text[:])
	}

	ui: Ui_State
	valid :: "npub1d6qfwzfzzexwg39v98msg2nv3v7ey8jpwr4dv5fy9hd3pucusmpqasx9s6"
	hex := "6e80970922164ce444ac29f7042a6c8b3d921e4170ead651242ddb10f31c86c2"
	cases := []struct {
		query, expected: string,
		invalid:         bool,
	} {
		{
			"npub1d6qfwzfzzexwg39v98msg2nv3v7ey8jpwr4dv5fy9hd3pucusmpqasx9s7",
			"This key has a typo.",
			true,
		},
		{"  NPUB1INVALID  ", "This key has a typo.", true},
		{"npub1", "This key has a typo.", true},
		{"Alice", "No matches", false},
		{"  ", "No contacts yet", false},
		{valid, "Start chat", false},
		{hex, "Start chat", false},
		{"marmot://profile/" + valid, "Start chat", false},
	}
	for scenario in cases {
		clear(&ui.nc_search)
		append(&ui.nc_search, scenario.query)
		text := render(&ui)
		testing.expect(t, strings.contains(text, scenario.expected), scenario.query)
		testing.expect_value(t, strings.contains(text, "This key has a typo."), scenario.invalid)
		if scenario.invalid {
			testing.expect(
				t,
				strings.contains(text, "Check each character against the original and try again."),
			)
			testing.expect(t, !strings.contains(text, "No matches"))
			testing.expect(t, !strings.contains(text, "Start chat"))
		}
	}
	// A valid key belonging to this account is not a decoding error.
	ui.account_ref = hex
	testing.expect_value(t, nc_address_hex(&ui, valid), "")
	testing.expect_value(t, deeplink_hex(valid), hex)
	clear(&ui.nc_search)
	append(&ui.nc_search, valid)
	text := render(&ui)
	testing.expect(t, !strings.contains(text, "This key has a typo."))
	testing.expect(t, !strings.contains(text, "Start chat"))

	// Contact loading must not hide a local, immediately detectable typo.
	jobs := account_jobs
	account_jobs = nil
	defer account_jobs = jobs
	job := Account_Job {
		account = hex,
		kind    = .Read_Contacts,
	}
	append(&account_jobs, &job)
	clear(&ui.nc_search)
	append(&ui.nc_search, cases[0].query)
	text = render(&ui)
	testing.expect(t, strings.contains(text, "This key has a typo."))
	testing.expect(
		t,
		strings.contains(text, "Check each character against the original and try again."),
	)
}
