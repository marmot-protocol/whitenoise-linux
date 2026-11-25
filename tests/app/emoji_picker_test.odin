package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
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
	defer emoji_preview_finish(.Discard)
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

	grid := nendo.id("PickerGrid")
	anim_frame += 1
	perform_composer_action(&ui, .Emoji)
	ui.picker_x, ui.picker_y = 64, 48
	build_layout(&ui, 0)
	category := nendo.element(nendo.id("PickerCategory", u32(Emoji_Group.People)))
	if !testing.expect(t, category.found) {return}
	nendo.set_pointer({category.rect.x + 5, category.rect.y + 5}, .Down)
	forced_press = true
	handle_picker(&ui, nil)
	forced_press = false
	nendo.set_pointer({category.rect.x + 5, category.rect.y + 5}, .Up)
	forced_release = true
	handle_picker(&ui, nil)
	forced_release = false
	if !testing.expect_value(t, ui.picker_group, Emoji_Group.People) {return}
	first_commands := build_layout(&ui, 0)
	matches := picker_matches(&ui)
	if !testing.expect(t, len(matches) > 0) {return}
	testing.expect_value(t, emoji_catalog[matches[0]].emoji, "👋")
	cols := ui.picker_columns
	last := matches[len(matches) - 1]
	last_id := nendo.id("PkCell", u32(last))
	tail_row := nendo.id("PkRow", u32((len(matches) - 1) / cols * cols))
	rl.BeginDrawing()
	draw_frame(first_commands)
	rl.TakeScreenshot("/tmp/wn-emoji-picker-cold.png")
	rl.EndDrawing()
	first_id := nendo.id("PkCell", u32(matches[0]))
	first := nendo.element(first_id)
	testing.expect(t, first.found && !nendo.element(nendo.id("PkCustomRow")).found)
	testing.expect(t, nendo.element(nendo.id("PickerSearch")).found)
	testing.expect(t, emoji_tex_cache[emoji_catalog[matches[0]].emoji] == nil)
	nendo.set_pointer(
		{first.rect.x + first.rect.width / 2, first.rect.y + first.rect.height / 2},
		.Up,
	)
	testing.expect(t, !nendo.pointer_over(first_id), "a loading placeholder cannot be selected")
	for _ in 0 ..< 16 {
		settings_emoji_tick(&ui)
		if emoji_tex_cache[emoji_catalog[matches[0]].emoji] != nil {break}
		anim_frame += 1
		build_layout(&ui, 0)
	}
	emoji_preview_finish(.Publish)
	testing.expect(t, emoji_tex_cache[emoji_catalog[matches[0]].emoji] != nil)
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
	for _ in 0 ..< 16 {
		settings_emoji_tick(&ui)
		anim_frame += 1
		commands = build_layout(&ui, 0)
		if emoji_tex_cache[emoji_catalog[last].emoji] != nil {break}
	}
	rl.BeginDrawing()
	draw_frame(commands)
	rl.TakeScreenshot("/tmp/wn-emoji-picker-bottom.png")
	rl.EndDrawing()

	for ch in "marmot_wave" {rl.PushChar(ch)}
	rl.PushKey(.DOWN, true)
	handle_picker(&ui, nil)
	rl.PushKey(.DOWN, false)
	nendo.update_scroll(.Off, {}, 0)
	build_layout(&ui, 0)
	custom_tile := nendo.element(nendo.id("PkCustom", 3))
	testing.expect(
		t,
		custom_tile.found && abs(custom_tile.rect.y - grid_rect.y) < 1,
		"custom-only results should be visible on the first frame after filtering",
	)
	testing.expect_value(t, nendo.scroll(grid).position.y, f32(0))
	nendo.update_scroll(.Off, {}, 0)
	build_layout(&ui, 0)

	clear_button := nendo.element(nendo.id("PickerClear")).rect
	nendo.set_pointer({clear_button.x + 5, clear_button.y + 5}, .Up)
	forced_release = true
	handle_picker(&ui, nil)
	forced_release = false
	nendo.update_scroll(.Off, {}, 0)
	build_layout(&ui, 0)
	testing.expect_value(t, nendo.scroll(grid).position.y, bottom)
	cell = nendo.element(last_id)
	nendo.set_pointer({cell.rect.x + cell.rect.width / 2, cell.rect.y + cell.rect.height / 2}, .Up)
	forced_release = true
	handle_picker(&ui, nil)
	forced_release = false
	testing.expect_value(t, string(ui.compose[:]), emoji_catalog[last].emoji)

	// An empty result still keeps search usable in a short desktop window.
	rl.SetWindowSize(900, 240)
	nendo.set_dimensions({900, 240})
	ui.picker_open = true
	append(&ui.picker_filter, "no-such-emoji-in-this-fixture")
	anim_frame += 1
	build_layout(&ui, 0)
	view = nendo.scroll(grid)
	testing.expect(t, view.found && view.viewport.height > 0 && view.content.height > 0)
	test_cold_custom_emoji(t, &ui)

	rl.SetWindowSize(360, 760)
	nendo.set_dimensions({360, 760})
	open_picker(&ui, "")
	for recent in ui.prefs.recent_emoji {delete(recent)}
	clear(&ui.prefs.recent_emoji)
	for emoji in ([8]string{"😀", "👍", "😂", "💚", "🎉", "🎶", "✋", "👀"}) {
		append(&ui.prefs.recent_emoji, strings.clone(emoji))
	}
	build_layout(&ui, 0)
	panel := nendo.element(nendo.id("PickerPanel")).rect
	strip := nendo.element(nendo.id("PickerCategories")).rect
	search := nendo.element(nendo.id("PickerSearch")).rect
	cell = nendo.element(nendo.id("PickerCategory", u32(Emoji_Group.Smileys)))
	testing.expect_value(t, panel.width, f32(360))
	testing.expect_value(t, panel.y + panel.height, f32(760))
	testing.expect(t, strip.y >= search.y + search.height && cell.rect.width >= 44)
	testing.expect_value(t, ui.focus, Focus.Compose)

	recents := nendo.id("PkRecentRow")
	row := nendo.scroll(recents)
	if !testing.expectf(
		t,
		row.found && row.content.width > row.viewport.width,
		"Recent shelf found: %v, content: %g, viewport: %g",
		row.found,
		row.content.width,
		row.viewport.width,
	) {return}
	right := row.viewport.width - row.content.width
	row.position.x = right
	ed_set(&ui, &ui.picker_filter, "rocket")
	for _ in 0 ..< 3 {
		nendo.update_scroll(.Off, {}, 0)
		build_layout(&ui, 0)
	}
	ed_set(&ui, &ui.picker_filter, "")
	build_layout(&ui, 0)
	row = nendo.scroll(recents)
	if testing.expect(t, row.found) {testing.expect_value(t, row.clip.offset.x, right)}
}

