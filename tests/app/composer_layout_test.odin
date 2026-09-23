package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=composer_layout
@(test)
composer_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "composer_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1200, 800, "Composer regression")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1200, 800})
	defer delete(memory)
	ui := Ui_State {
		row_menu         = -1,
		member_menu      = -1,
		selected_contact = -1,
		focus            = .Compose,
	}
	ui.prefs.stt_enabled = true
	ui.prefs.rail_w = RAIL_W_MIN
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Composer"})
	for i in 0 ..< 20 {
		append(
			&ui.staged,
			Staged_File{name = fmt.aprintf("attachment-%d-with-a-long-name.wav", i)},
		)
	}
	pixel := [4]u8{255, 255, 255, 255}
	ui.staged[0].tex = new(rl.Texture2D)
	ui.staged[0].tex^ = rl.LoadTextureFromImage({data = raw_data(pixel[:]), width = 1, height = 1})
	ui.staged[0].tex.width = 10000 // A panoramic thumbnail must not widen the composer.
	defer {
		for len(ui.staged) > 0 {remove_staged(&ui, len(ui.staged) - 1)}
		delete(ui.staged)
	}
	body := "A first paragraph.\n\nA separate paragraph after a blank line.\n\n\nTwo blank lines before this paragraph."
	append(
		&ui.messages,
		Msg_Ui {
			id = strings.clone("message"),
			sender = strings.clone("Alice"),
			body = strings.clone(body),
			blocks = parse_md_text(body),
		},
	)
	defer {message_free(ui.messages[0]); delete(ui.messages); wrap_clear()}
	defer {delete(ui.accounts); delete(ui.chats); delete(ui.compose); delete(ui.rail_rows)}
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	for zoom in ([]f32{1, 1.875}) {
		UI_ZOOM = zoom
		refresh_ui_scale()
		for width in ([]i32{1200, 720, 420}) {
			rl.SetWindowSize(i32(f32(width) * zoom), i32(800 * zoom))
			clay.SetLayoutDimensions({f32(width), 800})
			for suffix in ([]string{"tail", "tall", "👩🏽‍💻🔥", "\n\nnext", "", "word word"}) {
				text := fmt.tprintf(
					"%s%s",
					strings.repeat("a word ", 200, context.temp_allocator),
					suffix,
				)
				cached := compose_lines(text)
				copy_lines := make([][2]int, len(cached), context.temp_allocator)
				copy(copy_lines, cached)
				testing.expect(
					t,
					raw_data(cached) == raw_data(compose_lines(text)),
					"unchanged draft reuses line breaks",
				)
				wrap_clear()
				fresh := compose_lines(text)
				testing.expect_value(t, len(copy_lines), len(fresh))
				for line, i in copy_lines {testing.expect_value(t, line, fresh[i])}
			}
			for text in ([]string{"another small PR for yet another failed nightlyh simulator run:\n\nhttps://github.com/marmot-protocol/mdk/pull/1900", "Hello", strings.repeat("the quick brown fox jumps over the lazy dog ", 500, context.temp_allocator), strings.repeat("x", 10000, context.temp_allocator), strings.repeat("🔥", 100, context.temp_allocator), strings.repeat("👩🏽‍💻🇮🇹", 100, context.temp_allocator), strings.repeat("1️⃣#️⃣", 100, context.temp_allocator), strings.repeat(" ", 1000, context.temp_allocator)}) {
				ed_set(&ui, &ui.compose, text)
				for _ in 0 ..< 8 {
					build_layout(&ui, 0)
					box := clay.GetElementData(clay.ID("ComposeBox")).boundingBox
					testing.expect(
						t,
						box.x + box.width <= f32(width) + 0.01,
						"composer fits on every resize frame",
					)
				}
				commands := build_layout(&ui, 0)
				staged := clay.GetScrollContainerData(clay.ID("StagedRow"))
				testing.expect(
					t,
					staged.found &&
					staged.contentDimensions.height > staged.scrollContainerDimensions.height,
				)
				testing.expect(t, staged.scrollContainerDimensions.height <= 144)
				thumb := clay.GetElementData(clay.ID("StagedThumb", 0)).boundingBox
				testing.expect(t, thumb.width <= 80 && thumb.height <= 40)
				for id in ([]string{"ChatPane", "ChatHeader", "Composer", "ComposeBox", "StagedRow"}) {
					box := clay.GetElementData(clay.ID(id)).boundingBox
					testing.expect(t, box.x + box.width <= f32(width) + 0.01, id)
				}
				for _, i in ui.staged {
					box := clay.GetElementData(clay.ID("StagedX", u32(i))).boundingBox
					testing.expect(
						t,
						box.x + box.width <= f32(width) + 0.01,
						"attachment removal stays inside the window",
					)
				}
				clip := clay.GetElementData(clay.ID("ComposeClip")).boundingBox
				box := clay.GetElementData(clay.ID("ComposeBox")).boundingBox
				testing.expect(t, box.height <= 240 && box.y + box.height <= 800)
				testing.expect(
					t,
					clay.GetElementData(clay.ID("Timeline")).boundingBox.height > 100,
				)
				for _, i in compose_lines(text) {
					row := clay.GetElementData(clay.ID("ComposeLine", u32(i))).boundingBox
					testing.expect(
						t,
						row.x >= clip.x && row.x + row.width <= clip.x + clip.width + 1,
						"wrapped line fits text viewport",
					)
					testing.expect(
						t,
						row.height <= 21,
						"Clay must not wrap a manually wrapped line again",
					)
				}
				for id in ([]string{"AttachBtn", "EmojiBtn", "FxBtn", "PollBtn", "DictateBtn", "MicBtn"}) {
					button := clay.GetElementData(clay.ID(id)).boundingBox
					testing.expect(
						t,
						button.y >= clip.y + clip.height,
						"controls sit below the text viewport",
					)
					testing.expect(
						t,
						button.x + button.width <= f32(width),
						"controls fit the pane",
					)
				}
				if clay.GetScrollContainerData(clay.ID("ComposeClip")).contentDimensions.height >
				   clip.height {
					data := clay.GetScrollContainerData(clay.ID("ComposeClip"))
					testing.expect(
						t,
						data.scrollPosition.y < 0,
						"pasting follows the caret to the end",
					)
					ed_begin(&ui, &ui.compose)
					ui.ed.selection = {0, 0}
					ed_end(&ui, &ui.compose)
					for _ in 0 ..< 3 {build_layout(&ui, 0)}
					testing.expect_value(t, data.scrollPosition.y, f32(0))
					data.scrollPosition.y = -40
					build_layout(&ui, 0)
					testing.expect_value(t, data.scrollPosition.y, f32(-40))
					ui.ed.selection = {len(text), len(text)}
					for _ in 0 ..< 3 {build_layout(&ui, 0)}
					last_line :=
						clay.GetElementData(clay.ID("ComposeLine", u32(len(compose_lines(text)) - 1))).boundingBox
					testing.expect(
						t,
						last_line.y >= clip.y &&
						last_line.y + last_line.height <= clip.y + clip.height + 0.01,
						"caret remains visible",
					)
				}
				if len(text) > 10 {
					commands = build_layout(&ui, 0)
					rl.BeginDrawing()
					draw_frame(&commands)
					rl.TakeScreenshot(
						fmt.ctprintf("/tmp/wn-composer-%d-%d.png", width, int(zoom * 100)),
					)
					rl.EndDrawing()
				}
				staged.scrollPosition.y =
					staged.scrollContainerDimensions.height - staged.contentDimensions.height
				build_layout(&ui, 0)
				view := clay.GetElementData(clay.ID("StagedRow")).boundingBox
				last :=
					clay.GetElementData(clay.ID("StagedX", u32(len(ui.staged) - 1))).boundingBox
				testing.expect(
					t,
					last.y >= view.y && last.y + last.height <= view.y + view.height + 0.01,
					"last attachment can be scrolled into view for removal",
				)
			}
		}
	}
}
