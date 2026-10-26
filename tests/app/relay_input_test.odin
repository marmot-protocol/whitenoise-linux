package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:strings"
import "core:testing"
import "core:text/edit"
import rl "sdlrl"

// SDL and Clay own process globals, so run this in its own process.
@(test)
relay_input_dispatch :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "relay_input_dispatch" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 900, "Relay input")
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
	init_layout(&memory, 32768, {1024, 900})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui := Ui_State {
		page                    = .Settings,
		settings_section        = .Network,
		settings_level          = .Sheet,
		settings_anchor         = "AddRelayRow",
		settings_scroll_pending = true,
		account_ref             = "offline-relay-fixture",
		selected                = -1,
		selected_contact        = -1,
		row_menu                = -1,
		member_menu             = -1,
		member_nick             = -1,
		audit_scanned           = true,
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	append(&ui.accounts, "Offline fixture")
	append(&ui.account_ids, ui.account_ref)
	append(&ui.account_signing, Account_Signing{local = true})
	append(&ui.profile.nip65, "wss://outbox.example")
	append(&ui.profile.inbox, "wss://inbox.example")
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; forced_release, text_field_live = false, false}
	custom_emoji_scanned = true
	// A busy account stops the real admission gate before it can touch this
	// opaque fixture client. Unique input must reach that gate; duplicates must not.
	previous_jobs := account_jobs
	account_jobs = nil
	busy := Account_Job {
		account = ui.account_ref,
	}
	append(&account_jobs, &busy)
	defer {delete(account_jobs); account_jobs = previous_jobs}
	client := (^marmot.Client)(&busy)
	frame :: proc(ui: ^Ui_State) -> clay.ClayArray(clay.RenderCommand) {
		clay.SetPointerState({-100, -100}, false)
		anim_tick(1.0 / 60)
		banner_tick(ui)
		return build_layout(ui, 0)
	}
	click :: proc(t: ^testing.T, ui: ^Ui_State, client: ^marmot.Client, id: string) -> bool {
		data := clay.GetElementData(clay.ID(id))
		if !testing.expect(t, data.found, id) {return false}
		b := data.boundingBox
		clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
		if !testing.expect(t, clay.PointerOver(clay.ID(id)), id) {return false}
		forced_release = true
		handle_settings(ui, client)
		forced_release = false
		return true
	}
	for inbox in ([]bool{false, true}) {
		field := inbox ? &ui.inbox_input : &ui.relay_input
		button := inbox ? "AddInboxBtn" : "AddRelayBtn"
		focus := inbox ? Focus.Inbox : Focus.Relay
		relay := inbox ? "wss://inbox.example" : "wss://outbox.example"
		ui.settings_anchor = inbox ? "AddInboxRow" : "AddRelayRow"
		ui.settings_scroll_pending = true
		for input in ([]string{relay, strings.concatenate({" \t", relay, "\u3000"}, context.temp_allocator)}) {
			ed_set(&ui, field, input)
			ui.focus = .Compose
			ui.client_status, ui.banner, ui.banner_seen = "", "", ""
			for _ in 0 ..< 3 {frame(&ui)}
			if !click(t, &ui, client, button) {return}
			commands := frame(&ui)
			error := "This relay is already in your list."
			testing.expect_value(t, ui.client_status, error)
			testing.expect_value(t, ui.client_status_kind, Status_Kind.Info)
			testing.expect_value(t, ui.focus, focus)
			testing.expect_value(t, string(field[:]), input)
			testing.expect_value(t, len(account_jobs), 1)
			testing.expect(t, account_jobs[0] == &busy)
			testing.expect_value(t, ui.profile.nip65[0], "wss://outbox.example")
			testing.expect_value(t, ui.profile.inbox[0], "wss://inbox.example")
			visible := false
			for command in commands.internalArray[:commands.length] {
				if command.commandType != .Text {continue}
				text := command.renderData.text.stringContents
				visible ||= string(text.chars[:text.length]) == error
			}
			testing.expect(t, visible, "duplicate feedback is rendered on the next frame")
			// Match the main loop's dismissal, then idle, then reject again.
			ui.banner = ""
			frame(&ui)
			handle_settings(&ui, client)
			frame(&ui)
			testing.expect_value(t, ui.banner, "")
			if !click(t, &ui, client, button) {return}
			frame(&ui)
			testing.expect_value(t, ui.banner, error)
		}
		// Other-list membership and distinct endpoint spellings remain eligible.
		for input in ([]string{inbox ? "wss://outbox.example" : "wss://inbox.example", "wss://new.example", strings.concatenate({relay, "/"}, context.temp_allocator), "WSS://OUTBOX.EXAMPLE"}) {
			ed_set(&ui, field, input)
			ui.client_status, ui.banner, ui.banner_seen = "", "", ""
			frame(&ui)
			if !click(t, &ui, client, button) {return}
			testing.expect_value(
				t,
				ui.client_status,
				"Your previous account action is still running.",
			)
			testing.expect_value(t, len(field), 0)
			testing.expect_value(t, len(account_jobs), 1)
		}
	}
}
