package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=history_layout
@(test)
history_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "history_layout" {return}
	context.allocator = runtime.default_context().allocator
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
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; delete(ui.hist_versions); delete(ui.nicknames); wrap_clear()}
	token := strings.fields(TEST_MENTIONS)[0]
	ui.nicknames[mention_hex(token)] = "Danny"
	text := "do you want me to take a look at the CI runner? I managed to speed up the mdk one, I can probably do something for android too"
	append(&ui.hist_versions, Edit_Version{at = "15:57", text = text})
	append(&ui.hist_versions, Edit_Version{at = "15:59", text = fmt.tprintf("%s %s", token, text)})
	append(
		&ui.hist_versions,
		Edit_Version {
			at = "16:00",
			text = fmt.tprintf(
				"%s %s",
				token,
				strings.repeat("longword", 40, context.temp_allocator),
			),
		},
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
}
