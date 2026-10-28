package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:testing"
import rl "sdlrl"

@(test)
preview_boundaries :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "preview_boundaries" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 700, "Preview boundaries")
	defer rl.CloseWindow()
	UI_ZOOM = 1
	refresh_ui_scale()
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer delete(memory)
	ui := Ui_State {
		prefs    = default_prefs(),
		selected = 0,
	}
	ui.prefs.reduce_motion = true
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "preview", title = "Preview"})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; preview_close()}
	preview_shown = true
	append(&preview.slides, Slide{}, Slide{}, Slide{})
	view := Pdf_View {
		pages = 3,
		w     = 480,
		h     = 300,
	}
	for kind in ([]Preview_Kind{.Slides, .Pdf}) {
		preview.kind = kind
		preview.pdf = &view
		for page in 0 ..< 3 {
			preview.slide, view.page = page, page
			pdf_flip_hover = nil
			clay.SetPointerState({0, 0}, false)
			for _ in 0 ..< 3 {anim_tick(1.0 / 60); build_layout(&ui, 0)}
			commands := build_layout(&ui, 0)
			left, right: f32
			for command in commands.internalArray[:commands.length] {
				if command.commandType != .Text {continue}
				text := command.renderData.text
				glyph := string(text.stringContents.chars[:text.stringContents.length])
				if glyph == "<" {left = text.textColor.a}
				if glyph == ">" {right = text.textColor.a}
			}
			testing.expect(t, left > 0 && right > 0, "both arrows remain visible")
			switch page {
			case 0:
				testing.expect(t, left < right, "previous is dimmed at the start")
			case 1:
				testing.expect_value(t, left, right)
			case 2:
				testing.expect(t, right < left, "next is dimmed at the end")
			}
			for next in ([]bool{false, true}) {
				id :=
					kind == .Slides ? (next ? "PvSlideNext" : "PvSlidePrev") : (next ? "PvPdfNext" : "PvPdfPrev")
				box := clay.GetElementData(clay.ID(id)).boundingBox
				clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
				pdf_flip_hover = nil
				commands = build_layout(&ui, 0)
				if kind == .Pdf {
					testing.expect_value(t, pdf_flip_hover != nil, next ? page < 2 : page > 0)
				} else {
					preview.slide = page
					forced_release = true
					handle_preview(&ui, nil)
					forced_release = false
					testing.expect_value(t, preview.slide, clamp(page + (next ? 1 : -1), 0, 2))
					preview.slide = page
				}
			}
			clay.SetPointerState({0, 0}, false)
			commands = build_layout(&ui, 0)
			rl.BeginDrawing()
			draw_frame(&commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-preview-%v-%d.png", kind, page))
			rl.EndDrawing()
		}
	}
	// The stack-owned PDF must not be freed by preview_close.
	preview.pdf = nil
	preview.kind = .Slides
}
