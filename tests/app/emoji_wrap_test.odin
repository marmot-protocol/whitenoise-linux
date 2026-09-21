package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=emoji_wrap_layout
@(test)
emoji_wrap_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "emoji_wrap_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1000, 800, "Emoji wrapping")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1000, 800})
	defer delete(memory)
	ui: Ui_State
	g_ui = &ui
	defer {g_ui = nil; wrap_clear(); delete(sel_lines); sel_lines = nil}
	texts := []string {
		strings.repeat("😀", 150, context.temp_allocator),
		strings.repeat("👩🏽‍💻🇮🇹1️⃣❤️", 50, context.temp_allocator),
		strings.repeat("hello 😀😀 world 👩🏽‍💻 ", 30, context.temp_allocator),
		"😀😀😀😀😀😀",
		"😀😀😀😀😀😀😀",
	}
	for scale in ([]f32{1, 1.875}) {
		UI_SCALE = scale
		rl.SetPixelScale(scale)
		clay.ResetMeasureTextCache()
		for width in ([]f32{120, 240, 480, 960}) {
			for text, i in texts {
				for selected in 0 ..< 2 {
					ui.sel_on, ui.sel_block, ui.sel_a, ui.sel_b = selected == 1, 42, 0, len(text)
					clear(&sel_lines)
					clay.BeginLayout()
					if clay.UI(clay.ID("EmojiBody"))(
					{
						layout = {
							layoutDirection = .TopToBottom,
							sizing = {width = clay.SizingFixed(width)},
						},
					},
					) {
						body_text(42, text, BODY_FS, TEXT, true, width)
					}
					clay.EndLayout(0)
					if i < 3 {testing.expect(t, len(sel_lines) > 1)}
					for line in sel_lines {
						box := clay.GetElementData(clay.ID("BodyLine", line.id)).boundingBox
						testing.expect(
							t,
							box.width <= width + 0.1,
							fmt.tprintf(
								"case %d: rendered width %.1f exceeds %.1f (scale %.3f)",
								i,
								box.width,
								width,
								scale,
							),
						)
						if selected != 0 {continue}
						segment := -1
						previous_emoji := false
						it := utf8.decode_grapheme_iterator_make(line.text)
						for cluster, g in utf8.decode_grapheme_iterate(&it) {
							emoji := text_emoji(cluster) != nil
							if g.byte_index == 0 || emoji || previous_emoji {segment += 1}
							previous_emoji = emoji
							if !emoji {continue}
							tile := clay.GetElementData(
								clay.ID("SegEmoji", line.id * 128 + u32(segment)),
							)
							testing.expect(t, tile.found)
							for side in 0 ..< 2 {
								b := tile.boundingBox
								offset :=
									line.start +
									hit_plain(
										line.text,
										b.x + b.width * (side == 0 ? 0.25 : 0.75) - box.x,
										line.size,
										line.tile_px,
									)
								expected :=
									line.start + g.byte_index + (side == 0 ? 0 : len(cluster))
								testing.expect(
									t,
									offset == expected,
									fmt.tprintf(
										"case %d width %.0f scale %.3f segment %d side %d: offset %d expected %d, tile x %.1f, line %q",
										i,
										width,
										scale,
										segment,
										side,
										offset,
										expected,
										b.x - box.x,
										line.text,
									),
								)
							}
						}
					}
					testing.expect_value(
						t,
						sel_lines[len(sel_lines) - 1].start +
						len(sel_lines[len(sel_lines) - 1].text),
						len(text),
					)
				}
			}
		}
	}
	UI_SCALE = 1
	rl.SetPixelScale(1)
	clay.ResetMeasureTextCache()
	ui.sel_on = false
	clay.BeginLayout()
	if clay.UI(clay.ID("EmojiExcerpt"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(480), height = clay.SizingGrow()},
			padding = {top = 20},
		},
		backgroundColor = CARD,
	},
	) {
		testing.expect(t, message_excerpt(42, texts[1], TEXT))
	}
	commands := clay.EndLayout(0)
	testing.expect(t, clay.GetElementData(clay.ID("MessageMore", 42)).found)
	rl.BeginDrawing()
	clay_raylib_render(&commands)
	rl.TakeScreenshot("/tmp/wn-emoji-wrap.png")
	rl.EndDrawing()
}
