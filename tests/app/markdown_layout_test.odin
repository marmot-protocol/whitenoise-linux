package main

import marmot "../marmot"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "nendo"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=markdown_layout
@(test)
markdown_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "markdown_layout" {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("/tmp", "wn-markdown-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(dir)
	deployment: ^marmot.Deployment
	if !testing.expect_value(
		t,
		marmot.deployment_white_noise(&deployment),
		marmot.Status.OK,
	) {return}
	defer marmot.deployment_free(deployment)
	client: ^marmot.Client
	store := vault_secret_store()
	if !testing.expect_value(
		t,
		marmot.client_new_with_secret_store(
			strings.clone_to_cstring(dir, context.temp_allocator),
			nil,
			0,
			&store,
			deployment,
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
			nendo.begin()
			if nendo.box(nendo.id("MarkdownTest"))(
			{
				direction = .Column,
				width = nendo.fixed(width + 40),
				padding = nendo.pad(20),
				gap = 3,
				color = CARD,
			},
			) {
				md_blocks(blocks[:], 0, true, width)
			}
			commands := nendo.end(0)
			if frame < 2 {continue}
			strike, formula, code := false, false, false
			for cmd in commands {
				if cmd.kind != .Text {continue}
				flags := u8(uintptr(cmd.user_data))
				strike = strike || flags & TEXT_STRIKE != 0
				formula = formula || flags & TEXT_MATH != 0
				code = code || flags & TEXT_CODE != 0
				testing.expect(
					t,
					cmd.rect.x + cmd.rect.width <= width + 20.1,
					"text stays inside its column",
				)
			}
			testing.expect(t, strike && formula && code)
			for block, i in blocks {
				id := u32(i) * 16
				if block.quote_depth == 1 && block.quote_starts > 0 {
					group := nendo.element(nendo.id("MsgQuoteGroup", id * 128)).rect
					bar := nendo.element(nendo.id("MsgQuoteBar", id)).rect
					testing.expect_value(t, bar.height, group.height)
					testing.expect(
						t,
						bar.height > f32(BODY_FS),
						"outer quote border spans nested blocks",
					)
				}
				if block.kind == .Code {
					box := nendo.element(nendo.id("MsgCode", id)).rect
					numbers := 0
					for cmd in commands {
						if cmd.kind == .Text &&
						   cmd.text.size == 11 &&
						   cmd.rect.y >= box.y &&
						   cmd.rect.y < box.y + box.height {numbers += 1}
					}
					testing.expect_value(t, numbers, strings.count(block.text, "\n") + 1)
				}
				if block.kind == .List_Item {
					box := nendo.element(nendo.id("MsgListMarker", id)).rect
					testing.expect_value(t, box.x, 32 + f32(block.indent))
				}
				if block.kind ==
				   .Rule {testing.expect_value(t, nendo.element(nendo.id("MsgRule", id)).rect.width, width)}
				if block.kind == .Table {
					table := nendo.element(nendo.id("MsgTable", id)).rect
					testing.expect(
						t,
						abs(table.width - width) < 0.1,
						"table fills the available width",
					)
					for cmd in commands {
						if cmd.kind != .Text {continue}
						data := cmd.text
						text := data.text
						if text == "1,250" {
							cell := nendo.element(nendo.id("MsgTableCell", id + 64 + 2)).rect
							testing.expect(
								t,
								abs(cmd.rect.x + cmd.rect.width - (cell.x + cell.width - 7)) < 0.1,
								"numeric cells align right",
							)
						}
						if text == "Active" {
							cell := nendo.element(nendo.id("MsgTableCell", id + 64 + 1)).rect
							testing.expect(
								t,
								abs(cmd.rect.x + cmd.rect.width / 2 - (cell.x + cell.width / 2)) <
								0.1,
								"centered cells retain their alignment",
							)
						}
					}
				}
			}
			rl.BeginDrawing()
			render_nendo(commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-markdown-%d.png", int(width)))
			rl.EndDrawing()
		}
	}
	for level in 1 ..= 6 {
		heading := [1]Md_Block_Ui{{kind = .Heading, text = "Heading", level = level}}
		for frame in 0 ..< 3 {
			anim_tick(1.0 / 60)
			box := nendo.element(nendo.id("MdHeading", 77)).rect
			nendo.set_pointer(
				frame == 1 ? nendo.Vector2{box.x + 1, box.y + 1} : nendo.Vector2{-100, -100},
				.Up,
			)
			nendo.begin()
			if nendo.box(nendo.id("HeadingTest"))(
			{padding = {left = 60}, width = nendo.fixed(560)},
			) {md_blocks(heading[:], 77, true, 500)}
			commands := nendo.end(0)
			testing.expect_value(
				t,
				nendo.element(nendo.id("MdHeadingText", 77)).rect.x,
				f32(60) +
				(frame == 1 ? rl.MeasureTextLine(FONT_MONO, u16(max(24 - level * 2, 15)), strings.repeat("#", level, context.temp_allocator), 0).x + 6 : 0),
			)
			testing.expect_value(
				t,
				nendo.element(nendo.id("MdHeadingMarks", 77)).found,
				frame == 1,
			)
			if frame == 1 {
				found := false
				for cmd in commands {
					if cmd.kind != .Text {continue}
					text := cmd.text.text
					if text == strings.repeat("#", level, context.temp_allocator) {found = true}
				}
				testing.expect(t, found)
			}
		}
	}
	ui.prefs.reduce_motion = false
	heading := [1]Md_Block_Ui{{kind = .Heading, text = "Animated heading", level = 2}}
	previous: f32
	for frame in 0 ..< 41 {
		anim_tick(1.0 / 60)
		nendo.set_pointer(
			frame > 0 && frame <= 20 ? nendo.Vector2{61, 1} : nendo.Vector2{-100, -100},
			.Up,
		)
		nendo.begin()
		if nendo.box(nendo.id("HeadingTest"))({padding = {left = 60}, width = nendo.fixed(560)}) {
			md_blocks(heading[:], 77, true, 500)
		}
		commands := nendo.end(0)
		x := nendo.element(nendo.id("MdHeadingText", 77)).rect.x
		if frame ==
		   1 {testing.expect(t, x > 60 && x < 60 + rl.MeasureTextLine(FONT_MONO, 20, "##", 0).x + 6, "heading moves through an intermediate position")}
		if frame > 0 && frame <= 20 {testing.expect(t, x >= previous)}
		if frame > 20 {testing.expect(t, x <= previous)}
		if frame == 40 {testing.expect_value(t, x, f32(60))}
		previous = x
		if frame == 2 {
			rl.BeginDrawing()
			render_nendo(commands)
			rl.TakeScreenshot("/tmp/wn-heading-slide.png")
			rl.EndDrawing()
		}
	}
	ui.prefs.reduce_motion = true
	// Hover nested content and verify the background reaches its full block.
	CARD = {36, 42, 54, 255}
	HOVER = {255, 255, 255, 16}
	hover_blocks := []Md_Block_Ui {
		{kind = .List_Item, text = "• Parent", marker_len = len("• ")},
		{kind = .List_Item, text = "• Nested", marker_len = len("• "), indent = 24},
		{kind = .Quote, text = "Outer", quote_depth = 1, quote_starts = 1},
		{kind = .Quote, text = "Inner", quote_depth = 2, quote_starts = 1},
		{kind = .Table, cells = [][]string{{"Header", "Header"}, {"Cell", "Cell"}}},
	}
	targets := []nendo.Id {
		nendo.id("MsgListItem", 0),
		nendo.id("MsgListItem", 16),
		nendo.id("MsgQuoteGroup", 32 * 128),
		nendo.id("MsgQuoteGroup", 48 * 128 + 1),
		nendo.id("MsgTableCell", 64 + 64),
	}
	for target in targets {
		for frame in 0 ..< 3 {
			box := nendo.element(target).rect
			nendo.set_pointer(
				frame == 1 ? nendo.Vector2{box.x + 2, box.y + 2} : nendo.Vector2{-100, -100},
				.Up,
			)
			nendo.begin()
			if nendo.box(nendo.id("HoverTest"))(
			{direction = .Column, width = nendo.fixed(500), gap = 3, color = CARD},
			) {md_blocks(hover_blocks, 0, true, 500)}
			commands := nendo.end(0)
			filled := false
			for cmd in commands {
				if cmd.id == target.id && cmd.kind == .Rectangle {
					filled = true
					color := cmd.rectangle.color
					testing.expect_value(t, color.a, f32(255))
					testing.expect(
						t,
						color.r < 65,
						"nested translucent themes stay close to the surface color",
					)
				}
			}
			testing.expect_value(t, filled, frame == 1)
			if frame == 1 && target == targets[3] {
				rl.BeginDrawing()
				render_nendo(commands)
				rl.TakeScreenshot("/tmp/wn-markdown-hover.png")
				rl.EndDrawing()
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
