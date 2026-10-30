package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
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
		nendo.reset_measure_cache()
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

@(test)
tooltip_window_edges :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "tooltip_window_edges" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(600, 400, "Tooltip window edges")
	defer rl.CloseWindow()
	UI_ZOOM = 1.5
	refresh_ui_scale()
	load_themes()
	apply_theme(0, 0)
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {400, 400 / 1.5})
	defer delete(memory)
	labels := []string {
		"Copy",
		"End-to-end encrypted",
		"チャットの詳細",
		"Project name\n/home/user/project",
		strings.repeat("long filename ", 80, context.temp_allocator),
	}
	for label in labels {
		for side in Tip_Side {
			for point in ([]nendo.Vector2{{0, 0}, {360, 0}, {0, 225}, {360, 225}}) {
				commands: []nendo.Render_Command
				for _ in 0 ..< 2 {
					nendo.begin()
					if nendo.box(nendo.id("TooltipAnchor"))(
					{
						width = nendo.fixed(40),
						height = nendo.fixed(40),
						floating = {attach_to = .Root, offset = point},
					},
					) {tooltip(label, side)}
					commands = nendo.end(0)
				}
				shown := strings.builder_make(context.temp_allocator)
				for cmd in commands {
					if cmd.z != 18 {continue}
					box := cmd.rect
					testing.expect(
						t,
						box.x >= 0 &&
						box.y >= 0 &&
						box.x + box.width <= 400 &&
						box.y + box.height <= 400 / 1.5,
						fmt.tprintf("%v tooltip stays inside the window: %v", side, box),
					)
					if cmd.kind != .Text {continue}
					if strings.builder_len(shown) > 0 {strings.write_byte(&shown, '\n')}
					strings.write_string(&shown, cmd.text.text)
				}
				if len(label) < 100 {
					testing.expect_value(t, strings.to_string(shown), label)
				} else {
					testing.expect(
						t,
						strings.has_suffix(strings.to_string(shown), "…"),
						"oversized labels are visibly truncated",
					)
				}
				if path := os.get_env("WN_TOOLTIP_EDGE_CAPTURE", context.temp_allocator);
				   path != "" &&
				   side == .Above &&
				   point.x == 360 &&
				   point.y == 225 &&
				   strings.contains(label, "\n") {
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
