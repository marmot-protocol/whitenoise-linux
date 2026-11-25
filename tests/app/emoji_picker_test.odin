package main

import "base:runtime"
import "core:testing"
import "core:text/edit"
import "nendo"
import rl "sdlrl"

@(test)
emoji_picker_scroll :: proc(t: ^testing.T) {
	if !test_isolated("emoji_picker_scroll") {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(900, 760, "Emoji picker")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_emoji_catalog()
	emoji_set_load(.Noto)
	memory: []u8
	init_layout(&memory, 32768, {900, 760})
	defer delete(memory)
	ui := Ui_State {
		account_ref      = "offline-fixture",
		selected         = -1,
		selected_contact = -1,
		row_menu         = -1,
		member_menu      = -1,
		picker_open      = true,
		picker_x         = 64,
		picker_y         = 48,
	}
	ui.prefs.rail_w = RAIL_W_MIN
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	defer {
		delete(ui.picker_filter)
		delete(ui.compose)
		for recent in ui.prefs.recent_emoji {delete(recent)}
		delete(ui.prefs.recent_emoji)
		delete(ui.picker_used)
	}

	matches := picker_matches(&ui)
	if !testing.expect_value(t, len(matches), PICKER_MAX_CELLS) {return}
	cols := picker_cols()
	grid := nendo.id("PickerGrid")
	last := matches[len(matches) - 1]
	last_id := nendo.id("PkCell", u32(last))
	tail_row := nendo.id("PkRow", u32((len(matches) - 1) / cols * cols))
	anim_frame += 1
	build_layout(&ui, 0)
	custom := nendo.element(nendo.id("PkCustomRow"))
	first := nendo.element(nendo.id("PkCell", u32(matches[0])))
	testing.expect(
		t,
		custom.found && first.found && custom.rect.y + custom.rect.height < first.rect.y,
	)
	testing.expect(t, !nendo.element(tail_row).found, "offscreen rows should not mount")
	view := nendo.scroll(grid)
	if !testing.expect(t, view.found && view.content.height > view.viewport.height) {return}
	bottom := view.viewport.height - view.content.height
	view.position.y = bottom
	commands := build_layout(&ui, 0)
	cell := nendo.element(last_id)
	if !testing.expect(t, cell.found) {return}
	grid_rect := nendo.element(grid).rect
	testing.expect(
		t,
		abs(cell.rect.y + cell.rect.height - grid_rect.y - grid_rect.height) < 1,
		"the last tile should reach the bottom edge of the viewport",
	)
	rl.BeginDrawing()
	draw_frame(commands)
	rl.TakeScreenshot("/tmp/wn-emoji-picker-bottom.png")
	rl.EndDrawing()

	append(&ui.picker_filter, "marmot_wave")
	build_layout(&ui, 0)
	custom_tile := nendo.element(nendo.id("PkCustom", 0))
	testing.expect(
		t,
		custom_tile.found && abs(custom_tile.rect.y - grid_rect.y) < 1,
		"custom-only results should be visible on the first frame after filtering",
	)
	testing.expect_value(t, nendo.scroll(grid).position.y, f32(0))

	clear(&ui.picker_filter)
	build_layout(&ui, 0)
	nendo.scroll(grid).position.y = bottom
	build_layout(&ui, 0)
	cell = nendo.element(last_id)
	nendo.set_pointer({cell.rect.x + cell.rect.width / 2, cell.rect.y + cell.rect.height / 2}, .Up)
	forced_release = true
	handle_picker(&ui, nil)
	forced_release = false
	testing.expect_value(t, string(ui.compose[:]), emoji_catalog[last].emoji)

	// The message can be taller than the grid in a short desktop window.
	rl.SetWindowSize(900, 240)
	nendo.set_dimensions({900, 240})
	ui.picker_open = true
	append(&ui.picker_filter, "no-such-emoji-in-this-fixture")
	anim_frame += 1
	build_layout(&ui, 0)
	view = nendo.scroll(grid)
	if !testing.expectf(
		t,
		view.found && 0 < view.viewport.height && view.viewport.height < view.content.height,
		"message height %g must exceed the positive viewport height %g",
		view.content.height,
		view.viewport.height,
	) {return}
	bottom = view.viewport.height - view.content.height
	view.position.y = bottom
	build_layout(&ui, 0)
	testing.expect_value(t, nendo.scroll(grid).clip.offset.y, bottom)
}
