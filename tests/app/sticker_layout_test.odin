package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:text/edit"
import "core:thread"
import "nendo"
import rl "sdlrl"
import sdl "vendor:sdl3"

@(test)
sticker_layout :: proc(t: ^testing.T) {
	if !test_isolated("sticker_layout") {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(900, 760, "Sticker regression")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {900, 760})
	defer delete(memory)
	ui := Ui_State {
		row_menu         = -1,
		member_menu      = -1,
		selected_contact = -1,
		sticker_loaded   = true,
		sticker_page     = .Pack,
		focus            = .Compose,
	}
	ui.prefs.rail_w = RAIL_W_MIN
	ui.prefs.reduce_motion = true
	ui.account_ref = "offline-fixture"
	ui.sticker_account = ui.account_ref
	append(&ui.accounts, Account_Row_Ui{name = "Test"})
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Stickers"})
	append(&ui.compose, "Your draft stays here")
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	sha :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	coordinate :: "30031:" + sha + ":tiny"
	ui.sticker_pack = {
		coordinate = strings.clone(coordinate),
		title      = strings.clone("Marmots"),
	}
	art_path := fmt.ctprintf("%s/emoji/noto/1f9ab.png", res_dir())
	tex := new(rl.Texture2D)
	image := rl.LoadImage(art_path)
	testing.expect(t, image.data != nil)
	image = image_fit(image, STICKER_PX)
	tex^ = sticker_texture_load(image)
	rl.UnloadImage(image)
	sticker_textures[strings.clone(sha)] = tex
	defer sticker_stop()
	// Identical artwork sent as a photo must retain its own unstyled texture.
	photo := Media_Job {
		kind  = .Image,
		key   = sha,
		image = rl.LoadImage(art_path),
	}
	sticker := Media_Job {
		kind  = .Sticker,
		key   = sha,
		image = image_fit(rl.LoadImage(art_path), STICKER_PX),
	}
	media_publish(&photo)
	media_publish(&sticker)
	photo_view, photo_ok := media_cached(.Image, sha)
	sticker_view, sticker_ok := media_cached(.Sticker, sha)
	testing.expect(t, photo_ok && sticker_ok && photo_view != sticker_view)
	defer {
		for key, view in media_textures {rl.UnloadTexture(view^); free(view); delete(key)}
		delete(media_textures); media_textures = {}
	}
	for i in 0 ..< 14 {
		item := Sticker_Item {
			ref = {pack = coordinate, code = fmt.tprintf("marmot_%d_long_label", i), sha = sha},
			label = "A marmot",
		}
		append(&ui.sticker_preview, sticker_item_clone(item))
		append(&ui.stickers, sticker_item_clone(item))
	}
	for width in ([]i32{900, 420, 320}) {
		rl.SetWindowSize(width, 760)
		nendo.set_dimensions({f32(width), 760})
		for preview in ([]bool{true, false}) {
			ui.sticker_open = preview
			ui.picker_open, ui.sticker_tab = !preview, true
			ui.picker_x, ui.picker_y = 4, 4
			for _ in 0 ..< 8 {anim_frame += 1; build_layout(&ui, 0)}
			commands := build_layout(&ui, 0)
			panel := nendo.element(nendo.id(preview ? "StickerPanel" : "PickerPanel")).rect
			testing.expect(t, panel.x >= 0 && panel.x + panel.width <= f32(width) + 0.1)
			tile_id := preview ? "StickerPreviewTile" : "StickerPick"
			testing.expect(t, nendo.element(nendo.id(tile_id, 0)).found)
			for i in 0 ..< len(ui.sticker_preview) {
				tile := nendo.element(nendo.id(tile_id, u32(i)))
				if !tile.found {continue}
				box := tile.rect
				testing.expect(
					t,
					box.width == (preview ? 104 : 80) &&
					box.x >= panel.x &&
					box.x + box.width <= panel.x + panel.width,
					"sticker tiles fit the panel",
				)
			}
			rl.BeginDrawing()
			draw_frame(commands)
			rl.TakeScreenshot(
				fmt.ctprintf("/tmp/wn-stickers-%d-%s.png", width, preview ? "pack" : "picker"),
			)
			rl.EndDrawing()
		}
	}
	draw :: proc(ui: ^Ui_State, name: string, width: i32) {
		for _ in 0 ..< 8 {
			anim_frame += 1
			nendo.update_scroll(.Off, {}, 1.0 / 60)
			build_layout(ui, 0)
		}
		commands := build_layout(ui, 0)
		rl.BeginDrawing(); draw_frame(commands)
		rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-stickers-%d-%s.png", width, name))
		rl.EndDrawing()
	}
	press :: proc(t: ^testing.T, ui: ^Ui_State, id: nendo.Id) {
		data := nendo.element(id)
		testing.expect(t, data.found)
		nendo.set_pointer(
			{data.rect.x + data.rect.width / 2, data.rect.y + data.rect.height / 2},
			.Up,
		)
		forced_release = true
		handle_sticker_panel(ui)
		forced_release = false
	}
	// Add pack hands the coordinate to MDK and shows progress until it lands.
	ui.sticker_open, ui.picker_open = true, false
	rl.SetWindowSize(900, 760)
	nendo.set_dimensions({900, 760})
	draw(&ui, "adding", 900)
	press(t, &ui, nendo.id("StickerInstall", 0))
	testing.expect(t, ui.sticker_open)
	testing.expect(t, sticker_busy(&ui, .Install))
	testing.expect(t, len(sticker_jobs) == 1 && sticker_jobs[0].input == coordinate)
	for job in sticker_jobs {sticker_job_free(job)}
	clear(&sticker_jobs)
	append(&ui.sticker_packs, Sticker_Pack{strings.clone(coordinate), strings.clone("Marmots")})
	append(
		&ui.stickers,
		sticker_item_clone(
			{ref = {sha = sha, code = "Marmot"}, label = "Marmot", mime = "image/png"},
		),
	)
	for width in ([]i32{900, 420, 320}) {
		rl.SetWindowSize(width, 760)
		nendo.set_dimensions({f32(width), 760})
		sticker_show(&ui, {})
		draw(&ui, "library", width)
		press(t, &ui, nendo.id("StickerLibraryPack", 0))
		testing.expect_value(t, ui.sticker_page, Sticker_Page.Pack)
		draw(&ui, "installed", width)
		press(t, &ui, nendo.id("StickerPreviewTile", 0))
		testing.expect_value(t, ui.sticker_page, Sticker_Page.Detail)
		draw(&ui, "detail", width)
		stage := nendo.element(nendo.id("StickerDetailArt")).rect
		testing.expect(t, stage.width >= 220)
		press(t, &ui, nendo.id("StickerBack", 0))
		testing.expect_value(t, ui.sticker_page, Sticker_Page.Pack)
		draw(&ui, "back", width)
		press(t, &ui, nendo.id("StickerBack", 0))
		testing.expect_value(t, ui.sticker_page, Sticker_Page.Library)
		draw(&ui, "library", width)
		press(t, &ui, nendo.id("StickerLibraryItem", 14))
		testing.expect_value(t, ui.sticker_page, Sticker_Page.Detail)
		draw(&ui, "personal", width)
		testing.expect(t, nendo.element(nendo.id("StickerName")).found)
		testing.expect(t, nendo.element(nendo.id("StickerRemove", 0)).found)
		press(t, &ui, nendo.id("StickerBack", 0))
		testing.expect_value(t, ui.sticker_page, Sticker_Page.Library)
		draw(&ui, "library", width)
		press(t, &ui, nendo.id("StickerAddPack", 0))
		testing.expect_value(t, ui.sticker_page, Sticker_Page.AddPack)
		draw(&ui, "add", width)
		testing.expect(t, nendo.element(nendo.id("StickerInput")).found)
	}
	for locale in ([]string{"it", "de", "ja", "ko"}) {
		set_locale(locale)
		sticker_show(&ui, {pack = coordinate})
		draw(&ui, fmt.tprintf("%s-pack", locale), 320)
		panel := nendo.element(nendo.id("StickerPanel")).rect
		remove := nendo.element(nendo.id("StickerRemovePack", 0)).rect
		testing.expect(t, remove.x >= panel.x && remove.x + remove.width <= panel.x + panel.width)
		sticker_show(&ui, {})
		draw(&ui, fmt.tprintf("%s-library", locale), 320)
		press(t, &ui, nendo.id("StickerAddPack", 0))
		draw(&ui, fmt.tprintf("%s-add", locale), 320)
		field := nendo.element(nendo.id("StickerInput")).rect
		panel = nendo.element(nendo.id("StickerPanel")).rect
		testing.expect(
			t,
			field.x + field.width <= panel.x + panel.width,
			"translated text must not widen the form",
		)
	}
	set_locale("en")

	for i in 0 ..< 72 {
		code := fmt.tprintf("sticker-%d", i)
		append(&ui.stickers, sticker_item_clone({ref = {code = code, sha = sha}, label = code}))
		append(
			&ui.stickers,
			sticker_item_clone({ref = {pack = coordinate, code = code, sha = sha}, label = code}),
		)
	}
	rl.SetWindowSize(320, 360)
	nendo.set_dimensions({320, 360})
	for page in ([]Sticker_Page{.Library, .Pack}) {
		preview := page == .Pack
		sticker_show(&ui, {pack = preview ? coordinate : ""})
		name := preview ? "pack" : "library"
		panel_id := nendo.id("StickerPanel")
		draw(&ui, fmt.tprintf("%s-top", name), 320)
		panel := nendo.element(panel_id).rect
		tile_id := preview ? "StickerPreviewTile" : "StickerLibraryItem"
		last := preview ? len(ui.sticker_preview) - 1 : len(ui.stickers) - 2
		last_id := nendo.id(tile_id, u32(last))
		testing.expect(t, nendo.element(nendo.id(tile_id, preview ? 0 : 14)).found)
		testing.expect(
			t,
			!nendo.element(last_id).found,
			"the last row should not mount at the top",
		)
		viewport := nendo.scroll(panel_id)
		nendo.set_pointer({panel.x + 20, panel.y + panel.height / 2}, .Up)
		nendo.update_scroll(.Off, {0, -100000}, 1.0 / 60)
		testing.expectf(
			t,
			viewport.position.y < 0,
			"%s did not scroll: pointer %v, viewport %v, content %v",
			name,
			nendo.pointer_over(panel_id),
			viewport.viewport,
			viewport.content,
		)
		commands := build_layout(&ui, 0)
		rl.BeginDrawing(); draw_frame(commands)
		rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-stickers-320-%s-bottom.png", name))
		rl.EndDrawing()
		tail := nendo.element(last_id)
		testing.expect(
			t,
			tail.found &&
			tail.rect.y >= panel.y &&
			tail.rect.y + tail.rect.height <= panel.y + panel.height,
		)
		if preview {
			guide := nendo.element(nendo.id("StickerCopy", 3))
			footer := nendo.element(nendo.id("StickerRemovePack", 0))
			testing.expect(t, guide.found && guide.rect.y > tail.rect.y + tail.rect.height)
			testing.expect(
				t,
				footer.found && footer.rect.y + footer.rect.height <= panel.y + panel.height,
			)
		}
		press(t, &ui, last_id)
		testing.expect_value(t, ui.sticker_page, Sticker_Page.Detail)
		testing.expect_value(t, ui.sticker_selected.code, "sticker-71")
		testing.expect_value(t, ui.sticker_selected.pack, preview ? coordinate : "")
		build_layout(&ui, 0)
		panel = nendo.element(panel_id).rect
		for label in ([]string{"StickerBack", "StickerClose", "StickerDetailArt"}) {
			data := nendo.element(nendo.id(label))
			x, y := data.rect.x + data.rect.width / 2, data.rect.y + data.rect.height / 2
			testing.expectf(
				t,
				data.found &&
				x > panel.x &&
				x < panel.x + panel.width &&
				y > panel.y &&
				y < panel.y + panel.height,
				"%s must be visible on the first detail frame from %s",
				label,
				name,
			)
		}
	}

	panel_id := nendo.id("StickerPanel")
	sticker_show(&ui, {pack = coordinate})
	build_layout(&ui, 0)
	panel := nendo.element(panel_id).rect
	nendo.set_pointer({panel.x + 20, panel.y + panel.height / 2}, .Up)
	nendo.update_scroll(.Off, {0, -100000}, 1.0 / 60)
	build_layout(&ui, 0)
	thumb_id := nendo.id("ScrollThumb", panel_id.id)
	thumb := nendo.element(thumb_id)
	if !testing.expect(t, thumb.found) {return}
	x, y := thumb.rect.x + thumb.rect.width / 2, thumb.rect.y + thumb.rect.height / 2
	window_list := sdl.GetWindows(nil)
	defer sdl.free(window_list)
	if !testing.expect(t, window_list != nil && window_list[0] != nil) {return}
	window := window_list[0]

	rl.PushKey(.ESCAPE, true)
	handle_sticker_panel(&ui)
	rl.PushKey(.ESCAPE, false)
	testing.expect_value(t, ui.sticker_page, Sticker_Page.Library)
	sdl.WarpMouseInWindow(window, x, y)
	rl.WindowShouldClose()
	rl.PushMouseButton(.LEFT, true)
	nendo.set_pointer(transmute(nendo.Vector2)rl.GetMousePosition(), .Down)
	scroll_thumb_tick()
	testing.expect(t, nendo.pointer_over(thumb_id), "the press hit the outgoing pack thumb")
	build_layout(&ui, 0)

	sdl.WarpMouseInWindow(window, x, y + 10)
	rl.WindowShouldClose()
	point := rl.GetMousePosition()
	testing.expect(t, rl.IsMouseButtonDown(.LEFT) && point.y > y)
	nendo.set_pointer(transmute(nendo.Vector2)point, .Down)
	scroll_thumb_tick()
	build_layout(&ui, 0)
	testing.expect(
		t,
		nendo.scroll(panel_id).position.y == 0,
		"the old thumb cannot drag the library",
	)

	sdl.WarpMouseInWindow(window, 0, 0)
	rl.WindowShouldClose()
	rl.PushMouseButton(.LEFT, false)
	nendo.set_pointer(transmute(nendo.Vector2)rl.GetMousePosition(), .Up)
	scroll_thumb_tick()
	testing.expect(t, !nendo.pointer_over(panel_id), "the release is outside the library")
	handle_sticker_panel(&ui)
	testing.expect(t, ui.sticker_open, "the outgoing thumb release must not close the library")
	rl.WindowShouldClose()
	scroll_thumb_tick()

	// Both widths fit one column. Only the pack labels above the gallery reflow.
	for i in 0 ..< 32 {
		append(
			&ui.sticker_packs,
			Sticker_Pack {
				coordinate = fmt.tprintf("pack-%d", i),
				title = "A pack with a long title that wraps",
			},
		)
	}
	sticker_show(&ui, {})
	rl.SetWindowSize(260, 760)
	nendo.set_dimensions({260, 760})
	build_layout(&ui, 0)
	view := nendo.scroll(panel_id)
	view.position.y = view.viewport.height - view.content.height
	build_layout(&ui, 0)
	rl.SetWindowSize(210, 760)
	nendo.set_dimensions({210, 760})
	build_layout(&ui, 0)
	panel = nendo.element(panel_id).rect
	body := nendo.element(nendo.id("StickerContent", u32(Sticker_Page.Library))).rect
	first_y := body.y + body.height - 73 * f32(112) + 8
	row := int((panel.y + panel.height / 2 - first_y) / 112)
	if testing.expect(t, row > 0 && row < 73, "the viewport center should stay in the gallery") {
		tile := nendo.element(nendo.id("StickerLibraryItem", u32(15 + 2 * (row - 1))))
		testing.expect(
			t,
			tile.found && abs(tile.rect.y - first_y - f32(row) * 112) < 1,
			"the first resized frame must paint the row at the viewport center",
		)
	}

	// A send captures the destination/reply/effect and leaves the text draft intact.
	old_threads, old_done := send_threads, sends_done
	send_threads, sends_done = {}, {}
	defer {
		for worker in send_threads {thread.join(worker); thread.destroy(worker)}
		for done in sends_done {delete(done.err); for id in done.ids {delete(id)}; delete(done.ids)}
		delete(send_threads); delete(sends_done)
		send_threads, sends_done = old_threads, old_done
		for &p in ui.pending {free_pending(&p)}
		delete(ui.pending)
	}
	ui.account_ref = "account"
	ui.replying = sha
	ui.fx_armed = 3
	sticker_send(&ui, nil, ui.stickers[0])
	testing.expect_value(t, len(ui.pending), 1)
	if len(ui.pending) == 1 {
		p := ui.pending[0]
		testing.expect_value(t, p.group_id, "test")
		testing.expect_value(t, p.reply_to, sha)
		testing.expect_value(t, p.effect, 3)
		testing.expect_value(t, p.sticker.pack, coordinate)
		testing.expect_value(t, p.sticker.sha, sha)
	}
	testing.expect_value(t, string(ui.compose[:]), "Your draft stays here")
	// A personal sticker first reads its vault copy, keeping the same context.
	ui.replying = sha
	ui.fx_armed = 3
	job := Timeline_Work {
		account = "account",
		group   = "test",
	}
	old_timeline := timeline_job
	timeline_job = &job
	defer {timeline_job = old_timeline; delete(ui.thread_stack)}
	append(&ui.thread_stack, "thread-parent")
	ui.thread_placement = .Ready
	sticker_send(&ui, nil, ui.stickers[14])
	found := false
	for job in sticker_jobs {
		if job.op != .Send {continue}
		found = true
		testing.expect_value(t, job.group, "test")
		testing.expect_value(t, job.account, "account")
		testing.expect_value(t, job.root, "thread-parent")
		testing.expect_value(t, job.reply, sha)
		testing.expect_value(t, job.effect, 3)
	}
	testing.expect(t, found)
	// No disk or relay work in this UI fixture.
	for job in sticker_jobs {sticker_job_free(job)}
	clear(&sticker_jobs)
}

