package main

import "core:strings"
import "core:sync"
import "core:testing"

import clay "../vendor/clay/bindings/odin/clay-odin"

@(test)
new_chat_invalid_npub_feedback :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	context.allocator = context.temp_allocator
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	clay.SetMeasureTextFunction(
		proc "c" (text: clay.StringSlice, config: ^clay.TextElementConfig, user: rawptr) -> clay.Dimensions {
			return {f32(text.length) * f32(config.fontSize) / 2, f32(config.fontSize)}
		},
		nil,
	)
	defer {clay.SetCurrentContext(previous); delete(memory)}
	clay.SetPointerState({-1, -1}, false)

	render :: proc(ui: ^Ui_State) -> string {
		clay.BeginLayout()
		new_chat_pane(ui)
		commands := clay.EndLayout(0)
		text: [dynamic]u8
		for command in commands.internalArray[:commands.length] {
			if command.commandType != .Text {continue}
			data := command.renderData.text.stringContents
			append(&text, ..data.chars[:data.length])
			append(&text, ' ')
		}
		return string(text[:])
	}

	ui: Ui_State
	valid :: "npub1d6qfwzfzzexwg39v98msg2nv3v7ey8jpwr4dv5fy9hd3pucusmpqasx9s6"
	hex := "6e80970922164ce444ac29f7042a6c8b3d921e4170ead651242ddb10f31c86c2"
	cases := []struct {query, expected: string, invalid: bool} {
		{"npub1d6qfwzfzzexwg39v98msg2nv3v7ey8jpwr4dv5fy9hd3pucusmpqasx9s7", "This key has a typo.", true},
		{"  NPUB1INVALID  ", "This key has a typo.", true},
		{"npub1", "This key has a typo.", true},
		{"Alice", "No matching contacts", false},
		{"  ", "No contacts yet", false},
		{valid, "Start a chat with this public key", false},
		{hex, "Start a chat with this public key", false},
		{"marmot://profile/" + valid, "Start a chat with this public key", false},
	}
	for scenario in cases {
		clear(&ui.nc_search)
		append(&ui.nc_search, scenario.query)
		text := render(&ui)
		testing.expect(t, strings.contains(text, scenario.expected), scenario.query)
		testing.expect_value(t, strings.contains(text, "This key has a typo."), scenario.invalid)
		if scenario.invalid {
			testing.expect(t, strings.contains(text, "Check each character against the original and try again."))
			testing.expect(t, !strings.contains(text, "No matching contacts"))
			testing.expect(t, !strings.contains(text, "Start a chat with this public key"))
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
	testing.expect(t, !strings.contains(text, "Start a chat with this public key"))

	// Contact loading must not hide a local, immediately detectable typo.
	jobs := account_jobs
	account_jobs = nil
	defer account_jobs = jobs
	job := Account_Job{account = hex, kind = .Read_Contacts}
	append(&account_jobs, &job)
	clear(&ui.nc_search)
	append(&ui.nc_search, cases[0].query)
	text = render(&ui)
	testing.expect(t, strings.contains(text, "This key has a typo."))
	testing.expect(t, strings.contains(text, "Check each character against the original and try again."))
}
