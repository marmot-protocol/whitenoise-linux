package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:text/edit"
import "core:time"
import rl "sdlrl"
import sdl "vendor:sdl3"

@(test)
whip_filter_unavailable :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "whip_filter_unavailable" || rl.WhipAvailable() {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1280, 800, "Unavailable Whip filter")
	defer rl.CloseWindow()
	UI_ZOOM = 1
	refresh_ui_scale()
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1280, 800})
	defer delete(memory)
	ui := Ui_State {
		page             = .Chats,
		selected         = -1,
		selected_contact = -1,
		row_menu         = -1,
		member_menu      = -1,
		prefs            = default_prefs(),
	}
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "offline-chat", title = "Ordinary conversation"})
	defer {delete(ui.accounts); delete(ui.chats); delete(ui.rail_rows)}
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	for _ in 0 ..< 3 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
	testing.expect(
		t,
		!clay.GetElementData(clay.ID("WhipPill")).found,
		"unavailable Whip has no filter",
	)
	testing.expect(
		t,
		clay.GetElementData(clay.ID("ChatRow", 0)).found,
		"ordinary chats remain available without Whip",
	)
}

@(test)
whip_embed :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "whip_embed" || !rl.WhipAvailable() {return}
	context.allocator = runtime.default_context().allocator
	home, err := os.make_directory_temp("/tmp", "wn-whip-embed-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer {os.remove_all(home); delete(home)}
	keys := [?]string {
		"XDG_RUNTIME_DIR",
		"XDG_CONFIG_HOME",
		"XDG_STATE_HOME",
		"XDG_DATA_HOME",
		"SHELL",
	}
	previous: [len(keys)]string
	for name, i in keys {previous[i] = os.get_env(name, context.allocator)}
	defer {for name, i in keys {os.set_env(name, previous[i]); delete(previous[i])}}
	os.set_env("XDG_RUNTIME_DIR", home)
	os.set_env("XDG_CONFIG_HOME", fmt.tprintf("%s/config", home))
	os.set_env("XDG_STATE_HOME", fmt.tprintf("%s/state", home))
	os.set_env("XDG_DATA_HOME", fmt.tprintf("%s/data", home))
	os.set_env("SHELL", "/bin/sh")
	os.make_directory_all(fmt.tprintf("%s/config", home))
	os.make_directory_all(fmt.tprintf("%s/state", home))
	os.make_directory_all(fmt.tprintf("%s/data", home))
	defer {
		_, out, errors, err := os.process_exec(
			{command = {#config(WN_WHIP_EXE, ""), "server", "stop", "default"}},
			context.allocator,
		)
		delete(out); delete(errors)
		testing.expect_value(t, err, nil)
	}
	rl.InitWindow(1280, 800, "Whip live tab titles")
	defer rl.CloseWindow()
	UI_ZOOM = 1.5
	refresh_ui_scale()
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1280 / UI_ZOOM, 800 / UI_ZOOM})
	defer delete(memory)
	ui := Ui_State {
		page             = .Chats,
		selected         = -1,
		selected_contact = -1,
		row_menu         = -1,
		member_menu      = -1,
		prefs            = default_prefs(),
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	append(&ui.chats, Chat_Row_Ui{group_id = "offline-chat", title = "Ordinary conversation"})
	append(&ui.accounts, "Smoke")
	append(&ui.account_ids, "smoke")
	append(&ui.account_pics, "")
	append(&ui.account_npubs, "")
	ui.account_ref = "smoke"
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	defer rl.WhipClose()
	defer whip_avatar_stop(&ui)
	frame :: proc(ui: ^Ui_State, expected := "") -> bool {
		free_all(context.temp_allocator)
		rl.WindowShouldClose()
		inbox_shortcuts(ui, nil)
		if !ui.whip_open &&
		   ui.selected >= 0 &&
		   ui.focus == .Compose {edit_text(ui, &ui.compose, true)}
		anim_tick(1.0 / 60)
		clay.UpdateScrollContainers(false, {}, 1.0 / 60)
		commands := build_layout(ui, 0)
		for _ in 0 ..< 2 {
			timeline_scroll_apply(ui)
			data := clay.GetScrollContainerData(clay.ID("Timeline"))
			if !data.found || abs(data.scrollPosition.y - timeline_draw_offset) <= 0.01 {break}
			commands = build_layout(ui, 0)
		}
		found := false
		for command in commands.internalArray[:commands.length] {
			if command.commandType != .Text {continue}
			text := command.renderData.text.stringContents
			if string(text.chars[:text.length]) == expected {found = true}
		}
		rl.BeginDrawing()
		rl.BeginMode2D({zoom = UI_ZOOM})
		clay_raylib_render(&commands)
		rl.EndMode2D()
		rl.EndDrawing()
		whip_controls(ui, nil)
		visibility := whip_visibility(ui)
		rl.WhipFrame(visibility, ui.whip_project, ui.whip_tabs[ui.whip_project])
		whip_activity_sync(ui)
		whip_sync_tabs(ui)
		whip_focus_restore(ui)
		rl.SetTextInput(text_field_live || visibility == .Visible || visibility == .Unfocused)
		time.sleep(16 * time.Millisecond)
		return found
	}
	for _ in 0 ..< 120 {frame(&ui); if len(rl.WhipProjects()) > 0 {break}}
	if !testing.expect(t, len(rl.WhipProjects()) > 0) {return}
	testing.expect(
		t,
		!ui.whip_open,
		"the project observer starts while the normal Chats inbox is displayed",
	)
	project := rl.WhipProjects()[0].id
	project_name := strings.clone(rl.WhipProjects()[0].name)
	project_dir := strings.clone(rl.WhipProjects()[0].dir)
	defer {delete(project_name); delete(project_dir)}
	// Explicit timestamps, not shell startup timing, define the mixed order.
	{
		projects := rl.WhipProjects()
		activity := projects[0].activity_at
		defer {projects[0].activity_at = activity}
		fixture: Ui_State
		append(
			&fixture.chats,
			Chat_Row_Ui{group_id = "newer-chat", title = "Newer", activity_at = 300},
			Chat_Row_Ui{group_id = "older-chat", title = "Older", activity_at = 100},
		)
		defer {
			delete(fixture.chats)
			delete(fixture.prefs.pinned)
			delete(fixture.prefs.whip_activity)
			delete(fixture.sidebar_filter)
		}
		terminal_key := inbox_terminal_key(project_dir)
		activity_folder := whip_avatar_key(project_dir).folder
		expect_order :: proc(t: ^testing.T, fixture: ^Ui_State, project: u32, expected: []string) {
			rows := inbox_rows(fixture, []int{1, 0}, []u32{project})
			if !testing.expect_value(t, len(rows), len(expected)) {return}
			for row, i in rows {testing.expect_value(t, row.key, expected[i])}
		}
		projects[0].activity_at = 200
		fixture.prefs.whip_activity[activity_folder] = 200
		expect_order(t, &fixture, project, {"newer-chat", terminal_key, "older-chat"})
		projects[0].activity_at = 400
		fixture.prefs.whip_activity[activity_folder] = 400
		expect_order(t, &fixture, project, {terminal_key, "newer-chat", "older-chat"})
		projects[0].activity_at = 50
		fixture.prefs.whip_activity[activity_folder] = 50
		expect_order(t, &fixture, project, {"newer-chat", "older-chat", terminal_key})
		fixture.prefs.whip_activity[activity_folder] = 200
		expect_order(t, &fixture, project, {"newer-chat", terminal_key, "older-chat"})
		fixture.prefs.whip_activity[activity_folder] = 50
		fixture.prefs.pinned[terminal_key] = true
		expect_order(t, &fixture, project, {terminal_key, "newer-chat", "older-chat"})
		fixture.prefs.pinned["older-chat"] = true
		expect_order(t, &fixture, project, {"older-chat", terminal_key, "newer-chat"})
		fixture.chat_filter = .Whip
		append(&fixture.sidebar_filter, "no-inbox-match")
		all := inbox_all(&fixture)
		if testing.expect_value(t, len(all), 2 + len(projects)) {
			testing.expect_value(t, all[0].key, "older-chat")
			testing.expect_value(t, all[1].key, terminal_key)
			testing.expect_value(t, all[2].key, "newer-chat")
		}
		for chat, i in fixture.chats {
			testing.expect_value(t, chat.group_id, i == 0 ? "newer-chat" : "older-chat")
			testing.expect_value(t, chat.activity_at, i == 0 ? u64(300) : u64(100))
		}
	}
	for _ in 0 ..< 3 {frame(&ui)}
	list := clay.GetElementData(clay.ID("ChatList"))
	for id in ([]clay.ElementId{clay.ID("ChatRow", 0), clay.ID("WhipProject", project)}) {
		row := clay.GetElementData(id)
		testing.expect(
			t,
			list.found &&
			row.found &&
			row.boundingBox.width > 0 &&
			row.boundingBox.x >= list.boundingBox.x &&
			row.boundingBox.y >= list.boundingBox.y &&
			row.boundingBox.y + row.boundingBox.height <=
				list.boundingBox.y + list.boundingBox.height,
			"ordinary chats and real terminals share the inbox list",
		)
	}
	testing.expect(
		t,
		clay.GetElementData(clay.ID("WhipProjectIcon", project)).found,
		"terminal rows have an explicit terminal marker",
	)
	testing.expect(
		t,
		clay.GetElementData(clay.ID("WhipProjectAvatar", project)).found,
		"terminal rows retain their native project avatar",
	)
	testing.expect(t, len(ui.chats) == 1, "native terminals are not fake engine chats")
	chat_rows, terminal_rows := 0, 0
	for row in ui.rail_rows {if row.kind == .Chat {chat_rows += 1} else {terminal_rows += 1}}
	testing.expect_value(t, chat_rows, 1)
	testing.expect_value(t, terminal_rows, len(rl.WhipProjects()))
	testing.expect(
		t,
		clay.GetElementData(clay.ID("WhipPill")).found,
		"installed Whip has an inbox filter",
	)
	ui.chat_filter = .Whip
	for _ in 0 ..< 3 {frame(&ui)}
	testing.expect(t, clay.GetElementData(clay.ID("WhipProject", project)).found)
	testing.expect(
		t,
		!clay.GetElementData(clay.ID("ChatRow", 0)).found,
		"Is Whip excludes ordinary chats",
	)
	testing.expect_value(t, len(ui.rail_rows), len(rl.WhipProjects()))
	for row in ui.rail_rows {testing.expect_value(t, row.kind, Inbox_Kind.Terminal)}
	ui.chat_filter = .Chats
	for query in ([]string{project_name, project_dir}) {
		ed_set(&ui, &ui.sidebar_filter, query)
		for _ in 0 ..< 3 {frame(&ui)}
		testing.expect(
			t,
			clay.GetElementData(clay.ID("WhipProject", project)).found,
			"project name and folder are searchable",
		)
	}
	ed_set(&ui, &ui.sidebar_filter, "wn-no-matching-project-or-chat-42")
	for _ in 0 ..< 3 {frame(&ui)}
	testing.expect(
		t,
		!clay.GetElementData(clay.ID("WhipProject", project)).found,
		"unmatched terminals are filtered out",
	)
	ed_set(&ui, &ui.sidebar_filter, "")
	for scope in ([]Chat_Filter{.Groups, .Unread}) {
		ui.chat_filter = scope
		for _ in 0 ..< 3 {frame(&ui)}
		testing.expect(
			t,
			!clay.GetElementData(clay.ID("WhipProject", project)).found,
			"groups and unread without attention exclude the terminal",
		)
		for row in ui.rail_rows {testing.expect(t, row.kind != .Terminal, "keyboard cycling follows the visible inbox scope")}
	}
	ui.chat_filter = .Chats
	select_chat(&ui, nil, 0)
	{
		engine_chat := ui.chats[0]
		terminal_key := inbox_terminal_key(project_dir)
		recent := ui.prefs.recent_chats
		ui.prefs.recent_chats = false
		append(&ui.prefs.folders, "Shared", "Terminals")
		ui.prefs.folder_of["offline-chat"] = "Shared"
		ui.prefs.folder_of[terminal_key] = "Shared"
		ui.prefs.pinned[terminal_key] = true
		rules := Folder_Rules {
			match = .All,
		}
		append(&rules.rules, Folder_Rule{kind = .Is_Whip})
		ui.prefs.folder_rules["Terminals"] = rules
		defer {
			delete(rules.rules)
			delete_key(&ui.prefs.folder_rules, "Terminals")
			delete_key(&ui.prefs.folder_of, "offline-chat")
			delete_key(&ui.prefs.folder_of, terminal_key)
			delete_key(&ui.prefs.pinned, terminal_key)
			clear(&ui.prefs.folders)
			ui.prefs.recent_chats = recent
		}
		for _ in 0 ..< 3 {frame(&ui)}
		shared := clay.GetElementData(clay.ID("FolderHeader", 0))
		terminal := clay.GetElementData(clay.ID("WhipProject", project))
		chat := clay.GetElementData(clay.ID("ChatRow", 0))
		testing.expect(
			t,
			shared.found &&
			terminal.found &&
			chat.found &&
			terminal.boundingBox.y >= shared.boundingBox.y + shared.boundingBox.height &&
			chat.boundingBox.y >= terminal.boundingBox.y + terminal.boundingBox.height &&
			!clay.GetElementData(clay.ID("FolderHeader", 1)).found,
			"manual placement mixes pinned terminals with chats and overrides Is Whip",
		)
		delete_key(&ui.prefs.folder_of, terminal_key)
		for _ in 0 ..< 3 {frame(&ui)}
		automatic := clay.GetElementData(clay.ID("FolderHeader", 1))
		terminal = clay.GetElementData(clay.ID("WhipProject", project))
		chat = clay.GetElementData(clay.ID("ChatRow", 0))
		testing.expect(
			t,
			automatic.found &&
			terminal.found &&
			chat.found &&
			automatic.boundingBox.y >= chat.boundingBox.y + chat.boundingBox.height &&
			terminal.boundingBox.y >= automatic.boundingBox.y + automatic.boundingBox.height,
			"Is Whip files real terminal rows, never ordinary chats",
		)
		ui.prefs.folder_of[terminal_key] = ""
		for _ in 0 ..< 3 {frame(&ui)}
		unfiled := clay.GetElementData(clay.ID("FolderHeader", 2))
		terminal = clay.GetElementData(clay.ID("WhipProject", project))
		testing.expect(
			t,
			unfiled.found &&
			terminal.found &&
			terminal.boundingBox.y >= unfiled.boundingBox.y + unfiled.boundingBox.height &&
			!clay.GetElementData(clay.ID("FolderHeader", 1)).found,
			"explicit Unfiled placement overrides Is Whip",
		)
		testing.expect_value(t, len(ui.chats), 1)
		testing.expect(
			t,
			ui.chats[0] == engine_chat,
			"terminal grouping and pins leave engine chat data unchanged",
		)
	}
	for _ in 0 ..< 3 {frame(&ui)}
	ed_set(&ui, &ui.compose, "Unsent ordinary chat draft")
	{
		box := clay.GetElementData(clay.ID("WhipProject", project)).boundingBox
		clay.SetPointerState({box.x + box.width * 0.6, box.y + box.height / 2}, false)
		client: marmot.Client
		rl.PushMouseButton(.RIGHT, true)
		handle_pages(&ui, &client)
		handle_chat(&ui, &client)
		rl.PushMouseButton(.RIGHT, false)
		if !testing.expect(
			t,
			ui.row_menu >= 0 && ui.row_terminal == project,
			"the terminal menu survives both main-loop handlers on the opening press",
		) {return}
		for _ in 0 ..< 3 {frame(&ui)}
		testing.expect(
			t,
			clay.GetElementData(clay.ID("RowPin")).found &&
			clay.GetElementData(clay.ID("RowFolder")).found &&
			!clay.GetElementData(clay.ID("RowInfo")).found,
			"terminal menus expose pin and filing without chat-only operations",
		)
		box = clay.GetElementData(clay.ID("RowPin")).boundingBox
		clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
		forced_release = true
		handle_chat(&ui, &client)
		forced_release = false
		key := inbox_terminal_key(project_dir)
		testing.expect(
			t,
			ui.prefs.pinned[key] && !ui.prefs.pinned["offline-chat"],
			"the menu pins only its terminal target",
		)
		delete_key(&ui.prefs.pinned, key)
	}
	for _ in 0 ..< 3 {frame(&ui)}
	click_project :: proc(t: ^testing.T, ui: ^Ui_State, project: u32) -> bool {
		id := clay.ID("WhipProject", project)
		data := clay.GetElementData(id)
		if !testing.expect(
			t,
			data.found && data.boundingBox.width > 0,
			"terminal click target is visible",
		) {return false}
		box := data.boundingBox
		clay.SetPointerState({box.x + box.width * 0.6, box.y + box.height / 2}, false)
		if !testing.expect(t, clay.PointerOver(id), "terminal row is reachable") {return false}
		forced_release = true
		handle_pages(ui, nil)
		forced_release = false
		return true
	}
	selection_folder := whip_avatar_key(project_dir).folder
	selection_activity := ui.prefs.whip_activity[selection_folder]
	if !click_project(t, &ui, project) {return}
	testing.expect_value(t, ui.page, Page.Chats)
	testing.expect_value(t, ui.whip_project, project)
	testing.expect_value(t, ui.prefs.whip_activity[selection_folder], selection_activity)
	testing.expect(
		t,
		ui.whip_open && ui.selected == -1,
		"the actual terminal row handler selects only the terminal",
	)
	testing.expect_value(t, ui.drafts["offline-chat"], "Unsent ordinary chat draft")
	select_chat(&ui, nil, 0)
	testing.expect(
		t,
		!ui.whip_open && ui.selected == 0,
		"ordinary chat selection leaves the terminal",
	)
	testing.expect(
		t,
		string(ui.compose[:]) == "Unsent ordinary chat draft",
		"returning to a chat restores its draft",
	)
	testing.expect(
		t,
		ui.whip_project == project,
		"closing a terminal retains its stable project ID",
	)
	inbox_cycle(&ui, nil, 1)
	testing.expect(
		t,
		ui.whip_open && ui.whip_project == project && ui.selected == -1,
		"keyboard cycling includes the real terminal row",
	)
	inbox_cycle(&ui, nil, 1)
	testing.expect(
		t,
		!ui.whip_open && ui.selected == 0 && string(ui.compose[:]) == "Unsent ordinary chat draft",
		"keyboard cycling returns to the ordinary chat and its draft",
	)
	ui.new_chat_open, ui.nc_page, ui.focus = true, .Contacts, .NC_Search
	for _ in 0 ..< 3 {frame(&ui)}
	testing.expect(
		t,
		clay.GetElementData(clay.ID("NCTerminal")).found,
		"installed terminals are offered from New chat",
	)
	close_new_chat(&ui)
	for _ in 0 ..< 3 {frame(&ui)}
	if !click_project(t, &ui, project) {return}
	for _ in 0 ..< 20 {frame(&ui)}
	cli :: proc(args: []string) {
		command := make([dynamic]string, context.temp_allocator)
		append(&command, #config(WN_WHIP_EXE, "")); append(&command, ..args)
		result, out, errout, err := os.process_exec({command = command[:]}, context.allocator)
		defer delete(out); defer delete(errout)
		assert(err == nil && result.success)
	}
	pane := fmt.aprintf("%d/1/1", ui.whip_project)
	defer delete(pane)
	// The input may advance activity; its delayed PTY output must not.
	activity_key := whip_avatar_key(project_dir).folder
	cli({"pane", "send", pane, "sleep 2; printf '\\033]2;recency output\\007'", "--enter"})
	for _ in 0 ..< 8 {frame(&ui)}
	activity_before := rl.WhipProjects()[0].activity_at
	persisted_before := ui.prefs.whip_activity[activity_key]
	output_arrived := false
	for _ in 0 ..< 120 {
		if frame(&ui, "1  recency output") {output_arrived = true; break}
	}
	testing.expect(t, output_arrived, "the delayed real PTY output reached the terminal")
	testing.expect_value(t, rl.WhipProjects()[0].activity_at, activity_before)
	testing.expect_value(t, ui.prefs.whip_activity[activity_key], persisted_before)
	cli({"pane", "send", pane, "printf '\\033]2;editor live title\\007'", "--enter"})
	visible := false
	for _ in 0 ..< 20 {visible = frame(&ui, "1  editor live title")}
	testing.expect(t, visible, "OSC title is painted by the WN tab")
	cli(
		{
			"pane",
			"send",
			pane,
			"printf '\\033]2;abcdefghijklmnopqrstuvwxyz0123456789\\007'",
			"--enter",
		},
	)
	for _ in 0 ..< 20 {visible = frame(&ui, "1  abcdefghijklmnopqrstuvw…")}
	testing.expect(t, visible, "standalone shortening survives the next frame's arena reset")
	cli({"pane", "send", pane, "printf '\\033]2;dev@host:~/projects/editor\\007'", "--enter"})
	for _ in 0 ..< 20 {visible = frame(&ui, "1  editor")}
	testing.expect(t, visible, "standalone shell-path shortening is used")
	cli({"tab", "rename", fmt.tprintf("%d", ui.whip_tabs[ui.whip_project]), "Named work"})
	for _ in 0 ..< 20 {visible = frame(&ui, "1  Named work")}
	testing.expect(t, visible, "an explicit tab name takes precedence")
	cli({"tab", "rename", fmt.tprintf("%d", ui.whip_tabs[ui.whip_project]), ""})
	cli(
		{
			"pane",
			"send",
			pane,
			"printf '\\033]2;aaaaaaaaaaaaaaaaaaaaa👩🏽‍💻👩🏽‍💻👩🏽‍💻👩🏽‍💻\\007'",
			"--enter",
		},
	)
	for _ in 0 ..< 20 {visible = frame(&ui, "1  aaaaaaaaaaaaaaaaaaaaa👩🏽‍💻👩🏽‍💻…")}
	testing.expect(t, visible, "title truncation cannot split a joined skin-tone emoji")
	cli(
		{
			"tab",
			"rename",
			fmt.tprintf("%d", ui.whip_tabs[ui.whip_project]),
			"🛠️ Work 👩🏽‍💻 🇩🇪",
		},
	)
	for _ in 0 ..< 20 {visible = frame(&ui, "1  🛠️ Work 👩🏽‍💻 🇩🇪")}
	testing.expect(
		t,
		visible &&
		text_emoji("🛠️") != nil &&
		text_emoji("👩🏽‍💻") != nil &&
		text_emoji("🇩🇪") != nil,
	)
	key :: proc(scan: sdl.Scancode, code: sdl.Keycode, mods: sdl.Keymod) {
		id := sdl.GetWindowID(sdl.GetKeyboardFocus())
		e := sdl.Event {
			type = .KEY_DOWN,
		}
		e.key.windowID, e.key.scancode, e.key.key, e.key.mod, e.key.down =
			id, scan, code, mods, true
		assert(sdl.PushEvent(&e))
		e.type, e.key.down = .KEY_UP, false
		assert(sdl.PushEvent(&e))
	}
	text :: proc(value: cstring) {
		e := sdl.Event {
			type = .TEXT_INPUT,
		}
		e.text.windowID, e.text.text = sdl.GetWindowID(sdl.GetKeyboardFocus()), value
		assert(sdl.PushEvent(&e))
	}
	first_project := ui.whip_project
	first_tab := ui.whip_tabs[first_project]
	first_pane := rl.WhipPanes()[0].id
	key(.V, 'v', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 25 {frame(&ui)}
	if !testing.expect_value(t, len(rl.WhipPanes()), 2) {return}
	second_pane := rl.WhipPanes()[1].id
	focused :: proc() -> u32 {for pane in rl.WhipPanes() {if pane.focused {return pane.id}}
		return 0}
	testing.expect_value(t, focused(), second_pane)
	left := clay.GetElementData(clay.ID("WhipPaneContent", first_pane)).boundingBox
	right := clay.GetElementData(clay.ID("WhipPaneContent", second_pane)).boundingBox
	testing.expect(
		t,
		left.width > 0 && right.width > 0 && right.x >= left.x + left.width,
		"WN positions independent pane surfaces",
	)
	command := strings.clone_to_cstring(
		fmt.tprintf("printf pane-two > '%s/pane-two'", home),
		context.allocator,
	)
	defer delete(command)
	activity_before = rl.WhipProjects()[0].activity_at
	time.sleep(1100 * time.Millisecond)
	text(command)
	key(.RETURN, sdl.K_RETURN, {})
	for _ in 0 ..< 10 {frame(&ui)}
	testing.expect(
		t,
		rl.WhipProjects()[0].activity_at > activity_before,
		"genuine SDL terminal input advances project activity",
	)
	testing.expect_value(t, ui.prefs.whip_activity[activity_key], rl.WhipProjects()[0].activity_at)
	testing.expect(
		t,
		os.is_file(fmt.tprintf("%s/pane-two", home)),
		"focused pane receives terminal input",
	)
	key(.H, 'h', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 8 {frame(&ui)}
	testing.expect_value(t, focused(), first_pane)
	key(.L, 'l', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 8 {frame(&ui)}
	testing.expect_value(t, focused(), second_pane)
	key(.R, 'r', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 3 {frame(&ui)}
	key(.L, 'l', {})
	for _ in 0 ..< 8 {frame(&ui)}
	tree, root, _ := rl.WhipTree()
	testing.expect(t, tree[root].ratio > 0.5, "Whip resize mode changes the native split")
	key(.RETURN, sdl.K_RETURN, {})
	for _ in 0 ..< 3 {frame(&ui)}
	key(.Z, 'z', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect(t, !clay.GetElementData(clay.ID("WhipPaneContent", first_pane)).found)
	cli({"pane", "send", pane, "printf '\\a'", "--enter"})
	for _ in 0 ..< 8 {frame(&ui)}
	testing.expect_value(t, rl.WhipTabs()[0].waiting, 1)
	testing.expect(
		t,
		clay.GetElementData(clay.ID("WhipPaneContent", second_pane)).boundingBox.width >
		right.width,
	)
	ui.whip_open, ui.chat_filter = false, .Unread
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect(
		t,
		clay.GetElementData(clay.ID("WhipProject", first_project)).found,
		"Unread includes a real terminal waiting for attention",
	)
	testing.expect(
		t,
		clay.GetElementData(clay.ID("WhipProjectBadge", first_project)).found,
		"waiting terminals keep their unread badge in the inbox",
	)
	testing.expect_value(t, len(ui.rail_rows), 1)
	if len(ui.rail_rows) > 0 {
		testing.expect_value(t, ui.rail_rows[0].kind, Inbox_Kind.Terminal)
		testing.expect_value(t, ui.rail_rows[0].project, first_project)
	}
	ui.chat_filter = .Groups
	for _ in 0 ..< 3 {frame(&ui)}
	testing.expect(
		t,
		!clay.GetElementData(clay.ID("WhipProject", first_project)).found,
		"attention cannot leak terminals into Groups",
	)
	ui.chat_filter = .Unread
	for _ in 0 ..< 3 {frame(&ui)}
	if !click_project(t, &ui, first_project) {return}
	ui.chat_filter = .Chats
	for _ in 0 ..< 3 {frame(&ui)}
	key(.Z, 'z', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect(t, clay.GetElementData(clay.ID("WhipPaneContent", first_pane)).found)
	testing.expect_value(t, rl.WhipTabs()[0].waiting, 0)
	click :: proc(ui: ^Ui_State, pane: u32, action: string) {
		root := clay.GetElementData(clay.ID("WhipPane", pane)).boundingBox
		clay.SetPointerState({root.x + 32, root.y + 2}, false)
		for _ in 0 ..< 3 {frame(ui)}
		box := clay.GetElementData(clay.ID(action, pane)).boundingBox
		assert(box.width > 0)
		clay.SetPointerState({box.x + 2, box.y + box.height / 2}, false)
		forced_release = true
		whip_pane_input(ui)
		forced_release = false
	}
	ui.focus = .Filter
	for _ in 0 ..< 3 {frame(&ui)}
	for rl.GetCharPressed() != 0 {}
	filter_command := fmt.aprintf("printf leaked > '%s/filter-leaked'", home)
	filter_input := strings.clone_to_cstring(filter_command, context.allocator)
	defer {delete(filter_command); delete(filter_input)}
	text(filter_input)
	key(.RETURN, sdl.K_RETURN, {})
	frame(&ui)
	edit_text(&ui, &ui.sidebar_filter)
	testing.expect_value(t, string(ui.sidebar_filter[:]), filter_command)
	for _ in 0 ..< 8 {frame(&ui)}
	testing.expect(
		t,
		clay.GetElementData(clay.ID("WhipPaneContent", second_pane)).found,
		"the native terminal remains rendered while Filter owns text input",
	)
	testing.expect(
		t,
		!os.is_file(fmt.tprintf("%s/filter-leaked", home)),
		"typing a command and Enter in Filter cannot reach the native terminal",
	)
	ed_set(&ui, &ui.sidebar_filter, "")
	click(&ui, first_pane, "WhipPaneHead")
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect_value(t, focused(), first_pane)
	testing.expect_value(t, ui.focus, Focus.Compose)
	focus_input := strings.clone_to_cstring(
		fmt.tprintf("printf focused > '%s/filter-focus-restored'", home),
		context.allocator,
	)
	defer delete(focus_input)
	text(focus_input)
	key(.RETURN, sdl.K_RETURN, {})
	for _ in 0 ..< 10 {frame(&ui)}
	testing.expect(
		t,
		os.is_file(fmt.tprintf("%s/filter-focus-restored", home)),
		"clicking the native pane restores terminal keyboard input",
	)
	click(&ui, second_pane, "WhipPaneHead")
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect_value(t, focused(), second_pane)
	tree, root, _ = rl.WhipTree()
	rl.WhipPaneRatio(root, 0.4)
	for _ in 0 ..< 8 {frame(&ui)}
	testing.expect(
		t,
		clay.GetElementData(clay.ID("WhipPaneContent", first_pane)).boundingBox.width < left.width,
	)
	key(.F, 'f', sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
	for _ in 0 ..< 4 {frame(&ui)}
	testing.expect_value(t, rl.WhipPanes()[1].mode, "FIND")
	text("pane")
	key(.ESCAPE, sdl.K_ESCAPE, {})
	for _ in 0 ..< 4 {frame(&ui)}
	key(.SLASH, '/', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 4 {frame(&ui)}
	testing.expect_value(t, rl.WhipPanes()[1].mode, "HELP")
	key(.ESCAPE, sdl.K_ESCAPE, {})
	for _ in 0 ..< 5 {frame(&ui)}
	key(.MINUS, '-', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 20 {frame(&ui)}
	testing.expect_value(t, len(rl.WhipPanes()), 3)
	rl.BeginDrawing()
	split_commands := build_layout(&ui, 0)
	rl.BeginMode2D({zoom = UI_ZOOM}); clay_raylib_render(&split_commands); rl.EndMode2D()
	rl.TakeScreenshot("/tmp/wn-whip-panes.png"); rl.EndDrawing()
	click(&ui, focused(), "WhipPaneClose")
	for _ in 0 ..< 15 {frame(&ui)}
	testing.expect_value(t, len(rl.WhipPanes()), 2)
	key(.X, 'x', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 15 {frame(&ui)}
	testing.expect_value(t, len(rl.WhipPanes()), 1)
	click(&ui, focused(), "WhipSplitDown")
	for _ in 0 ..< 20 {frame(&ui)}
	testing.expect_value(t, len(rl.WhipPanes()), 2)
	key(.X, 'x', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 15 {frame(&ui)}
	testing.expect_value(t, len(rl.WhipPanes()), 1)
	collapsed := ui.prefs.rail_collapsed
	key(.B, 'b', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect_value(t, ui.prefs.rail_collapsed, !collapsed)
	key(.B, 'b', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 5 {frame(&ui)}
	key(.T, 't', sdl.KMOD_CTRL)
	for _ in 0 ..< 20 {frame(&ui)}
	second_tab := ui.whip_tabs[first_project]
	testing.expect_value(t, len(rl.WhipTabs()), 2)
	testing.expect(t, second_tab != first_tab, "Ctrl+T selects the new WN tab")
	key(.LEFT, sdl.K_LEFT, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
	for _ in 0 ..< 8 {frame(&ui)}
	testing.expect_value(t, ui.whip_tabs[first_project], first_tab)
	key(.RIGHT, sdl.K_RIGHT, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
	for _ in 0 ..< 8 {frame(&ui)}
	testing.expect_value(t, ui.whip_tabs[first_project], second_tab)
	key(._1, '1', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 8 {frame(&ui)}
	testing.expect_value(t, ui.whip_tabs[first_project], first_tab)
	key(._2, '2', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 8 {frame(&ui)}
	testing.expect_value(t, ui.whip_tabs[first_project], second_tab)
	key(.T, 't', sdl.KMOD_CTRL | sdl.KMOD_ALT | sdl.KMOD_SHIFT)
	for _ in 0 ..< 4 {frame(&ui)}
	key(.U, 'u', sdl.KMOD_CTRL)
	text("Renamed by shortcut")
	key(.RETURN, sdl.K_RETURN, {})
	for _ in 0 ..< 15 {frame(&ui)}
	testing.expect_value(t, rl.WhipTabs()[1].name, "Renamed by shortcut")
	key(.N, 'n', sdl.KMOD_CTRL)
	for _ in 0 ..< 20 {frame(&ui)}
	second_project := ui.whip_project
	testing.expect_value(t, len(rl.WhipProjects()), 2)
	testing.expect(t, second_project != first_project, "Ctrl+N selects the created project")
	{
		projects := rl.WhipProjects()
		original := [2]rl.Whip_Project{projects[0], projects[1]}
		defer {projects[0], projects[1] = original[0], original[1]}
		projects[0].activity_at, projects[1].activity_at = 200, 200
		fixture: Ui_State
		rows := inbox_all(&fixture)
		if testing.expect_value(t, len(rows), 2) {
			first, second := rows[0].project, rows[1].project
			projects[0], projects[1] = projects[1], projects[0]
			rows = inbox_all(&fixture)
			testing.expect_value(t, rows[0].project, first)
			testing.expect_value(t, rows[1].project, second)
		}
	}
	// Both real PTYs keep producing output while the user is idle.
	{
		projects := rl.WhipProjects()
		ids := [2]u32{projects[0].id, projects[1].id}
		folders := [2]string {
			whip_avatar_key(projects[0].dir).folder,
			whip_avatar_key(projects[1].dir).folder,
		}
		activity := [2]u64{projects[0].activity_at, projects[1].activity_at}
		persisted := [2]u64{ui.prefs.whip_activity[folders[0]], ui.prefs.whip_activity[folders[1]]}
		before := inbox_rows(&ui, nil, ids[:])
		order := [2]u32{before[0].project, before[1].project}
		for id in ids {
			cli(
				{
					"pane",
					"send",
					fmt.tprintf("%d/1/1", id),
					fmt.tprintf(
						"sleep 1; i=0; while [ $i -lt 5 ]; do printf 'background output\\n'; i=$((i+1)); sleep 0.1; done; printf done > '%s/recency-%d'",
						home,
						id,
					),
					"--enter",
				},
			)
		}
		complete := false
		for _ in 0 ..< 180 {
			frame(&ui)
			if os.is_file(fmt.tprintf("%s/recency-%d", home, ids[0])) &&
			   os.is_file(fmt.tprintf("%s/recency-%d", home, ids[1])) {complete = true; break}
		}
		testing.expect(t, complete, "both real terminal workloads completed")
		for _ in 0 ..< 10 {frame(&ui)}
		for project, i in rl.WhipProjects() {
			testing.expect_value(t, project.activity_at, activity[i])
			testing.expect_value(t, ui.prefs.whip_activity[folders[i]], persisted[i])
		}
		after := inbox_rows(&ui, nil, ids[:])
		for row, i in after {testing.expect_value(t, row.project, order[i])}
	}
	{
		// Two projects cannot distinguish opposite cyclic orders. Keep four
		// real projects, with folder order deliberately unlike server order.
		append(&ui.chats, Chat_Row_Ui{group_id = "navigation-chat", title = "Second conversation"})
		defer ordered_remove(&ui.chats, len(ui.chats) - 1)
		ui.drafts["navigation-chat"] = strings.clone("first line\nsecond line")
		defer {delete(ui.drafts["navigation-chat"]); delete_key(&ui.drafts, "navigation-chat")}
		held := sdl.Event {
			type = .KEY_DOWN,
		}
		held.key.windowID = sdl.GetWindowID(sdl.GetKeyboardFocus())
		held.key.scancode, held.key.key, held.key.mod, held.key.down =
			.LCTRL, sdl.K_LCTRL, sdl.KMOD_CTRL, true
		assert(sdl.PushEvent(&held))
		held.key.scancode, held.key.key, held.key.mod =
			.LSHIFT, sdl.K_LSHIFT, sdl.KMOD_CTRL | sdl.KMOD_SHIFT
		assert(sdl.PushEvent(&held))
		defer {
			held.type, held.key.down, held.key.mod = .KEY_UP, false, sdl.KMOD_CTRL
			assert(sdl.PushEvent(&held))
			held.key.scancode, held.key.key, held.key.mod = .LCTRL, sdl.K_LCTRL, {}
			assert(sdl.PushEvent(&held))
			frame(&ui)
		}
		dirs := [2]string {
			fmt.aprintf("%s/navigation-third", home),
			fmt.aprintf("%s/navigation-fourth", home),
		}
		defer {for dir in dirs {delete(dir)}}
		extra: [2]u32
		for dir, i in dirs {
			if !testing.expect_value(t, os.make_directory_all(dir), nil) {return}
			if !testing.expect(t, rl.WhipCreate(dir)) {return}
			for _ in 0 ..< 120 {
				frame(&ui)
				status, id := rl.WhipCreatePoll()
				if status == .Ready {extra[i] = id; break}
				if status == .Failed {break}
			}
			if !testing.expect(
				t,
				extra[i] != 0,
				"navigation fixture creates a real project",
			) {return}
		}
		for _ in 0 ..< 5 {frame(&ui)}
		// Type immediately after entering a project whose pane has never drawn.
		// The destination shell, not the previous pane, must receive the command.
		whip_open_project(&ui, extra[0])
		frame(&ui)
		cold_command := strings.clone_to_cstring(
			fmt.tprintf("printf '%%s' \"$PWD\" > '%s/cold-input'", home),
			context.allocator,
		)
		defer delete(cold_command)
		text(cold_command)
		key(.RETURN, sdl.K_RETURN, {})
		for _ in 0 ..< 20 {frame(&ui)}
		cold_input, cold_err := os.read_entire_file(
			fmt.tprintf("%s/cold-input", home),
			context.allocator,
		)
		defer delete(cold_input)
		if !testing.expect(t, cold_err == nil, "first-visit typing reaches the terminal") {return}
		testing.expect_value(t, string(cold_input), dirs[0])
		old_folders, old_recent := ui.prefs.folders, ui.prefs.recent_chats
		ui.prefs.folders = nil
		append(&ui.prefs.folders, "Navigation first", "Navigation middle", "Navigation last")
		keys := [3]string {
			inbox_terminal_key(dirs[0]),
			inbox_terminal_key(project_dir),
			inbox_terminal_key(dirs[1]),
		}
		previous_folders: [3]string
		had_folder: [3]bool
		for item, i in keys {
			previous_folders[i], had_folder[i] = ui.prefs.folder_of[item]
			ui.prefs.folder_of[item] = ui.prefs.folders[i]
		}
		was_collapsed, had_collapse := ui.prefs.collapsed_folders["Navigation middle"]
		defer {
			for item, i in keys {
				if had_folder[i] {ui.prefs.folder_of[item] = previous_folders[i]} else {delete_key(&ui.prefs.folder_of, item)}
			}
			if had_collapse {ui.prefs.collapsed_folders["Navigation middle"] = was_collapsed} else {delete_key(&ui.prefs.collapsed_folders, "Navigation middle")}
			delete(ui.prefs.folders); ui.prefs.folders = old_folders
			ui.prefs.recent_chats = old_recent
		}
		ui.prefs.recent_chats = false
		whip_open_project(&ui, extra[0])
		for _ in 0 ..< 5 {frame(&ui)}
		order: [6]Inbox_Row
		count := 0
		for row in ui.rail_rows {
			if !testing.expect(
				t,
				count < len(order),
				"navigation fixture has four projects and two chats",
			) {return}
			order[count] = row
			count += 1
		}
		if !testing.expect_value(t, count, len(order)) {return}
		testing.expect_value(t, order[0].project, extra[0])
		testing.expect_value(t, order[3].project, extra[1])
		testing.expect_value(t, order[4].kind, Inbox_Kind.Chat)
		testing.expect_value(t, order[5].kind, Inbox_Kind.Chat)
		check_row :: proc(t: ^testing.T, ui: ^Ui_State, row: Inbox_Row) {
			testing.expect_value(t, ui.whip_open, row.kind == .Terminal)
			if row.kind == .Terminal {
				testing.expect_value(t, ui.whip_project, row.project)
				return
			}
			testing.expect_value(t, ui.selected, row.index)
			testing.expect_value(t, ui.ed.selection[0], ui.ed.selection[1])
			if row.index ==
			   1 {testing.expect_value(t, string(ui.compose[:]), "first line\nsecond line")}
		}
		for step in 1 ..= 2 * len(order) {
			key(.DOWN, sdl.K_DOWN, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
			for _ in 0 ..< 4 {frame(&ui)}
			check_row(t, &ui, order[step % len(order)])
		}
		for step in 1 ..= len(order) {
			key(.UP, sdl.K_UP, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
			for _ in 0 ..< 4 {frame(&ui)}
			check_row(t, &ui, order[(len(order) - step) % len(order)])
		}
		for _ in 0 ..< 3 {key(.DOWN, sdl.K_DOWN, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)}
		for _ in 0 ..< 4 {frame(&ui)}
		check_row(t, &ui, order[3])
		for _ in 0 ..< 3 {key(.UP, sdl.K_UP, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)}
		for _ in 0 ..< 4 {frame(&ui)}
		check_row(t, &ui, order[0])
		ui.page = .Settings
		inbox_cycle(&ui, nil, -1)
		for _ in 0 ..< 4 {frame(&ui)}
		check_row(t, &ui, order[5])
		testing.expect_value(t, ui.page, Page.Chats)
		ui.prefs.recent_chats = true
		ed_set(&ui, &ui.sidebar_filter, "navigation-")
		ui.focus = .Compose
		whip_open_project(&ui, extra[0])
		for _ in 0 ..< 4 {frame(&ui)}
		for step in 1 ..= 4 {
			key(.DOWN, sdl.K_DOWN, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
			for _ in 0 ..< 4 {frame(&ui)}
			testing.expect_value(t, ui.whip_project, extra[step % len(extra)])
		}
		whip_open_project(&ui, first_project)
		for _ in 0 ..< 4 {frame(&ui)}
		last_visible := ui.rail_rows[len(ui.rail_rows) - 1].project
		key(.UP, sdl.K_UP, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
		for _ in 0 ..< 4 {frame(&ui)}
		testing.expect_value(t, ui.whip_project, last_visible)
		select_chat(&ui, nil, 0)
		for _ in 0 ..< 4 {frame(&ui)}
		first_visible := ui.rail_rows[0].project
		key(.DOWN, sdl.K_DOWN, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
		for _ in 0 ..< 4 {frame(&ui)}
		testing.expect_value(t, ui.whip_project, first_visible)
		ed_set(&ui, &ui.sidebar_filter, "")
		ui.prefs.recent_chats = false
		ui.prefs.collapsed_folders["Navigation middle"] = true
		whip_open_project(&ui, extra[0])
		for _ in 0 ..< 4 {frame(&ui)}
		key(.DOWN, sdl.K_DOWN, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
		for _ in 0 ..< 4 {frame(&ui)}
		testing.expect_value(t, ui.whip_project, extra[1])
		key(.UP, sdl.K_UP, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
		for _ in 0 ..< 4 {frame(&ui)}
		testing.expect_value(t, ui.whip_project, extra[0])
		key(.UP, sdl.K_UP, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
		for _ in 0 ..< 4 {frame(&ui)}
		check_row(t, &ui, order[5])
		whip_open_project(&ui, extra[1])
		ed_set(&ui, &ui.sidebar_filter, "no-matching-conversation")
		for _ in 0 ..< 3 {frame(&ui)}
		testing.expect_value(t, len(ui.rail_rows), 0)
		selected := ui.whip_project
		key(.DOWN, sdl.K_DOWN, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
		for _ in 0 ..< 4 {frame(&ui)}
		testing.expect_value(t, ui.whip_project, selected)
		testing.expect_value(t, string(ui.sidebar_filter[:]), "no-matching-conversation")
		ed_set(&ui, &ui.sidebar_filter, "")
		ui.prefs.collapsed_folders["Navigation middle"] = false
		whip_open_project(&ui, extra[1])
		for _ in 0 ..< 4 {frame(&ui)}
		// Navigation and typing can arrive together after a busy frame.
		key(.DOWN, sdl.K_DOWN, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
		key(.DOWN, sdl.K_DOWN, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
		held.type, held.key.down, held.key.mod = .KEY_UP, false, sdl.KMOD_CTRL
		assert(sdl.PushEvent(&held))
		held.key.scancode, held.key.key, held.key.mod = .LCTRL, sdl.K_LCTRL, {}
		assert(sdl.PushEvent(&held))
		text(" queued input")
		for _ in 0 ..< 6 {frame(&ui)}
		testing.expect(t, !ui.whip_open && ui.selected == 1)
		testing.expect_value(t, string(ui.compose[:]), "first line\nsecond line queued input")
		ed_set(&ui, &ui.compose, "first line\nsecond line")
		{
			old_messages := ui.messages
			old_account, old_group := ui.messages_account, ui.messages_group
			ui.messages = nil
			ui.messages_account, ui.messages_group = ui.account_ref, ui.chats[1].group_id
			defer {
				reading_clear(&ui)
				for msg in ui.messages {delete(msg.id)}
				delete(ui.messages); ui.messages = old_messages
				ui.messages_account, ui.messages_group = old_account, old_group
			}
			for i in 0 ..< 60 {
				append(
					&ui.messages,
					Msg_Ui {
						id = fmt.aprintf("reading-%d", i),
						sender = "Reader",
						sender_id = "peer",
						body = "Keep this conversation in place while working in a terminal.",
						sort_at = u64(i + 1),
					},
				)
			}
			ui.scroll_pending = true
			for _ in 0 ..< 4 {frame(&ui)}
			data := clay.GetScrollContainerData(clay.ID("Timeline"))
			data.scrollPosition.y = -320
			for _ in 0 ..< 3 {frame(&ui)}
			whip_open_project(&ui, extra[0])
			place := ui.reading_places[fmt.tprintf("%s:%s", ui.account_ref, ui.messages_group)]
			if !testing.expect(
				t,
				place.message != "",
				"a scrolled conversation records its visible message",
			) {return}
			for _ in 0 ..< 4 {frame(&ui)}
			select_chat(&ui, nil, 1)
			for _ in 0 ..< 4 {frame(&ui)}
			view := clay.GetElementData(clay.ID("Timeline"))
			for msg, i in ui.messages {
				if msg.id != place.message {continue}
				row := clay.GetElementData(clay.ID("MsgRow", u32(i)))
				testing.expect(
					t,
					row.found && abs(row.boundingBox.y - view.boundingBox.y - place.offset) < 1,
					"returning from a terminal preserves the visible message and offset",
				)
			}
			whip_open_project(&ui, extra[0])
			for _ in 0 ..< 3 {frame(&ui)}
			gs_jump(&ui, nil, ui.chats[1].group_id, ui.messages[35].id)
			for _ in 0 ..< 3 {frame(&ui)}
			jumped := clay.GetElementData(clay.ID("MsgRow", 35)).boundingBox
			view = clay.GetElementData(clay.ID("Timeline"))
			testing.expect(
				t,
				abs(
					jumped.y +
					jumped.height / 2 -
					view.boundingBox.y -
					view.boundingBox.height / 2,
				) <
				1,
				"an explicit search result overrides the saved reading place",
			)
			data = clay.GetScrollContainerData(clay.ID("Timeline"))
			data.scrollPosition.y = -max(
				data.contentDimensions.height - data.scrollContainerDimensions.height,
				0,
			)
			for _ in 0 ..< 2 {frame(&ui)}
			whip_open_project(&ui, extra[0])
			for _ in 0 ..< 3 {frame(&ui)}
			select_chat(&ui, nil, 1)
			for _ in 0 ..< 3 {frame(&ui)}
			data = clay.GetScrollContainerData(clay.ID("Timeline"))
			testing.expect(
				t,
				abs(
					data.scrollPosition.y +
					max(data.contentDimensions.height - data.scrollContainerDimensions.height, 0),
				) <
				1,
				"bottom-following conversations still open at newest",
			)
			whip_open_project(&ui, extra[0])
		}
		{
			before := len(ui.chats)
			for i in 0 ..< 50 {
				append(
					&ui.chats,
					Chat_Row_Ui {
						group_id = fmt.aprintf("navigation-%d", i),
						title = "Offscreen conversation",
					},
				)
			}
			defer {
				for len(ui.chats) >
				    before {delete(ui.chats[len(ui.chats) - 1].group_id); ordered_remove(&ui.chats, len(ui.chats) - 1)}
			}
			whip_open_project(&ui, extra[0])
			for _ in 0 ..< 4 {frame(&ui)}
			key(.UP, sdl.K_UP, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
			for _ in 0 ..< 2 {frame(&ui)}
			row := clay.GetElementData(clay.ID("ChatRow", u32(ui.selected)))
			view := clay.GetElementData(clay.ID("ChatList"))
			testing.expect(
				t,
				row.found &&
				row.boundingBox.y >= view.boundingBox.y &&
				row.boundingBox.y + row.boundingBox.height <=
					view.boundingBox.y + view.boundingBox.height + 1,
				"keyboard selection is fully visible",
			)
			rl.BeginDrawing(); rl.BeginMode2D({zoom = UI_ZOOM})
			commands := build_layout(&ui, 0); clay_raylib_render(&commands)
			rl.EndMode2D(); rl.TakeScreenshot("/tmp/wn-inbox-navigation.png"); rl.EndDrawing()
			list_scroll := clay.GetScrollContainerData(clay.ID("ChatList"))
			list_scroll.scrollPosition.y = 0
			for _ in 0 ..< 3 {frame(&ui)}
			testing.expect_value(
				t,
				clay.GetScrollContainerData(clay.ID("ChatList")).scrollPosition.y,
				f32(0),
			)
			whip_open_project(&ui, extra[0])
		}
		for id in ([2]u32{extra[1], extra[0]}) {
			whip_open_project(&ui, id)
			for _ in 0 ..< 4 {frame(&ui)}
			key(.D, 'd', sdl.KMOD_CTRL | sdl.KMOD_ALT | sdl.KMOD_SHIFT)
			for _ in 0 ..< 12 {frame(&ui)}
		}
		whip_open_project(&ui, second_project)
		for _ in 0 ..< 4 {frame(&ui)}
	}
	key(.UP, sdl.K_UP, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
	for _ in 0 ..< 8 {frame(&ui)}
	testing.expect_value(t, ui.whip_project, first_project)
	key(.DOWN, sdl.K_DOWN, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
	for _ in 0 ..< 8 {frame(&ui)}
	testing.expect_value(t, ui.whip_project, second_project)
	key(.W, 'w', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 8 {frame(&ui)}
	testing.expect(t, rl.WhipProjects()[1].navigating, "picker focus is visible on the WN row")
	key(.K, 'k', {})
	for _ in 0 ..< 4 {frame(&ui)}
	testing.expect(t, rl.WhipProjects()[0].navigating)
	key(.RETURN, sdl.K_RETURN, {})
	for _ in 0 ..< 8 {frame(&ui)}
	testing.expect_value(t, ui.whip_project, first_project)
	key(.W, 'w', sdl.KMOD_CTRL)
	for _ in 0 ..< 15 {frame(&ui)}
	testing.expect_value(t, len(rl.WhipTabs()), 1)
	testing.expect_value(t, ui.whip_tabs[first_project], first_tab)
	ui.accounts_open = true
	for _ in 0 ..< 2 {frame(&ui)}
	key(.T, 't', sdl.KMOD_CTRL)
	for _ in 0 ..< 8 {frame(&ui)}
	testing.expect_value(t, len(rl.WhipTabs()), 1)
	ui.accounts_open = false
	for _ in 0 ..< 3 {frame(&ui)}
	key(.D, 'd', sdl.KMOD_CTRL | sdl.KMOD_ALT | sdl.KMOD_SHIFT)
	for _ in 0 ..< 15 {frame(&ui)}
	testing.expect_value(t, len(rl.WhipProjects()), 1)
	testing.expect_value(t, ui.whip_project, second_project)
	key(.Q, 'q', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect_value(t, ui.page, Page.Chats)
	testing.expect(t, !ui.whip_open, "detach returns to the Chats inbox")
	testing.expect_value(t, rl.WhipState(), rl.Whip_State.Ready)
	whip_open_project(&ui, ui.whip_project)
	for _ in 0 ..< 5 {frame(&ui)}
	cli(
		{
			"tab",
			"rename",
			fmt.tprintf("%d", ui.whip_tabs[ui.whip_project]),
			"🛠️ Work 👩🏽‍💻 🇩🇪",
		},
	)
	for _ in 0 ..< 8 {frame(&ui)}
	rl.BeginDrawing()
	commands := build_layout(&ui, 0)
	rl.BeginMode2D({zoom = UI_ZOOM}); clay_raylib_render(&commands); rl.EndMode2D()
	rl.TakeScreenshot("/tmp/wn-whip-titles.png"); rl.EndDrawing()
}
