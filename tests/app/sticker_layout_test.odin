package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=sticker_layout
@(test)
sticker_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "sticker_layout" {return}
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
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Stickers"})
	append(&ui.compose, "Your draft stays here")
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	sha :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	coordinate :: "30031:" + sha + ":tiny"
	ui.sticker_pack = {
		coordinate = strings.clone(coordinate),
		title      = strings.clone("Marmots"),
		author     = strings.clone(sha),
	}
	tex := new(rl.Texture2D)
	image := rl.LoadImage("vendor/twemoji/1f9ab.png")
	testing.expect(t, image.data != nil)
	image = sticker_thumb(image)
	tex^ = sticker_texture_load(image)
	rl.UnloadImage(image)
	sticker_textures[strings.clone(sha)] = tex
	defer sticker_stop()
	// Identical artwork sent as a photo must retain its own unstyled texture.
	photo := Media_Job {
		kind  = .Image,
		key   = sha,
		image = rl.LoadImage("vendor/twemoji/1f9ab.png"),
	}
	sticker := Media_Job {
		kind  = .Sticker,
		key   = sha,
		image = sticker_thumb(rl.LoadImage("vendor/twemoji/1f9ab.png")),
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
			mime = "image/png",
		}
		append(&ui.sticker_preview, sticker_item_clone(item))
		append(&ui.stickers, sticker_item_clone(item))
	}
	for width in ([]i32{900, 420, 320}) {
		rl.SetWindowSize(width, 760)
		clay.SetLayoutDimensions({f32(width), 760})
		for preview in ([]bool{true, false}) {
			ui.sticker_open = preview
			ui.picker_open, ui.sticker_tab = !preview, true
			ui.picker_x, ui.picker_y = 4, 4
			for _ in 0 ..< 8 {anim_frame += 1; build_layout(&ui, 0)}
			commands := build_layout(&ui, 0)
			panel :=
				clay.GetElementData(clay.ID(preview ? "StickerPanel" : "PickerPanel")).boundingBox
			testing.expect(t, panel.x >= 0 && panel.x + panel.width <= f32(width) + 0.1)
			for i in 0 ..< len(ui.sticker_preview) {
				box :=
					clay.GetElementData(clay.ID(preview ? "StickerPreviewTile" : "StickerPick", u32(i))).boundingBox
				testing.expect(
					t,
					box.width == (preview ? 104 : 80) &&
					box.x >= panel.x &&
					box.x + box.width <= panel.x + panel.width,
					"sticker tiles fit the panel",
				)
			}
			rl.BeginDrawing()
			draw_frame(&commands)
			rl.TakeScreenshot(
				fmt.ctprintf("/tmp/wn-stickers-%d-%s.png", width, preview ? "pack" : "picker"),
			)
			rl.EndDrawing()
		}
	}
	ui.sticker_installing = true
	sticker_finish_install(&ui)
	testing.expect_value(t, len(ui.sticker_packs), 1)
	testing.expect(t, !ui.sticker_installing)
	append(
		&ui.stickers,
		sticker_item_clone(
			{ref = {sha = sha, code = "Marmot"}, label = "Marmot", mime = "image/png"},
		),
	)
	draw :: proc(ui: ^Ui_State, name: string, width: i32) {
		for _ in 0 ..< 8 {anim_frame += 1; build_layout(ui, 0)}
		commands := build_layout(ui, 0)
		rl.BeginDrawing(); draw_frame(&commands)
		rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-stickers-%d-%s.png", width, name))
		rl.EndDrawing()
	}
	press :: proc(t: ^testing.T, ui: ^Ui_State, id: clay.ElementId) {
		data := clay.GetElementData(id)
		testing.expect(t, data.found)
		clay.SetPointerState(
			{
				data.boundingBox.x + data.boundingBox.width / 2,
				data.boundingBox.y + data.boundingBox.height / 2,
			},
			false,
		)
		forced_release = true
		handle_sticker_panel(ui)
		forced_release = false
	}
	for width in ([]i32{900, 420, 320}) {
		rl.SetWindowSize(width, 760)
		clay.SetLayoutDimensions({f32(width), 760})
		sticker_show(&ui, {})
		draw(&ui, "library", width)
		press(t, &ui, clay.ID("StickerLibraryPack", 0))
		testing.expect_value(t, ui.sticker_page, Sticker_Page.Pack)
		draw(&ui, "installed", width)
		press(t, &ui, clay.ID("StickerPreviewTile", 0))
		testing.expect_value(t, ui.sticker_page, Sticker_Page.Detail)
		draw(&ui, "detail", width)
		stage := clay.GetElementData(clay.ID("StickerPersonalPreview")).boundingBox
		testing.expect(t, stage.width >= 220)
		press(t, &ui, clay.ID("StickerBack", 0))
		testing.expect_value(t, ui.sticker_page, Sticker_Page.Pack)
		draw(&ui, "back", width)
		press(t, &ui, clay.ID("StickerBack", 0))
		testing.expect_value(t, ui.sticker_page, Sticker_Page.Library)
		draw(&ui, "library", width)
		press(t, &ui, clay.ID("StickerLibraryItem", 14))
		testing.expect_value(t, ui.sticker_page, Sticker_Page.Detail)
		draw(&ui, "personal", width)
		testing.expect(t, clay.GetElementData(clay.ID("StickerRemove", 0)).found)
		press(t, &ui, clay.ID("StickerBack", 0))
		draw(&ui, "library", width)
		press(t, &ui, clay.ID("StickerAddPack", 0))
		testing.expect_value(t, ui.sticker_page, Sticker_Page.AddPack)
		draw(&ui, "add", width)
		testing.expect(t, clay.GetElementData(clay.ID("StickerInput")).found)
	}
	for locale in ([]string{"it", "de", "ja"}) {
		set_locale(locale)
		sticker_show(&ui, {pack = coordinate})
		draw(&ui, fmt.tprintf("%s-pack", locale), 320)
		panel := clay.GetElementData(clay.ID("StickerPanel")).boundingBox
		remove := clay.GetElementData(clay.ID("StickerRemovePack", 0)).boundingBox
		testing.expect(t, remove.x >= panel.x && remove.x + remove.width <= panel.x + panel.width)
		sticker_show(&ui, {})
		draw(&ui, fmt.tprintf("%s-library", locale), 320)
		press(t, &ui, clay.ID("StickerAddPack", 0))
		draw(&ui, fmt.tprintf("%s-add", locale), 320)
		field := clay.GetElementData(clay.ID("StickerInput")).boundingBox
		panel = clay.GetElementData(clay.ID("StickerPanel")).boundingBox
		testing.expect(
			t,
			field.x + field.width <= panel.x + panel.width,
			"translated text must not widen the form",
		)
	}
	set_locale("en")
	// A send captures the destination/reply/effect and leaves the text draft intact.
	ui.account_ref = "account"
	ui.replying = sha
	ui.fx_armed = 3
	sticker_send(&ui, ui.stickers[0])
	found := false
	for job in sticker_jobs {
		if job.op != .Send {continue}
		found = true
		testing.expect_value(t, job.group, "test")
		testing.expect_value(t, job.account, "account")
		testing.expect_value(t, job.reply, sha)
		testing.expect_value(t, job.effect, 3)
	}
	testing.expect(t, found)
	testing.expect_value(t, string(ui.compose[:]), "Your draft stays here")
	// No disk or relay work in this UI fixture.
	for job in sticker_jobs {sticker_job_free(job)}
	clear(&sticker_jobs)
}
