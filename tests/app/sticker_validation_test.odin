package main

import "base:runtime"
import "core:testing"
import "nendo"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=sticker_input_validation
// Exercise the real Add pack controls. Blank input fails at once; MDK parses
// everything else, so a lookup shows progress until it returns.
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
		row_menu         = -1,
		member_menu      = -1,
		selected_contact = -1,
		sticker_loaded   = true,
		sticker_open     = true,
		sticker_page     = .AddPack,
		focus            = .Compose,
	}
	ui.prefs.rail_w = RAIL_W_MIN
	ui.prefs.reduce_motion = true
	append(&ui.accounts, Account_Row_Ui{name = "Test"})
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Stickers"})
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	defer {
		sticker_pack_free(ui.sticker_pack)
		sticker_ref_free(ui.sticker_selected)
		delete(ui.sticker_input); delete(ui.sticker_preview)
		sticker_stop()
	}
	draw :: proc(ui: ^Ui_State) {
		for _ in 0 ..< 8 {anim_frame += 1; build_layout(ui, 0)}
	}
	press :: proc(t: ^testing.T, ui: ^Ui_State, id: string) {
		data := nendo.element(nendo.id(id, 0))
		testing.expect(t, data.found)
		nendo.set_pointer(
			{data.rect.x + data.rect.width / 2, data.rect.y + data.rect.height / 2},
			.Up,
		)
		forced_release = true
		handle_sticker_panel(ui)
		forced_release = false
	}
	lookup :: proc(t: ^testing.T, ui: ^Ui_State, input: string, keyboard: bool) {
		clear(&ui.sticker_input); append(&ui.sticker_input, input)
		draw(ui)
		if keyboard {
			rl.PushKey(.ENTER, true)
			handle_sticker_panel(ui)
			rl.PushKey(.ENTER, false)
		} else {press(t, ui, "StickerLookup")}
	}
	failed :: "Couldn't load the pack. Check your relay settings and try again."
	for keyboard in ([]bool{false, true}) {
		for input in ([]string{"", "  "}) {
			lookup(t, &ui, input, keyboard)
			testing.expect_value(t, ui.sticker_page, Sticker_Page.AddPack)
			testing.expect_value(t, len(sticker_jobs), 0)
			testing.expect_value(t, ui.sticker_error, "Enter a valid pack link or address.")
			draw(&ui)
			testing.expect(t, !nendo.element(nendo.id("StickerRetry", 0)).found)
		}
		lookup(t, &ui, "not a pack", keyboard)
		testing.expect_value(t, len(sticker_jobs), 1)
		if len(sticker_jobs) == 1 {
			testing.expect_value(t, sticker_jobs[0].op, Sticker_Operation.Pack)
			testing.expect_value(t, sticker_jobs[0].input, "not a pack")
		}
		testing.expect_value(t, ui.sticker_error, "")
		draw(&ui)
		testing.expect(
			t,
			nendo.element(nendo.id("StickerLookupBusy")).found,
			"a lookup shows progress before the relay answers",
		)
		// A nil client fails the lookup; the form stays for correction.
		sticker_test_drain(&ui)
		testing.expect_value(t, ui.sticker_page, Sticker_Page.AddPack)
		testing.expect_value(t, ui.sticker_error, failed)
		draw(&ui)
		testing.expect(t, !nendo.element(nendo.id("StickerLookupBusy")).found)
		testing.expect(t, !nendo.element(nendo.id("StickerRetry", 0)).found)
	}
	// A pack opened from a message can retry the same lookup.
	coordinate :: "30031:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:tiny"
	sticker_show(&ui, {pack = coordinate})
	testing.expect_value(t, ui.sticker_page, Sticker_Page.Pack)
	testing.expect_value(t, len(sticker_jobs), 1)
	draw(&ui)
	testing.expect(t, nendo.element(nendo.id("StickerPackBusy")).found)
	sticker_test_drain(&ui)
	testing.expect_value(t, ui.sticker_error, failed)
	draw(&ui)
	press(t, &ui, "StickerRetry")
	testing.expect_value(t, ui.sticker_error, "")
	testing.expect(
		t,
		len(sticker_jobs) == 1 && sticker_jobs[0].input == coordinate,
		"Retry must enqueue another lookup, not just dismiss the error",
	)
	sticker_test_drain(&ui)
}
