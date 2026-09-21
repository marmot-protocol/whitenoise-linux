package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=history_layout
@(test)
history_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "history_layout" {return}
	context.allocator = runtime.default_context().allocator
	dir, err := os.make_directory_temp("/tmp", "wn-history-*", context.temp_allocator)
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
	rl.InitWindow(600, 600, "History")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes()
	apply_theme(0, 0)
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {600, 600})
	defer delete(memory)
	ui: Ui_State
	ui.prefs.reduce_motion = true
	ui.hist_original = true
	ui.hist_changes = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil
		for v in ui.hist_versions {delete(v.at); delete(v.text); blocks_free(v.blocks)}
		delete(ui.hist_versions); delete(ui.nicknames); wrap_clear()}
	token := strings.fields(TEST_MENTIONS)[0]
	ui.nicknames[mention_hex(token)] = "Danny"
	text := "do you want me to take a look at the CI runner? I managed to speed up the mdk one, I can probably do something for android too"
	append(&ui.hist_versions, history_version(client, 0, text))
	append(&ui.hist_versions, history_version(client, 60, fmt.tprintf("%s %s", token, text)))
	append(
		&ui.hist_versions,
		history_version(
			client,
			120,
			fmt.tprintf("%s %s", token, strings.repeat("longword", 40, context.temp_allocator)),
		),
	)
	for width in ([]i32{600, 320}) {
		rl.SetWindowSize(width, 600)
		clay.SetLayoutDimensions({f32(width), 600})
		for frame in 0 ..< 3 {
			anim_tick(1.0 / 60)
			open_now(clay.ID("HistModal"), true)
			clay.BeginLayout()
			if clay.UI(clay.ID("HistoryTest"))(
			{
				layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}},
				backgroundColor = BG,
			},
			) {edit_history_modal(&ui)}
			commands := clay.EndLayout(0)
			if frame < 2 {continue}
			modal := clay.GetElementData(clay.ID("HistModal")).boundingBox
			scroll := clay.GetElementData(clay.ID("HistScroll")).boundingBox
			testing.expect(t, modal.x >= 0 && modal.x + modal.width <= f32(width))
			for i in 0 ..< len(ui.hist_versions) {
				row := clay.GetElementData(clay.ID("HistRow", u32(i))).boundingBox
				testing.expect(
					t,
					row.x + row.width <= scroll.x + scroll.width - f32(HISTORY_GUTTER) + 0.1,
				)
			}
			mentions := 0
			for cmd in commands.internalArray[:commands.length] {
				if cmd.commandType != .Text {continue}
				data := cmd.renderData.text.stringContents
				shown := string(data.chars[:data.length])
				if shown == "@Danny" {mentions += 1}
				testing.expect(t, !strings.contains(shown, "npub1"))
				testing.expect(
					t,
					cmd.boundingBox.x + cmd.boundingBox.width <= modal.x + modal.width - 16 + 0.1,
					shown,
				)
			}
			testing.expect_value(t, mentions, 2)
			rl.BeginDrawing()
			clay_raylib_render(&commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-history-%d.png", width))
			rl.EndDrawing()
		}
	}
	for v in ui.hist_versions {delete(v.at); delete(v.text); blocks_free(v.blocks)}
	clear(&ui.hist_versions)
	ui.hist_changes = false
	source := "## Heading\n\n**bold** and `code` with $x^2$.\n\n- item\n  - nested\n\n> quote\n\n| A | B |\n|---|---|\n| one | two |\n\n```python\nprint(1)\n```"
	append(&ui.hist_versions, history_version(client, 0, source))
	updated, _ := strings.replace_all(source, "bold", "updated", context.temp_allocator)
	append(&ui.hist_versions, history_version(client, 60, updated))
	for width in ([]i32{600, 320}) {
		rl.SetWindowSize(width, 600)
		clay.SetLayoutDimensions({f32(width), 600})
		for frame in 0 ..< 3 {
			anim_tick(1.0 / 60)
			clay.BeginLayout()
			if clay.UI(clay.ID("HistoryTest"))(
			{
				layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}},
				backgroundColor = BG,
			},
			) {edit_history_modal(&ui)}
			commands := clay.EndLayout(0)
			if frame < 2 {continue}
			for version, i in ui.hist_versions {
				testing.expect(t, len(version.blocks) > 0)
				for block, j in version.blocks {
					id := 0xD0000 + u32(i) * 0x10000 + u32(j) * 16
					#partial switch block.kind {
					case .Heading:
						testing.expect(t, clay.GetElementData(clay.ID("MdHeading", id)).found)
					case .List_Item:
						testing.expect(t, clay.GetElementData(clay.ID("MsgListItem", id)).found)
					case .Table:
						testing.expect(t, clay.GetElementData(clay.ID("MsgTable", id)).found)
					case .Code:
						testing.expect(t, clay.GetElementData(clay.ID("MsgCode", id)).found)
					}
				}
			}
			bold, literal := false, false
			modal := clay.GetElementData(clay.ID("HistModal")).boundingBox
			for cmd in commands.internalArray[:commands.length] {
				if cmd.commandType != .Text {continue}
				data := cmd.renderData.text
				shown := string(data.stringContents.chars[:data.stringContents.length])
				if shown == "bold" {bold = data.fontId == FONT_TITLE}
				literal = literal || u8(uintptr(cmd.userData)) & TEXT_MATH != 0
				testing.expect(t, !strings.contains(shown, "**"))
				testing.expect(
					t,
					cmd.boundingBox.x + cmd.boundingBox.width <= modal.x + modal.width - 16 + 0.1,
					shown,
				)
			}
			testing.expect(t, bold && literal)
			rl.BeginDrawing()
			clay_raylib_render(&commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-history-markdown-%d.png", width))
			rl.EndDrawing()
		}
	}
}
