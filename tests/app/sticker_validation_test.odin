package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=sticker_input_validation
// Exercise the real Add pack controls and bounded loopback lookup failures.
@(test)
sticker_input_validation :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "sticker_input_validation" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(900, 760, "Sticker validation")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {900, 760})
	defer delete(memory)
	ui := Ui_State {
		row_menu = -1,
		member_menu = -1,
		selected_contact = -1,
		sticker_loaded = true,
		sticker_open = true,
		sticker_page = .AddPack,
		focus = .Compose,
	}
	ui.prefs.rail_w = RAIL_W_MIN
	ui.prefs.reduce_motion = true
	append(&ui.accounts, "Test")
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Stickers"})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	defer {
		sticker_pack_free(ui.sticker_pack)
		delete(ui.sticker_input)
		for job in sticker_jobs {sticker_job_free(job)}
		clear(&sticker_jobs)
		delete(ui.prefs.fetch_relays)
	}
	draw :: proc(ui: ^Ui_State) {
		for _ in 0 ..< 8 {anim_frame += 1; build_layout(ui, 0)}
	}
	press :: proc(t: ^testing.T, ui: ^Ui_State, id: string) {
		data := clay.GetElementData(clay.ID(id, 0))
		testing.expect(t, data.found)
		clay.SetPointerState({data.boundingBox.x + data.boundingBox.width / 2,
			data.boundingBox.y + data.boundingBox.height / 2}, false)
		forced_release = true
		handle_sticker_panel(ui)
		forced_release = false
	}
	for input in ([]string{"", "  ", "not a pack", "naddr1broken"}) {
		for keyboard in ([]bool{false, true}) {
			clear(&ui.sticker_input); append(&ui.sticker_input, input)
			draw(&ui)
			if keyboard {
				rl.PushKey(.ENTER, true)
				handle_sticker_panel(&ui)
				rl.PushKey(.ENTER, false)
			} else {press(t, &ui, "StickerLookup")}
			testing.expect_value(t, ui.sticker_page, Sticker_Page.AddPack)
			testing.expect(t, !ui.sticker_loading)
			testing.expect_value(t, len(sticker_jobs), 0)
			testing.expect_value(t, ui.sticker_error,
				"Enter a valid pack link or address.")
			draw(&ui)
			testing.expect(t, !clay.GetElementData(clay.ID("StickerRetry", 0)).found,
				"Invalid input has not failed a network lookup and must not offer Retry")
		}
	}
	// Both accepted address forms still look up a pack. Closed loopback ports
	// exercise real network failure without depending on a public relay.
	coordinate :: "30031:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:tiny"
	relay :: "wss://127.0.0.1:9"
	append(&ui.prefs.fetch_relays, "wss://127.0.0.1:1")
	payload := make([dynamic]u8)
	defer delete(payload)
	append(&payload, 0, 4); append(&payload, "tiny")
	append(&payload, 1, u8(len(relay))); append(&payload, relay)
	append(&payload, 2, 32)
	for _ in 0 ..< 32 {append(&payload, 0xaa)}
	kind := u32(STICKER_PACK_KIND)
	append(&payload, 3, 4, u8(kind >> 24), u8(kind >> 16), u8(kind >> 8), u8(kind))
	address := bech32_encode("naddr", payload[:])
	defer delete(address)
	for input in ([]string{coordinate, address, strings.concatenate({"nostr:", address}, context.temp_allocator)}) {
		encoded := input != coordinate
		ui.sticker_page = .AddPack
		clear(&ui.sticker_input)
		append(&ui.sticker_input, input)
		draw(&ui)
		press(t, &ui, "StickerLookup")
		testing.expect_value(t, ui.sticker_page, Sticker_Page.Pack)
		testing.expect_value(t, ui.sticker_pack.coordinate, coordinate)
		testing.expect(t, ui.sticker_loading && ui.sticker_error == "")
		testing.expect_value(t, len(sticker_jobs), 1)
		draw(&ui)
		testing.expect(t, !clay.GetElementData(clay.ID("StickerRetry", 0)).found)
		for attempt in 0 ..< 2 {
			job := sticker_jobs[0]
			testing.expect_value(t, job.op, Sticker_Operation.Pack)
			testing.expect_value(t, job.input, coordinate)
			testing.expect_value(t, job.relays[0], encoded ? relay : ui.prefs.fetch_relays[0])
			drain_stickers(&ui, nil)
			for !thread.is_done(job.worker) {time.sleep(time.Millisecond)}
			drain_stickers(&ui, nil)
			testing.expect_value(t, len(sticker_jobs), 0)
			testing.expect(t, !ui.sticker_loading)
			testing.expect_value(t, ui.sticker_error,
				"Couldn't load the pack. Check your relay settings and try again.")
			draw(&ui)
			testing.expect(t, clay.GetElementData(clay.ID("StickerRetry", 0)).found)
			if attempt == 0 {
				press(t, &ui, "StickerRetry")
				testing.expect(t, ui.sticker_loading && ui.sticker_error == "")
				testing.expect(t, len(sticker_jobs) == 1,
					"Retry must enqueue another lookup, not just dismiss the error")
			}
		}
	}
	// A previous failed lookup must not make a new invalid input retryable.
	ui.sticker_page = .AddPack
	clear(&ui.sticker_input)
	draw(&ui)
	press(t, &ui, "StickerLookup")
	testing.expect_value(t, ui.sticker_error, "Enter a valid pack link or address.")
	testing.expect_value(t, len(sticker_jobs), 0)
	draw(&ui)
	testing.expect(t, !clay.GetElementData(clay.ID("StickerRetry", 0)).found)
}
