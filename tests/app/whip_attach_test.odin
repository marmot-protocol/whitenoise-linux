package main

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
whip_float_dock :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "whip_float_dock" || !rl.WhipAvailable() {return}
	context.allocator = runtime.default_context().allocator
	home, err := os.make_directory_temp("/tmp", "wn-whip-attach-*", context.allocator)
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
	for key, i in keys {previous[i] = os.get_env(key, context.allocator)}
	defer {for key, i in keys {os.set_env(key, previous[i]); delete(previous[i])}}
	for key in keys[:len(keys) - 1] {os.set_env(key, home)}
	os.set_env("SHELL", "/bin/sh")
	defer {
		_, out, errors, err := os.process_exec(
			{command = {#config(WN_WHIP_EXE, ""), "server", "stop", "default"}},
			context.allocator,
		)
		delete(out); delete(errors)
		testing.expect_value(t, err, nil)
	}
	rl.InitWindow(1280, 800, "Whip floating and chat docking")
	defer rl.CloseWindow()
	defer rl.WhipClose()
	assert(sdl.SetWindowPosition(sdl.GetKeyboardFocus(), 0, 0))
	assert(sdl.SyncWindow(sdl.GetKeyboardFocus()))
	UI_ZOOM = 1
	refresh_ui_scale()
	init_fonts()
	clay.SetCurrentContext(nil)
	clay.SetMaxElementCount(32768)
	memory := make([]u8, int(clay.MinMemorySize()))
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)),
		{1280, 800},
		{
			handler = proc "c" (err: clay.ErrorData) {
				context = runtime.default_context()
				testing.expect(
					(^testing.T)(err.userData),
					false,
					string(err.errorText.chars[:err.errorText.length]),
				)
			},
			userData = t,
		},
	)
	clay.SetMeasureTextFunction(measure_text, nil)
	defer delete(memory)
	ui := Ui_State {
		page             = .Chats,
		selected         = -1,
		selected_contact = -1,
		row_menu         = -1,
		member_menu      = -1,
		prefs            = default_prefs(),
		account_ref      = "attach-account",
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	append(&ui.accounts, "Local")
	append(
		&ui.chats,
		Chat_Row_Ui{group_id = "chat-a", title = "Release planning"},
		Chat_Row_Ui{group_id = "chat-b", title = "Code review"},
	)
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; whip_attach_clear(&ui)}
	frame :: proc(ui: ^Ui_State, shot: cstring = nil) {
		free_all(context.temp_allocator)
		rl.WindowShouldClose()
		anim_tick(1.0 / 60)
		commands := build_layout(ui, 0)
		rl.BeginDrawing()
		rl.BeginMode2D({zoom = UI_ZOOM})
		clay_raylib_render(&commands)
		rl.EndMode2D()
		if shot != nil {rl.TakeScreenshot(shot)}
		rl.EndDrawing()
		whip_controls(ui, nil)
		rl.WhipFrame(
			whip_visibility(ui),
			ui.whip_project,
			ui.whip_tabs[ui.whip_project],
			whip_attach_surfaces(ui),
			whip_attach_focused(ui),
		)
		whip_sync_tabs(ui)
		whip_focus_restore(ui)
		whip_workspace_sync(ui)
		whip_workspace_remember(ui)
		rl.SetTextInput(
			text_field_live || whip_attach_focused(ui) != 0 || whip_visibility(ui) == .Visible,
		)
		time.sleep(16 * time.Millisecond)
	}
	has_title :: proc(ui: ^Ui_State, id: clay.ElementId, name: string) -> bool {
		commands := build_layout(ui, 0)
		box := clay.GetElementData(id).boundingBox
		for command in commands.internalArray[:commands.length] {
			if command.commandType != .Text {continue}
			bounds := command.boundingBox
			if bounds.x < box.x ||
			   bounds.y < box.y ||
			   bounds.x + bounds.width > box.x + box.width ||
			   bounds.y + bounds.height > box.y + box.height {continue}
			text := command.renderData.text.stringContents
			if string(text.chars[:text.length]) == name {return true}
		}
		return false
	}
	click :: proc(t: ^testing.T, ui: ^Ui_State, id: clay.ElementId, root: clay.ElementId = {}) {
		data := clay.GetElementData(id)
		if !data.found && root.id != 0 {
			box := clay.GetElementData(root).boundingBox
			clay.SetPointerState({box.x + 32, box.y + 2}, false)
			for _ in 0 ..< 3 {frame(ui)}
			data = clay.GetElementData(id)
		}
		if !testing.expect(
			t,
			data.found && data.boundingBox.width > 0,
			"pane action is visible",
		) {return}
		box := data.boundingBox
		point := clay.Vector2{box.x + box.width / 2, box.y + box.height / 2}
		event := sdl.Event {
			type = .MOUSE_BUTTON_DOWN,
		}
		event.button.windowID = sdl.GetWindowID(sdl.GetKeyboardFocus())
		event.button.button, event.button.down = 1, true
		event.button.x, event.button.y = point.x * UI_ZOOM, point.y * UI_ZOOM
		assert(sdl.PushEvent(&event))
		rl.WindowShouldClose()
		clay.SetPointerState(point, true)
		whip_attach_input(ui)
		event.type, event.button.down = .MOUSE_BUTTON_UP, false
		assert(sdl.PushEvent(&event))
		rl.WindowShouldClose()
		clay.SetPointerState(point, false)
		if !whip_attach_input(ui) && !whip_inbox_input(ui) {whip_pane_input(ui)}
	}
	warp :: proc(point: clay.Vector2) {
		target := rl.Vector2{f32(int(point.x * UI_ZOOM)), f32(int(point.y * UI_ZOOM))}
		x, y: i32
		assert(sdl.GetWindowPosition(sdl.GetKeyboardFocus(), &x, &y))
		assert(sdl.WarpMouseGlobal(f32(x) + target.x, f32(y) + target.y))
		for _ in 0 ..< 100 {
			sdl.PumpEvents()
			if rl.GetMousePosition() == target {return}
			time.sleep(time.Millisecond)
		}
		gx, gy: f32
		_ = sdl.GetGlobalMouseState(&gx, &gy)
		assert(
			rl.GetMousePosition() == target,
			fmt.tprintf(
				"pointer=%v target=%v window=(%d,%d) global=(%g,%g)",
				rl.GetMousePosition(),
				target,
				x,
				y,
				gx,
				gy,
			),
		)
	}
	drag :: proc(ui: ^Ui_State, id: clay.ElementId, delta: clay.Vector2) {
		box := clay.GetElementData(id).boundingBox
		start := clay.Vector2{box.x + box.width / 2, box.y + box.height / 2}
		warp(start)
		event := sdl.Event {
			type = .MOUSE_BUTTON_DOWN,
		}
		event.button.windowID = sdl.GetWindowID(sdl.GetKeyboardFocus())
		event.button.button, event.button.down = 1, true
		event.button.x, event.button.y = start.x * UI_ZOOM, start.y * UI_ZOOM
		assert(sdl.PushEvent(&event))
		rl.WindowShouldClose()
		clay.SetPointerState(start, true)
		whip_attach_input(ui)
		frame(ui)
		warp(start + delta)
		rl.WindowShouldClose()
		clay.SetPointerState(start + delta, true)
		whip_attach_input(ui)
		frame(ui)
		event.type, event.button.down = .MOUSE_BUTTON_UP, false
		event.button.x = (start.x + delta.x) * UI_ZOOM
		event.button.y = (start.y + delta.y) * UI_ZOOM
		assert(sdl.PushEvent(&event))
		rl.WindowShouldClose()
		clay.SetPointerState(start + delta, false)
		whip_attach_input(ui)
	}
	command :: proc(value: string) -> cstring {
		id := sdl.GetWindowID(sdl.GetKeyboardFocus())
		// SDL text events carry at most a short string in this fixture.
		c := strings.clone_to_cstring(value, context.allocator)
		e := sdl.Event {
			type = .TEXT_INPUT,
		}
		e.text.windowID, e.text.text = id, c
		assert(sdl.PushEvent(&e))
		e = {
			type = .KEY_DOWN,
		}
		e.key.windowID, e.key.scancode, e.key.key, e.key.down = id, .RETURN, sdl.K_RETURN, true
		assert(sdl.PushEvent(&e))
		e.type, e.key.down = .KEY_UP, false
		assert(sdl.PushEvent(&e))
		return c
	}
	key :: proc(scan: sdl.Scancode, code: sdl.Keycode, mods: sdl.Keymod) {
		event := sdl.Event {
			type = .KEY_DOWN,
		}
		event.key.windowID = sdl.GetWindowID(sdl.GetKeyboardFocus())
		event.key.scancode, event.key.key, event.key.mod, event.key.down = scan, code, mods, true
		assert(sdl.PushEvent(&event))
		event.type, event.key.down = .KEY_UP, false
		assert(sdl.PushEvent(&event))
	}
	reload_view :: proc(ui: ^Ui_State) {
		rl.WhipClose()
		whip_attach_clear(ui)
		delete(ui.whip_tabs); ui.whip_tabs = nil
		ui.whip_open, ui.whip_project, ui.selected = false, 0, -1
		load_settings(ui, .Preferences)
		restore_workspace(ui, nil)
		if ui.prefs.restore_last_chat {select_by_id(ui, nil, ui.prefs.last_chat)}
		whip_workspace_begin(ui)
	}
	for _ in 0 ..< 120 {frame(&ui); if len(rl.WhipProjects()) > 0 {break}}
	if !testing.expect(t, len(rl.WhipProjects()) > 0, "real Whip server starts") {return}
	whip_open_project(&ui, rl.WhipProjects()[0].id)
	opening: clay.BoundingBox
	feedback := false
	for _ in 0 ..< 8 {
		frame(&ui, "/tmp/wn-whip-opening.png")
		if len(rl.WhipPanes()) == 0 {continue}
		id := rl.WhipPanes()[0].id
		progress := clay.GetElementData(clay.ID("WhipPaneProgress", id))
		if !progress.found ||
		   progress.boundingBox.width <= 0 ||
		   progress.boundingBox.height <= 0 {continue}
		opening = clay.GetElementData(clay.ID("WhipPaneContent", id)).boundingBox
		feedback = true
		break
	}
	testing.expect(t, feedback, "opening a real pane displays loading feedback")
	for _ in 0 ..< 20 {frame(&ui)}
	if !testing.expect(t, len(rl.WhipPanes()) > 0) {return}
	pane := rl.WhipPanes()[0].id
	name := strings.clone(rl.WhipPanes()[0].name)
	defer delete(name)
	ui.focus = .Filter
	click(t, &ui, clay.ID("WhipTab", ui.whip_tabs[ui.whip_project]))
	testing.expect(
		t,
		ui.focus == .Compose,
		"selecting a terminal tab releases sidebar search focus",
	)
	clay.SetPointerState({-1, -1}, false)
	for _ in 0 ..< 3 {frame(&ui)}
	testing.expect(
		t,
		!clay.GetElementData(clay.ID("WhipPaneHead", pane)).found,
		"the entire split titlebar is absent away from the top edge",
	)
	content := clay.GetElementData(clay.ID("WhipPaneContent", pane)).boundingBox
	if feedback {testing.expect_value(t, content, opening)}
	root := clay.GetElementData(clay.ID("WhipPane", pane)).boundingBox
	testing.expect(t, content.y == root.y + 1, "hidden chrome reserves no terminal rows")
	clay.SetPointerState({root.x + 32, root.y + 2}, false)
	for _ in 0 ..< 3 {frame(&ui)}
	testing.expect(
		t,
		has_title(&ui, clay.ID("WhipPaneTitle", pane), name),
		"the top bar reveals its pane name on hover",
	)
	head := clay.GetElementData(clay.ID("WhipPaneHead", pane)).boundingBox
	clay.SetPointerState({head.x + 32, head.y + head.height - 2}, false)
	for _ in 0 ..< 3 {frame(&ui)}
	testing.expect(
		t,
		clay.GetElementData(clay.ID("WhipPaneHead", pane)).found,
		"revealed chrome stays open while its controls are hovered",
	)
	testing.expect_value(
		t,
		clay.GetElementData(clay.ID("WhipPaneContent", pane)).boundingBox,
		content,
	)
	frame(&ui, "/tmp/wn-whip-title-hover.png")
	clay.SetPointerState({content.x + 32, content.y + 32}, false)
	for _ in 0 ..< 3 {frame(&ui)}
	testing.expect(
		t,
		!clay.GetElementData(clay.ID("WhipPaneHead", pane)).found,
		"hovering terminal content hides the whole titlebar",
	)
	frame(&ui, "/tmp/wn-whip-title-hidden.png")
	click(t, &ui, clay.ID("WhipPaneFloat", pane), clay.ID("WhipPane", pane))
	for _ in 0 ..< 5 {frame(&ui)}
	if !testing.expect_value(t, len(ui.whip_attachments), 1) {return}
	clay.SetPointerState({-1, -1}, false)
	for _ in 0 ..< 3 {frame(&ui)}
	testing.expect(
		t,
		has_title(&ui, clay.ID("WhipAttachTitle", pane), name),
		"floating panes retain their names without hover",
	)
	testing.expect(
		t,
		!clay.GetElementData(clay.ID("WhipPaneContent", pane)).found,
		"floating pane is removed from its original slot",
	)
	original_tab := ui.whip_tabs[ui.whip_project]
	page_before := clay.GetElementData(clay.ID("WhipPage")).boundingBox
	click(t, &ui, clay.ID("WhipNewTab"))
	frame(&ui, "/tmp/wn-whip-tab-opening.png")
	testing.expect_value(t, clay.GetElementData(clay.ID("WhipPage")).boundingBox, page_before)
	for _ in 0 ..< 120 {
		frame(&ui)
		status, tab := rl.WhipTabPoll()
		if status == .Ready {ui.whip_tabs[ui.whip_project] = tab; ui.whip_tab_op = .None; break}
		if status == .Failed {testing.expect(t, false, "second native tab opens"); return}
	}
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect(
		t,
		ui.whip_tabs[ui.whip_project] != original_tab,
		"detached shell survives a different native tab selection",
	)
	select_chat(&ui, nil, 0)
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect(
		t,
		clay.GetElementData(clay.ID("WhipFloat", pane)).found,
		"floating terminal follows the first chat",
	)
	before := ui.whip_attachments[0].bounds
	drag(&ui, clay.ID("WhipAttachHead", pane), {-40, 30})
	for _ in 0 ..< 3 {frame(&ui)}
	after := ui.whip_attachments[0].bounds
	testing.expect(
		t,
		after.x < before.x && after.y > before.y,
		"floating terminal header moves the window",
	)
	drag(&ui, clay.ID("WhipAttachResize", pane), {-40, -30})
	for _ in 0 ..< 3 {frame(&ui)}
	resized := ui.whip_attachments[0].bounds
	testing.expect(
		t,
		resized.width < after.width && resized.height < after.height,
		"resize grip changes terminal geometry",
	)
	select_chat(&ui, nil, 1)
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect(
		t,
		clay.GetElementData(clay.ID("WhipFloat", pane)).found,
		"floating terminal follows another chat",
	)
	click(t, &ui, clay.ID("WhipAttachHead", pane))
	for _ in 0 ..< 3 {frame(&ui)}
	input := command(fmt.tprintf("printf live > '%s/floating-input'", home))
	defer delete(input)
	frame(&ui)
	testing.expect(
		t,
		!rl.IsKeyPressed(.ENTER) && rl.GetCharPressed() == 0,
		"terminal keys never reach chat input",
	)
	for _ in 0 ..< 20 {frame(&ui); if os.is_file(fmt.tprintf("%s/floating-input", home)) {break}}
	testing.expect(
		t,
		os.is_file(fmt.tprintf("%s/floating-input", home)),
		"floating pane runs real shell input over another chat",
	)
	frame(&ui, "/tmp/wn-whip-floating.png")
	compose := clay.GetElementData(clay.ID("ComposeBox")).boundingBox
	point := clay.Vector2{compose.x + 12, compose.y + compose.height / 2}
	warp(point)
	event := sdl.Event {
		type = .MOUSE_BUTTON_DOWN,
	}
	event.button.windowID = sdl.GetWindowID(sdl.GetKeyboardFocus())
	event.button.button, event.button.down, event.button.x, event.button.y =
		1, true, point.x, point.y
	assert(sdl.PushEvent(&event))
	click_input := command(fmt.tprintf("printf unsafe > '%s/click-leak'", home))
	defer delete(click_input)
	frame(&ui)
	testing.expect(
		t,
		rl.GetCharPressed() != 0 && rl.IsKeyPressed(.ENTER),
		"clicking the composer releases native keys within the same SDL batch",
	)
	clay.SetPointerState(point, true)
	whip_attach_input(&ui)
	rl.PushMouseButton(.LEFT, false)
	for rl.GetCharPressed() != 0 {}
	for _ in 0 ..< 10 {frame(&ui)}
	testing.expect(
		t,
		!os.is_file(fmt.tprintf("%s/click-leak", home)),
		"click-and-type cannot execute chat text in the floating shell",
	)
	click(t, &ui, clay.ID("WhipAttachDock", pane))
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect_value(t, ui.whip_attachments[0].group_id, "chat-b")
	testing.expect(
		t,
		clay.GetElementData(clay.ID("WhipDockLayout")).found,
		"pane docks beside its chat",
	)
	clay.SetPointerState({-1, -1}, false)
	for _ in 0 ..< 3 {frame(&ui)}
	testing.expect(
		t,
		!clay.GetElementData(clay.ID("WhipAttachHead", pane)).found,
		"docked titlebars disappear without top-edge hover",
	)
	content = clay.GetElementData(clay.ID("WhipAttachContent", pane)).boundingBox
	root = clay.GetElementData(clay.ID("WhipDockPane", pane)).boundingBox
	testing.expect(t, content.y == root.y + 1, "docked terminals use the space vacated by chrome")
	clay.SetPointerState({root.x + 8, root.y + 2}, false)
	for _ in 0 ..< 3 {frame(&ui)}
	testing.expect(
		t,
		has_title(&ui, clay.ID("WhipAttachTitle", pane), name),
		"docked panes reveal their names on top-bar hover",
	)
	testing.expect_value(
		t,
		clay.GetElementData(clay.ID("WhipAttachContent", pane)).boundingBox,
		content,
	)
	clay.SetPointerState({-1, -1}, false)
	for _ in 0 ..< 3 {frame(&ui)}
	frame(&ui, "/tmp/wn-whip-docked.png")
	wide_before := clay.GetElementData(clay.ID("WhipDockPane", pane)).boundingBox
	drag(&ui, clay.ID("WhipDockDivider"), {-80, 0})
	for _ in 0 ..< 3 {frame(&ui)}
	wide_after := clay.GetElementData(clay.ID("WhipDockPane", pane)).boundingBox
	testing.expect(
		t,
		wide_after.width > wide_before.width + 60,
		"the chat divider enlarges the live terminal",
	)
	chosen_width := ui.whip_dock_width
	rl.SetWindowSize(720, 520)
	clay.SetLayoutDimensions({720, 520})
	for _ in 0 ..< 5 {frame(&ui)}
	dock := clay.GetElementData(clay.ID("WhipDockPane", pane)).boundingBox
	chat := clay.GetElementData(clay.ID("WhipDockChat")).boundingBox
	composer := clay.GetElementData(clay.ID("ComposeBox")).boundingBox
	testing.expect(
		t,
		dock.y >= chat.y + chat.height && dock.height > 28,
		"narrow windows dock below the chat with visible terminal content",
	)
	testing.expect(
		t,
		composer.y >= chat.y && composer.y + composer.height <= chat.y + chat.height,
		"docking keeps the chat composer inside its allotted space",
	)
	frame(&ui, "/tmp/wn-whip-docked-narrow.png")
	drag(&ui, clay.ID("WhipDockDivider"), {0, -28})
	for _ in 0 ..< 3 {frame(&ui)}
	narrow_after := clay.GetElementData(clay.ID("WhipDockPane", pane)).boundingBox
	testing.expect(t, narrow_after.height > dock.height + 20, "stacked docking resizes vertically")
	testing.expect_value(t, ui.whip_dock_width, chosen_width)
	rl.SetWindowSize(1280, 800)
	clay.SetLayoutDimensions({1280, 800})
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect_value(
		t,
		clay.GetElementData(clay.ID("WhipDockPane", pane)).boundingBox.width,
		wide_after.width,
	)
	click(t, &ui, clay.ID("WhipAttachHead", pane), clay.ID("WhipDockPane", pane))
	for _ in 0 ..< 3 {frame(&ui)}
	continuity := command("WN_CONTINUITY=kept")
	defer delete(continuity)
	for _ in 0 ..< 5 {frame(&ui)}
	saved_session := ui.whip_attachments[0].session
	testing.expect(
		t,
		saved_session != ([4]u64{}),
		"live panes expose a verified server incarnation",
	)
	save_settings(&ui)
	saved_snapshot, snapshot_err := os.read_entire_file(settings_path(), context.allocator)
	if !testing.expect_value(t, snapshot_err, nil) {return}
	defer delete(saved_snapshot)
	reload_view(&ui)
	for _ in 0 ..< 120 {frame(&ui); if ui.whip_workspace_loaded && len(ui.whip_attachments) == 1 {break}}
	if !testing.expect_value(t, len(ui.whip_attachments), 1) {return}
	testing.expect_value(t, ui.whip_attachments[0].pane, pane)
	testing.expect_value(t, ui.whip_attachments[0].session, saved_session)
	testing.expect_value(t, ui.whip_attachments[0].group_id, "chat-b")
	testing.expect_value(t, ui.whip_dock_width, chosen_width)
	for _ in 0 ..< 5 {frame(&ui)}
	click(t, &ui, clay.ID("WhipAttachHead", pane), clay.ID("WhipDockPane", pane))
	for _ in 0 ..< 3 {frame(&ui)}
	restored_input := command(fmt.tprintf("printf \"$WN_CONTINUITY\" > '%s/restored-shell'", home))
	defer delete(restored_input)
	for _ in 0 ..< 20 {frame(&ui); if os.is_file(fmt.tprintf("%s/restored-shell", home)) {break}}
	restored_bytes, restored_err := os.read_entire_file(
		fmt.tprintf("%s/restored-shell", home),
		context.allocator,
	)
	if testing.expect_value(t, restored_err, nil) {
		testing.expect_value(t, string(restored_bytes), "kept")
		delete(restored_bytes)
	}
	select_chat(&ui, nil, 0)
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect(
		t,
		!clay.GetElementData(clay.ID("WhipAttachContent", pane)).found,
		"docked terminal is hidden on unrelated chats",
	)
	testing.expect_value(t, whip_attach_focused(&ui), u32(0))
	hidden_input := command(fmt.tprintf("printf leaked > '%s/hidden-input'", home))
	defer delete(hidden_input)
	for _ in 0 ..< 10 {frame(&ui)}
	testing.expect(
		t,
		!os.is_file(fmt.tprintf("%s/hidden-input", home)),
		"hidden dock cannot receive keyboard input",
	)
	for rl.GetCharPressed() != 0 {}
	select_chat(&ui, nil, 1)
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect(
		t,
		clay.GetElementData(clay.ID("WhipAttachContent", pane)).found,
		"returning to the same chat restores its dock",
	)
	ui.account_ref = "another-account"
	for _ in 0 ..< 3 {frame(&ui)}
	testing.expect(
		t,
		!clay.GetElementData(clay.ID("WhipAttachContent", pane)).found,
		"docks never cross accounts",
	)
	ui.account_ref = "attach-account"
	for _ in 0 ..< 3 {frame(&ui)}
	click(t, &ui, clay.ID("WhipAttachFloat", pane), clay.ID("WhipDockPane", pane))
	for _ in 0 ..< 3 {frame(&ui)}
	testing.expect_value(t, ui.whip_attachments[0].group_id, "")
	testing.expect(
		t,
		clay.GetElementData(clay.ID("WhipFloat", pane)).found,
		"docked pane can float again",
	)
	click(t, &ui, clay.ID("WhipAttachReturn", pane))
	for _ in 0 ..< 5 {frame(&ui)}
	testing.expect_value(t, len(ui.whip_attachments), 0)
	if !testing.expect(
		t,
		ui.whip_open && ui.whip_tabs[ui.whip_project] == original_tab,
		"Return to project opens the pane's original tab without another navigation step",
	) {return}
	info, alive := rl.WhipPaneInfo(pane)
	testing.expect(
		t,
		alive && info.id == pane && clay.GetElementData(clay.ID("WhipPaneContent", pane)).found,
		"returning restores the same live shell, not a replacement",
	)
	resume_input := command(fmt.tprintf("printf resumed > '%s/resumed-input'", home))
	defer delete(resume_input)
	for _ in 0 ..< 20 {frame(&ui); if os.is_file(fmt.tprintf("%s/resumed-input", home)) {break}}
	testing.expect(
		t,
		os.is_file(fmt.tprintf("%s/resumed-input", home)),
		"returning also restores shell keyboard input",
	)
	resumed_project := ui.whip_project
	activity_folder := whip_workspace_folder(resumed_project)
	save_settings(&ui)
	activity_before_restore := ui.prefs.whip_activity[activity_folder]
	reload_view(&ui)
	for _ in 0 ..< 120 {frame(&ui); if ui.whip_workspace_loaded && ui.whip_open {break}}
	testing.expect(
		t,
		ui.whip_open &&
		ui.whip_project == resumed_project &&
		ui.whip_tabs[resumed_project] == original_tab,
		"launch restoration reopens the selected terminal tab",
	)
	testing.expect_value(t, len(ui.whip_attachments), 0)
	testing.expect_value(t, len(ui.prefs.whip_placements), 0)
	testing.expect_value(t, ui.prefs.whip_activity[activity_folder], activity_before_restore)
	for _ in 0 ..< 5 {frame(&ui)}
	for _ in 0 ..< 7 {
		click(t, &ui, clay.ID("WhipNewTab"))
		created := false
		for _ in 0 ..< 120 {
			frame(&ui)
			status, tab := rl.WhipTabPoll()
			if status == .Ready {
				ui.whip_tabs[ui.whip_project], ui.whip_tab_op = tab, .None
				created = true
				break
			}
			if status == .Failed {break}
		}
		if !testing.expect(t, created, "crowded workspace creates a real terminal tab") {return}
		for _ in 0 ..< 3 {frame(&ui)}
	}
	last_tab := ui.whip_tabs[ui.whip_project]
	key(._1, '1', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 4 {frame(&ui)}
	testing.expect_value(t, ui.whip_tabs[ui.whip_project], original_tab)
	key(.LEFT, sdl.K_LEFT, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
	for _ in 0 ..< 4 {frame(&ui)}
	testing.expect_value(t, ui.whip_tabs[ui.whip_project], last_tab)
	frame(&ui, "/tmp/wn-whip-crowded-tabs.png")
	tabs_wide := clay.GetElementData(clay.ID("WhipTabs")).boundingBox
	last_close := clay.GetElementData(clay.ID("WhipTabClose", last_tab)).boundingBox
	testing.expect(
		t,
		last_close.x + last_close.width <= tabs_wide.x + tabs_wide.width,
		"keyboard selection reveals the active tab in a crowded workspace",
	)
	view := clay.GetScrollContainerData(clay.ID("WhipTabs"))
	before_wheel := view.scrollPosition.x
	point = clay.Vector2{tabs_wide.x + tabs_wide.width / 2, tabs_wide.y + tabs_wide.height / 2}
	warp(point)
	clay.SetPointerState(point, false)
	wheel_event := sdl.Event {
		type = .MOUSE_WHEEL,
	}
	wheel_event.wheel.windowID = sdl.GetWindowID(sdl.GetKeyboardFocus())
	wheel_event.wheel.y = 2
	wheel_event.wheel.mouse_x, wheel_event.wheel.mouse_y = point.x, point.y
	assert(sdl.PushEvent(&wheel_event))
	rl.WindowShouldClose()
	wheel := rl.GetMouseWheelMoveV()
	whip_tab_wheel(&ui, &wheel)
	clay.UpdateScrollContainers(false, transmute(clay.Vector2)wheel, 1.0 / 60)
	for _ in 0 ..< 3 {frame(&ui)}
	testing.expect(
		t,
		view.scrollPosition.x > before_wheel,
		"the ordinary mouse wheel browses overflow tabs",
	)
	key(._1, '1', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 4 {frame(&ui)}
	key(.LEFT, sdl.K_LEFT, sdl.KMOD_CTRL | sdl.KMOD_SHIFT)
	for _ in 0 ..< 4 {frame(&ui)}
	rl.SetWindowSize(720, 520)
	UI_ZOOM = 2
	refresh_ui_scale()
	clay.SetLayoutDimensions({360, 260})
	for _ in 0 ..< 5 {frame(&ui)}
	frame(&ui, "/tmp/wn-whip-workspace-small.png")
	tabs_box := clay.GetElementData(clay.ID("WhipTabs")).boundingBox
	close_box := clay.GetElementData(clay.ID("WhipTabClose", last_tab)).boundingBox
	testing.expect(
		t,
		close_box.x >= tabs_box.x && close_box.x + close_box.width <= tabs_box.x + tabs_box.width,
		"the active tab's close action remains reachable at narrow width and 200% zoom",
	)
	UI_ZOOM = 1
	refresh_ui_scale()
	rl.SetWindowSize(1280, 800)
	clay.SetLayoutDimensions({1280, 800})
	for _ in 0 ..< 5 {frame(&ui)}
	key(._1, '1', sdl.KMOD_CTRL | sdl.KMOD_ALT)
	for _ in 0 ..< 4 {frame(&ui)}
	click(t, &ui, clay.ID("WhipPaneFloat", pane), clay.ID("WhipPane", pane))
	select_chat(&ui, nil, 0)
	for _ in 0 ..< 5 {frame(&ui)}
	click(t, &ui, clay.ID("WhipAttachHead", pane))
	for _ in 0 ..< 3 {frame(&ui)}
	exit_input := command("exit")
	defer delete(exit_input)
	for _ in 0 ..< 60 {frame(&ui); if len(ui.whip_attachments) == 0 {break}}
	testing.expect_value(t, len(ui.whip_attachments), 0)
	testing.expect(
		t,
		rl.WhipState() != .Failed,
		"closing a detached shell does not fail the remaining native session",
	)
	rl.WhipClose()
	stop_status, stop_out, stop_errors, stop_err := os.process_exec(
		{command = {#config(WN_WHIP_EXE, ""), "server", "stop", "default"}},
		context.allocator,
	)
	delete(stop_out); delete(stop_errors)
	if !testing.expect_value(t, stop_err, nil) {return}
	testing.expect(t, stop_status.success, "the isolated old server stops")
	fresh := fmt.tprintf("%s/fresh-session", home)
	if !testing.expect_value(t, os.make_directory(fresh), nil) {return}
	os.set_env("XDG_RUNTIME_DIR", fresh)
	os.set_env("XDG_STATE_HOME", fresh)
	if !testing.expect_value(
		t,
		os.write_entire_file(settings_path(), saved_snapshot),
		nil,
	) {return}
	reload_view(&ui)
	for _ in 0 ..< 120 {frame(&ui); if ui.whip_workspace_loaded && rl.WhipState() == .Ready {break}}
	reused, reused_live := rl.WhipPaneInfo(pane)
	testing.expect(
		t,
		reused_live && reused.id == pane && reused.session != saved_session,
		"a clean server can reuse the numeric pane ID with a different incarnation",
	)
	testing.expect_value(t, len(ui.whip_attachments), 0)
	testing.expect_value(t, len(ui.prefs.whip_placements), 0)
}
