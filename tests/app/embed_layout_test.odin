package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=embed_layout
@(test)
embed_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "embed_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(900, 900, "Attachment and Nostr previews")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {900, 900})
	defer delete(memory)
	ui: Ui_State
	g_ui = &ui
	defer {g_ui = nil; wrap_clear(); preview_close()}
	for dim, n in ([][2]int{{8000, 200}, {200, 8000}, {800, 600}}) {
		pixels := make([]u8, dim[0] * dim[1] * 4)
		for y in 0 ..< dim[1] {
			for x in 0 ..< dim[0] {
				i := (y * dim[0] + x) * 4
				shade := ((x / 40 + y / 40) % 2 == 0) ? u8(220) : u8(80)
				pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3] = shade, shade, 240, 255
			}
		}
		tex := rl.LoadTextureFromImage(
			{data = raw_data(pixels), width = i32(dim[0]), height = i32(dim[1])},
		)
		delete(pixels)
		defer rl.UnloadTexture(tex)
		msg := Msg_Ui {
			id     = "image-test",
			sender = "Sender",
			mine   = true,
		}
		append(&msg.images, Att_Item(^rl.Texture2D){&tex, 0})
		append(&msg.att_names, "screenshot.png")
		defer {delete(msg.images); delete(msg.att_names)}
		for width in ([]f32{280, 800}) {
			for frame in 0 ..< 3 {
				clay.BeginLayout()
				if clay.UI(clay.ID("Timeline"))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(width)},
						layoutDirection = .TopToBottom,
					},
					backgroundColor = CARD,
				},
				) {message_row(0, msg)}
				commands := clay.EndLayout(0)
				if frame < 2 {continue}
				box := clay.GetElementData(clay.ID("MsgImage", 0)).boundingBox
				testing.expect(t, box.height >= min(body_wrap_w(), 480) / 3 && box.height <= 320)
				testing.expect(t, box.x + box.width <= width)
				testing.expect(t, !clay.GetScrollContainerData(clay.ID("MsgImage", 0)).found)
				rl.BeginDrawing()
				clay_raylib_render(&commands)
				rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-image-%d-%.0f.png", n, width))
				rl.EndDrawing()
			}
		}
		preview.kind = .Slides
		preview_shown = true
		append(&preview.slides, Slide{name = strings.clone("screenshot.png"), tex = &tex})
		for width in ([]i32{900, 360}) {
			rl.SetWindowSize(width, 900)
			clay.SetLayoutDimensions({f32(width), 900})
			for zoom in ([]f32{0, -1, 1, 2}) {
				preview.image_zoom = zoom
				for frame in 0 ..< 3 {
					clay.BeginLayout()
					if clay.UI(clay.ID("Root"))(
					{
						layout = {
							sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()},
						},
						backgroundColor = BG,
					},
					) {preview_modal(&ui)}
					commands := clay.EndLayout(0)
					if frame < 2 {continue}
					box := clay.GetElementData(clay.ID("PvModal")).boundingBox
					data := clay.GetScrollContainerData(clay.ID("PvScroll"))
					testing.expect(
						t,
						box.x >= 0 &&
						box.x + box.width <= f32(width) + 0.1 &&
						box.height <= 900 * PV_MAX_HEIGHT,
					)
					testing.expect(t, clay.GetElementData(clay.ID("PvZoomIn")).found)
					if zoom ==
					   -1 {testing.expect(t, data.contentDimensions.width <= data.scrollContainerDimensions.width + 1)}
					if n == 0 &&
					   zoom ==
						   0 {testing.expect(t, data.contentDimensions.width > data.scrollContainerDimensions.width)}
					rl.BeginDrawing()
					clay_raylib_render(&commands)
					rl.TakeScreenshot(
						fmt.ctprintf("/tmp/wn-image-modal-%d-%d-%.0f.png", n, width, zoom),
					)
					rl.EndDrawing()
					if n == 0 && width == 900 && zoom == 2 {
						data.scrollPosition^ = {}
						point := rl.GetMousePosition()
						preview.image_pointer = {point.x + 64, point.y}
						preview.image_drag = true
						clay.SetPointerState({-1, -1}, true)
						rl.PushMouseButton(.LEFT, true)
						handle_preview(&ui, nil)
						testing.expect_value(t, data.scrollPosition.x, f32(-64))
						rl.PushMouseButton(.LEFT, false)
						handle_preview(&ui, nil)
						testing.expect(t, !preview.image_drag)
					}
				}
			}
		}
		preview_close()
		rl.SetWindowSize(900, 900)
		clay.SetLayoutDimensions({900, 900})
	}
	key := strings.repeat("a", 64, context.temp_allocator)
	for kind in NEV_TEXT_KINDS {
		for count in ([]int{6, 7}) {
			text := strings.repeat("line\n", count - 1, context.temp_allocator)
			text = fmt.tprintf("%sfinal line", text)
			for parsed in 0 ..< 2 {
				card := Nev_Card {
					kind    = kind,
					done    = true,
					raw     = "{}",
					content = text,
				}
				if parsed == 1 {
					for i in 0 ..< count {append(&card.blocks, Md_Block_Ui{kind = .Para, text = strings.clone(i == count - 1 ? "final line" : "line")})}
				}
				defer blocks_free(card.blocks)
				nev_cards[key] = card
				clay.BeginLayout()
				if clay.UI(clay.ID("NostrTest"))(
				{
					layout = {
						layoutDirection = .TopToBottom,
						sizing = {width = clay.SizingFixed(400)},
					},
				},
				) {nev_card(99, key, "note", nil)}
				commands := clay.EndLayout(0)
				testing.expect_value(
					t,
					clay.GetElementData(clay.ID("NevMore", 99)).found,
					count > MESSAGE_LINES,
				)
				for command in commands.internalArray[:commands.length] {
					if command.commandType != .Text || count == MESSAGE_LINES {continue}
					text := command.renderData.text.stringContents
					testing.expect(
						t,
						!strings.contains(string(text.chars[:text.length]), "final line"),
					)
				}
				preview_message(card.content, card.blocks[:])
				testing.expect_value(t, string(preview.bytes), text)
			}
		}
	}
}
