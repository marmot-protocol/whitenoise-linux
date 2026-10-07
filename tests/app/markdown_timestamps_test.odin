package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import rl "sdlrl"

@(test)
markdown_timestamps :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("/tmp", "wn-timestamps-*", context.temp_allocator)
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
	source :: "**[Before <t:120:R> after](https://example.com/time)** then [next](https://example.com/next)\n\n# <t:-1:F>\n\n- <t:120:R>\n\n| <t:120:R> | untouched |\n| --- | --- |\n| [<t:120:R>](https://example.com/table) | <t:0:d> |\n\n`<t:120:R>` \\<t:120:R> <t:120:Q> <t:9223372036854775808>\n\n<t:9223372036854775807:F> <t:-9223372036854775808:F>"
	doc: ^marmot.Markdown_Document
	if !testing.expect_value(
		t,
		marmot.parse_markdown(client, source, &doc),
		marmot.Status.OK,
	) {return}
	blocks: [dynamic]Md_Block_Ui
	convert_blocks(&blocks, doc.blocks, doc.blocks_len, false)
	marmot.markdown_document_free(doc)
	defer blocks_free(blocks)
	future := timestamp_block(blocks[0], 0)
	past := timestamp_block(blocks[0], 240)
	testing.expect_value(t, future.text, "Before \uf017 in 2 minutes after then next")
	testing.expect_value(t, past.text, "Before \uf017 2 minutes ago after then next")
	testing.expect_value(
		t,
		future.text[future.links[1].start:future.links[1].end],
		"\uf017 in 2 minutes",
	)
	for run in future.links[:3] {testing.expect_value(t, run.url, "https://example.com/time")}
	testing.expect_value(t, past.text[past.links[3].start:past.links[3].end], "next")
	testing.expect_value(t, past.links[3].url, "https://example.com/next")
	testing.expect_value(t, text_font(future.fonts, len("Before ")), u16(FONT_ICON))
	testing.expect_value(t, text_font(future.fonts, len("Before \uf017 ")), u16(FONT_TITLE))
	testing.expect(
		t,
		future.links[0].stamp == nil && future.links[2].stamp == nil,
		"surrounding link text has no timestamp tooltip",
	)
	testing.expect_value(t, future.links[1].stamp.seconds, i64(120))
	testing.expect_value(t, blocks[0].text, "Before <t:120:R> after then next")
	list := timestamp_block(blocks[2], 0)
	testing.expect_value(t, list.text[list.marker_len:], "\uf017 in 2 minutes")
	table := timestamp_block(blocks[3], 240)
	testing.expect_value(t, table.cells[0][0], "\uf017 2 minutes ago")
	testing.expect_value(t, table.cells[0][1], "untouched")
	testing.expect_value(t, table.cells[1][0], "\uf017 2 minutes ago")
	testing.expect_value(t, table.cell_links[1][0][0].end, len("\uf017 2 minutes ago"))
	testing.expect_value(
		t,
		blocks[4].text,
		"<t:120:R> <t:120:R> <t:120:Q> <t:9223372036854775808>",
	)
	testing.expect_value(t, len(blocks[4].timestamps), 0)
	testing.expect_value(
		t,
		timestamp_block(blocks[5], 0).text,
		"\uf017 <t:9223372036854775807:F> \uf017 <t:-9223372036854775808:F>",
	)
	// Preview owns its spans after the original message is freed or replaced.
	preview_message("", blocks[:])
	preview_label := timestamp_block(preview.message_blocks[0], 240)
	testing.expect_value(t, preview_label.text, past.text)
	preview_close()
	if !testing.expect_value(
		t,
		marmot.parse_markdown(
			client,
			"before <t:120:R> https://example.com/image.png after <t:120:R>",
			&doc,
		),
		marmot.Status.OK,
	) {return}
	image_blocks: [dynamic]Md_Block_Ui
	convert_blocks(&image_blocks, doc.blocks, doc.blocks_len, false)
	marmot.markdown_document_free(doc)
	nev_split_images(&image_blocks)
	defer blocks_free(image_blocks)
	testing.expect_value(t, timestamp_block(image_blocks[0], 0).text, "before \uf017 in 2 minutes")
	testing.expect_value(t, image_blocks[1].kind, Md_Kind.Image)
	testing.expect_value(
		t,
		timestamp_block(image_blocks[2], 240).text,
		"after \uf017 2 minutes ago",
	)
	if #config(ODIN_TEST_NAMES, "") != "markdown_timestamps" {return}

	smoke_source :: "# Local timestamps\n\nt: <t:1791280800:t> / T: <t:1791280800:T>\n\nd: <t:1791280800:d> / D: <t:1791280800:D>\n\nf: <t:1791280800:f>\n\nF: <t:1791280800:F>\n\ns: <t:1791280800:s> / S: <t:1791280800:S>\n\nR: <t:1791280800:R>\n\n- **[<t:1791280800:R>](https://example.com/time)**\n\n| <t:1791280800:F> | <t:1791280800:R> |\n| --- | --- |\n| <t:-1:F> | <t:1791280800:t> |"
	if !testing.expect_value(
		t,
		marmot.parse_markdown(client, smoke_source, &doc),
		marmot.Status.OK,
	) {return}
	smoke_blocks: [dynamic]Md_Block_Ui
	convert_blocks(&smoke_blocks, doc.blocks, doc.blocks_len, false)
	marmot.markdown_document_free(doc)
	defer blocks_free(smoke_blocks)

	// Render the actual Clay/SDL surface, including selection and narrow wrapping.
	rl.InitWindow(760, 1100, "Markdown timestamps")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes(); apply_theme(0, 0); init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {760, 1100})
	defer delete(memory)
	ui: Ui_State
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; wrap_clear(); delete(sel_lines); sel_lines = nil}
	for width in ([]f32{700, 220}) {
		clay.SetPointerState({-100, -100}, false)
		for frame in 0 ..< 3 {
			commands := timestamp_smoke_frame(smoke_blocks[:], width)
			if frame < 2 {continue}
			for line in sel_lines {testing.expect(t, !strings.contains(line.block_text, "<t:"), "selection contains the formatted label")}
			rl.BeginDrawing(); clay_raylib_render(&commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-markdown-timestamps-%d.png", int(width)))
			rl.EndDrawing()
			clocks := make([dynamic]clay.Vector2, context.temp_allocator)
			wrapped := make([dynamic]clay.Vector2, context.temp_allocator)
			plain: clay.Vector2
			for cmd in commands.internalArray[:commands.length] {
				if cmd.commandType != .Text {continue}
				text := cmd.renderData.text.stringContents
				shown := string(text.chars[:text.length])
				point := clay.Vector2 {
					cmd.boundingBox.x + cmd.boundingBox.width / 2,
					cmd.boundingBox.y + cmd.boundingBox.height / 2,
				}
				if shown == "\uf017" {append(&clocks, point)}
				if width == 220 && strings.contains(shown, "2026") {append(&wrapped, point)}
				if shown == "R: " {plain = point}
			}
			styles := []string {
				"t",
				"T",
				"d",
				"D",
				"f",
				"F",
				"s",
				"S",
				"R",
				"R",
				"F",
				"R",
				"F",
				"t",
			}
			if !testing.expect_value(t, len(clocks), len(styles)) {return}
			for point, i in clocks {
				clay.SetPointerState({-100, -100}, false)
				commands = timestamp_smoke_frame(smoke_blocks[:], width)
				clay.SetPointerState(point, false)
				link_hover = ""
				commands = timestamp_smoke_frame(smoke_blocks[:], width)
				seconds := i == 12 ? i64(-1) : i64(1791280800)
				expected := fmt.tprintf(
					"%s\n<t:%d:%s>",
					timestamp_label(seconds, .LONG_DATE_TIME, 0),
					seconds,
					styles[i],
				)
				testing.expect_value(t, timestamp_smoke_tip(commands), expected)
				if i == 9 {testing.expect_value(t, link_hover, "https://example.com/time")}
			}
			for point in wrapped {
				clay.SetPointerState({-100, -100}, false)
				commands = timestamp_smoke_frame(smoke_blocks[:], width)
				clay.SetPointerState(point, false)
				commands = timestamp_smoke_frame(smoke_blocks[:], width)
				testing.expect(
					t,
					strings.contains(timestamp_smoke_tip(commands), "<t:1791280800:"),
					"wrapped date fragments retain their tooltip",
				)
			}
			rl.BeginDrawing(); clay_raylib_render(&commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-markdown-timestamps-hover-%d.png", int(width)))
			rl.EndDrawing()
			clay.SetPointerState({-100, -100}, false)
			commands = timestamp_smoke_frame(smoke_blocks[:], width)
			clay.SetPointerState(plain, false)
			commands = timestamp_smoke_frame(smoke_blocks[:], width)
			testing.expect_value(t, timestamp_smoke_tip(commands), "")
		}
	}
}

@(private)
timestamp_smoke_frame :: proc(
	blocks: []Md_Block_Ui,
	width: f32,
) -> clay.ClayArray(clay.RenderCommand) {
	clear(&sel_lines)
	clay.BeginLayout()
	if clay.UI(clay.ID("TimestampSmoke"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(width + 40)},
			padding = clay.PaddingAll(20),
			childGap = 5,
		},
		backgroundColor = CARD,
	},
	) {
		md_blocks(blocks, 0, true, width)
	}
	return clay.EndLayout(0)
}

