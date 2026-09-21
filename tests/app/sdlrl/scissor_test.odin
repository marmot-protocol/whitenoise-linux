package sdlrl

import "core:testing"
import sdl "vendor:sdl3"

// Run headlessly: SDL_VIDEODRIVER=dummy tests/odin.sh app/sdlrl
@(test)
test_nested_scissor :: proc(t: ^testing.T) {
	InitWindow(100, 100, "Nested clipping")
	defer CloseWindow()
	defer delete(clip_stack)

	BeginScissorMode(10, 10, 60, 60)
	BeginScissorMode(20, 50, 80, 40)
	rect: sdl.Rect
	testing.expect(t, sdl.GetRenderClipRect(state.renderer, &rect))
	testing.expect_value(t, rect, sdl.Rect{20, 50, 50, 20})
	EndScissorMode()
	testing.expect(t, sdl.RenderClipEnabled(state.renderer))
	testing.expect(t, sdl.GetRenderClipRect(state.renderer, &rect))
	testing.expect_value(t, rect, sdl.Rect{10, 10, 60, 60})

	BeginScissorMode(80, 80, 10, 10)
	testing.expect(t, sdl.RenderClipEnabled(state.renderer))
	testing.expect(t, sdl.GetRenderClipRect(state.renderer, &rect))
	testing.expect(t, rect.w == 0 && rect.h == 0, "disjoint clips must draw nothing")
	EndScissorMode()
	EndScissorMode()
	testing.expect(t, !sdl.RenderClipEnabled(state.renderer))
}
