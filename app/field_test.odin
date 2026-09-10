package main

import "core:testing"
import "core:sync"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
field_overflow :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)

	// The shim's fallback glyph metrics need no window or font files.
	rl.SetPixelScale(1)
	memory := make([]u8, int(clay.MinMemorySize()))
	defer delete(memory)
	previous := clay.GetCurrentContext()
	defer clay.SetCurrentContext(previous)
	clay.Initialize(clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)), {600, 200}, {})
	clay.SetMeasureTextFunction(measure_text, nil)

	ui: Ui_State
	append(&ui.nc_member, "npub1x6v727034rm4q6tewkc2pw2wurp72vqvhpu95mnk2n2hw7xdyesj7520l")
	defer delete(ui.nc_member)
	ui.ed_target = &ui.nc_member
	heads := []int{len(ui.nc_member), 0, 24}
	for head in heads {
		ui.ed.selection = {head, head}
		// The viewport's resolved width is available on the next frame.
		for frame in 0 ..< 2 {
			clay.BeginLayout()
			input_box(&ui, "TestField", &ui.nc_member, "Contact", true, 220)
			compose_line(0, string(ui.nc_member[:]), 0, len(ui.nc_member), head, head, head)
			commands := clay.EndLayout(0)
			if frame == 0 {
				continue
			}
			view := clay.GetElementData(clay.ID("TestField", 3)).boundingBox
			row := clay.GetElementData(clay.ID("TestField", 1)).boundingBox
			testing.expect_value(t, view.width, f32(196))
			testing.expect_value(t, row.width, rl.MeasureTextLine(FONT_BODY, 14, string(ui.nc_member[:]), 0).x)
			line := clay.GetElementData(clay.ID("ComposeLine", 0)).boundingBox
			testing.expect_value(t, line.width, rl.MeasureTextLine(FONT_BODY, BODY_FS, string(ui.nc_member[:]), 0).x)
			x := row.x + rl.MeasureTextLine(FONT_BODY, 14, string(ui.nc_member[:head]), 0).x
			testing.expect(t, x >= view.x && x + CARET_W <= view.x + view.width + 0.01)
			testing.expect_value(t, hit_plain(string(ui.nc_member[:]), x - row.x, 14), head)
			clipped := false
			painted := false
			for command in commands.internalArray[:commands.length] {
				if command.commandType == .ScissorStart && command.boundingBox == view {
					clipped = true
				}
				if command.commandType == .Rectangle && command.boundingBox.width == CARET_W && command.boundingBox.height == 15 {
					testing.expect_value(t, command.boundingBox.x, x)
					painted = true
				}
			}
			testing.expect(t, clipped, "field text must be clipped to the padded viewport")
			testing.expect(t, painted, "the zero-width caret must still paint its stroke")
		}
	}
}
