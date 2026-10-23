package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import rl "sdlrl"
import sdl "vendor:sdl3"

@(test)
whip_embed :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "whip_embed" || !rl.WhipAvailable() {return}
	context.allocator = runtime.default_context().allocator
	home, err := os.make_directory_temp("/tmp", "wn-whip-embed-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer {os.remove_all(home); delete(home)}
	keys := [?]string{"XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "SHELL"}
	previous: [len(keys)]string
	for name, i in keys {previous[i] = os.get_env(name, context.allocator)}
	defer {for name, i in keys {os.set_env(name, previous[i]); delete(previous[i])}}
	os.set_env("XDG_RUNTIME_DIR", home)
	os.set_env("XDG_CONFIG_HOME", fmt.tprintf("%s/config", home))
	os.set_env("XDG_STATE_HOME", fmt.tprintf("%s/state", home))
	os.set_env("SHELL", "/bin/sh")
	os.make_directory_all(fmt.tprintf("%s/config", home))
	os.make_directory_all(fmt.tprintf("%s/state", home))
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
		page             = .Whip,
		selected         = -1,
		selected_contact = -1,
		row_menu         = -1,
		member_menu      = -1,
		prefs            = default_prefs(),
	}
	append(&ui.accounts, "Smoke")
	append(&ui.account_ids, "smoke")
	append(&ui.account_pics, "")
	append(&ui.account_npubs, "")
	ui.account_ref = "smoke"
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	defer rl.WhipClose()
	frame :: proc(ui: ^Ui_State, expected := "") -> bool {
		free_all(context.temp_allocator)
		rl.WindowShouldClose()
		anim_tick(1.0 / 60)
		commands := build_layout(ui, 0)
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
		visible := ui.page == .Whip && !modal_open(ui)
		content := visible && (!single_pane() || ui.whip_detail)
		rl.WhipFrame(
			visible ? (content ? .Visible : .Projects) : .Hidden,
			ui.whip_project,
			ui.whip_tabs[ui.whip_project],
		)
		whip_sync_tabs(ui)
		whip_controls(ui)
		rl.SetTextInput(content)
		time.sleep(16 * time.Millisecond)
		return found
	}
	for _ in 0 ..< 120 {frame(&ui); if len(rl.WhipProjects()) > 0 {break}}
	if !testing.expect(t, len(rl.WhipProjects()) > 0) {return}
	ui.whip_project = rl.WhipProjects()[0].id
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
	text(command)
	key(.RETURN, sdl.K_RETURN, {})
	for _ in 0 ..< 10 {frame(&ui)}
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
	key(.Z, 'z', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect(t, clay.GetElementData(clay.ID("WhipPaneContent", first_pane)).found)
	testing.expect_value(t, rl.WhipTabs()[0].waiting, 0)
	click :: proc(ui: ^Ui_State, id: clay.ElementId) {
		box := clay.GetElementData(id).boundingBox
		assert(box.width > 0)
		clay.SetPointerState({box.x + 2, box.y + box.height / 2}, false)
		forced_release = true
		whip_pane_input(ui)
		forced_release = false
	}
	click(&ui, clay.ID("WhipPaneHead", first_pane))
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect_value(t, focused(), first_pane)
	click(&ui, clay.ID("WhipPaneHead", second_pane))
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
	click(&ui, clay.ID("WhipPaneClose", focused()))
	for _ in 0 ..< 15 {frame(&ui)}
	testing.expect_value(t, len(rl.WhipPanes()), 2)
	key(.X, 'x', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 15 {frame(&ui)}
	testing.expect_value(t, len(rl.WhipPanes()), 1)
	click(&ui, clay.ID("WhipSplitDown", focused()))
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
	testing.expect_value(t, rl.WhipState(), rl.Whip_State.Ready)
	ui.page, ui.whip_detail = .Whip, true
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
	whip_avatar_stop(&ui)
	rl.WhipClose()
}
