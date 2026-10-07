package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import rl "sdlrl"

// The layout mode also renders screenshots and hovers wrapped link fragments.
// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=markdown_links
@(test)
markdown_links :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("/tmp", "wn-links-*", context.temp_allocator)
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
	source :: "[a **long label** with `code` and 日本語](https://example.com/path?q=1#part)\n\n# [Heading](https://example.com/heading)\n\n- [List label](https://example.com/list)\n\n| [Header](https://example.com/header) |\n| --- |\n| [Cell label](https://example.com/cell) |\n\n[unsafe](javascript:alert(1))\n\n`https://example.com/literal`"
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
	testing.expect_value(t, blocks[0].text, "a long label with code and 日本語")
	for block in blocks {
		for link in block.links {
			label := block.text[link.start:link.end]
			switch block.kind {
			case .Para:
				testing.expect_value(t, label, "a long label with code and 日本語")
				testing.expect_value(t, link.url, "https://example.com/path?q=1#part")
			case .Heading:
				testing.expect_value(t, label, "Heading")
				testing.expect_value(t, link.url, "https://example.com/heading")
			case .List_Item:
				testing.expect_value(t, label, "List label")
				testing.expect_value(t, link.url, "https://example.com/list")
			case .Code, .Quote, .Rule, .Table, .Image, .Math:
				testing.expect(t, false, "unexpected link block")
			}
		}
		if block.kind == .Table {
			for row, r in block.cell_links {
				for links, c in row {
					testing.expect_value(
						t,
						links[0].url,
						r == 0 ? "https://example.com/header" : "https://example.com/cell",
					)
					testing.expect_value(
						t,
						block.cells[r][c][links[0].start:links[0].end],
						r == 0 ? "Header" : "Cell label",
					)
				}
			}
		}
		if block.text == "unsafe" || strings.has_suffix(block.text, "/literal") {
			testing.expect_value(t, len(block.links), 0)
			for seg in inline_segs(block.text, block.fonts) {testing.expect_value(t, seg.url, "")}
		}
	}
	// Selected and wrapped pieces must retain their destination, even in code spans.
	link := blocks[0].links[0]
	for span in ([][2]int{{0, 6}, {7, 16}, {18, 22}, {26, len(blocks[0].text)}}) {
		segs := inline_segs(
			blocks[0].text[span[0]:span[1]],
			text_fonts(blocks[0].fonts, span[0], span[1]),
			blocks[0].links[:],
			span[0],
		)
		testing.expect_value(t, segs[0].url, link.url)
	}
	if #config(ODIN_TEST_NAMES, "") != "markdown_links" {return}
	rl.InitWindow(760, 650, "Markdown links")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes(); apply_theme(0, 0); init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {760, 650})
	defer delete(memory)
	ui: Ui_State
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; wrap_clear(); delete(sel_lines); sel_lines = nil
		delete(ui.link_url)}
	for width in ([]f32{700, 170}) {
		for frame in 0 ..< 3 {
			clear(&sel_lines)
			clay.BeginLayout()
			if clay.UI(clay.ID("LinksSmoke"))(
			{
				layout = {
					layoutDirection = .TopToBottom,
					sizing = {width = clay.SizingFixed(width + 40)},
					padding = clay.PaddingAll(20),
				},
			},
			) {md_blocks(blocks[:], 0, true, width)}
			commands := clay.EndLayout(0)
			if frame < 2 {continue}
			for cmd in commands.internalArray[:commands.length] {
				if cmd.commandType != .Text {continue}
				text := cmd.renderData.text.stringContents
				shown := string(text.chars[:text.length])
				if strings.contains(blocks[0].text, shown) &&
				   cmd.renderData.text.textColor == ACCENT {
					clay.SetPointerState(
						{
							cmd.boundingBox.x + cmd.boundingBox.width / 2,
							cmd.boundingBox.y + cmd.boundingBox.height / 2,
						},
						false,
					)
					link_hover = ""
					clay.BeginLayout()
					if clay.UI(clay.ID("LinksSmoke"))(
					{
						layout = {
							layoutDirection = .TopToBottom,
							sizing = {width = clay.SizingFixed(width + 40)},
							padding = clay.PaddingAll(20),
						},
					},
					) {md_blocks(blocks[:], 0, true, width)}
					commands = clay.EndLayout(0)
					testing.expect_value(t, link_hover, link.url)
					open_link(&ui, link_hover)
					testing.expect(t, ui.link_open)
					testing.expect_value(t, ui.link_url, link.url)
					break
				}
			}
			rl.BeginDrawing(); clay_raylib_render(&commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-markdown-links-%d.png", int(width)))
			rl.EndDrawing()
		}
	}
}
