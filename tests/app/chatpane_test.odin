package main

// Clay and the UI caches are global. Run this check alone:
// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=chat_title_overflow
import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:testing"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=thread_reply_count_layout
@(test)
thread_reply_count_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "thread_reply_count_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(600, 400, "Thread reply counts")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {600, 400})
	defer delete(memory)
	ui: Ui_State
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	append(&ui.messages, Msg_Ui{id = "parent", sender = "Parent", thread_replies = 1})
	append(
		&ui.messages,
		Msg_Ui{id = "child", sender = "Child", thread_of = "parent", thread_replies = 2},
	)
	defer {g_ui, g_prefs = nil, nil; delete(ui.messages); delete(ui.thread_stack)}
	for root in ([]string{"", "parent", "child", "parent", ""}) {
		clear(&ui.thread_stack)
		if root != "" {append(&ui.thread_stack, root)}
		clay.BeginLayout()
		if clay.UI(clay.ID("ThreadCountTest"))(
		{layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(600)}}},
		) {
			if root != "" {thread_root_plate(&ui)}
			for msg, i in ui.messages {
				if msg.id != root {message_row(u32(i), msg)}
			}
		}
		clay.EndLayout(0)
		for msg, i in ui.messages {
			testing.expect_value(
				t,
				clay.GetElementData(clay.ID("MsgThreadChip", u32(i))).found,
				msg.id != root,
			)
			testing.expect_value(t, msg.thread_replies, i + 1)
		}
	}
}

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
	for locale in ([]string{"en", "it", "de", "ja"}) {
		set_locale(locale)
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
				for id in ([]string{"IssuesBtn", "FilesBtn", "SearchBtn", "BellBtn", "MembersBtn"}) {
					clay.SetPointerState({-100, -100}, false)
					anim_snap_all()
					anim_tick(0.02)
					build_layout(&ui, 0)
					button := clay.GetElementData(clay.ID(id)).boundingBox
					pointer := clay.Vector2 {
						button.x + button.width / 2,
						button.y + button.height / 2,
					}
					first_width: f32
					for frame in 0 ..< 5 {
						clay.SetPointerState(pointer, false)
						anim_tick(0.02)
						build_layout(&ui, 0)
						expanded := clay.GetElementData(clay.ID(id)).boundingBox
						if frame == 0 {first_width = expanded.width}
						testing.expect(t, expanded.width > button.width, id)
						testing.expect(
							t,
							expanded.x <= pointer.x && expanded.x + expanded.width >= pointer.x,
							id,
						)
						testing.expect(t, expanded.x + expanded.width <= width + 0.01, id)
						right := clay.GetElementData(clay.ID("MembersBtn")).boundingBox
						testing.expect(t, right.x + right.width <= width + 0.01, id)
					}
					full := clay.GetElementData(clay.ID(id)).boundingBox.width
					testing.expect(
						t,
						full > first_width,
						"label must animate rather than appear instantly",
					)
					anim_tick(0.02)
					build_layout(&ui, 0)
					testing.expect(
						t,
						clay.GetElementData(clay.ID(id)).boundingBox.width == full,
						"animation must finish in 100 ms",
					)
					clay.SetPointerState({-100, -100}, false)
					for _ in 0 ..< 5 {anim_tick(0.02); build_layout(&ui, 0)}
					testing.expect_value(
						t,
						clay.GetElementData(clay.ID(id)).boundingBox.width,
						button.width,
					)
					ui.prefs.reduce_motion = true
					clay.SetPointerState(pointer, false)
					anim_tick(0.02)
					build_layout(&ui, 0)
					testing.expect_value(
						t,
						clay.GetElementData(clay.ID(id)).boundingBox.width,
						full,
					)
					ui.prefs.reduce_motion = false
				}
				clay.SetPointerState({-100, -100}, false)
			}
		}
	}
	set_locale("en")
}
