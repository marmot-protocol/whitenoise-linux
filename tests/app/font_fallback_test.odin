package main

import "base:runtime"
import "core:testing"
import rl "sdlrl"

// Run alone because SDL and the font caches are global.
@(test)
nerd_font_fallback :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "nerd_font_fallback" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(640, 240, "Nerd Font fallback")
	defer rl.CloseWindow()
	UI_SCALE = 1
	init_fonts()
	path := res_font("JetBrainsMonoNerdFont-Regular.ttf")
	defer delete(path)
	reference :: u16(98)
	rl.LoadFontStack(reference, {path})

	// Warm icons first, then text first at a different raster size. Sharing
	// the face must not share icon centering or replace native text advances.
	for size in ([]u16{32, 33}) {
		if size == 32 {rl.MeasureTextLine(FONT_ICON, size, "\ue795", 0)}
		native := rl.MeasureTextLine(reference, size, "\ue795", 0)
		icon := rl.MeasureTextLine(FONT_ICON, size, "\ue795", 0)
		testing.expect(t, native.x != icon.x, "inline glyphs retain native text metrics")
		testing.expect_value(t, rl.MeasureTextLine(reference, size, "\ue795", 0), native)
		testing.expect_value(t, rl.MeasureTextLine(FONT_ICON, size, "\ue795", 0), icon)

		for text in ([]string{"\ue795", "\uf120", "\U000f0001"}) {
			want := rl.MeasureTextLine(reference, size, text, 0)
			for role in ([]u16{FONT_BODY, FONT_TITLE, FONT_ITALIC, FONT_BOLD_ITALIC, FONT_MONO}) {
				testing.expect_value(t, rl.MeasureTextLine(role, size, text, 0), want)
			}
			for face in THEME_FONTS {
				testing.expect_value(t, rl.MeasureTextLine(face.id, size, text, 0), want)
				if face.bold_file != "" {
					testing.expect_value(t, rl.MeasureTextLine(face.id + 1, size, text, 0), want)
				}
			}
		}
	}
}
