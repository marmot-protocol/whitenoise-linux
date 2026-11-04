package main

import marmot "../marmot"
import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"
import "nendo"
import rl "sdlrl"

@(test)
recent_folder_filters :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "recent_folder_filters" {return}
	context.allocator = runtime.default_context().allocator
	home, err := os.make_directory_temp("", "wn-recent-folders-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(home)
	previous_config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", home)
	defer os.set_env("XDG_CONFIG_HOME", previous_config)
	rl.InitWindow(1280, 800, "Recent folder filters")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	memory: []u8
	init_layout(&memory, 32768, {1280, 800})
	defer delete(memory)
	ui := Ui_State {
		page        = .Chats,
		selected    = -1,
		row_menu    = -1,
		member_menu = -1,
		prefs       = default_prefs(),
	}
	ui.prefs.reduce_motion, ui.prefs.recent_chats = true, true
	append(&ui.accounts, Account_Row_Ui{name = "Offline fixture"})
	append(&ui.prefs.folders, "Work", "Empty")
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "old", title = "Project older", activity_at = 100},
		Chat_Row_Ui{group_id = "other", title = "Outside folder", activity_at = 300},
		Chat_Row_Ui{group_id = "new", title = "Project newer", activity_at = 200},
		Chat_Row_Ui {
			group_id = "archived",
			title = "Project archived",
			activity_at = 400,
			archived = true,
		},
	)
	ui.prefs.folder_of = make(map[string]string)
	ui.prefs.folder_of["old"] = "Work"
	ui.prefs.folder_of["archived"] = "Work"
	ui.prefs.folder_rules = make(map[string]Folder_Rules)
	rules := Folder_Rules {
		match = .All,
	}
	append(&rules.rules, Folder_Rule{kind = .Name_Has, value = "project"})
	ui.prefs.folder_rules["Work"] = rules
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; forced_release = false}
	frame :: proc(ui: ^Ui_State) -> []nendo.Render_Command {
		nendo.set_pointer({-100, -100}, .Up)
		anim_tick(1.0 / 60)
		return build_layout(ui, 0)
	}
	click :: proc(t: ^testing.T, ui: ^Ui_State, id: nendo.Id) {
		data := nendo.element(id)
		if !testing.expect(t, data.found) {return}
		b := data.rect
		filters := nendo.element(nendo.id("ChatFilters")).rect
		scroll := nendo.scroll(nendo.id("ChatFilters"))
		if scroll.found {
			if b.x < filters.x {scroll.position.x += filters.x - b.x}
			if b.x + b.width > filters.x + filters.width {
				scroll.position.x -= b.x + b.width - filters.x - filters.width
			}
			frame(ui)
			b = nendo.element(id).rect
		}
		nendo.set_pointer({b.x + b.width / 2, b.y + b.height / 2}, .Up)
		if !testing.expect(t, nendo.pointer_over(id)) {return}
		forced_release = true
		client: marmot.Client // This local filter action never calls the engine.
		handle_pages(ui, &client)
		forced_release = false
	}
	for _ in 0 ..< 3 {frame(&ui)}
	click(t, &ui, nendo.id("FolderPill", 0))
	commands := frame(&ui)
	testing.expect_value(t, ui.chat_folder, "Work")
	testing.expect_value(t, ui.chat_filter, Chat_Filter.Chats)
	if testing.expect_value(t, len(ui.rail_rows), 2) {
		testing.expect_value(t, ui.rail_rows[0].key, "new")
		testing.expect_value(t, ui.rail_rows[1].key, "old")
	}
	testing.expect(t, !nendo.element(nendo.id("FolderHeader", 0)).found)
	if path := os.get_env("WN_FOLDER_CAPTURE", context.temp_allocator); path != "" {
		rl.BeginDrawing()
		draw_frame(commands)
		rl.TakeScreenshot(strings.clone_to_cstring(path, context.temp_allocator))
		rl.EndDrawing()
	}
	append(&ui.sidebar_filter, "older")
	frame(&ui)
	if testing.expect_value(t, len(ui.rail_rows), 1) {
		testing.expect_value(t, ui.rail_rows[0].key, "old")
	}
	clear(&ui.sidebar_filter)
	click(t, &ui, nendo.id("FolderPill", 1))
	commands = frame(&ui)
	testing.expect_value(t, len(ui.rail_rows), 0)
	found_empty := false
	for command in commands {
		if command.kind != .Text {continue}
		text := command.text.text
		if text == "No matching chats" {found_empty = true}
	}
	testing.expect(t, found_empty, "an empty folder does not claim the entire inbox is empty")
	click(t, &ui, nendo.id("AllPill"))
	frame(&ui)
	testing.expect_value(t, ui.chat_folder, "")
	testing.expect_value(t, len(ui.rail_rows), 3)
	click(t, &ui, nendo.id("FolderPill", 0))
	frame(&ui)
	filters := nendo.scroll(nendo.id("ChatFilters"))
	if testing.expect(t, filters.found) {
		filters.position.x = 0
		frame(&ui)
		row := nendo.element(nendo.id("ChatFilters")).rect
		nendo.set_pointer({row.x + row.width / 2, row.y + row.height / 2}, .Up)
		plain := rl.Vector2{0, -3}
		chat_filter_wheel(&ui, &plain)
		testing.expect_value(t, plain, rl.Vector2{0, -3})
		rl.PushKey(.LEFT_SHIFT, true)
		sideways := rl.Vector2{0, -3}
		chat_filter_wheel(&ui, &sideways)
		rl.PushKey(.LEFT_SHIFT, false)
		testing.expect_value(t, sideways, rl.Vector2{-3, 0})
		nendo.update_scroll(.Off, transmute(nendo.Vector2)sideways, 1.0 / 60)
		frame(&ui)
		testing.expect(t, filters.position.x < 0, "Shift+wheel scrolls the filter row")
	}
	data := nendo.element(nendo.id("ChatViewBtn"))
	b := data.rect
	nendo.set_pointer({b.x + b.width / 2, b.y + b.height / 2}, .Up)
	forced_release = true
	handle_folder_navigation(&ui)
	forced_release = false
	frame(&ui)
	testing.expect_value(t, ui.chat_folder, "")
	testing.expect(t, !ui.prefs.recent_chats)
	testing.expect(t, !nendo.element(nendo.id("FolderPill", 0)).found)
	testing.expect(t, nendo.element(nendo.id("FolderHeader", 0)).found)
}
