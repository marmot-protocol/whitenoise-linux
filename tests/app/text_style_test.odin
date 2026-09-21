package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import rl "sdlrl"

@(private)
emphasis_fixture :: proc() -> [dynamic]Md_Block_Ui {
	plain := marmot.Markdown_Inline {
		tag = .TEXT,
	}
	plain.body.text.content = "Normal "
	bold := marmot.Markdown_Inline {
		tag = .TEXT,
	}
	bold.body.text.content = "bold "
	both := marmot.Markdown_Inline {
		tag = .TEXT,
	}
	both.body.text.content = "both 🌻"
	nested := marmot.Markdown_Inline {
		tag = .EMPH,
	}
	nested.body.emph = {&both, 1}
	children := [2]marmot.Markdown_Inline{bold, nested}
	strong := marmot.Markdown_Inline {
		tag = .STRONG,
	}
	strong.body.strong = {raw_data(children[:]), 2}
	italic := marmot.Markdown_Inline {
		tag = .TEXT,
	}
	italic.body.text.content = " italic"
	emph := marmot.Markdown_Inline {
		tag = .EMPH,
	}
	emph.body.emph = {&italic, 1}
	code := marmot.Markdown_Inline {
		tag = .CODE,
	}
	code.body.code.content = " *literal*"
	inlines := [4]marmot.Markdown_Inline{plain, strong, emph, code}
	block := marmot.Markdown_Block {
		tag = .PARAGRAPH,
	}
	block.body.paragraph = {raw_data(inlines[:]), len(inlines)}
	blocks: [dynamic]Md_Block_Ui
	convert_blocks(&blocks, &block, 1, false)
	return blocks
}

@(test)
markdown_emphasis :: proc(t: ^testing.T) {
	blocks := emphasis_fixture()
	defer blocks_free(blocks)
	text, fonts := blocks[0].text, blocks[0].fonts
	testing.expect_value(t, text, "Normal bold both 🌻 italic *literal*")
	testing.expect_value(t, len(fonts), len(text))
	expected_fonts := []u8{FONT_BODY, FONT_TITLE, FONT_BOLD_ITALIC, FONT_ITALIC, FONT_BODY}
	for part, i in ([]string{"Normal", "bold", "both 🌻", "italic", "*literal*"}) {
		start := strings.index(text, part)
		expected := expected_fonts[i]
		for at in start ..< start + len(part) {testing.expect_value(t, fonts[at], expected)}
	}
}

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=rich_text_layout
@(test)
rich_text_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "rich_text_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(700, 900, "Rich text")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes()
	apply_theme(0, 0)
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {700, 900})
	defer delete(memory)
	ui: Ui_State
	g_ui = &ui
	defer {g_ui = nil; preview_close(); wrap_clear(); delete(sel_lines); sel_lines = nil
		delete(ui.link_url)}
	blocks := emphasis_fixture()
	defer blocks_free(blocks)
	for width in ([]f32{140, 460}) {
		for frame in 0 ..< 3 {
			clear(&sel_lines)
			clay.BeginLayout()
			if clay.UI(clay.ID("StyledTest"))(
			{
				layout = {
					layoutDirection = .TopToBottom,
					sizing = {width = clay.SizingFixed(width), height = clay.SizingGrow()},
					childGap = 8,
				},
				backgroundColor = CARD,
			},
			) {
				md_blocks(blocks[:], 16, true, width)
			}
			commands := clay.EndLayout(0)
			if frame < 2 {continue}
			images := 0
			seen: [6]bool
			for cmd in commands.internalArray[:commands.length] {
				if cmd.commandType == .Text {
					data := cmd.renderData.text
					seen[data.fontId] = true
					part := string(data.stringContents.chars[:data.stringContents.length])
					start := strings.index(blocks[0].text, part)
					for line in sel_lines {
						if start < line.start || start >= line.start + len(line.text) {continue}
						box := clay.GetElementData(clay.ID("BodyLine", line.id)).boundingBox
						x :=
							cmd.boundingBox.x +
							0.25 * rl.MeasureTextLine(data.fontId, data.fontSize, part[:1], 0).x -
							box.x
						testing.expect_value(
							t,
							line.start +
							hit_plain(line.text, x, line.size, line.tile_px, line.fonts),
							start,
						)
					}
				}
				if cmd.commandType == .Image {
					images += 1
					testing.expect(t, cmd.boundingBox.width > 0 && cmd.boundingBox.height > 0)
				}
			}
			testing.expect_value(t, images, 1)
			for font in ([]int{FONT_BODY, FONT_TITLE, FONT_ITALIC, FONT_BOLD_ITALIC}) {testing.expect(t, seen[font])}
			for line in sel_lines {
				box := clay.GetElementData(clay.ID("BodyLine", line.id)).boundingBox
				testing.expect(t, box.width <= width + 0.1)
				if len(line.text) > 0 {testing.expect(t, len(line.fonts) == len(line.text))}
			}
			rl.BeginDrawing()
			clay_raylib_render(&commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-emphasis-%d.png", int(width)))
			rl.EndDrawing()
		}
	}
	preview_message(blocks[0].text, blocks[:])
	testing.expect_value(t, preview.message_blocks[0].fonts, blocks[0].fonts)
	testing.expect(t, raw_data(preview.message_blocks[0].fonts) != raw_data(blocks[0].fonts))
	preview_close()

	url := fmt.tprintf(
		"https://imgs.example/%s/end.gif?x=1&y=2",
		strings.repeat("long/path/", 30, context.temp_allocator),
	)
	text := fmt.tprintf("Before %s after", url)
	draw :: proc(text: string) {
		clear(&sel_lines)
		link_hover = ""
		clay.BeginLayout()
		if clay.UI(clay.ID("LinkTest"))(
		{layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(240)}}},
		) {body_text(99, text, 14, TEXT, true, 232)}
		clay.EndLayout(0)
	}
	draw(text)
	boxes := make([dynamic]clay.BoundingBox, context.temp_allocator)
	for line in sel_lines {
		for k in 0 ..< 3 {
			box := clay.GetElementData(clay.ID("SegLink", line.id * 128 + u32(k)))
			if box.found {append(&boxes, box.boundingBox)}
		}
	}
	testing.expect(t, len(boxes) > 2)
	forced_release = true
	defer {forced_release = false; link_hover = ""}
	for box in boxes {
		clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
		draw(text)
		testing.expect_value(t, link_hover, url)
		handle_link_click(&ui)
		testing.expect_value(t, ui.link_url, url)
	}
}
