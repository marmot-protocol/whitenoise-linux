package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:text/edit"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// SDL and Clay own process globals, so the canonical suite runs this alone.
@(test)
folder_picker_dispatch :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "folder_picker_dispatch" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 700, "Folder picker")
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
		page          = .Chats,
		selected      = 0,
		row_menu      = -1,
		member_menu   = -1,
		audit_scanned = true,
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	append(&ui.accounts, "Offline fixture")
	append(&ui.chats, Chat_Row_Ui{group_id = "offline-chat", title = "Example chat"})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; forced_release = false; text_field_live = false}

	frame :: proc(ui: ^Ui_State) -> clay.ClayArray(clay.RenderCommand) {
		clay.SetPointerState({-100, -100}, false)
		anim_tick(1.0 / 60)
		return build_layout(ui, 0)
	}
	click :: proc(t: ^testing.T, id: clay.ElementId) -> bool {
		data := clay.GetElementData(id)
		if !testing.expect(t, data.found, "dispatch target exists") {return false}
		b := data.boundingBox
		clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
		return testing.expect(t, clay.PointerOver(id), "dispatch target is reachable")
	}
	text_of :: proc(commands: clay.ClayArray(clay.RenderCommand)) -> string {
		text := make([dynamic]u8, context.temp_allocator)
		for command in commands.internalArray[:commands.length] {
			if command.commandType != .Text {continue}
			data := command.renderData.text.stringContents
			append(&text, ..data.chars[:data.length])
			append(&text, ' ')
		}
		return string(text[:])
	}

	// Exercise the real row-menu action, not a direct call to the opener.
	for count in ([]int{0, 1, 5, 6}) {
		clear(&ui.prefs.folders)
		for i in 0 ..< count {append(&ui.prefs.folders, fmt.aprintf("Folder %d", i))}
		ui.folder_open = false
		ui.row_menu, ui.row_menu_x, ui.row_menu_y = 0, 100, 80
		for _ in 0 ..< 3 {frame(&ui)}
		if !click(t, clay.ID("RowFolder")) {return}
		forced_release = true
		handle_row_menu(&ui, nil)
		forced_release = false
		testing.expect(t, ui.folder_open)
		testing.expect_value(t, ui.folder_mode, Folder_Mode.Move)
		testing.expect_value(t, ui.folder_gid, "offline-chat")
		testing.expect_value(t, ui.focus == .Folder, count > 5)
		commands: clay.ClayArray(clay.RenderCommand)
		for _ in 0 ..< 3 {commands = frame(&ui)}
		text := text_of(commands)
		testing.expect_value(t, clay.GetElementData(clay.ID("FolderSearchBox")).found, count > 5)
		testing.expect_value(t, strings.contains(text, "You have no folders yet."), count == 0)
		testing.expect(t, strings.contains(text, "Unfiled"))
		testing.expect(t, clay.GetElementData(clay.ID("FolderNew")).found)
		if count == 0 {
			if path := os.get_env("WN_FOLDER_CAPTURE", context.temp_allocator); path != "" {
				rl.BeginDrawing()
				draw_frame(&commands)
				rl.TakeScreenshot(strings.clone_to_cstring(path, context.temp_allocator))
				rl.EndDrawing()
			}
		}
		// Typing must not activate a hidden filter or the underlying composer.

		text_field_live = false
		rl.PushChar('z')
		handle_folder_modal(&ui, nil)

		testing.expect_value(t, string(ui.folder_search[:]), count > 5 ? "z" : "")
		testing.expect_value(t, len(ui.compose), 0)
		testing.expect_value(t, text_field_live, count > 5)
		for rl.GetCharPressed() != 0 {}
		// A zero-match search still retains its field and Unfiled destination.
		if count > 5 {
			commands = frame(&ui)
			testing.expect(t, clay.GetElementData(clay.ID("FolderSearchBox")).found)
			testing.expect(t, strings.contains(text_of(commands), "No folders match your search."))
			testing.expect(t, clay.GetElementData(clay.ID("FolderDestination", u32(count))).found)
		} else {
			// Stale text must not hide destinations when the list is too short.
			ed_set(&ui, &ui.folder_search, "stale search")
			commands = frame(&ui)
			for i in 0 ..< count {
				testing.expect(t, clay.GetElementData(clay.ID("FolderDestination", u32(i))).found)
			}
		}
		if !click(t, clay.ID("FolderNew")) {return}
		forced_release = true
		handle_folder_modal(&ui, nil)
		forced_release = false
		testing.expect_value(t, ui.folder_mode, Folder_Mode.Create)
		testing.expect_value(t, ui.focus, Focus.Folder)
		for _ in 0 ..< 3 {frame(&ui)}
		testing.expect(t, clay.GetElementData(clay.ID("FolderBox")).found)
		// Cancel must return to the same picker with the appropriate focus.
		if !click(t, clay.ID("FolderCancel")) {return}
		forced_release = true
		handle_folder_modal(&ui, nil)
		forced_release = false
		testing.expect(t, ui.folder_open)
		testing.expect_value(t, ui.folder_mode, Folder_Mode.Move)
		testing.expect_value(t, ui.focus == .Folder, count > 5)
	}
}
