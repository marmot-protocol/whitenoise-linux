package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"

import "nendo"
import rl "sdlrl"

@(test)
tooltip_labels_fit :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "tooltip_labels_fit" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 700, "Navigation tooltips")
	defer rl.CloseWindow()
	load_themes()
	apply_theme(0, 0)
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1024, 700})
	defer delete(memory)

	for zoom in ([]f32{1, 1.25, 1.5, 1.75, 2}) {
		UI_ZOOM = zoom
		refresh_ui_scale()
		nendo.reset_text_cache()
		nendo.set_dimensions({1024 / zoom, 700 / zoom})
		for theme in 0 ..< len(theme_packs) {
			apply_theme(theme, 0)
			for page in ([]Page{.Chats, .Contacts, .Archived, .Settings, .Profile}) {
				nendo.set_pointer({-100, -100}, .Up)
				for _ in 0 ..< 2 {
					nendo.begin()
					nav_button(page, false)
					nendo.end(0)
				}
				box := nendo.element(nendo.id("Nav", u32(page))).rect
				nendo.set_pointer({box.x + box.width / 2, box.y + box.height / 2}, .Up)
				nendo.begin()
				nav_button(page, false)
				commands := nendo.end(0)
				shown: string
				for cmd in commands {
					if cmd.kind != .Text || cmd.z != 18 {continue}
					shown = cmd.text.text
					testing.expect(
						t,
						cmd.rect.x >= 0 && cmd.rect.x + cmd.rect.width <= 1024 / zoom,
						"tooltip stays within the window",
					)
				}
				testing.expect(
					t,
					shown == tr(NAV_TIPS[page]),
					fmt.tprintf(
						"theme=%s zoom=%.2f expected=%s shown=%s",
						theme_packs[theme].name,
						zoom,
						tr(NAV_TIPS[page]),
						shown,
					),
				)
				if page == .Contacts && theme == 0 && zoom == 1.5 {
					if path := os.get_env("WN_TOOLTIP_CAPTURE", context.temp_allocator);
					   path != "" {
						rl.BeginDrawing()
						rl.BeginMode2D(rl.Camera2D{zoom = UI_ZOOM})
						render_nendo(commands)
						rl.EndMode2D()
						rl.TakeScreenshot(fmt.ctprintf("%s", path))
						rl.EndDrawing()
					}
				}
			}
		}
	}
}