@(private = "file")
test_cold_custom_emoji :: proc(t: ^testing.T, ui: ^Ui_State) {
	home, err := os.make_directory_temp("", "wn-emoji-picker-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer os.remove_all(home)
	config_root :: "HOME" when ODIN_OS == .Darwin else "XDG_CONFIG_HOME"
	previous := os.get_env(config_root, context.temp_allocator)
	if !testing.expect_value(t, os.set_env(config_root, home), nil) {return}
	defer {
		if previous == "" {os.unset_env(config_root)} else {os.set_env(config_root, previous)}
	}
	directory := emoji_dir()
	if !testing.expect(
		t,
		strings.has_prefix(directory, fmt.tprintf("%s/", home)),
		"emoji fixture must use the temporary config directory",
	) {return}
	if !testing.expect_value(t, os.make_directory_all(directory), nil) {return}
	defer emoji_preview_finish(.Discard)
	defer {
		for name in custom_emoji_names {delete(name)}
		delete(custom_emoji_names)
		custom_emoji_names = nil
	}
	for i in 0 ..< 36 {
		// These two names collide if their hashes are used as picker slots.
		name :=
			i == 24 ? "emoji_141208.png" : i == 25 ? "emoji_149880.png" : fmt.tprintf("emoji_%s_%02d.png", i < 24 ? "00" : "zz", i)
		append(&custom_emoji_names, strings.clone(name))
		data := i == 24 || i == 25 ? BUILTIN_EMOJI[0].png : []u8{0}
		if !testing.expect_value(
			t,
			os.write_entire_file(fmt.tprintf("%s/%s", directory, name), data),
			nil,
		) {return}
	}
	rl.SetWindowSize(900, 760)
	nendo.set_dimensions({900, 760})
	ed_set(ui, &ui.picker_filter, "emoji_")
	clear(&ui.compose)
	ui.picker_return = 0
	anim_frame += 1
	build_layout(ui, 0)
	emoji_preview_finish(.Discard)
	row_id := nendo.id("PkCustomRow")
	row := nendo.scroll(row_id)
	if !testing.expect(t, row.found && row.content.width > row.viewport.width) {return}
	first_collision := nendo.element(nendo.id("PkCustom", 24))
	if !testing.expect(t, first_collision.found) {return}
	row.position.x += nendo.element(row_id).rect.x - first_collision.rect.x
	build_layout(ui, 0)
	settings_emoji_tick(ui)
	emoji_preview_finish(.Publish)
	_, decoded_prefix := custom_emoji_textures[custom_emoji_names[0]]
	testing.expect(t, !decoded_prefix, "clipped artwork must wait for scrolling into view")
	testing.expect(t, custom_emoji_textures[custom_emoji_names[25]] != nil)
	build_layout(ui, 0)
	tile := nendo.element(nendo.id("PkCustom", 25))
	if !testing.expect(t, tile.found) {return}
	nendo.set_pointer({tile.rect.x + tile.rect.width / 2, tile.rect.y + tile.rect.height / 2}, .Up)
	ui.picker_hit_revision = ui.picker_custom_revision
	if !testing.expect_value(
		t,
		os.write_entire_file(fmt.tprintf("%s/emoji_0.png", directory), []u8{0}),
		nil,
	) {return}
	custom_emoji_scan()
	build_layout(ui, 0)
	forced_release = true
	handle_picker(ui, nil)
	forced_release = false
	testing.expect(
		t,
		ui.picker_open && len(ui.compose) == 0,
		"the old slot must not pick its new shortcode",
	)

	tile = nendo.element(nendo.id("PkCustom", 26))
	if !testing.expect(t, tile.found) {return}
	nendo.set_pointer({tile.rect.x + tile.rect.width / 2, tile.rect.y + tile.rect.height / 2}, .Up)
	ui.picker_hit_revision = ui.picker_custom_revision
	forced_release = true
	handle_picker(ui, nil)
	forced_release = false
	testing.expect_value(t, string(ui.compose[:]), ":emoji_149880:")
	test_picker_packs(t, ui, directory)
}

@(private = "file")
test_picker_packs :: proc(t: ^testing.T, ui: ^Ui_State, directory: string) {
	for title, i in ([2]string{"Wood\nland", " \t\n "}) {
		event := emoji_test_event(i == 0 ? "woodland" : "Party", title)
		defer emoji_event_free(event)
		set, ok := emoji_set_parse(event, "")
		if !testing.expect(t, ok) {return}
		defer emoji_set_free(set)
		if !testing.expect(
			t,
			emoji_import_asset(directory, set, set.items[i], BUILTIN_EMOJI[4 + i * 3].png, ".png"),
		) {return}
	}
	custom_emoji_scan()
	defer emoji_sources_clear()
	emoji_sets_stop(ui) // Vault lock stops the account's workers, not the device's catalog.
	open_picker(ui, "")
	build_layout(ui, 0)
	if !testing.expect_value(t, len(picker_emoji_packs), 2) {return}
	testing.expect_value(t, picker_emoji_packs[0].title, "Party")
	testing.expect_value(t, picker_emoji_packs[1].title, "Wood land")
	custom := nendo.element(nendo.id("PickerCategory", u32(Emoji_Group.Custom))).rect
	marmots := nendo.element(nendo.id("PickerCategory", u32(Emoji_Group.Marmot)))
	party_id := nendo.id("PickerCategory", u32(len(PICKER_CATEGORIES)))
	woodland_id := nendo.id("PickerCategory", u32(len(PICKER_CATEGORIES) + 1))
	party, woodland := nendo.element(party_id), nendo.element(woodland_id)
	smileys := nendo.element(nendo.id("PickerCategory", u32(Emoji_Group.Smileys))).rect
	if !testing.expect(
		t,
		marmots.found &&
		party.found &&
		woodland.found &&
		custom.y < marmots.rect.y &&
		marmots.rect.y < party.rect.y &&
		party.rect.y < woodland.rect.y &&
		woodland.rect.y < smileys.y,
	) {return}
	testing.expect_value(t, ui.picker_group, Emoji_Group.Custom)

	pointer :: proc(ui: ^Ui_State, rect: nendo.Rect, phase: nendo.Pointer_Button) {
		nendo.set_pointer({rect.x + rect.width / 2, rect.y + rect.height / 2}, phase)
		ui.picker_hit_revision = ui.picker_custom_revision
		forced_press, forced_release = phase == .Down, phase == .Up
		handle_picker(ui, nil)
		forced_press, forced_release = false, false
	}
	{
		pointer(ui, marmots.rect, .Down)
		pointer(ui, marmots.rect, .Up)
		commands := build_layout(ui, 0)
		items, _ := picker_custom_matches(ui)
		if !testing.expect_value(t, len(items), 12) {return}
		wave: nendo.Id
		for item in items {
			testing.expect(t, item.code == "marmot" || strings.has_prefix(item.code, "marmot_"))
			if item.code == "marmot_wave" {wave = nendo.id("PkCustom", item.slot)}
		}
		for _ in 0 ..< 16 {
			settings_emoji_tick(ui)
			emoji_preview_finish(.Publish)
			commands = build_layout(ui, 0)
		}
		rail_id := nendo.id("PickerCategories")
		rail := nendo.element(rail_id).rect
		button := nendo.element(nendo.id("PickerCategory", u32(Emoji_Group.Marmot))).rect
		testing.expect(
			t,
			abs(button.x + button.width / 2 - rail.x - rail.width / 2) < 1,
			"category buttons must be centered in the rail",
		)
		thumb := nendo.element(nendo.id("ScrollThumb", rail_id.id))
		testing.expect(
			t,
			thumb.found && thumb.rect.x > button.x + button.width,
			"the category scrollbar must not overlap the buttons",
		)
		rl.BeginDrawing()
		draw_frame(commands)
		rl.TakeScreenshot("/tmp/wn-emoji-picker-marmot.png")
		rl.EndDrawing()
		tile := nendo.element(wave)
		if !testing.expect(t, tile.found) {return}
		clear(&ui.compose)
		ui.picker_return = 0
		pointer(ui, tile.rect, .Up)
		testing.expect_value(t, string(ui.compose[:]), ":marmot_wave:")
	}
	open_picker(ui, "")
	for expected_pack in 0 ..< 2 {
		rl.PushKey(.TAB, true)
		handle_picker(ui, nil)
		rl.PushKey(.TAB, false)
		testing.expect_value(t, ui.picker_pack, expected_pack)
		if expected_pack == 0 {testing.expect_value(t, ui.picker_group, Emoji_Group.Marmot)}
	}
	open_picker(ui, "")
	build_layout(ui, 0)
	pointer(ui, party.rect, .Down)
	custom_emoji_scan()
	build_layout(ui, 0)
	pointer(ui, party.rect, .Up)
	testing.expect_value(t, ui.picker_pack, 0)
	pointer(ui, party.rect, .Down)
	pointer(ui, party.rect, .Up)
	build_layout(ui, 0)
	items, _ := picker_custom_matches(ui)
	if !testing.expect_value(t, len(items), 1) {return}
	testing.expect_value(t, items[0].code, "second")
	ed_set(ui, &ui.picker_filter, "happy-fox")
	build_layout(ui, 0)
	items, _ = picker_custom_matches(ui)
	if !testing.expect_value(t, len(items), 1) {return}
	testing.expect_value(t, items[0].code, "happy-fox")
	ed_set(ui, &ui.picker_filter, "")
	build_layout(ui, 0)
	pointer(ui, woodland.rect, .Down)
	pointer(ui, woodland.rect, .Up)
	if !testing.expect_value(
		t,
		os.write_entire_file(fmt.tprintf("%s/second.png", directory), []u8{0}),
		nil,
	) {return}
	custom_emoji_scan()
	build_layout(ui, 0)
	if !testing.expect(
		t,
		nendo.element(party_id).found,
		"a local override must not hide its installed pack",
	) {return}
	items, _ = picker_custom_matches(ui)
	if !testing.expect_value(t, len(items), 1) {return}
	testing.expect_value(t, items[0].code, "happy-fox")
	tile_id := nendo.id("PkCustom", items[0].slot)
	for _ in 0 ..< 10 {
		settings_emoji_tick(ui)
		emoji_preview_finish(.Publish)
		build_layout(ui, 0)
		if custom_emoji_textures[custom_emoji_names[items[0].slot]] != nil {break}
	}
	tile := nendo.element(tile_id)
	if !testing.expect(t, tile.found && !nendo.element(nendo.id("PkCustomRow")).found) {return}
	rl.SetWindowSize(390, 760)
	nendo.set_dimensions({390, 760})
	commands := build_layout(ui, 0)
	rl.BeginDrawing()
	draw_frame(commands)
	rl.TakeScreenshot("/tmp/wn-emoji-picker-pack.png")
	rl.EndDrawing()
	clear(&ui.compose)
	ui.picker_return = 0
	pointer(ui, nendo.element(tile_id).rect, .Up)
	testing.expect_value(t, string(ui.compose[:]), ":happy-fox:")
}
