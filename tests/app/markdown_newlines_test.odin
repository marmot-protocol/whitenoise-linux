package main

import marmot "../marmot"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "nendo"
import rl "sdlrl"

@(test)
markdown_newlines :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("/tmp", "wn-newlines-*", context.temp_allocator)
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
	source :: `Engine issues filed:
#1 31 relative doc links point outside the repo and 404 on the forge: https://git.rctngl.lol/rctngl/engine/issues/1
#2 build the CI test image once and push it to the forge registry: https://git.rctngl.lol/rctngl/engine/issues/2
#3 CI never runs just punch or the VM suite; proposal for a nightly KVM job: https://git.rctngl.lol/rctngl/engine/issues/3
#4 rectangle should wait for POLLOUT after EAGAIN, not the next QUIC deadline: https://git.rctngl.lol/rctngl/engine/issues/4
#5 triangle.service restarts every 15s when idle (about 5,700 a day): https://git.rctngl.lol/rctngl/engine/issues/5
#6 root README should say what the repo holds and link docs/README.md: https://git.rctngl.lol/rctngl/engine/issues/6
The doc links and CI ones are mine; the rest are yours.`
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
	testing.expect_value(t, blocks[0].text, source)
	if #config(ODIN_TEST_NAMES, "") != "markdown_newlines" {return}
	rl.InitWindow(1500, 650, "Markdown newlines")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes(); apply_theme(0, 0); init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1500, 650})
	defer delete(memory)
	ui: Ui_State
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; wrap_clear(); delete(sel_lines); sel_lines = nil}
	for width in ([]f32{1460, 480}) {
		for frame in 0 ..< 3 {
			clear(&sel_lines)
			nendo.begin()
			if nendo.box(nendo.id("NewlinesSmoke"))(
			{direction = .Column, width = nendo.fixed(width + 40), padding = nendo.pad(20)},
			) {
				md_blocks(blocks[:], 0, true, width)
			}
			commands := nendo.end(0)
			if frame < 2 {continue}
			starts := 0
			last_y := f32(-1)
			for cmd in commands {
				if cmd.kind != .Text {continue}
				text := cmd.text.text
				shown := text
				testing.expect(
					t,
					cmd.rect.x + cmd.rect.width <= width + 20.1,
					"text stays inside the message",
				)
				if strings.has_prefix(shown, "#") || strings.has_prefix(shown, "The doc links") {
					testing.expect_value(t, cmd.rect.x, f32(20))
					testing.expect(
						t,
						cmd.rect.y > last_y,
						"each source line starts below the preceding line",
					)
					last_y = cmd.rect.y
					starts += 1
				}
			}
			testing.expect_value(t, starts, 7)
			rl.BeginDrawing(); render_nendo(commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-markdown-newlines-%d.png", int(width)))
			rl.EndDrawing()
		}
	}
}
