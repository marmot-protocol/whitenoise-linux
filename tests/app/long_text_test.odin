package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import rl "sdlrl"

@(test)
long_text_wrap :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	rl.SetPixelScale(1)
	// Preserve word boundaries, UTF-8, and indivisible event cards.
	word_width := rl.MeasureTextLine(FONT_BODY, 14, "hello w", 0).x
	testing.expect_value(t, wrap_break("hello world", 0, 11, word_width, 14), 5)
	testing.expect_value(t, wrap_break("hello", 0, 5, word_width, 14), 5)
	testing.expect_value(t, wrap_break("日本語", 0, len("日本語"), 1, 14), len("日"))
	testing.expect_value(t, wrap_break("", 0, 0, 480, 14), 0)
	event := "note13ze9zdt8ulg08ggc4g9ycmpen5ltscc4hvfy8seceu578zlvkyzsq77jau"
	testing.expect_value(t, wrap_break(event, 0, len(event), 20, 14), len(event))

	sizes := []int{16384, 65536, 262144}
	for size in sizes {
		text := strings.repeat("x", size)
		started := time.tick_now()
		lines := 0
		for at := 0; at < len(text); {
			cut := wrap_break(text, at, len(text), 480, 14)
			testing.expect(t, cut > at)
			at = cut
			lines += 1
		}
		fmt.printf(
			"long-wrap bytes=%d lines=%d ms=%.3f\n",
			size,
			lines,
			time.duration_milliseconds(time.tick_since(started)),
		)
		delete(text)
	}
}
