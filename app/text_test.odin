// Line-level markdown parser checks.
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:testing"
import "core:sync"
import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
md_blank_lines :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	blocks := parse_md_text("first\n\nsecond\n\n\nthird")
	defer blocks_free(blocks)
	testing.expect_value(t, len(blocks), 3)
	for block, i in blocks { testing.expect_value(t, block.blank_lines_before, u8(i)) }
	inline: marmot.Markdown_Inline
	inline.tag = .TEXT
	inline.body.text.content = "paragraph"
	paragraph: marmot.Markdown_Block
	paragraph.tag = .PARAGRAPH
	paragraph.body.paragraph = {inlines = &inline, inlines_len = 1}
	raw := [3]marmot.Markdown_Block{paragraph, paragraph, paragraph}
	gaps := [3]u8{0, 1, 2}
	converted: [dynamic]Md_Block_Ui
	convert_blocks(&converted, raw_data(raw[:]), 3, false, gaps[:])
	defer blocks_free(converted)
	for block, i in converted { testing.expect_value(t, block.blank_lines_before, u8(i)) }

	rl.SetPixelScale(1)
	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	previous := clay.GetCurrentContext()
	defer clay.SetCurrentContext(previous)
	clay.Initialize(clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)), {240, 400}, {})
	clay.SetMeasureTextFunction(measure_text, nil)
	clay.BeginLayout()
	if clay.UI(clay.ID("ParagraphTest"))({layout = {layoutDirection = .TopToBottom}}) {
		md_blocks(blocks[:], 0)
		body_text(100, "first\n\nsecond", BODY_FS, TEXT)
	}
	clay.EndLayout(0)
	testing.expect(t, !clay.GetElementData(clay.ID("MdGap", 0)).found)
	for i in 1 ..< 3 {
		gap := clay.GetElementData(clay.ID("MdGap", u32(i) * 16))
		testing.expect(t, gap.found)
		testing.expect_value(t, gap.boundingBox.height, f32(i) * f32(BODY_FS))
	}
	testing.expect_value(t, clay.GetElementData(clay.ID("BodyLine", 802)).boundingBox.height, f32(BODY_FS))
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
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)

	rl.SetPixelScale(1)
	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	previous := clay.GetCurrentContext()
	defer clay.SetCurrentContext(previous)
	clay.Initialize(clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)), {240, 400}, {})
	clay.SetMeasureTextFunction(measure_text, nil)
	blocks := parse_md_text("- Answer questions and explain things and help you write or plan")
	defer delete(blocks[0].text)
	defer delete(blocks)
	clay.BeginLayout()
	md_blocks(blocks[:], 0, wrap_w = 200)
	commands := clay.EndLayout(0)
	marker := clay.GetElementData(clay.ID("MsgListMarker", 0)).boundingBox
	body := clay.GetElementData(clay.ID("MsgListBody", 0)).boundingBox
	testing.expect_value(t, marker.x, f32(12))
	testing.expect_value(t, body.x, marker.x + marker.width)
	lines := 0
	for command in commands.internalArray[:commands.length] {
		if command.commandType != .Text || command.boundingBox.x < body.x {
			continue
		}
		lines += 1
		testing.expect_value(t, command.boundingBox.x, body.x)
		testing.expect(t, command.boundingBox.x + command.boundingBox.width <= 200)
	}
	testing.expect(t, lines > 1, "long list items must wrap with a hanging indent")
}

@(test)
md_list_markers :: proc(t: ^testing.T) {
	inline: marmot.Markdown_Inline
	inline.tag = .TEXT
	inline.body.text.content = "Answer questions"
	paragraph: marmot.Markdown_Block
	paragraph.tag = .PARAGRAPH
	paragraph.body.paragraph = {inlines = &inline, inlines_len = 1}
	items := [2]marmot.Markdown_List_Item{
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
			list.body.list_block.kind.body.ordered = {start = 3, delimiter = "."}
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
