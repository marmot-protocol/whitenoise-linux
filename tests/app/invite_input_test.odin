package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:strings"
import "core:testing"
import "core:text/edit"
import rl "sdlrl"

// SDL and Clay own process globals. The canonical suite runs this alone.
@(test)
invite_input_dispatch :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "invite_input_dispatch" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 700, "Invite input")
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
		show_members     = true,
		info_tab         = .Members,
		row_menu         = -1,
		member_menu      = -1,
		member_nick      = -1,
		selected_contact = -1,
		audit_scanned    = true,
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	append(&ui.accounts, "Offline fixture")
	append(&ui.chats, Chat_Row_Ui{group_id = "offline-group", title = "Example group"})
	append(&ui.members, Member_Ui{is_self = true, is_admin = true, name = "You"})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs = nil, nil
		forced_release, text_field_live = false, false
		rl.PushKey(.ENTER, false)
	}
	frame :: proc(ui: ^Ui_State) -> clay.ClayArray(clay.RenderCommand) {
		clay.SetPointerState({-100, -100}, false)
		anim_tick(1.0 / 60)
		banner_tick(ui)
		return build_layout(ui, 0)
	}
	click :: proc(t: ^testing.T, id: string) -> bool {
		data := clay.GetElementData(clay.ID(id))
		if !testing.expect(t, data.found, id) {return false}
		b := data.boundingBox
		clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
		return testing.expect(t, clay.PointerOver(clay.ID(id)), id)
	}
	error := "Couldn't invite the member. Enter an npub or nprofile and try again."
	for input in ([]string{"", " \t\n", "\u3000"}) {
		for keyboard in ([]bool{false, true}) {
			ed_set(&ui, &ui.invite_input, input)
			ui.focus = keyboard ? .Invite : .Rename
			ui.client_status, ui.banner, ui.banner_seen = "", "", ""
			for _ in 0 ..< 3 {frame(&ui)}
			if keyboard {
				rl.PushKey(.ENTER, true)
			} else {
				if !click(t, "InviteBtn") {return}
				forced_release = true
			}
			handle_members(&ui, nil)
			forced_release = false
			rl.PushKey(.ENTER, false)
			commands := frame(&ui)
			testing.expect_value(t, ui.client_status, error)
			testing.expect_value(t, ui.client_status_kind, Status_Kind.Error)
			testing.expect_value(t, ui.focus, Focus.Invite)
			testing.expect_value(t, ui.nip05_ticket, 0)
			testing.expect_value(t, string(ui.invite_input[:]), input)
			testing.expect(t, ui.show_members)
			visible := false
			for command in commands.internalArray[:commands.length] {
				if command.commandType != .Text {continue}
				text := command.renderData.text.stringContents
				visible ||= strings.contains(string(text.chars[:text.length]), error)
			}
			testing.expect(t, visible, "required-input feedback is rendered")
			if ui.banner == "" {continue}
			if !click(t, "BannerClose") {return}
			forced_release = true
			// Match the main loop's BannerClose dispatch.
			if clicked("BannerClose") {ui.banner = ""}
			forced_release = false
			frame(&ui)
			testing.expect_value(t, ui.banner, "")
			handle_members(&ui, nil)
			frame(&ui)
			testing.expect_value(t, ui.banner, "")
			// The same rejected action rearms a dismissed banner.
			rl.PushKey(.ENTER, true)
			handle_members(&ui, nil)
			rl.PushKey(.ENTER, false)
			frame(&ui)
			testing.expect_value(t, ui.banner, error)
		}
	}
	// Permissions and unrelated Enter presses still leave the action alone.
	for allowed in ([]bool{false, true}) {
		ui.members[0].is_admin = allowed
		ui.focus = allowed ? .Compose : .Invite
		ui.client_status, ui.banner, ui.banner_seen = "", "", ""
		rl.PushKey(.ENTER, true)
		handle_members(&ui, nil)
		rl.PushKey(.ENTER, false)
		testing.expect_value(t, ui.client_status, "")
	}
}
