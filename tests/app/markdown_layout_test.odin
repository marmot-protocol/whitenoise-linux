package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=markdown_layout
@(test)
markdown_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "markdown_layout" {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("/tmp", "wn-markdown-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	client: ^marmot.Client
	store := vault_secret_store()
	if !testing.expect_value(
		t,
		marmot.client_new_with_secret_store(
			strings.clone_to_cstring(dir, context.temp_allocator),
			nil,
			0,
			&store,
			&client,
		),
		marmot.Status.OK,
	) {return}
	defer marmot.client_free(client)
	source :: #load("markdown_fixture.md", string)
	doc: ^marmot.Markdown_Document
	if !testing.expect_value(
		t,
		marmot.parse_markdown(
			client,
			strings.clone_to_cstring(source, context.temp_allocator),
			&doc,
		),
		marmot.Status.OK,
	) {return}
	blocks: [dynamic]Md_Block_Ui
	convert_blocks(
		&blocks,
		doc.blocks,
		doc.blocks_len,
		false,
		([^]u8)(doc.blank_lines_before)[:doc.blank_lines_before_len],
	)
	marmot.markdown_document_free(doc)
	defer blocks_free(blocks)
	max_indent, max_quote: u16
	math_blocks, code_blocks := 0, 0
	for block in blocks {
		max_indent = max(max_indent, block.indent)
		max_quote = max(max_quote, block.quote_depth)
		if block.kind == .Math {math_blocks += 1}
		if block.kind == .Code {
			code_blocks += 1
			testing.expect_value(t, len(block.code_kinds), len(block.text))
			testing.expect(
				t,
				len(strings.trim(block.code_kinds, "\x00")) > 0,
				"code contains syntax colors",
			)
		}
	}
	testing.expect_value(t, max_indent, u16(48))
	testing.expect_value(t, max_quote, u16(3))
	testing.expect_value(t, math_blocks, 1)
	testing.expect_value(t, code_blocks, 3)
	rl.InitWindow(760, 1500, "Markdown")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes()
	for pack, i in theme_packs {if pack.name == "Dark" {apply_theme(i, 0); break}}
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {760, 1500})
	defer delete(memory)
	ui: Ui_State
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; preview_close(); wrap_clear(); delete(sel_lines)
		sel_lines = nil}
	for width in ([]f32{700, 280}) {
		for frame in 0 ..< 3 {
			clear(&sel_lines)
			clay.BeginLayout()
			if clay.UI(clay.ID("MarkdownTest"))(
			{
				layout = {
					layoutDirection = .TopToBottom,
					sizing = {width = clay.SizingFixed(width + 40)},
					padding = clay.PaddingAll(20),
					childGap = 3,
				},
				backgroundColor = CARD,
			},
			) {
				md_blocks(blocks[:], 0, true, width)
			}
			commands := clay.EndLayout(0)
			if frame < 2 {continue}
			strike, formula, code := false, false, false
			for cmd in commands.internalArray[:commands.length] {
				if cmd.commandType != .Text {continue}
				flags := u8(uintptr(cmd.userData))
				strike = strike || flags & TEXT_STRIKE != 0
				formula = formula || flags & TEXT_MATH != 0
				code = code || flags & TEXT_CODE != 0
				testing.expect(
					t,
					cmd.boundingBox.x + cmd.boundingBox.width <= width + 20.1,
					"text stays inside its column",
				)
			}
			testing.expect(t, strike && formula && code)
			for block, i in blocks {
				id := u32(i) * 16
				if block.quote_depth == 1 && block.quote_starts > 0 {
					group := clay.GetElementData(clay.ID("MsgQuoteGroup", id * 128)).boundingBox
					bar := clay.GetElementData(clay.ID("MsgQuoteBar", id)).boundingBox
					testing.expect_value(t, bar.height, group.height)
					testing.expect(
						t,
						bar.height > f32(BODY_FS),
						"outer quote border spans nested blocks",
					)
				}
				if block.kind == .Code {
					box := clay.GetElementData(clay.ID("MsgCode", id)).boundingBox
					numbers := 0
					for cmd in commands.internalArray[:commands.length] {
						if cmd.commandType == .Text &&
						   cmd.renderData.text.fontSize == 11 &&
						   cmd.boundingBox.y >= box.y &&
						   cmd.boundingBox.y < box.y + box.height {numbers += 1}
					}
					testing.expect_value(t, numbers, strings.count(block.text, "\n") + 1)
				}
				if block.kind == .List_Item {
					box := clay.GetElementData(clay.ID("MsgListMarker", id)).boundingBox
					testing.expect_value(t, box.x, 32 + f32(block.indent))
				}
				if block.kind ==
				   .Rule {testing.expect_value(t, clay.GetElementData(clay.ID("MsgRule", id)).boundingBox.width, width)}
				if block.kind == .Table {
					for cmd in commands.internalArray[:commands.length] {
						if cmd.commandType != .Text {continue}
						data := cmd.renderData.text
						text := string(data.stringContents.chars[:data.stringContents.length])
						if text == "1,250" {
							cell :=
								clay.GetElementData(clay.ID("MsgTableCell", id + 64 + 2)).boundingBox
							testing.expect(
								t,
								abs(
									cmd.boundingBox.x +
									cmd.boundingBox.width -
									(cell.x + cell.width - 7),
								) <
								0.1,
								"numeric cells align right",
							)
						}
						if text == "Active" {
							cell :=
								clay.GetElementData(clay.ID("MsgTableCell", id + 64 + 1)).boundingBox
							testing.expect(
								t,
								abs(
									cmd.boundingBox.x +
									cmd.boundingBox.width / 2 -
									(cell.x + cell.width / 2),
								) <
								0.1,
								"centered cells retain their alignment",
							)
						}
					}
				}
			}
			rl.BeginDrawing()
			clay_raylib_render(&commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-markdown-%d.png", int(width)))
			rl.EndDrawing()
		}
	}
	for level in 1 ..= 6 {
		heading := [1]Md_Block_Ui{{kind = .Heading, text = "Heading", level = level}}
		for frame in 0 ..< 3 {
			box := clay.GetElementData(clay.ID("MdHeading", 77)).boundingBox
			clay.SetPointerState(
				frame == 1 ? clay.Vector2{box.x + 1, box.y + 1} : clay.Vector2{-100, -100},
				false,
			)
			clay.BeginLayout()
			if clay.UI(clay.ID("HeadingTest"))(
			{layout = {padding = {left = 60}, sizing = {width = clay.SizingFixed(560)}}},
			) {md_blocks(heading[:], 77, true, 500)}
			commands := clay.EndLayout(0)
			testing.expect_value(
				t,
				clay.GetElementData(clay.ID("MdHeadingText", 77)).boundingBox.x,
				f32(60),
			)
			testing.expect_value(
				t,
				clay.GetElementData(clay.ID("MdHeadingMarks", 77)).found,
				frame == 1,
			)
			if frame == 1 {
				found := false
				for cmd in commands.internalArray[:commands.length] {
					if cmd.commandType != .Text {continue}
					text := cmd.renderData.text.stringContents
					if string(text.chars[:text.length]) ==
					   strings.repeat("#", level, context.temp_allocator) {found = true}
				}
				testing.expect(t, found)
			}
		}
	}
	preview_message(source, blocks[:])
	for block, i in blocks {
		testing.expect_value(t, preview.message_blocks[i].quote_depth, block.quote_depth)
		testing.expect_value(t, preview.message_blocks[i].code_kinds, block.code_kinds)
		if len(block.alignments) >
		   0 {testing.expect(t, raw_data(preview.message_blocks[i].alignments) != raw_data(block.alignments))}
	}
}
