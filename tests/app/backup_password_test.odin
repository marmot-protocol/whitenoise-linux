package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:strings"
import "core:testing"
import "core:text/edit"
import rl "sdlrl"

// SDL and Clay use process globals; the canonical suite runs this separately.
@(test)
backup_password_dispatch :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "backup_password_dispatch" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 700, "Backup password")
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
		page          = .Settings,
		selected      = -1,
		row_menu      = -1,
		member_menu   = -1,
		audit_scanned = true,
		cache_scanned = true,
	}
	append(&ui.accounts, "Offline fixture")
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	edit.init(&ui.ed, context.allocator, context.allocator)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; forced_release = false; backup_close(&ui)
		delete(ui.backup_pw)}
	settings_open(&ui, nil, .Storage, 0, level = .Sheet)
	frame :: proc(ui: ^Ui_State) -> clay.ClayArray(clay.RenderCommand) {
		clay.SetPointerState({-100, -100}, false)
		anim_tick(1.0 / 60)
		return build_layout(ui, 0)
	}
	click :: proc(t: ^testing.T, id: clay.ElementId) -> bool {
		data := clay.GetElementData(id)
		if !testing.expect(t, data.found, "button exists") {return false}
		b := data.boundingBox
		clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
		return testing.expect(t, clay.PointerOver(id), "button reachable")
	}
	for mode in ([]Backup_Mode{.Create, .Import}) {
		for keyboard in ([]bool{false, true}) {
			ui.client_status, ui.banner, ui.banner_seen = "", "", ""
			if mode == .Create {
				for _ in 0 ..< 3 {frame(&ui)}
				if !click(t, clay.ID("BackupBtn")) {return}
				forced_release = true
				handle_storage(&ui)
				forced_release = false
			} else {
				ui.backup_mode = .Import
				ui.focus = .BackupPw
				ui.backup_blob = transmute([]u8)strings.clone("fixture")
			}
			testing.expect_value(t, ui.backup_mode, mode)
			for attempt in 0 ..< 2 {
				if attempt == 0 {
					for _ in 0 ..< 3 {frame(&ui)}
					testing.expect(
						t,
						!clay.GetElementData(clay.ID("BackupPwError")).found,
						"opening starts without stale validation",
					)
				}
				if attempt == 1 {
					rl.PushChar('x')
					handle_backup(&ui)
					testing.expect_value(t, string(ui.backup_pw[:]), "x")
					frame(&ui)
					testing.expect(
						t,
						!clay.GetElementData(clay.ID("BackupPwError")).found,
						"typing clears required feedback",
					)
					rl.PushKey(.BACKSPACE, true)
					handle_backup(&ui)
					rl.PushKey(.BACKSPACE, false)
					rl.WindowShouldClose()
				}
				for _ in 0 ..< 3 {frame(&ui)}
				if keyboard {
					rl.PushKey(.ENTER, true)
					handle_backup(&ui)
					rl.PushKey(.ENTER, false)
					rl.WindowShouldClose()
				} else {
					if !click(t, clay.ID("BackupGo")) {return}
					forced_release = true
					handle_backup(&ui)
					forced_release = false
				}
				expected :=
					mode == .Create ? tr("Enter a password to encrypt your backup.") : tr("Enter the backup password.")
				testing.expect_value(t, ui.backup_mode, mode)
				testing.expect_value(t, ui.focus, Focus.BackupPw)
				testing.expect_value(t, len(ui.backup_pw), 0)
				testing.expect(
					t,
					!backup_saving,
					"no save dialog on invalid input",
				)
				testing.expect_value(
					t,
					string(ui.backup_blob),
					mode == .Import ? "fixture" : "",
				)
				commands := frame(&ui)
				visible := false
				for command in commands.internalArray[:commands.length] {
					if command.commandType != .Text {continue}
					data := command.renderData.text.stringContents
					if strings.contains(
						string(data.chars[:data.length]),
						expected,
					) {visible = true}
				}
				testing.expect(t, visible, "feedback renders on next frame")
				error_data := clay.GetElementData(clay.ID("BackupPwError"))
				modal_data := clay.GetElementData(clay.ID("BackupModal"))
				testing.expect(
					t,
					error_data.found,
					"feedback belongs to the modal, above its backdrop",
				)
				if error_data.found && modal_data.found {
					e, m := error_data.boundingBox, modal_data.boundingBox
					testing.expect(
						t,
						e.x >= m.x &&
						e.y >= m.y &&
						e.x + e.width <= m.x + m.width &&
						e.y + e.height <= m.y + m.height,
					)
				}
			}
			// A nonempty but wrong import password still reaches decryption.
			if mode == .Import {
				append(&ui.backup_pw, 'x')
				rl.PushKey(.ENTER, true)
				handle_backup(&ui)
				rl.PushKey(.ENTER, false)
				rl.WindowShouldClose()
				testing.expect_value(
					t,
					ui.client_status,
					tr(
						"Couldn't open the backup. Double-check the password and try again.",
					),
				)
				testing.expect_value(t, ui.backup_mode, Backup_Mode.Import)
			}
			for _ in 0 ..< 3 {frame(&ui)}
			if !click(t, clay.ID("BackupCancel")) {return}
			forced_release = true
			handle_backup(&ui)
			forced_release = false
			testing.expect_value(t, ui.backup_mode, Backup_Mode.None)
			testing.expect_value(t, len(ui.backup_pw), 0)
			testing.expect_value(t, len(ui.backup_blob), 0)
		}
	}
}
