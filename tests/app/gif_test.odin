package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:text/edit"
import "core:thread"
import rl "sdlrl"


@(test)
gif_ios_message :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	old_lines, old_deleted, old_moving := sel_lines, del_seen, anim_moving
	sel_lines, del_seen = {}, {}
	defer {
		delete(sel_lines)
		for key in del_seen {delete(key)}
		delete(del_seen)
		sel_lines, del_seen, anim_moving = old_lines, old_deleted, old_moving
	}
	url :: "https://media3.giphy.com/media/v1.Y2lkPWFjZTYxYTllYWpldGZ0Ym05em5sbmhvc3ZxMDBjdjh6MG1kMDJxbm01YXQ5OHZ6ZCZlcD12MV9naWZzX3NlYXJjaCZjdD1n/l4FATJpd4LWgeruTK/giphy.gif"
	msg := Msg_Ui {
		body = strings.clone(url + " via GIPHY"),
	}
	defer message_free(msg)
	view := Video_View {
		w       = 320,
		h       = 240,
		looping = true,
	}
	old_views := video_views
	video_views = {}
	video_views[url] = &view
	defer {delete(video_views); video_views = old_views}
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {800, 2000})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	clay.BeginLayout()
	message_row(0, msg)
	commands := clay.EndLayout(0)
	drawn := false
	for command in commands.internalArray[:commands.length] {
		if command.commandType == .Image && command.renderData.image.imageData == &view.tex {
			drawn = true
		}
	}
	testing.expect(t, drawn, "iOS GIPHY shares must render the looping GIF")
	for size in ([][2]i32{{0, 240}, {320, 0}, {-1, 240}, {320, -1}}) {
		view.w, view.h = size[0], size[1]
		clay.BeginLayout()
		message_row(0, msg)
		commands = clay.EndLayout(0)
		text := strings.builder_make(context.temp_allocator)
		for command in commands.internalArray[:commands.length] {
			if command.commandType == .Image {
				testing.expect(t, command.renderData.image.imageData != &view.tex)
			}
			if command.commandType == .Text {
				part := command.renderData.text.stringContents
				strings.write_string(&text, string(part.chars[:part.length]))
			}
		}
		testing.expect(
			t,
			strings.contains(strings.to_string(text), url),
			"invalid dimensions must leave the original link visible",
		)
	}
	view.w, view.h = 320, 240
	testing.expect_value(t, giphy_message_url("\n" + url + "\nvia GIPHY\n"), url)
	query :: "https://media.giphy.com/media/test/giphy.gif?size=small"
	testing.expect_value(t, giphy_message_url(query + " via GIPHY"), query)
	for body in ([]string{url, "Look at " + url + " via GIPHY", url + " via GIPHY extra", "https://media3.giphy.com.evil.test/media/test/giphy.gif via GIPHY", "https://media3.giphy.com@evil.test/media/test/giphy.gif via GIPHY", "https://mediaevil.giphy.com/media/test/giphy.gif via GIPHY", "https://media3.giphy.com/media/test/video.mp4 via GIPHY", "http://media3.giphy.com/media/test/giphy.gif via GIPHY"}) {
		testing.expect_value(t, giphy_message_url(body), "")
	}
	msg.deleted = true
	clay.BeginLayout()
	message_row(0, msg)
	commands = clay.EndLayout(0)
	for command in commands.internalArray[:commands.length] {
		if command.commandType == .Image {
			testing.expect(
				t,
				command.renderData.image.imageData != &view.tex,
				"deleted shares must not render GIFs",
			)
		}
	}
}
@(test)
gif_data :: proc(t: ^testing.T) {
	context.allocator = runtime.default_context().allocator
	for bad in ([]string{"http://gifsnap.com/a", "https://gifsnap.com.evil.test/a", "https://127.0.0.1/a", "file:///tmp/a", "https://user@gifsnap.com/a"}) {testing.expect(t, !gif_asset_url(bad))}
	items, more, ok := gif_parse(
		transmute([]u8)string(
			`{"data":[{"title":"Cat","url":"https://gifsnap.com/api/v1/media/cat","preview_url":"https://gifsnap.com/api/v1/media/thumb"},{"url":"https://evil.test/a","preview_url":"https://gifsnap.com/api/v1/media/a"}],"pagination":{"page":1,"has_next":true}}`,
		),
	)
	testing.expect(t, ok && more && len(items) == 1)
	for item in items {gif_item_free(item)}; delete(items)
	for invalid in ([]string{"{}", "bad", `{"data":[],"pagination":{"page":0}}`, `{"data":42}`}) {
		_, _, parsed := gif_parse(transmute([]u8)invalid); testing.expect(t, !parsed)
	}
	_, _, empty := gif_parse(transmute([]u8)string(`{"data":[],"pagination":{"page":1}}`))
	testing.expect(t, empty, "empty results are not a network error")
	bytes, err := base64.decode("R0lGODlhAQABAIAAAAAAAP///yH5BAAAAAAALAAAAAABAAEAAAIBRAA7")
	testing.expect(t, err == nil); defer delete(bytes)
	testing.expect(t, gif_valid(bytes))
	testing.expect(t, !gif_valid(bytes[:12]))
	bytes[6], bytes[7] = 255, 255
	testing.expect(t, !gif_valid(bytes), "reject huge canvases before decoding")
	bytes[6], bytes[7] = 1, 0
	sync.lock(&test_home_lock); defer sync.unlock(&test_home_lock)
	previous := data_home; data_home = "/tmp/wn-gif-storage-test"
	defer {data_home = previous}
	os.make_directory(data_home); defer os.remove_all(data_home)
	testing.expect_value(t, vault_create("test"), Vault_Err.None)
	sha := string(hex.encode(hash.hash_bytes(.SHA256, bytes, context.temp_allocator)))
	defer delete(sha)
	item := Gif_Item {
		title = "Saved cat",
		sha   = sha,
	}
	index, marshal_err := json.marshal([]Gif_Item{item}); testing.expect(t, marshal_err == nil)
	save := new(Gif_Job); save^ = {
		op    = .Save,
		item  = gif_item_clone(item),
		data  = make([]u8, len(bytes)),
		index = index,
	}
	copy(save.data, bytes)
	worker := thread.Thread {
		data = save,
	}; gif_worker(&worker)
	testing.expect_value(t, save.error, "")
	gif_job_free(save)
	sealed, read_err := os.read_entire_file(gif_path(sha), context.temp_allocator)
	testing.expect(
		t,
		read_err == nil && string(sealed) != string(bytes),
		"saved GIF bytes stay encrypted",
	)
	loaded := gif_read(sha); testing.expect_value(t, string(loaded), string(bytes)); delete(loaded)
	load := new(Gif_Job); load.op = .Library; worker.data = load; gif_worker(&worker)
	testing.expect_value(t, load.error, "")
	testing.expect_value(t, len(load.items), 1)
	// Opening Saved reads only its index; image bytes are loaded per visible tile.
	thumb_data := gif_read(load.items[0].sha)
	thumb := rl.LoadImageFromMemory(".gif", raw_data(thumb_data), i32(len(thumb_data)))
	testing.expect(t, thumb.data != nil, "saved thumbnails work offline")
	rl.UnloadImage(thumb); delete(thumb_data)
	gif_job_free(load)
	remove := new(Gif_Job); remove^ = {
		op    = .Remove,
		item  = gif_item_clone(item),
		index = transmute([]u8)strings.clone("[]"),
	}
	worker.data = remove; gif_worker(&worker)
	testing.expect_value(t, remove.error, "")
	testing.expect(t, !os.exists(gif_path(sha)))
	gif_job_free(remove)
	// A queued save completes during shutdown, even before a frame starts its worker.
	ui: Ui_State
	job := gif_start(&ui, .Save); job.item = gif_item_clone(item)
	job.data = make([]u8, len(bytes)); copy(job.data, bytes)
	job.index, _ = json.marshal([]Gif_Item{item})
	gif_stop(&ui)
	testing.expect(t, os.exists(gif_path(sha)))
	testing.expect(t, media_write_sealed(gif_path(sha), []u8{1, 2, 3}))
	testing.expect(t, len(gif_read(sha)) == 0, "corrupt saved files are not staged")
}

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=gif_keyboard
@(test)
gif_keyboard :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "gif_keyboard" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(900, 760, "GIF keyboard regression"); defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8; init_layout(&memory, 32768, {900, 760}); defer delete(memory)
	ui := Ui_State {
		row_menu         = -1,
		member_menu      = -1,
		selected_contact = -1,
		picker_open      = true,
		gif_tab          = true,
		gif_saved        = true,
		gif_loaded       = true,
		focus            = .Picker,
		gif_focus        = -1,
		picker_x         = 4,
		picker_y         = 4,
	}
	edit.init(&ui.ed, context.allocator, context.allocator)
	ui.prefs.rail_w = RAIL_W_MIN; ui.prefs.reduce_motion = true
	append(&ui.accounts, "Test"); append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "GIFs"})
	append(&ui.compose, "Keep your draft")
	g_ui, g_prefs = &ui, &ui.prefs; defer {g_ui, g_prefs = nil, nil}
	defer gif_stop(&ui)
	image := rl.LoadImage("vendor/twemoji/1f9ab.png")
	defer rl.UnloadImage(image)
	for i in 0 ..< 8 {
		append(
			&ui.gif_library,
			Gif_Item{title = fmt.aprintf("Saved GIF %d", i), thumb = fmt.aprintf("fixture%d", i)},
		)
		register_local_pic(fmt.tprintf("image:fixture%d", i), image)
	}
	press :: proc(t: ^testing.T, ui: ^Ui_State, id: clay.ElementId) {
		data := clay.GetElementData(id); testing.expect(t, data.found)
		clay.SetPointerState(
			{
				data.boundingBox.x + data.boundingBox.width / 2,
				data.boundingBox.y + data.boundingBox.height / 2,
			},
			false,
		)
		forced_release = true; handle_picker(ui, nil); forced_release = false
	}
	for width in ([]i32{900, 420, 320}) {
		rl.SetWindowSize(width, 760); clay.SetLayoutDimensions({f32(width), 760})
		for locale in ([]string{"en", "it", "de", "ja"}) {
			set_locale(locale)
			for _ in 0 ..< 8 {anim_frame += 1; build_layout(&ui, 0)}
			commands := build_layout(&ui, 0)
			panel := clay.GetElementData(clay.ID("PickerPanel")).boundingBox
			for i in 0 ..< 8 {
				box := clay.GetElementData(clay.ID("GifTile", u32(i))).boundingBox
				testing.expect(
					t,
					box.width > 0 &&
					box.x >= panel.x &&
					box.x + box.width <= panel.x + panel.width,
				)
			}
			rl.BeginDrawing()
			draw_frame(&commands)
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-gifs-%d-%s.png", width, locale))
			rl.EndDrawing()
		}
	}
	set_locale("en")
	// An in-flight search must not swallow typing or publish an obsolete response.
	ui.gif_saved = false
	job := gif_start(&ui, .Search); job.query = strings.clone("old query")
	rl.PushChar('c'); handle_gif_picker(&ui)
	testing.expect_value(t, string(ui.picker_filter[:]), "c")
	testing.expect(t, ui.gif_due > rl.GetTime())
	job.worker = thread.create_and_start(proc() {})
	thread.join(job.worker); gif_drain(&ui)
	testing.expect_value(t, len(ui.gif_hits), 0)
	ed_set(&ui, &ui.picker_filter, ""); ui.gif_due = 0
	delete(ui.gif_filter); ui.gif_filter = ""
	// Metadata pages append without moving the viewport; only visible tiles load.
	for i in 0 ..< GIF_PAGE_SIZE {
		append(
			&ui.gif_hits,
			Gif_Item {
				title = fmt.aprintf("Result %d", i),
				thumb = fmt.aprintf("https://gifsnap.com/fixture%d", i),
				width = 200,
				height = 200,
			},
		)
	}
	ui.gif_page, ui.gif_more = 1, true
	for _ in 0 ..< 8 {anim_frame += 1; build_layout(&ui, 0)}
	testing.expect(t, gif_visible(0) && !gif_visible(GIF_PAGE_SIZE - 1))
	_, first_loading, _ := gif_thumb(ui.gif_hits[0], 0)
	_, last_loading, _ := gif_thumb(ui.gif_hits[GIF_PAGE_SIZE - 1], GIF_PAGE_SIZE - 1)
	testing.expect(t, first_loading && !last_loading, "offscreen thumbnails are not requested")
	testing.expect(t, clay.GetElementData(clay.ID("GifTileLoading0")).found)
	testing.expect(
		t,
		!clay.GetElementData(clay.ID("GifNext")).found &&
		!clay.GetElementData(clay.ID("GifPrevious")).found,
	)
	clay.SetPointerState({0, 0}, false)
	handle_gif_picker(&ui)
	testing.expect(t, ui.gif_job == nil, "do not fetch more metadata at the top")
	scroll := clay.GetScrollContainerData(clay.ID("GifGrid"))
	scroll.scrollPosition.y =
		scroll.scrollContainerDimensions.height - scroll.contentDimensions.height
	position := scroll.scrollPosition.y
	handle_gif_picker(&ui)
	testing.expect(t, ui.gif_job != nil, "reaching the end requests the next page")
	if ui.gif_job != nil {
		testing.expect_value(t, ui.gif_job.page, 2)
		append(&ui.gif_job.items, Gif_Item{title = strings.clone("Next page")})
		ui.gif_job.worker = thread.create_and_start(proc() {})
		thread.join(ui.gif_job.worker); gif_drain(&ui)
		testing.expect_value(t, len(ui.gif_hits), GIF_PAGE_SIZE + 1)
		testing.expect_value(t, ui.gif_hits[0].title, "Result 0")
		testing.expect_value(t, scroll.scrollPosition.y, position)
		testing.expect(t, !ui.gif_more, "stop when the provider has no next page")
	}
	scroll.scrollPosition^ = {}
	// A broken full GIF disappears while other results remain usable.
	ui.gif_hits[0].url = strings.clone("https://gifsnap.com/broken")
	broken := gif_start(&ui, .Preview)
	broken.item = gif_item_clone(ui.gif_hits[0])
	broken.error = "Couldn't load the GIF. Please try again."
	broken.worker = thread.create_and_start(proc() {})
	thread.join(broken.worker); gif_drain(&ui)
	testing.expect(t, ui.gif_hits[0].failed)
	testing.expect_value(t, len(gif_matches(&ui)), GIF_PAGE_SIZE)
	testing.expect_value(t, ui.gif_error, "")
	for &item in ui.gif_hits {item.failed = true}
	for _ in 0 ..< 8 {anim_frame += 1; build_layout(&ui, 0)}
	testing.expect_value(t, len(gif_matches(&ui)), 0)
	empty_box := clay.GetElementData(clay.ID("GifEmpty")).boundingBox
	grid_box := clay.GetElementData(clay.ID("GifGrid")).boundingBox
	testing.expect(t, empty_box.width >= grid_box.width - 1, "the error uses the full grid width")
	testing.expect(
		t,
		clay.GetElementData(clay.ID("GifEmpty")).found &&
		clay.GetElementData(clay.ID("GifRetry")).found,
	)
	gif_retry(&ui)
	testing.expect_value(t, len(gif_matches(&ui)), GIF_PAGE_SIZE + 1)
	ui.gif_saved = true
	// Stage through the real control. It preserves the draft and reply and never sends.
	bytes, _ := base64.decode("R0lGODlhAQABAIAAAAAAAP///yH5BAAAAAAALAAAAAABAAEAAAIBRAA7")
	ui.gif_view = video_view_make(bytes, .Loop)
	ui.gif_library[0].url = strings.clone("https://gifsnap.com/test")
	ui.gif_selected = gif_item_clone(ui.gif_library[0])
	ui.replying = "reply-target"
	for _ in 0 ..< 8 {anim_frame += 1; build_layout(&ui, 0)}
	press(t, &ui, clay.ID("GifTile", 0))
	testing.expect_value(t, len(ui.staged), 1)
	testing.expect_value(t, string(ui.compose[:]), "Keep your draft")
	testing.expect_value(t, ui.replying, "reply-target")
	testing.expect(t, !ui.picker_open && ui.focus == .Compose)
	if len(ui.staged) ==
	   1 {testing.expect_value(t, ui.staged[0].media_type, "image/gif"); remove_staged(&ui, 0)}
	ui.adding_quick = true; ui.gif_tab = true
	open_picker(&ui, ""); testing.expect(t, !ui.gif_tab)
	if os.get_env("WN_TEST_GIF_LIVE", context.temp_allocator) != "" {
		start_pic_worker(); defer stop_pic_worker()
		rl.SetWindowSize(900, 760); clay.SetLayoutDimensions({900, 760})
		rl.SetTargetFPS(30)
		ui.adding_quick = false; ui.gif_tab = true; ui.gif_saved = false
		ed_set(&ui, &ui.picker_filter, "cat")
		gif_search(&ui); gif_drain(&ui)
		thread.join(ui.gif_job.worker); gif_drain(&ui)
		testing.expect_value(t, ui.gif_error, "")
		testing.expect(t, len(ui.gif_hits) > 0, "keyless live search returns GIFs")
		if len(ui.gif_hits) > 0 {
			preview := gif_start(&ui, .Preview); preview.item = gif_item_clone(ui.gif_hits[0])
			gif_drain(&ui); thread.join(ui.gif_job.worker); gif_drain(&ui)
			testing.expect_value(t, ui.gif_error, "")
			testing.expect(t, ui.gif_view != nil)
			if ui.gif_view != nil {
				for _ in 0 ..< 150 {
					drain_pics(); advance_videos(); anim_frame += 1
					commands := build_layout(&ui, 0)
					rl.BeginDrawing()
					draw_frame(&commands)
					rl.EndDrawing()
				}
				commands := build_layout(&ui, 0)
				rl.BeginDrawing()
				draw_frame(&commands)
				rl.TakeScreenshot("/tmp/wn-gif-live-preview.png")
				rl.EndDrawing()
			}
		}
	}
}
