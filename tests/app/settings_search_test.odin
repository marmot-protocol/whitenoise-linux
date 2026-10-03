// Typing on a settings page must land in the search box. Focus left on
// the hidden composer used to discard the keystrokes until a click.
package main

import "base:runtime"
import "core:sync"
import "core:testing"
import "core:text/edit"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
settings_search_takes_typing :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 600})
	defer {
		clay.SetCurrentContext(previous)
		delete(memory)
	}

	ui: Ui_State
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer {
		edit.destroy(&ui.ed)
		delete(ui.settings_search)
		for rl.GetCharPressed() != 0 {}
	}

	ui.page = .Settings
	ui.settings_section = .Folders
	ui.focus = .Compose
	text_field_live = false
	for r in "relay" {rl.PushChar(r)}
	settings_search_field(&ui)
	testing.expect_value(t, ui.focus, Focus.SettingsSearch)
	testing.expect_value(t, string(ui.settings_search[:]), "relay")
	testing.expect_value(t, ui.settings_section, Settings_Section.Home)
	testing.expect(t, text_field_live, "the search box must enable platform text input")

	// A field on the page keeps what it already had. The typed rune stays
	// queued for that field instead of the search box.
	clear(&ui.settings_search)
	ui.settings_section = .Network
	ui.focus = .Relay
	text_field_live = false
	rl.PushChar('z')
	settings_search_field(&ui)
	testing.expect_value(t, ui.focus, Focus.Relay)
	testing.expect_value(t, len(ui.settings_search), 0)
	testing.expect(t, !text_field_live)
	testing.expect_value(t, rl.GetCharPressed(), 'z')

	// An open settings modal owns the keyboard. Idle composer focus stays put.
	ui.focus = .Compose
	ui.export_open = true
	text_field_live = false
	rl.PushChar('q')
	settings_search_field(&ui)
	testing.expect_value(t, ui.focus, Focus.Compose)
	testing.expect_value(t, len(ui.settings_search), 0)
	testing.expect(t, !text_field_live)
	testing.expect_value(t, rl.GetCharPressed(), 'q')
}
