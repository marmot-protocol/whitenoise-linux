package main

import "base:runtime"
import "core:testing"
import "core:text/edit"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// SDL and Clay have process globals; run this in its own test invocation.
@(test)
login_input_required :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "login_input_required" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 700, "Import key validation")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	locale := g_prefs != nil ? g_prefs.locale : "en"
	set_locale("en")
	defer set_locale(locale)
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui := Ui_State {
		selected    = -1,
		row_menu    = -1,
		member_menu = -1,
	}
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	edit.init(&ui.ed, context.allocator, context.allocator)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs = nil, nil
		forced_release = false
		rl.PushKey(.ENTER, false)
		delete(ui.login_error)
		delete(ui.login_input)
	}
	// Rejected input must never dereference the opaque runtime handle.
	client: marmot.Client
	frame :: proc(ui: ^Ui_State) -> clay.ClayArray(clay.RenderCommand) {
		clay.SetPointerState({-100, -100}, false)
		anim_tick(1.0 / 60)
		return build_layout(ui, 0)
	}
	click :: proc(t: ^testing.T, ui: ^Ui_State, client: ^marmot.Client, name: string) {
		data := clay.GetElementData(clay.ID(name))
		if !testing.expect(t, data.found, "button exists") {return}
		b := data.boundingBox
		clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
		if !testing.expect(t, clay.PointerOver(clay.ID(name)), "button is reachable") {return}
		forced_release = true
		handle_login(ui, client)
		forced_release = false
	}
	for _ in 0 ..< 3 {frame(&ui)}
	click(t, &ui, &client, "LoginImportBtn")
	testing.expect_value(t, ui.login_method, Login_Method.Import)
	for _ in 0 ..< 3 {frame(&ui)}
	click(t, &ui, &client, "LoginGo")
	testing.expect_value(t, ui.login_error, "Enter your nsec to continue.")
	testing.expect(t, auth_job == nil)
	commands := frame(&ui)
	visible := false
	for command in commands.internalArray[:commands.length] {
		if command.commandType != .Text {continue}
		text := command.renderData.text.stringContents
		if string(text.chars[:text.length]) == "Enter your nsec to continue." {visible = true}
	}
	testing.expect(t, visible, "required-key feedback is rendered on the next frame")
	// Keyboard submission takes the same path, including repeated attempts.
	delete(ui.login_error); ui.login_error = ""
	rl.PushKey(.ENTER, true)
	handle_login(&ui, &client)
	rl.PushKey(.ENTER, false)
	testing.expect_value(t, ui.login_error, "Enter your nsec to continue.")
	testing.expect(t, auth_job == nil)
	// Accounts uses the same form while another identity is already selected.
	append(&ui.accounts, "Offline fixture")
	defer delete(ui.accounts)
	ui.add_account_open = true
	for language in ([]string{"en", "it", "de", "ja"}) {
		set_locale(language)
		rl.PushKey(.ENTER, true)
		handle_login(&ui, &client)
		rl.PushKey(.ENTER, false)
		testing.expect_value(t, ui.login_error, tr("Enter your nsec to continue."))
		testing.expect(t, auth_job == nil)
	}
	set_locale("en")
	// A nonempty malformed key retains the existing correction, without auth.
	delete(ui.login_error); ui.login_error = ""
	append(&ui.login_input, "not-an-nsec")
	frame(&ui)
	click(t, &ui, &client, "LoginGo")
	testing.expect_value(
		t,
		ui.login_error,
		"That key isn't an nsec. Double-check it and try again.",
	)
	testing.expect(t, auth_job == nil)
	// Empty remote-signer forms must not get nsec-specific feedback.
	for method in ([]Login_Method{.Bunker, .Pair}) {
		clear(&ui.login_input)
		delete(ui.login_error); ui.login_error = ""
		ui.login_method = method
		rl.PushKey(.ENTER, true)
		handle_login(&ui, &client)
		rl.PushKey(.ENTER, false)
		testing.expect_value(t, ui.login_error, "")
		testing.expect(t, auth_job == nil)
	}
}
