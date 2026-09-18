package main

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:text/edit"
import "core:time"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy odin test app -o:minimal -define:ODIN_TEST_NAMES=composer_performance
@(test)
composer_performance :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "composer_performance" { return }
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1200, 800, "Long draft regression")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 131072, {1200, 800})
	defer delete(memory)
	ui := Ui_State{row_menu = -1, member_menu = -1, selected_contact = -1, focus = .Compose}
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	ui.prefs.rail_w = RAIL_W_MIN
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Composer"})
	g_ui, g_prefs = &ui, &ui.prefs
	defer { delete(ui.accounts); delete(ui.chats); delete(ui.compose); delete(ui.rail_rows); wrap_clear(); g_ui, g_prefs = nil, nil }
	for count in ([]int{1500, 6000}) {
		text := strings.repeat("the quick brown fox jumps over the lazy dog ", count)
		ed_set(&ui, &ui.compose, text)
		delete(text)
		for _ in 0 ..< 5 { build_layout(&ui, 0); free_all(context.temp_allocator) }
		for typing in 0 ..< 2 {
			samples, layout: [15]f64
			for &ms, i in samples {
				start := time.tick_now()
				if typing == 1 { ed_insert(&ui, &ui.compose, "x") }
				commands := build_layout(&ui, 0)
				layout[i] = time.duration_milliseconds(time.tick_since(start))
				rl.BeginDrawing(); draw_frame(&commands); rl.EndDrawing()
				ms = time.duration_milliseconds(time.tick_since(start))
				testing.expect(t, !layout_overflow)
				free_all(context.temp_allocator)
			}
			slice.sort(samples[:])
			slice.sort(layout[:])
			fmt.printf("composer bytes=%d typing=%d median_ms=%.3f p95_ms=%.3f layout_ms=%.3f\n", len(ui.compose), typing, samples[7], samples[14], layout[7])
		}
	}
}
