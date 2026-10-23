package main

import "core:sync"
import "core:testing"

@(test)
video_texture_resolution :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	view := Video_View {
		dw = 1920,
		dh = 1080,
	}
	defer {delete(view.buf); rl.UnloadTexture(view.tex)}

	testing.expect(t, adopt_size(&view))
	testing.expect_value(t, view.w, 480)
	testing.expect_value(t, view.h, 270)

	view.max_width = 1600
	testing.expect(t, adopt_size(&view))
	testing.expect_value(t, view.w, 1600)
	testing.expect_value(t, view.h, 900)
	testing.expect_value(t, len(view.buf), 1600 * 900 * 4)
	testing.expect(t, !adopt_size(&view), "unchanged sizes retain the current frame")

	view.max_width = 3840
	testing.expect(t, adopt_size(&view))
	testing.expect_value(t, view.w, 1920)
	testing.expect_value(t, view.h, 1080)

	view.max_width = 0
	testing.expect(t, adopt_size(&view))
	testing.expect_value(t, view.w, 480)
	testing.expect_value(t, view.h, 270)

	view.dw, view.dh = 1080, 1920
	view.max_width = 900
	testing.expect(t, adopt_size(&view))
	testing.expect_value(t, view.w, 900)
	testing.expect_value(t, view.h, 1600)
}
