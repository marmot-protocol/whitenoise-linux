package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy odin test app -define:ODIN_TEST_NAMES=composer_layout
@(test)
composer_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "composer_layout" { return }
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1200, 800, "Composer regression")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1200, 800})
	defer delete(memory)
	ui := Ui_State{row_menu = -1, member_menu = -1, selected_contact = -1, focus = .Compose}
	ui.prefs.stt_enabled = true
	ui.prefs.rail_w = RAIL_W_MIN
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Composer"})
	body := "A first paragraph.\n\nA separate paragraph after a blank line.\n\n\nTwo blank lines before this paragraph."
	append(&ui.messages, Msg_Ui{id = strings.clone("message"), sender = strings.clone("Alice"),
		body = strings.clone(body), blocks = parse_md_text(body)})
	defer { message_free(ui.messages[0]); delete(ui.messages); wrap_clear() }
	defer { delete(ui.accounts); delete(ui.chats); delete(ui.compose); delete(ui.rail_rows) }
	g_ui, g_prefs = &ui, &ui.prefs
	defer { g_ui, g_prefs = nil, nil }
	for zoom in ([]f32{1, 1.875}) {
		UI_ZOOM = zoom
		refresh_ui_scale()
		for width in ([]i32{420, 720, 1200}) {
			rl.SetWindowSize(i32(f32(width) * zoom), i32(800 * zoom))
			clay.SetLayoutDimensions({f32(width), 800})
			for text in ([]string{
				"another small PR for yet another failed nightlyh simulator run:\n\nhttps://github.com/marmot-protocol/mdk/pull/1900",
				"Hello",
			}) {
				ed_set(&ui, &ui.compose, text)
				for _ in 0 ..< 8 { build_layout(&ui, 0) }
				commands := build_layout(&ui, 0)
				for i in 1 ..< 3 {
					previous := clay.GetElementData(clay.ID("BodyLine", u32(((i - 1) * 16 + 1) * 8))).boundingBox
					paragraph := clay.GetElementData(clay.ID("BodyLine", u32((i * 16 + 1) * 8))).boundingBox
					testing.expect(t, paragraph.y >= previous.y + previous.height + f32(i) * f32(BODY_FS), "paragraphs retain their blank-line gaps")
				}
				clip := clay.GetElementData(clay.ID("ComposeClip")).boundingBox
				column := clay.GetElementData(clay.ID("ComposeText")).boundingBox
				for _, i in compose_lines(text) {
					row := clay.GetElementData(clay.ID("ComposeLine", u32(i))).boundingBox
					testing.expect(t, row.x >= clip.x && row.x + row.width <= clip.x + clip.width + 1, "wrapped line fits text viewport")
					testing.expect(t, row.height <= 21, "Clay must not wrap a manually wrapped line again")
				}
				for id in ([]string{"AttachBtn", "EmojiBtn", "FxBtn", "PollBtn", "DictateBtn", "MicBtn"}) {
					button := clay.GetElementData(clay.ID(id)).boundingBox
					testing.expect(t, button.y >= column.y + column.height, "controls sit below the draft")
					testing.expect(t, button.x + button.width <= f32(width), "controls fit the pane")
				}
				if len(text) > 10 {
					rl.BeginDrawing()
					draw_frame(&commands)
					rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-composer-%d-%d.png", width, int(zoom * 100)))
					rl.EndDrawing()
				}
			}
		}
	}
}
