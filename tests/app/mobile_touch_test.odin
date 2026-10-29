package main

import "base:runtime"
import "core:sync"
import "core:testing"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
mobile_touch_scrolling :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "mobile_touch_scrolling" {return}
	context.allocator = runtime.default_context().allocator
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	rl.InitWindow(360, 640, "Touch scrolling")
	defer rl.CloseWindow()
	UI_ZOOM = 1
	ui: Ui_State
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	previous_prefs := g_prefs
	g_prefs = &ui.prefs
	defer {g_prefs = previous_prefs}
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {360, 640})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	for horizontal in ([]bool{false, true}) {
		clear(&drag_targets)
		for _ in 0 ..< 3 {
			clay.BeginLayout()
			if clay.UI(clay.ID("TouchScroll"))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(300), height = clay.SizingFixed(300)},
				},
				clip = {
					horizontal = horizontal,
					vertical = !horizontal,
					childOffset = clay.GetScrollOffset(),
				},
			},
			) {
				if clay.UI(clay.ID("TouchContent"))(
				{
					layout = {
						sizing = {
							width = clay.SizingFixed(horizontal ? 900 : 300),
							height = clay.SizingFixed(horizontal ? 300 : 900),
						},
					},
				},
				) {}
			}
			scrollbar(clay.ID("TouchScroll"))
			clay.EndLayout(0)
		}
		rl.InjectFinger(.Down, 200, 200)
		rl.WindowShouldClose()
		clay.SetPointerState({200, 200}, true)
		update_drag_scroll(&ui, false)
		// Many small moves must become a scroll once total travel passes slop.
		for step in 1 ..= 10 {
			x, y :=
				horizontal ? f32(200 - step * 2) : 200, horizontal ? f32(200) : f32(200 - step * 2)
			rl.InjectFinger(.Move, x, y)
			clay.SetPointerState({x, y}, true)
			rl.WindowShouldClose()
			update_drag_scroll(&ui, false)
		}
		data := clay.GetScrollContainerData(clay.ID("TouchScroll"))
		position := horizontal ? data.scrollPosition.x : data.scrollPosition.y
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
			scroll_residual == clay.Vector2{},
			"Reduce motion disables the fling, not direct scrolling",
		)
		rl.WindowShouldClose()
		update_drag_scroll(&ui, false)
		testing.expect(t, !drag_moved, "next gesture starts without stale click suppression")
	}
}
