package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "nendo"
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
	ui.prefs.message_lines = DEFAULT_MESSAGE_LINES
	ui.prefs.reduce_motion = true
	ui.prefs.tts_enabled = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; preview_close(); wrap_clear(); delete(sel_lines)
		sel_lines = nil}
	for text, i in ([]string{"1\n2\n3\n4\n5\n6", "1\n2\n3\n4\n5\n6\n7", strings.repeat("Wrapped text 👩🏽‍💻 with emoji. ", 100, context.temp_allocator)}) {
		clear(&sel_lines)
		nendo.begin()
		if nendo.box(nendo.id("ExcerptTest"))({direction = .Column, width = nendo.fixed(480)}) {
			testing.expect_value(t, message_excerpt(17, text, TEXT), i > 0)
		}
		nendo.end(0)
		if i > 0 {
			testing.expect_value(t, len(sel_lines), DEFAULT_MESSAGE_LINES)
			testing.expect(t, sel_lines[5].start + len(sel_lines[5].text) < len(text))
			testing.expect(t, nendo.element(nendo.id("MessageMore", 17)).found)
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
			nendo.begin()
			if nendo.box(nendo.id("MarkdownExcerptTest"))(
			{width = nendo.fixed(600), height = nendo.grow(), direction = .Column, color = CARD},
			) {message_row(2, msg)}
			commands := nendo.end(0)
			if frame < 2 {continue}
			testing.expect_value(t, len(sel_lines), DEFAULT_MESSAGE_LINES)
			testing.expect_value(
				t,
				nendo.element(nendo.id("MessageMore", 2 * 4096)).found,
				count > DEFAULT_MESSAGE_LINES,
			)
			testing.expect(t, nendo.element(nendo.id("MsgQuoteBar", 2 * 4096 + 3 * 16)).found)
			for cmd in commands {
				if cmd.kind != .Text {continue}
				data := cmd.text
				part := data.text
				testing.expect(
					t,
					!strings.contains(part, "######") &&
					!strings.contains(part, "===") &&
					!strings.contains(part, "**") &&
					!strings.contains(part, "hidden tail"),
				)
				if part == "H6" ||
				   part == "Setext heading" ||
				   part == "bold" {testing.expect_value(t, data.font, u16(FONT_TITLE))}
			}
			rl.BeginDrawing()
			render_nendo(commands)
			rl.TakeScreenshot("/tmp/wn-markdown-excerpt.png")
			rl.EndDrawing()
		}
	}
	// Expand and collapse both body renderers, including reduced motion.
	for width in ([]f32{280, 700}) {
		for markdown in ([]bool{false, true}) {
			for reduced in ([]bool{false, true}) {
				ui.prefs.reduce_motion = reduced
				state: Excerpt
				closed, full, previous: f32
				steps := [4]time.Duration{0, 25, 50, 100}
				for frame in 0 ..< 9 {
					if frame == 1 || frame == 5 {excerpt_toggle(&state, 99)}
					if frame > 0 {
						elapsed := steps[(frame - 1) % 4] * time.Millisecond
						state.changed = time.tick_add(time.tick_now(), -elapsed)
					}
					clear(&sel_lines)
					anim_tick(0.025)
					nendo.begin()
					if nendo.box(nendo.id("ExpandTest"))(
					{direction = .Column, width = nendo.fixed(width)},
					) {
						blocks := markdown ? rows[:] : nil
						testing.expect(
							t,
							excerpt_body(
								99,
								"1\n2\n3\n4\n5\n6\n7\n8\n9\n10",
								blocks,
								state,
								width,
								TEXT,
							),
						)
						message_more(99, state)
					}
					commands := nendo.end(0)
					nendo.update_scroll(.Off, {}, 0.025)
					height := nendo.element(nendo.id("ExcerptClip", 99)).rect.height
					if frame == 0 {closed = height}
					if frame == 1 {full = nendo.element(nendo.id("ExcerptBody", 99)).rect.height}
					if frame == 2 || frame == 3 {
						testing.expect(t, height >= previous && height > closed)
						testing.expect(
							t,
							reduced || height < full,
							"expansion has intermediate heights",
						)
					}
					if frame == 4 ||
					   reduced && frame > 0 && frame < 5 {testing.expect_value(t, height, full)}
					if frame == 6 || frame == 7 {
						testing.expect(t, height <= previous && height < full)
						testing.expect(
							t,
							reduced || height > closed,
							"collapse has intermediate heights",
						)
					}
					if frame == 8 ||
					   reduced && frame >= 5 {testing.expect_value(t, height, closed)}
					testing.expect_value(t, preview.kind, Preview_Kind.None)
					if markdown &&
					   !reduced &&
					   width == 700 &&
					   (frame == 2 || frame == 4 || frame == 8) {
						rl.BeginDrawing()
						render_nendo(commands)
						rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-excerpt-%d.png", frame))
						rl.EndDrawing()
					}
					previous = height
				}
			}
		}
	}
	// Thresholds include the exact boundary and 0, even with an old toggle in flight.
	for markdown in ([]bool{false, true}) {
		for threshold in ([]int{1, 3, 6, 7, 8, 0}) {
			ui.prefs.message_lines = threshold
			ui.prefs.reduce_motion = true
			state: Excerpt
			if threshold == 0 {state = {
					expanded = true,
					changed  = time.tick_now(),
				}; ui.prefs.reduce_motion = false}
			clear(&sel_lines)
			nendo.begin()
			if nendo.box(nendo.id("ThresholdTest"))(
			{direction = .Column, width = nendo.fixed(700)},
			) {
				if markdown {
					if excerpt_body(99, "", rows[:], state, 700, TEXT) {message_more(99, state)}
				} else if !message_excerpt(99, "1\n2\n3\n4\n5\n6\n7", TEXT, state) {
					body_text(99, "1\n2\n3\n4\n5\n6\n7", BODY_FS, TEXT, true)
				}
			}
			commands := nendo.end(0)
			cropped := threshold > 0 && threshold < 7
			testing.expect_value(t, len(sel_lines), cropped ? threshold : 7)
			testing.expect_value(t, nendo.element(nendo.id("MessageMore", 99)).found, cropped)
			if threshold == 0 {
				testing.expect_value(
					t,
					sel_lines[len(sel_lines) - 1].text,
					markdown ? "hidden tail" : "7",
				)
				rl.BeginDrawing()
				render_nendo(commands)
				rl.TakeScreenshot(
					markdown ? "/tmp/wn-unlimited-markdown.png" : "/tmp/wn-unlimited-plain.png",
				)
				rl.EndDrawing()
			}
		}
	}
	ui.prefs.message_lines = DEFAULT_MESSAGE_LINES
	ui.prefs.reduce_motion = true
	list := parse_md_text(
		"asked astra:\n\n• Jeff has related work, but I found no duplicate of #1961:\n\n" +
		"- #1955, still open: subscription failure isolation and recovery. Touches the same transport code, but doesn’t reuse sockets for outbound sends.\n\n" +
		"- #1120, merged July 26: reuses connections within KeyPackage deletion batches.\n\n" +
		"- #1635, merged September 3: reuses HTTP clients for media downloads.\n\n" +
		"Our group-message and push connection reuse remains distinct. #1955 is the one to coordinate with when merging.",
	)
	defer blocks_free(list)
	for limit in ([]int{DEFAULT_MESSAGE_LINES, max(int)}) {
		clear(&sel_lines)
		nendo.begin()
		if nendo.box(nendo.id("ListExcerptTest"))(
		{
			direction = .Column,
			width = nendo.fixed(680),
			padding = nendo.pad(20),
			gap = 3,
			color = BG,
		},
		) {
			cropped := md_blocks(list[:], 0, true, 640, limit)
			testing.expect_value(t, cropped, limit == DEFAULT_MESSAGE_LINES)
			if cropped {message_more(0)}
		}
		commands := nendo.end(0)
		testing.expect(
			t,
			!nendo.element(nendo.id("MdGap", 32)).found,
			"the first list item follows its introduction without an extra spacer",
		)
		testing.expect(
			t,
			len(sel_lines) >= DEFAULT_MESSAGE_LINES,
			"blank lines leave room for six text lines",
		)
		rl.BeginDrawing()
		render_nendo(commands)
		rl.TakeScreenshot(
			limit == DEFAULT_MESSAGE_LINES ? "/tmp/wn-list-excerpt.png" : "/tmp/wn-list-full.png",
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
		nendo.set_dimensions({f32(width), 700})
		for frame in 0 ..< 3 {
			nendo.begin()
			if nendo.box(nendo.id("TestRoot"))(
			{width = nendo.grow(), height = nendo.grow(), color = BG},
			) {
				preview_modal(&ui)
			}
			commands := nendo.end(0)
			box := nendo.element(nendo.id("PvModal")).rect
			testing.expect(t, nendo.element(nendo.id("PvRead")).found)
			testing.expect(t, box.x >= 0 && box.x + box.width <= f32(width))
			testing.expect(t, box.height <= 700 * PV_MAX_HEIGHT)
			data := nendo.scroll(nendo.id("PvScroll"))
			testing.expect(t, data.found && data.content.height > data.viewport.height)
			testing.expect_value(t, sel_lines[len(sel_lines) - 1].text, "THE END")
			rl.BeginDrawing()
			render_nendo(commands)
			rl.EndDrawing()
			if frame == 0 {continue}
			scroll_box := nendo.element(nendo.id("PvScroll")).rect
			thumb := nendo.element(nendo.id("ScrollThumb", nendo.id("PvScroll").id))
			testing.expect(t, thumb.found)
			for line in sel_lines {
				line_box := nendo.element(nendo.id("BodyLine", line.id)).rect
				testing.expect(
					t,
					line_box.x + line_box.width <= thumb.rect.x - 3,
					"text leaves a scrollbar gutter",
				)
			}
			nendo.set_pointer(
				{scroll_box.x + scroll_box.width / 2, scroll_box.y + scroll_box.height / 2},
				.Up,
			)
			before := data.position.y
			nendo.update_scroll(.Off, {0, frame == 1 ? -3 : 3}, 1.0 / 60)
			testing.expect(
				t,
				frame == 1 ? data.position.y < before : data.position.y > before,
				"wheel over message scrolls the popup in both directions",
			)
		}
	}
	rl.TakeScreenshot("/tmp/wn-message-popup.png")
}
