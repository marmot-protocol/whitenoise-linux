package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=message_excerpt_layout
@(test)
message_excerpt_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "message_excerpt_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(900, 700, "Message excerpt")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes()
	apply_theme(0, 0)
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {900, 700})
	defer delete(memory)
	ui: Ui_State
	ui.prefs.reduce_motion = true
	ui.prefs.tts_enabled = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; preview_close(); wrap_clear(); delete(sel_lines)
		sel_lines = nil}
	for text, i in ([]string{"1\n2\n3\n4\n5\n6", "1\n2\n3\n4\n5\n6\n7", strings.repeat("Wrapped text 👩🏽‍💻 with emoji. ", 100, context.temp_allocator)}) {
		clear(&sel_lines)
		clay.BeginLayout()
		if clay.UI(clay.ID("ExcerptTest"))(
		{layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(480)}}},
		) {
			testing.expect_value(t, message_excerpt(17, text, TEXT), i > 0)
		}
		clay.EndLayout(0)
		if i > 0 {
			testing.expect_value(t, len(sel_lines), MESSAGE_LINES)
			testing.expect(t, sel_lines[5].start + len(sel_lines[5].text) < len(text))
			testing.expect(t, clay.GetElementData(clay.ID("MessageMore", 17)).found)
		}
	}
	// The collapsed row must render parsed blocks, not the source markdown.
	font := [1]u8{FONT_TITLE}
	rows := []Md_Block_Ui {
		{kind = .Heading, text = "H6", level = 6},
		{kind = .Heading, text = "Setext heading", level = 1},
		{kind = .Para, text = "not a heading #hashtag mid-line"},
		{kind = .Quote, text = "blockquote"},
		{kind = .Quote, text = "nested blockquote"},
		{
			kind = .List_Item,
			text = "• bold",
			marker_len = len("• "),
			fonts = fmt.tprintf(
				"%s%s",
				strings.repeat("\x00", len("• "), context.temp_allocator),
				strings.repeat(string(font[:]), len("bold"), context.temp_allocator),
			),
		},
		{kind = .Para, text = "hidden tail"},
	}
	msg := Msg_Ui {
		id     = "markdown-excerpt",
		sender = "Sender",
		mine   = true,
		body   = "###### H6\nSetext heading\n===\nnot a heading #hashtag mid-line\n> blockquote\n>> nested blockquote\n- **bold**\nhidden tail",
	}
	defer delete(msg.blocks)
	for count in ([]int{6, 7}) {
		clear(&msg.blocks)
		append(&msg.blocks, ..rows[:count])
		for frame in 0 ..< 3 {
			clear(&sel_lines)
			clay.BeginLayout()
			if clay.UI(clay.ID("MarkdownExcerptTest"))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(600), height = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
				},
				backgroundColor = CARD,
			},
			) {message_row(2, msg)}
			commands := clay.EndLayout(0)
			if frame < 2 {continue}
			testing.expect_value(t, len(sel_lines), MESSAGE_LINES)
			testing.expect_value(
				t,
				clay.GetElementData(clay.ID("MessageMore", 2 * 4096)).found,
				count > MESSAGE_LINES,
			)
			testing.expect(t, clay.GetElementData(clay.ID("MsgQuoteBar", 2 * 4096 + 3 * 16)).found)
			for cmd in commands.internalArray[:commands.length] {
				if cmd.commandType != .Text {continue}
				data := cmd.renderData.text
				part := string(data.stringContents.chars[:data.stringContents.length])
				testing.expect(
					t,
					!strings.contains(part, "######") &&
					!strings.contains(part, "===") &&
					!strings.contains(part, "**") &&
					!strings.contains(part, "hidden tail"),
				)
				if part == "H6" ||
				   part == "Setext heading" ||
				   part == "bold" {testing.expect_value(t, data.fontId, u16(FONT_TITLE))}
			}
			rl.BeginDrawing()
			clay_raylib_render(&commands)
			rl.TakeScreenshot("/tmp/wn-markdown-excerpt.png")
			rl.EndDrawing()
		}
	}
	list := parse_md_text(
		"asked astra:\n\n• Jeff has related work, but I found no duplicate of #1961:\n\n" +
		"- #1955, still open: subscription failure isolation and recovery. Touches the same transport code, but doesn’t reuse sockets for outbound sends.\n\n" +
		"- #1120, merged July 26: reuses connections within KeyPackage deletion batches.\n\n" +
		"- #1635, merged September 3: reuses HTTP clients for media downloads.\n\n" +
		"Our group-message and push connection reuse remains distinct. #1955 is the one to coordinate with when merging.",
	)
	defer blocks_free(list)
	for limit in ([]int{MESSAGE_LINES, max(int)}) {
		clear(&sel_lines)
		clay.BeginLayout()
		if clay.UI(clay.ID("ListExcerptTest"))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingFixed(680)},
				padding = clay.PaddingAll(20),
				childGap = 3,
			},
			backgroundColor = BG,
		},
		) {
			cropped := md_blocks(list[:], 0, true, 640, limit)
			testing.expect_value(t, cropped, limit == MESSAGE_LINES)
			if cropped {message_more(0)}
		}
		commands := clay.EndLayout(0)
		testing.expect(
			t,
			!clay.GetElementData(clay.ID("MdGap", 32)).found,
			"the first list item follows its introduction without an extra spacer",
		)
		testing.expect(
			t,
			len(sel_lines) >= MESSAGE_LINES,
			"blank lines leave room for six text lines",
		)
		rl.BeginDrawing()
		clay_raylib_render(&commands)
		rl.TakeScreenshot(
			limit == MESSAGE_LINES ? "/tmp/wn-list-excerpt.png" : "/tmp/wn-list-full.png",
		)
		rl.EndDrawing()
	}
	text := fmt.tprintf(
		"%sTHE END",
		strings.repeat("A paragraph with **formatting**.\n\n", 100, context.temp_allocator),
	)
	blocks := parse_md_text(text)
	preview_message(text, blocks[:])
	blocks_free(blocks) // The popup must survive timeline refreshes.
	testing.expect_value(t, string(preview.bytes), text)
	testing.expect_value(t, len(preview.message_blocks), 101)
	for width in ([]i32{900, 360}) {
		rl.SetWindowSize(width, 700)
		clay.SetLayoutDimensions({f32(width), 700})
		for frame in 0 ..< 3 {
			clay.BeginLayout()
			if clay.UI(clay.ID("TestRoot"))(
			{
				layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}},
				backgroundColor = BG,
			},
			) {
				preview_modal(&ui)
			}
			commands := clay.EndLayout(0)
			box := clay.GetElementData(clay.ID("PvModal")).boundingBox
			testing.expect(t, clay.GetElementData(clay.ID("PvRead")).found)
			testing.expect(t, box.x >= 0 && box.x + box.width <= f32(width))
			testing.expect(t, box.height <= 700 * PV_MAX_HEIGHT)
			data := clay.GetScrollContainerData(clay.ID("PvScroll"))
			testing.expect(
				t,
				data.found &&
				data.contentDimensions.height > data.scrollContainerDimensions.height,
			)
			testing.expect_value(t, sel_lines[len(sel_lines) - 1].text, "THE END")
			rl.BeginDrawing()
			clay_raylib_render(&commands)
			rl.EndDrawing()
			if frame == 0 {continue}
			scroll_box := clay.GetElementData(clay.ID("PvScroll")).boundingBox
			thumb := clay.GetElementData(clay.ID("ScrollThumb", clay.ID("PvScroll").id))
			testing.expect(t, thumb.found)
			for line in sel_lines {
				line_box := clay.GetElementData(clay.ID("BodyLine", line.id)).boundingBox
				testing.expect(
					t,
					line_box.x + line_box.width <= thumb.boundingBox.x - 3,
					"text leaves a scrollbar gutter",
				)
			}
			clay.SetPointerState(
				{scroll_box.x + scroll_box.width / 2, scroll_box.y + scroll_box.height / 2},
				false,
			)
			before := data.scrollPosition.y
			clay.UpdateScrollContainers(false, {0, frame == 1 ? -3 : 3}, 1.0 / 60)
			testing.expect(
				t,
				frame == 1 ? data.scrollPosition.y < before : data.scrollPosition.y > before,
				"wheel over message scrolls the popup in both directions",
			)
		}
	}
	rl.TakeScreenshot("/tmp/wn-message-popup.png")
}
