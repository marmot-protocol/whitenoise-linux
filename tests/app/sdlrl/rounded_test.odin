package sdlrl

import "core:c"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
test_rounded_edge_coverage :: proc(t: ^testing.T) {
	sync.lock(&sdl_test_mutex)
	defer sync.unlock(&sdl_test_mutex)
	InitWindow(128, 96, "Rounded edges", driver = .Software)
	defer CloseWindow()

	red_at :: proc(surface: ^sdl.Surface, x, y: c.int) -> u8 {
		r, g, b, a: u8
		sdl.ReadSurfacePixel(surface, x, y, &r, &g, &b, &a)
		return r
	}

	for scale in ([2]f32{1, 1.25}) {
		BeginDrawing()
		sdl.SetRenderScale(state.renderer, scale, scale)
		white := Color{255, 255, 255, 255}
		DrawRectangleRoundedPx(8, 8, 32, 32, 12, white)
		DrawArc(76, 20, 12, 180, 270, 1, white)
		surface := sdl.RenderReadPixels(state.renderer, nil)
		testing.expect(t, surface != nil, "read the rendered frame")
		if surface == nil {return}
		defer sdl.DestroySurface(surface)

		testing.expect_value(t, red_at(surface, c.int(24 * scale), c.int(8 * scale)), u8(255))
		testing.expect_value(t, red_at(surface, c.int(74 * scale), c.int(18 * scale)), u8(0))
		for left in ([2]f32{8, 64}) {
			partial := 0
			for y in c.int(8 * scale) ..< c.int(18 * scale) {
				for x in c.int(left * scale) ..< c.int((left + 10) * scale) {
					red := red_at(surface, x, y)
					if red > 0 && red < 255 {partial += 1}
				}
			}
			testing.expect(t, partial >= 4, "the curve blends edge pixels with the background")
		}
		EndDrawing()
	}
}
