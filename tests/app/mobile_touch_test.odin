package main

import "base:runtime"
import "core:sync"
import "core:testing"

import "nendo"
import rl "sdlrl"

@(test)
mobile_touch_scrolling :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "mobile_touch_scrolling" {return}
	context.allocator = runtime.default_context().allocator
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	rl.InitWindow(360, 640, "Touch scrolling")
	defer rl.CloseWindow()
	UI_ZOOM = 1
	ui: Ui_State
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	previous_prefs := g_prefs
	g_prefs = &ui.prefs
	defer {g_prefs = previous_prefs}
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {360, 640})
	defer {nendo.set_context(previous); delete(memory)}
	for horizontal in ([]bool{false, true}) {
		clear(&drag_targets)
		for _ in 0 ..< 3 {
			nendo.begin()
			if nendo.box(nendo.id("TouchScroll"))(
			{
				width = nendo.fixed(300),
				height = nendo.fixed(300),
				clip = {x = horizontal, y = !horizontal, scroll = true},
			},
			) {
				if nendo.box(nendo.id("TouchContent"))(
				{
					width = nendo.fixed(horizontal ? 900 : 300),
					height = nendo.fixed(horizontal ? 300 : 900),
				},
				) {}
			}
			scrollbar(nendo.id("TouchScroll"))
			nendo.end(0)
		}
		rl.InjectFinger(.Down, 200, 200)
		rl.WindowShouldClose()
		nendo.set_pointer({200, 200}, .Down)
		update_drag_scroll(&ui, false)
		// Many small moves must become a scroll once total travel passes slop.
		for step in 1 ..= 10 {
			x, y :=
				horizontal ? f32(200 - step * 2) : 200, horizontal ? f32(200) : f32(200 - step * 2)
			rl.InjectFinger(.Move, x, y)
			nendo.set_pointer({x, y}, .Down)
			rl.WindowShouldClose()
			update_drag_scroll(&ui, false)
		}
		data := nendo.scroll(nendo.id("TouchScroll"))
		position := horizontal ? data.position.x : data.position.y
		testing.expect(
			t,
			position <= -19,
			"finger drag scrolls directly even with Reduce motion enabled",
		)
		rl.InjectFinger(.Up, horizontal ? 180 : 200, horizontal ? 200 : 180)
		rl.WindowShouldClose()
		update_drag_scroll(&ui, false)
		testing.expect(
			t,
			!mouse_released(),
			"ending a scroll cannot activate the control under the finger",
		)
		testing.expect(
			t,
			scroll_residual == nendo.Vector2{},
			"Reduce motion disables the fling, not direct scrolling",
		)
		rl.WindowShouldClose()
		update_drag_scroll(&ui, false)
		testing.expect(t, !drag_moved, "next gesture starts without stale click suppression")
	}
}