@(private)
timestamp_smoke_tip :: proc(commands: clay.ClayArray(clay.RenderCommand)) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for cmd in commands.internalArray[:commands.length] {
		if cmd.commandType != .Text || cmd.zIndex != 18 {continue}
		text := cmd.renderData.text.stringContents
		shown := string(text.chars[:text.length])
		if strings.builder_len(builder) > 0 {strings.write_byte(&builder, '\n')}
		strings.write_string(&builder, shown)
	}
	return strings.to_string(builder)
}

@(test)
timestamp_relative_boundaries :: proc(t: ^testing.T) {
	testing.expect_value(t, timestamp_label(59, .RELATIVE, 0), "in 59 seconds")
	testing.expect_value(t, timestamp_label(60, .RELATIVE, 0), "in 1 minute")
	testing.expect_value(t, timestamp_label(0, .RELATIVE, 3600), "1 hour ago")
	testing.expect_value(t, timestamp_label(0, .RELATIVE, 86400), "1 day ago")
	testing.expect_value(
		t,
		timestamp_label(max(i64), .RELATIVE, min(i64)),
		"in 584942417355 years",
	)
	testing.expect_value(
		t,
		timestamp_label(min(i64), .RELATIVE, max(i64)),
		"584942417355 years ago",
	)
}
