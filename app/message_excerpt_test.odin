package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy odin test app -define:ODIN_TEST_NAMES=message_excerpt_layout
@(test)
message_excerpt_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "message_excerpt_layout" { return }
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(900, 700, "Message excerpt")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes()
	apply_theme(0, 0)
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {900, 700})
	defer delete(memory)
	ui: Ui_State
	ui.prefs.reduce_motion = true
	ui.prefs.tts_enabled = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer { g_ui, g_prefs = nil, nil; preview_close(); wrap_clear(); delete(sel_lines); sel_lines = nil }
	for text, i in ([]string{
		"1\n2\n3\n4\n5\n6",
		"1\n2\n3\n4\n5\n6\n7",
		strings.repeat("Wrapped text 👩🏽‍💻 with emoji. ", 100, context.temp_allocator),
	}) {
		clear(&sel_lines)
		clay.BeginLayout()
		if clay.UI(clay.ID("ExcerptTest"))({layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(480)}}}) {
			testing.expect_value(t, message_excerpt(17, text, TEXT), i > 0)
		}
		clay.EndLayout(0)
		if i > 0 {
			testing.expect_value(t, len(sel_lines), MESSAGE_LINES)
			testing.expect(t, sel_lines[5].start + len(sel_lines[5].text) < len(text))
			testing.expect(t, clay.GetElementData(clay.ID("MessageMore", 17)).found)
		}
	}
	text := fmt.tprintf("%sTHE END", strings.repeat("A paragraph with **formatting**.\n\n", 100, context.temp_allocator))
	blocks := parse_md_text(text)
	preview_message(text, blocks[:])
	blocks_free(blocks) // The popup must survive timeline refreshes.
	testing.expect_value(t, string(preview.bytes), text)
	testing.expect_value(t, len(preview.message_blocks), 101)
	for width in ([]i32{900, 360}) {
		rl.SetWindowSize(width, 700)
		clay.SetLayoutDimensions({f32(width), 700})
		for frame in 0 ..< 3 {
			clay.BeginLayout()
			if clay.UI(clay.ID("TestRoot"))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}}, backgroundColor = BG}) {
				preview_modal(&ui)
			}
			commands := clay.EndLayout(0)
			box := clay.GetElementData(clay.ID("PvModal")).boundingBox
			testing.expect(t, clay.GetElementData(clay.ID("PvRead")).found)
			testing.expect(t, box.x >= 0 && box.x + box.width <= f32(width))
			testing.expect(t, box.height <= 700 * PV_MAX_HEIGHT)
			data := clay.GetScrollContainerData(clay.ID("PvScroll"))
			testing.expect(t, data.found && data.contentDimensions.height > data.scrollContainerDimensions.height)
			testing.expect_value(t, sel_lines[len(sel_lines) - 1].text, "THE END")
			rl.BeginDrawing()
			clay_raylib_render(&commands)
			rl.EndDrawing()
			if frame == 0 { continue }
			scroll_box := clay.GetElementData(clay.ID("PvScroll")).boundingBox
			clay.SetPointerState({scroll_box.x + scroll_box.width / 2, scroll_box.y + scroll_box.height / 2}, false)
			before := data.scrollPosition.y
			clay.UpdateScrollContainers(false, {0, frame == 1 ? -3 : 3}, 1.0 / 60)
			testing.expect(t, frame == 1 ? data.scrollPosition.y < before : data.scrollPosition.y > before,
				"wheel over message scrolls the popup in both directions")
		}
	}
	rl.TakeScreenshot("/tmp/wn-message-popup.png")
}
