package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:text/edit"

import "nendo"
import rl "sdlrl"

// Run alone because SDL and nendo own process globals.
@(test)
folder_count_dispatch :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "folder_count_dispatch" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 700, "Folder count")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	locale := g_prefs != nil ? g_prefs.locale : "en"
	set_locale("en")
	defer set_locale(locale)
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer {nendo.set_context(previous); delete(memory)}
	home, err := os.make_directory_temp("", "wn-folder-count", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	old_config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", home)
	defer {
		if old_config ==
		   "" {os.unset_env("XDG_CONFIG_HOME")} else {os.set_env("XDG_CONFIG_HOME", old_config)}
	}
	ui := Ui_State {
		page             = .Settings,
		selected         = -1,
		settings_section = .Folders,
		row_menu         = -1,
		member_menu      = -1,
		audit_scanned    = true,
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	append(&ui.accounts, Account_Row_Ui{name = "Offline fixture"})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; forced_release = false; text_field_live = false}

	frame :: proc(ui: ^Ui_State) -> []nendo.Render_Command {
		nendo.set_pointer({-100, -100}, .Up)
		anim_tick(1.0 / 60)
		return build_layout(ui, 0)
	}
	click :: proc(t: ^testing.T, ui: ^Ui_State, id: nendo.Id) -> bool {
		for _ in 0 ..< 3 {frame(ui)}
		data := nendo.element(id)
		if !testing.expect(t, data.found, "dispatch target exists") {return false}
		b := data.rect
		nendo.set_pointer({b.x + b.width / 2, b.y + b.height / 2}, .Up)
		if !testing.expect(t, nendo.pointer_over(id), "dispatch target reachable") {return false}
		forced_release = true
		defer forced_release = false
		if ui.folder_open {handle_folder_modal(ui, nil)} else {handle_folder_board(ui)}
		return true
	}
	text_of :: proc(commands: []nendo.Render_Command) -> string {
		text := make([dynamic]u8, context.temp_allocator)
		for command in commands {
			if command.kind != .Text {continue}
			data := command.text.text
			append(&text, data)
			append(&text, ' ')
		}
		return string(text[:])
	}
	count_text :: proc(commands: []nendo.Render_Command) -> string {
		box := nendo.element(nendo.id("FolderRuleBox0")).rect
		for command in commands {
			if command.kind != .Text {continue}
			b := command.rect
			if b.x < box.x ||
			   b.x >= box.x + box.width ||
			   b.y < box.y ||
			   b.y >= box.y + box.height {continue}
			data := command.text.text
			return data
		}
		return ""
	}
	capture :: proc(ui: ^Ui_State, suffix: string) {
		if prefix := os.get_env("WN_FOLDER_COUNT_CAPTURE", context.temp_allocator); prefix != "" {
			commands := frame(ui)
			rl.BeginDrawing()
			draw_frame(commands)
			rl.TakeScreenshot(
				strings.clone_to_cstring(
					fmt.tprintf("%s-%s.png", prefix, suffix),
					context.temp_allocator,
				),
			)
			rl.EndDrawing()
		}
	}

	if !click(t, &ui, nendo.id("SettingsFolderNew")) {return}
	testing.expect(t, ui.folder_open)
	ed_set(&ui, &ui.folder_input, "Small chats")
	if !click(t, &ui, nendo.id("FolderRuleAdd")) {return}
	if !click(t, &ui, nendo.id("FolderRuleKind", 0)) {return}
	if !click(
		t,
		&ui,
		nendo.id(fmt.tprintf("FolderRulePick%d", int(Folder_Rule_Kind.Fewer_Than))),
	) {return}
	testing.expect_value(t, ui.folder_rules[0].kind, Folder_Rule_Kind.Fewer_Than)
	commands := frame(&ui)
	// The empty count box names what to type instead of suggesting a count.
	testing.expect_value(t, count_text(commands), "Number")
	capture(&ui, "example")

	for value in ([]string{"0", "1", "-1", "1.5", "nope"}) {
		ed_set(&ui, &ui.folder_rules[0].input, "")
		for ch in value {rl.PushChar(ch)}
		handle_folder_modal(&ui, nil)
		testing.expect_value(t, string(ui.folder_rules[0].input[:]), value)
		if !click(t, &ui, nendo.id("FolderSave")) {return}
		if !testing.expect(t, ui.folder_open, "invalid count must keep editor open") {return}
		testing.expect_value(t, len(ui.prefs.folders), 0)
		testing.expect_value(t, ui.focus, Focus.FolderRule)
		commands = frame(&ui)
		error :=
			value == "0" || value == "1" ? "Enter at least 2 people. Counts include you." : "Enter the number of people as a whole number and try again."
		testing.expect(
			t,
			strings.contains(text_of(commands), error),
			"specific validation is visible",
		)
		if value == "0" {capture(&ui, "error")}
	}
	ed_set(&ui, &ui.folder_rules[0].input, "2")
	if !click(t, &ui, nendo.id("FolderSave")) {return}
	testing.expect(t, !ui.folder_open)
	testing.expect_value(t, ui.prefs.folder_rules["Small chats"].rules[0].count, 2)

	// The sibling rule can meaningfully match every chat with more than zero people.
	if !click(t, &ui, nendo.id("SettingsFolderNew")) {return}
	ed_set(&ui, &ui.folder_input, "All chats")
	if !click(t, &ui, nendo.id("FolderRuleAdd")) {return}
	if !click(t, &ui, nendo.id("FolderRuleKind", 0)) {return}
	if !click(
		t,
		&ui,
		nendo.id(fmt.tprintf("FolderRulePick%d", int(Folder_Rule_Kind.More_Than))),
	) {return}
	ed_set(&ui, &ui.folder_rules[0].input, "0")
	if !click(t, &ui, nendo.id("FolderSave")) {return}
	testing.expect(t, !ui.folder_open)
	testing.expect_value(t, ui.prefs.folder_rules["All chats"].rules[0].count, 0)
}
