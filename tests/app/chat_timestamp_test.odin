package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import rl "sdlrl"

// Full shell layout and pointer hit testing, without a live account or network.
@(test)
chat_timestamp_hover :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "chat_timestamp_hover" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 700, "Chat timestamp hover")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes(); apply_theme(0, 0); init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer delete(memory)
	ui := Ui_State {
		selected         = -1,
		selected_contact = -1,
		row_menu         = -1,
		member_menu      = -1,
		prefs            = default_prefs(),
	}
	ui.prefs.reduce_motion = true
	append(&ui.accounts, "Offline fixture")
	row := Chat_Row_Ui {
		group_id    = "fixture",
		title       = "Mountain marmots",
		preview     = "See you at the trailhead",
		at          = "12:34",
		activity_at = 1791280800,
	}
	append(&ui.chats, row)
	append(&ui.archived, row)
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; clay.SetPointerState({-100, -100}, false)}

	layout :: proc(ui: ^Ui_State) -> clay.ClayArray(clay.RenderCommand) {
		commands: clay.ClayArray(clay.RenderCommand)
		for _ in 0 ..< 3 {commands = build_layout(ui, 0)}
		return commands
	}
	text_box :: proc(
		commands: clay.ClayArray(clay.RenderCommand),
		wanted: string,
	) -> (
		box: clay.BoundingBox,
		found: bool,
	) {
		for cmd in commands.internalArray[:commands.length] {
			if cmd.commandType != .Text {continue}
			s := cmd.renderData.text.stringContents
			if string(s.chars[:s.length]) == wanted {return cmd.boundingBox, true}
		}
		return
	}
	// The Chats list and the Archive page each render chat_timestamp.
	for page in ([2]Page{.Chats, .Archived}) {
		ui.page = page
		clay.SetPointerState({-100, -100}, false)
		commands := layout(&ui)
		stamp, found := text_box(commands, row.at)
		if !testing.expect(t, found, "visible row timestamp") {continue}
		before := clay.GetElementData(clay.ID("ChatRow", 0)).boundingBox
		expected := format_full(row.activity_at)
		defer delete(expected)
		_, present := text_box(commands, expected)
		testing.expect(t, !present, "no tooltip before hover")
		clay.SetPointerState({stamp.x + stamp.width / 2, stamp.y + stamp.height / 2}, false)
		commands = layout(&ui)
		if dir := os.get_env("WN_CHAT_TIMESTAMP_CAPTURE_DIR", context.temp_allocator); dir != "" {
			rl.BeginDrawing(); draw_frame(&commands)
			rl.TakeScreenshot(fmt.ctprintf("%s/hover-%v.png", dir, page))
			rl.EndDrawing()
		}
		tip, shown := text_box(commands, expected)
		testing.expect(t, shown, "hover shows the exact local date and time")
		if shown {
			testing.expect(
				t,
				tip.x >= 0 && tip.y >= 0 && tip.x + tip.width <= 1024 && tip.y + tip.height <= 700,
				"tooltip remains in the window",
			)
		}
		testing.expect(
			t,
			clay.GetElementData(clay.ID("ChatRow", 0)).boundingBox == before,
			"hover does not resize the row",
		)
		testing.expect(t, ui.selected == -1, "hover does not select")
		testing.expect(t, ui.row_menu == -1, "hover does not open the menu")
		clay.SetPointerState({-100, -100}, false)
		commands = layout(&ui)
		_, shown = text_box(commands, expected)
		testing.expect(t, !shown, "tooltip disappears on leave")
		if page == .Archived {
			ui.archived[0].activity_at = 0
		} else {
			ui.chats[0].activity_at = 0
		}
		commands = layout(&ui)
		stamp, _ = text_box(commands, row.at)
		clay.SetPointerState({stamp.x + stamp.width / 2, stamp.y + stamp.height / 2}, false)
		commands = layout(&ui)
		unknown := format_full(0)
		_, shown = text_box(commands, unknown)
		delete(unknown)
		testing.expect(t, !shown, "unknown activity must not invent an epoch date")
		ui.chats[0].activity_at, ui.archived[0].activity_at = row.activity_at, row.activity_at
	}
}
