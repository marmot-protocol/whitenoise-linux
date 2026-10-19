package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import rl "sdlrl"

@(test)
centered_chat_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "centered_chat_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1600, 800, "Centered conversation")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1600, 800})
	defer delete(memory)
	ui := Ui_State {
		row_menu         = -1,
		member_menu      = -1,
		selected_contact = -1,
	}
	ui.prefs.rail_w = RAIL_W_MIN
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Centered conversation"})
	text := strings.repeat(
		"A conversation that fits its reading width. ",
		20,
		context.temp_allocator,
	)
	append(
		&ui.messages,
		Msg_Ui {
			id = strings.clone("message"),
			sender = strings.clone("Alice"),
			body = strings.clone(text),
			blocks = parse_md_text(text),
		},
	)
	defer {message_free(ui.messages[0]); delete(ui.messages); wrap_clear()}
	defer {delete(ui.accounts); delete(ui.chats); delete(ui.compose); delete(ui.rail_rows)}
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	ed_set(&ui, &ui.compose, text)
	for zoom in ([]f32{1, 1.875}) {
		UI_ZOOM = zoom
		refresh_ui_scale()
		for width in ([]i32{1600, 1033, 720, 420}) {
			rl.SetWindowSize(i32(f32(width) * zoom), i32(800 * zoom))
			clay.SetLayoutDimensions({f32(width), 800})
			for mode in 0 ..< 3 {
				ui.prefs.centered_chat = mode != 1
				for _ in 0 ..< 3 {
					build_layout(&ui, 0)
					body := clay.GetElementData(clay.ID("ChatBody")).boundingBox
					column := clay.GetElementData(clay.ID("ChatColumn")).boundingBox
					expected := ui.prefs.centered_chat ? min(body.width, 720) : body.width
					testing.expect(
						t,
						math.abs(column.width - expected) < 0.01,
						"conversation width respects the setting",
					)
					testing.expect(
						t,
						math.abs((column.x - body.x) - (body.width - column.width) / 2) < 0.01,
						"conversation stays centered",
					)
					for id in ([]string{"Timeline", "Composer", "ComposeBox"}) {
						box := clay.GetElementData(clay.ID(id)).boundingBox
						testing.expect(
							t,
							box.x >= column.x &&
							box.x + box.width <= column.x + column.width + 0.01,
							id,
						)
					}
				}
			}
			commands := build_layout(&ui, 0)
			rl.BeginDrawing()
			draw_frame(&commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-centered-%d-%d.png", width, int(zoom * 100)))
			rl.EndDrawing()
		}
	}
}
