package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:strings"
import "core:testing"
import "core:text/edit"
import rl "sdlrl"

// SDL and Clay process globals require this isolated canonical invocation.
@(test)
export_password_dispatch :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "export_password_dispatch" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 700, "Export password")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes(); apply_theme(0, 0)
	locale := g_prefs != nil ? g_prefs.locale : "en"
	set_locale("en")
	defer set_locale(locale)
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui := Ui_State {
		page          = .Settings,
		selected      = -1,
		row_menu      = -1,
		member_menu   = -1,
		audit_scanned = true,
		account_ref   = "offline",
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	append(&ui.accounts, "Offline fixture")
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	append(&ui.account_ids, "offline")
	append(&ui.account_signing, Account_Signing{local = true})
	g_ui, g_prefs = &ui, &ui.prefs
	scanned := custom_emoji_scanned
	custom_emoji_scanned = true
	defer {
		g_ui, g_prefs = nil, nil
		custom_emoji_scanned = scanned
		forced_release = false
		rl.PushKey(.ENTER, false); rl.PushKey(.ESCAPE, false)
		close_export(&ui)
		delete(
			ui.export_pw,
		); delete(ui.account_ids); delete(ui.account_signing); delete(ui.accounts)
	}
	settings_open(&ui, nil, .Keys, 0, level = .Sheet)
	frame :: proc(ui: ^Ui_State) -> clay.ClayArray(clay.RenderCommand) {
		clay.SetPointerState({-100, -100}, false)
		anim_tick(1.0 / 60)
		return build_layout(ui, 0)
	}
	visible :: proc(commands: clay.ClayArray(clay.RenderCommand), needle: string) -> bool {
		for command in commands.internalArray[:commands.length] {
			if command.commandType != .Text {continue}
			text := command.renderData.text.stringContents
			if strings.contains(string(text.chars[:text.length]), needle) {return true}
		}
		return false
	}
	click :: proc(t: ^testing.T, ui: ^Ui_State, id: string) {
		button := clay.GetElementData(clay.ID(id))
		if !testing.expect(t, button.found, id) {return}
		b := button.boundingBox
		clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
		if !testing.expect(t, clay.PointerOver(clay.ID(id)), id) {return}
		forced_release = true
		handle_settings(ui, nil)
		forced_release = false
	}
	error := "Pick a password first."
	for keyboard in ([]bool{false, true}) {
		ui.export_open = true
		ui.focus = .Compose
		for _ in 0 ..< 3 {frame(&ui)}
		testing.expect(t, !visible(frame(&ui), error), "no error before submitting")
		for _ in 0 ..< 2 {
			if keyboard {
				rl.PushKey(.ENTER, true)
				handle_settings(&ui, nil)
				rl.PushKey(.ENTER, false)
			} else {
				click(t, &ui, "ExportGo")
			}
			testing.expect(
				t,
				visible(frame(&ui), error),
				"empty submission visibly explains the correction",
			)
			feedback := clay.GetElementData(clay.ID("ExportPwError"))
			modal := clay.GetElementData(clay.ID("ExportModal"))
			testing.expect(t, feedback.found, "feedback belongs inside the modal")
			if feedback.found && modal.found {
				b, m := feedback.boundingBox, modal.boundingBox
				testing.expect(
					t,
					b.x >= m.x &&
					b.y >= m.y &&
					b.x + b.width <= m.x + m.width &&
					b.y + b.height <= m.y + m.height,
				)
			}
			testing.expect(t, ui.export_open, "keep the password dialog open")
			testing.expect_value(t, ui.focus, Focus.ExportPw)
			testing.expect_value(t, ui.export_result, "")
			testing.expect_value(t, ui.client_status, "")
		}
		// Editing clears feedback without normalizing passphrase bytes or exporting.
		for ch in "  exact passphrase  " {rl.PushChar(ch)}
		edit_text(&ui, &ui.export_pw)
		handle_settings(&ui, nil)
		testing.expect(
			t,
			!visible(frame(&ui), error),
			"a nonempty password clears required feedback",
		)
		testing.expect_value(t, string(ui.export_pw[:]), "  exact passphrase  ")
		testing.expect_value(t, ui.export_result, "")
		// The real C boundary rejects a nil client safely. Reaching that error
		// distinguishes a nonempty submission from the local empty-input guard.
		rl.PushKey(.ENTER, true)
		handle_settings(&ui, nil)
		rl.PushKey(.ENTER, false)
		testing.expect(t, strings.contains(ui.client_status, "client handle was NULL"))
		testing.expect_value(t, ui.client_status_kind, Status_Kind.Error)
		testing.expect_value(t, string(ui.export_pw[:]), "  exact passphrase  ")
		ui.client_status = ""
		bytes := ui.export_pw[:]
		if keyboard {
			rl.PushKey(.ESCAPE, true)
			handle_settings(&ui, nil)
			rl.PushKey(.ESCAPE, false)
		} else {
			click(t, &ui, "ExportCancel")
		}
		testing.expect(t, !ui.export_open)
		testing.expect_value(t, len(ui.export_pw), 0)
		for b in bytes {testing.expect_value(t, b, u8(0))}
		testing.expect_value(t, ui.focus, Focus.Compose)
		ui.export_open = true
		for _ in 0 ..< 3 {frame(&ui)}
		testing.expect(t, !visible(frame(&ui), error), "reopening clears old feedback")
		close_export(&ui)
	}
	// Closing while still invalid must clear the prompt for the next opening.
	for keyboard in ([]bool{false, true}) {
		ui.export_open = true
		for _ in 0 ..< 3 {frame(&ui)}
		click(t, &ui, "ExportGo")
		testing.expect(t, visible(frame(&ui), error))
		if keyboard {
			rl.PushKey(.ESCAPE, true)
			handle_settings(&ui, nil)
			rl.PushKey(.ESCAPE, false)
		} else {
			click(t, &ui, "ExportCancel")
		}
		ui.export_open = true
		for _ in 0 ..< 3 {frame(&ui)}
		testing.expect(t, !visible(frame(&ui), error), "cancel clears outstanding feedback")
		close_export(&ui)
	}
	// Nonlocal account restrictions still win before password validation.
	ui.account_signing[0].local = false
	ui.export_open = true
	rl.PushKey(.ENTER, true)
	handle_settings(&ui, nil)
	rl.PushKey(.ENTER, false)
	testing.expect(t, !ui.export_open)
	testing.expect_value(t, ui.export_result, "")
}
