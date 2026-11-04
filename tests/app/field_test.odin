package main

import "core:sync"
import "core:testing"
import "nendo"
import rl "sdlrl"

@(test)
field_overflow :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)

	// The shim's fallback glyph metrics need no window or font files.
	rl.SetPixelScale(1)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer delete(memory)
	previous := nendo.current_context()
	defer nendo.set_context(previous)
	nendo.init(memory, {600, 200}, {})
	nendo.set_measure_text(measure_text, nil)

	ui: Ui_State
	append(&ui.nc_member, "npub1x6v727034rm4q6tewkc2pw2wurp72vqvhpu95mnk2n2hw7xdyesj7520l")
	defer delete(ui.nc_member)
	ui.ed_target = &ui.nc_member
	heads := []int{len(ui.nc_member), 0, 24}
	for head in heads {
		ui.ed.selection = {head, head}
		caret_wake() // solid, not mid-blink
		// The viewport's resolved width is available on the next frame.
		for frame in 0 ..< 2 {
			nendo.begin()
			input_box(&ui, "TestField", &ui.nc_member, "Contact", true, 220)
			compose_line(0, string(ui.nc_member[:]), 0, len(ui.nc_member), head, head, head)
			commands := nendo.end(0)
			if frame == 0 {
				continue
			}
			view := nendo.element(nendo.id("TestField", 3)).rect
			row := nendo.element(nendo.id("TestField", 1)).rect

			// The focused row is its text plus the inline caret ink, which
			// stays inside the field's scroll clip.
			testing.expect_value(
				t,
				row.width,
				rl.MeasureTextLine(FONT_BODY, 14, string(ui.nc_member[:]), 0).x + CARET_W,
			)
			line := nendo.element(nendo.id("ComposeLine", 0)).rect
			testing.expect_value(
				t,
				line.width,
				rl.MeasureTextLine(FONT_BODY, BODY_FS, string(ui.nc_member[:]), 0).x + CARET_W,
			)
			x := row.x + rl.MeasureTextLine(FONT_BODY, 14, string(ui.nc_member[:head]), 0).x
			testing.expect(t, x >= view.x && x + CARET_W <= view.x + view.width + 0.01)
			testing.expect_value(t, hit_plain(string(ui.nc_member[:]), x - row.x, 14), head)
			clipped := false
			painted := false
			for command in commands {
				if command.kind == .Scissor_Start && command.rect == view {
					clipped = true
				}
				if command.kind == .Rectangle &&
				   command.rect.width == CARET_W &&
				   command.rect.height == 15 {
					testing.expect_value(t, command.rect.x, x)
					painted = true
				}
			}
			testing.expect(t, clipped, "field text must be clipped to the padded viewport")
			testing.expect(t, painted, "the zero-width caret must still paint its stroke")
		}
	}
}

// A field inside a floating panel (the emoji picker floats at z 12)
// must paint its caret in the panel's layer, not under the panel.
@(test)
field_caret_in_float :: proc(t: ^testing.T) {
	sync.lock(&nendo_test_mutex)
	defer sync.unlock(&nendo_test_mutex)

	rl.SetPixelScale(1)
	memory := make([]u8, int(nendo.min_memory_size()))
	defer delete(memory)
	previous := nendo.current_context()
	defer nendo.set_context(previous)
	nendo.init(memory, {600, 200}, {})
	nendo.set_measure_text(measure_text, nil)

	ui: Ui_State
	append(&ui.picker_filter, "face")
	defer delete(ui.picker_filter)
	ui.ed_target = &ui.picker_filter
	ui.ed.selection = {4, 4}
	caret_wake() // solid, not mid-blink

	nendo.begin()
	if nendo.box(nendo.id("TestPanel"))(
	{
		width = nendo.fixed(300),
		height = nendo.fixed(100),
		color = {1, 1, 1, 255},
		floating = {attach_to = .Root, z = 12},
	},
	) {
		field_text(&ui, "TestSearch", &ui.picker_filter, "search...", true)
	}
	commands := nendo.end(0)

	panel_at, caret_at := -1, -1
	for command, i in commands {
		if command.kind != .Rectangle {
			continue
		}
		if command.rect.width == 300 {
			panel_at = i
		}
		if command.rect.width == CARET_W {
			caret_at = i
			testing.expect_value(t, command.z, 12)
		}
	}
	testing.expect(t, panel_at >= 0 && caret_at > panel_at, "the caret must draw over its panel")
}
