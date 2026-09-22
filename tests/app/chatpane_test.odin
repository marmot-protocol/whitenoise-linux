package main

// Clay and the UI caches are global. Run this check alone:
// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=chat_title_overflow
import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:testing"
import rl "sdlrl"

@(test)
chat_title_overflow :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "chat_title_overflow" {return}
	rl.InitWindow(987, 1382, "Layout regression")
	defer rl.CloseWindow()
	UI_ZOOM = 1.875
	UI_SCALE = UI_ZOOM
	init_fonts()
	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	previous := clay.GetCurrentContext()
	defer clay.SetCurrentContext(previous)
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)),
		{400, 700},
		{},
	)
	clay.SetMeasureTextFunction(measure_text, nil)

	ui := Ui_State {
		row_menu         = -1,
		member_menu      = -1,
		selected_contact = -1,
	}
	g_ui = &ui
	g_prefs = &ui.prefs
	append(&ui.accounts, "Test")
	defer delete(ui.accounts)
	ui.prefs.rail_w = RAIL_W_MIN
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "01e88b174112addb56b562777c32c5f"})
	defer delete(ui.chats)
	append(
		&ui.messages,
		Msg_Ui {
			sender = "Alice",
			body = "This is a longer message with several words to exercise wrapping in a narrow window.",
		},
	)
	append(
		&ui.messages,
		Msg_Ui {
			sender = "Another participant",
			body = "A short reply",
			reply_from = "Alice",
			reply_text = ui.messages[0].body,
		},
	)
	append(&ui.messages, Msg_Ui{system = true, body = "Disappearing timer changed", at = "12:00"})
	defer delete(ui.messages)
	for search in ([]bool{false, true}) {
		ui.search_open = search
		ui.issue_setting = .Enabled
		for width in ([]f32{526.4, 340, 400, 700}) {
			rl.SetWindowSize(i32(width * UI_ZOOM), 1382)
			clay.SetLayoutDimensions({width, 700})
			commands := build_layout(&ui, 0)
			for id in ([]string{"ChatPane", "ChatHeader", "SearchBtn", "FilesBtn", "BellBtn", "MembersBtn", "Composer"}) {
				element := clay.GetElementData(clay.ID(id))
				testing.expect(t, element.found, id)
				testing.expect(
					t,
					element.boundingBox.x + element.boundingBox.width <= width + 0.01,
					id,
				)
			}
			view := clay.GetElementData(clay.ID("ChatHeadTitleClip")).boundingBox
			clipped := false
			for command in commands.internalArray[:commands.length] {
				if command.commandType == .ScissorStart && command.boundingBox == view {
					clipped = true
				}
			}
			testing.expect(t, clipped, "title must be clipped inside the header")
		}
	}
}