@(test)
sticker_picker_virtual_rows :: proc(t: ^testing.T) {
	if !test_isolated("sticker_picker_virtual_rows") {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(360, 560, "Virtual sticker grid")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts(); load_themes(); apply_theme(0, 0)
	previous := nendo.current_context()
	memory: []u8
	init_layout(&memory, 32768, {360, 560})
	defer {nendo.set_context(previous); delete(memory)}
	ui := Ui_State {
		account_ref      = "sticker-fixture",
		selected         = -1,
		selected_contact = -1,
		row_menu         = -1,
		member_menu      = -1,
		picker_open      = true,
		sticker_tab      = true,
		picker_x         = 8,
		picker_y         = 8,
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	defer edit.destroy(&ui.ed)
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {
		g_ui, g_prefs = nil, nil
		delete(ui.chats); delete(ui.stickers); delete(ui.sticker_packs)
		delete(ui.picker_filter); delete(ui.sticker_filter)
		for &p in ui.pending {free_pending(&p)}
		delete(ui.pending)
		for sha in ui.sticker_recent {delete(sha)}
		delete(ui.sticker_recent)
		for job in sticker_jobs {sticker_job_free(job)}
		clear(&sticker_jobs)
		sticker_stop()
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "destination"})
	for i in 0 ..< 128 {append(&ui.stickers, Sticker_Item{ref = {pack = "fixture-pack", code = fmt.tprintf("sticker-%d", i)}})}
	frame := proc(ui: ^Ui_State, wheel: f32 = 0) -> []nendo.Render_Command {
		anim_tick(1.0 / 60)
		nendo.update_scroll(.Off, {0, wheel}, 1.0 / 60)
		return build_layout(ui, 0)
	}
	frame(&ui)
	grid_id := nendo.id("StickerGrid")
	grid := nendo.element(grid_id).rect
	mounted := 0
	for i in 0 ..< len(ui.stickers) {if nendo.element(nendo.id("StickerPick", u32(i))).found {mounted += 1}}
	testing.expect(t, mounted > 0 && mounted <= 24)
	nendo.set_pointer({grid.x + 20, grid.y + 20}, .Up)
	frame(&ui, -100000)
	last := nendo.element(nendo.id("StickerPick", 127))
	testing.expect(
		t,
		last.found && abs(last.rect.y + last.rect.height - (grid.y + grid.height)) < 1,
	)

	ui.prefs.reduce_motion = false
	fling_id, fling_vel = grid_id, {0, -600}
	defer {fling_id, fling_vel = {}, {}}
	for width, i in ([]i32{360, 248}) {
		rl.SetWindowSize(width, 560)
		nendo.set_dimensions({f32(width), 560})
		if i > 0 {frame(&ui)}
		rl.PushKey(.DOWN, true); handle_picker(&ui, nil); rl.PushKey(.DOWN, false)
		commands := frame(&ui)
		grid = nendo.element(grid_id).rect
		focus := i == 0 ? 3 : 5
		testing.expect_value(t, ui.sticker_focus, focus)
		tile_id := nendo.id("StickerPick", u32(focus))
		tile := nendo.element(tile_id)
		testing.expect(
			t,
			tile.found &&
			tile.rect.y >= grid.y &&
			tile.rect.y + tile.rect.height <= grid.y + grid.height + 0.01,
		)
		if i == 0 {
			update_drag_scroll(&ui, false)
			frame(&ui)
			testing.expect(
				t,
				nendo.element(tile_id).rect.y >= grid.y,
				"A touch fling must not hide keyboard focus",
			)
		}
		if i == 1 {
			rl.BeginDrawing(); render_nendo(commands)
			rl.TakeScreenshot("/tmp/wn-sticker-virtual-picker.png")
			rl.EndDrawing()
		}
	}
	rl.SetWindowSize(248, 348)
	nendo.set_dimensions({248, 348})
	ui.focus = .Picker
	ed_set(&ui, &ui.picker_filter, "x")
	frame(&ui); frame(&ui)
	handle_picker(&ui, nil)
	rl.PushKey(.BACKSPACE, true); rl.PushKey(.DOWN, true)
	handle_picker(&ui, nil)
	rl.PushKey(.BACKSPACE, false); rl.PushKey(.DOWN, false)
	frame(&ui)
	grid = nendo.element(grid_id).rect
	restored := nendo.element(nendo.id("StickerPick", 2))
	testing.expect(
		t,
		restored.found &&
		restored.rect.y >= grid.y &&
		restored.rect.y + restored.rect.height <= grid.y + grid.height + 0.01,
		"Focus must be visible on the first restored results frame",
	)

	rl.SetWindowSize(248, 400)
	nendo.set_dimensions({248, 400})
	append(&ui.sticker_packs, Sticker_Pack{coordinate = "fixture-pack", title = "Pack"})
	ui.sticker_focus = 0
	nendo.scroll(grid_id).position.y = 0
	frame(&ui)
	packs := nendo.scroll(nendo.id("StickerPacks"))
	packs.position.x = -(packs.content.width - packs.viewport.width)
	frame(&ui)
	chip := nendo.element(nendo.id("StickerPack", 0)).rect
	nendo.set_pointer({chip.x + chip.width / 2, chip.y + chip.height / 2}, .Up)
	forced_release = true
	rl.PushKey(.DOWN, true); handle_picker(&ui, nil); rl.PushKey(.DOWN, false)
	forced_release = false
	frame(&ui)
	grid = nendo.element(grid_id).rect
	with_footer := nendo.element(nendo.id("StickerPick", 2))
	testing.expect(
		t,
		nendo.element(nendo.id("StickerViewPack", 0)).found &&
		with_footer.found &&
		with_footer.rect.y >= grid.y &&
		with_footer.rect.y + with_footer.rect.height <= grid.y + grid.height + 0.01,
		"Focus must stay visible when the pack footer appears",
	)

	ui.selected = 0
	delete(ui.sticker_filter); ui.sticker_filter = ""
	for height in ([2]i32{620, 540}) {
		rl.SetWindowSize(248, 700)
		nendo.set_dimensions({248, 700})
		frame(&ui); frame(&ui)
		ui.sticker_focus = 4
		nendo.scroll(grid_id).position.y = 0
		frame(&ui)
		if !testing.expect(t, nendo.element(nendo.id("ComposeBox")).found) {return}
		rl.PushKey(.DOWN, true); handle_picker(&ui, nil); rl.PushKey(.DOWN, false)
		rl.SetWindowSize(248, height)
		nendo.set_dimensions({248, f32(height)})
		frame(&ui)
		grid = nendo.element(grid_id).rect
		tile := nendo.element(nendo.id("StickerPick", 6))
		testing.expect_value(t, grid.height >= tile.rect.height, height == 620)
		visible :=
			min(grid.y + grid.height, tile.rect.y + tile.rect.height) - max(grid.y, tile.rect.y)
		// A viewport shorter than a tile can only reveal one viewport's worth.
		testing.expectf(
			t,
			grid.height > 0 && tile.found && visible + 0.01 >= min(tile.rect.height, grid.height),
			"Picker focus at window height %d: tile %v, grid %v",
			height,
			tile.rect,
			grid,
		)
	}
	rl.PushKey(.ENTER, true); handle_picker(&ui, nil); rl.PushKey(.ENTER, false)
	if testing.expect_value(t, len(ui.pending), 1) {
		testing.expect_value(t, ui.pending[0].sticker.code, "sticker-6")
		testing.expect(t, !ui.picker_open)
	}
}
