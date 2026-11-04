// Line-level markdown parser checks.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import marmot "../marmot"
import "core:sync"
import "core:testing"
import "nendo"
import rl "sdlrl"

@(test)
md_blank_lines :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)
	blocks := parse_md_text("first\n\nsecond\n\n\nthird")
	defer blocks_free(blocks)
	testing.expect_value(t, len(blocks), 3)
	for block, i in blocks {testing.expect_value(t, block.blank_lines_before, u8(i))}
	span: marmot.Markdown_Inline
	span.tag = .TEXT
	span.body.text.content = "paragraph"
	paragraph: marmot.Markdown_Block
	paragraph.tag = .PARAGRAPH
	paragraph.body.paragraph = {
		inlines     = &span,
		inlines_len = 1,
	}
	raw := [3]marmot.Markdown_Block{paragraph, paragraph, paragraph}
	gaps := [3]u8{0, 1, 2}
	converted: [dynamic]Md_Block_Ui
	convert_blocks(&converted, raw_data(raw[:]), 3, false, gaps[:])
	defer blocks_free(converted)
	for block, i in converted {testing.expect_value(t, block.blank_lines_before, u8(i))}

	rl.SetPixelScale(1)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer delete(memory)
	previous := nendo.current_context()
	defer nendo.set_context(previous)
	nendo.init(memory, {240, 400}, {})
	nendo.set_measure_text(measure_text, nil)
	nendo.begin()
	if nendo.box(nendo.id("ParagraphTest"))({direction = .Column}) {
		testing.expect(
			t,
			!md_blocks(blocks[:], 0, max_lines = 3),
			"spacing does not truncate text",
		)
		body_text(100, "first\n\nsecond", BODY_FS, TEXT)
	}
	nendo.end(0)
	testing.expect(t, !nendo.element(nendo.id("MdGap", 0)).found)
	for i in 1 ..< 3 {
		gap := nendo.element(nendo.id("MdGap", u32(i) * 16))
		testing.expect(t, gap.found)
		testing.expect_value(t, gap.rect.height, f32(i) * f32(BODY_FS) / 2)
	}
	testing.expect_value(t, nendo.element(nendo.id("BodyLine", 802)).rect.height, f32(BODY_FS))
	joined := parse_md_text("first\nsecond")
	defer blocks_free(joined)
	testing.expect_value(t, len(joined), 1)
	testing.expect_value(t, joined[0].text, "first second")
	testing.expect_value(t, joined[0].blank_lines_before, u8(0))
}

@(test)
md_text_parse :: proc(t: ^testing.T) {
	src := "# Title\n\nHello\nworld\n\n- one\n- two\n\n```\ncode here\n```\n> quoted\n---\n"
	blocks := parse_md_text(src)
	defer delete(blocks)

	testing.expect_value(t, len(blocks), 7)
	testing.expect_value(t, blocks[0].kind, Md_Kind.Heading)
	testing.expect_value(t, blocks[0].level, 1)
	testing.expect_value(t, blocks[1].kind, Md_Kind.Para)
	testing.expect_value(t, blocks[1].text, "Hello world") // joined lines
	testing.expect_value(t, blocks[2].kind, Md_Kind.List_Item)
	testing.expect_value(t, blocks[2].text, "• one")
	testing.expect_value(t, blocks[2].marker_len, len("• "))
	testing.expect_value(t, blocks[4].kind, Md_Kind.Code)
	testing.expect_value(t, blocks[4].text, "code here")
	testing.expect_value(t, blocks[5].kind, Md_Kind.Quote)
	testing.expect_value(t, blocks[6].kind, Md_Kind.Rule)

	// Unclosed fence still yields its code block.
	open_fence := parse_md_text("```\ndangling")
	defer delete(open_fence)
	testing.expect_value(t, len(open_fence), 1)
	testing.expect_value(t, open_fence[0].kind, Md_Kind.Code)
}

@(test)
md_list_layout :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)

	rl.SetPixelScale(1)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer delete(memory)
	previous := nendo.current_context()
	defer nendo.set_context(previous)
	nendo.init(memory, {240, 400}, {})
	nendo.set_measure_text(measure_text, nil)
	blocks := parse_md_text(
		"- Answer questions and explain things and help you write or plan\n\n- Next item\n\n\n- Separate item",
	)
	defer blocks_free(blocks)
	nendo.begin()
	if nendo.box(nendo.id("ListTest"))(
	{direction = .Column, gap = 3},
	) {md_blocks(blocks[:], 0, wrap_w = 200)}
	commands := nendo.end(0)
	marker := nendo.element(nendo.id("MsgListMarker", 0)).rect
	body := nendo.element(nendo.id("MsgListBody", 0)).rect
	testing.expect_value(t, marker.x, f32(12))
	testing.expect_value(
		t,
		marker.width,
		max(f32(12), rl.MeasureTextLine(FONT_BODY, BODY_FS, "• ", 0).x),
	)
	testing.expect_value(t, body.x, marker.x + marker.width)
	first := nendo.element(nendo.id("MsgListItem", 0)).rect
	next := nendo.element(nendo.id("MsgListItem", 16)).rect
	testing.expect_value(t, next.y, first.y + first.height + 3)
	testing.expect(t, !nendo.element(nendo.id("MdGap", 16)).found)
	testing.expect_value(t, nendo.element(nendo.id("MdGap", 32)).rect.height, f32(BODY_FS) / 2)
	lines := 0
	for command in commands {
		if command.kind != .Text || command.rect.x < body.x {
			continue
		}
		lines += 1
		testing.expect_value(t, command.rect.x, body.x)
		testing.expect(t, command.rect.x + command.rect.width <= 200)
	}
	testing.expect(t, lines > 1, "long list items must wrap with a hanging indent")
}

@(test)
md_list_markers :: proc(t: ^testing.T) {
	span: marmot.Markdown_Inline
	span.tag = .TEXT
	span.body.text.content = "Answer questions"
	paragraph: marmot.Markdown_Block
	paragraph.tag = .PARAGRAPH
	paragraph.body.paragraph = {
		inlines     = &span,
		inlines_len = 1,
	}
	items := [2]marmot.Markdown_List_Item {
		{blocks = &paragraph, blocks_len = 1},
		{blocks = &paragraph, blocks_len = 1},
	}
	list: marmot.Markdown_Block
	list.tag = .LIST_BLOCK
	list.body.list_block.items = &items[0]
	list.body.list_block.items_len = 2
	markers := [3][2]string{{"• ", "• "}, {"3. ", "4. "}, {"[ ] ", "[x] "}}
	for expected, i in markers {
		if i == 1 {
			list.body.list_block.kind.tag = 1
			list.body.list_block.kind.body.ordered = {
				start     = 3,
				delimiter = ".",
			}
		}
		if i == 2 {
			items[0].has_checked = true
			items[1].has_checked = true
			items[1].checked = true
		}
		blocks: [dynamic]Md_Block_Ui
		convert_blocks(&blocks, &list, 1, false)
		testing.expect_value(t, len(blocks), 2)
		for block, j in blocks {
			testing.expect_value(t, block.kind, Md_Kind.List_Item)
			testing.expect_value(t, block.text[:block.marker_len], expected[j])
			testing.expect_value(t, block.text[block.marker_len:], "Answer questions")
			delete(block.text)
		}
		delete(blocks)
	}
}
