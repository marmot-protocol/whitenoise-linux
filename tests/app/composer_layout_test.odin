package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "nendo"
import rl "sdlrl"

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=composer_layout
@(test)
composer_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "composer_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1200, 800, "Composer regression")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {1200, 800})
	defer delete(memory)
	ui := Ui_State {
		row_menu         = -1,
		member_menu      = -1,
		selected_contact = -1,
		focus            = .Compose,
	}
	ui.prefs.stt_enabled = true
	ui.prefs.rail_w = RAIL_W_MIN
	ui.prefs.composer = composer_config(&ui.prefs)^
	ui.prefs.composer.layout = .Expanded
	for action in ([]Composer_Action{.Effect, .Poll, .Location, .Dictate, .Voice}) {
		ui.prefs.composer.slots[action] = .Right
	}
	ui.account_ref = "offline-fixture"
	append(&ui.accounts, Account_Row_Ui{name = "Test"})
	append(&ui.chats, Chat_Row_Ui{group_id = "test", title = "Composer"})
	for i in 0 ..< 20 {
		append(
			&ui.staged,
			Staged_File{name = fmt.aprintf("attachment-%d-with-a-long-name.wav", i)},
		)
	}
	pixel := [4]u8{255, 255, 255, 255}
	ui.staged[0].tex = new(rl.Texture2D)
	ui.staged[0].tex^ = rl.LoadTextureFromImage({data = raw_data(pixel[:]), width = 1, height = 1})
	ui.staged[0].tex.width = 10000 // A panoramic thumbnail must not widen the composer.
	defer {
		for len(ui.staged) > 0 {remove_staged(&ui, len(ui.staged) - 1)}
		delete(ui.staged)
	}
	body := "A first paragraph.\n\nA separate paragraph after a blank line.\n\n\nTwo blank lines before this paragraph."
	append(
		&ui.messages,
		Msg_Ui {
			id = strings.clone("message"),
			sender = strings.clone("Alice"),
			body = strings.clone(body),
			blocks = parse_md_text(body),
		},
	)
	defer {message_free(ui.messages[0]); delete(ui.messages); wrap_clear()}
	defer {delete(ui.accounts); delete(ui.chats); delete(ui.compose); delete(ui.rail_rows)}
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	for zoom in ([]f32{1, 1.875}) {
		UI_ZOOM = zoom
		refresh_ui_scale()
		for width in ([]i32{1200, 720, 420}) {
			rl.SetWindowSize(i32(f32(width) * zoom), i32(800 * zoom))
			nendo.set_dimensions({f32(width), 800})
			for suffix in ([]string{"tail", "tall", "👩🏽‍💻🔥", "\n\nnext", "", "word word"}) {
				text := fmt.tprintf(
					"%s%s",
					strings.repeat("a word ", 200, context.temp_allocator),
					suffix,
				)
				cached := compose_lines(text)
				copy_lines := make([][2]int, len(cached), context.temp_allocator)
				copy(copy_lines, cached)
				testing.expect(
					t,
					raw_data(cached) == raw_data(compose_lines(text)),
					"unchanged draft reuses line breaks",
				)
				wrap_clear()
				fresh := compose_lines(text)
				testing.expect_value(t, len(copy_lines), len(fresh))
				for line, i in copy_lines {testing.expect_value(t, line, fresh[i])}
			}
			for text in ([]string{"another small PR for yet another failed nightlyh simulator run:\n\nhttps://github.com/marmot-protocol/mdk/pull/1900", "Hello", strings.repeat("the quick brown fox jumps over the lazy dog ", 500, context.temp_allocator), strings.repeat("x", 10000, context.temp_allocator), strings.repeat("🔥", 100, context.temp_allocator), strings.repeat("👩🏽‍💻🇮🇹", 100, context.temp_allocator), strings.repeat("1️⃣#️⃣", 100, context.temp_allocator), strings.repeat(" ", 1000, context.temp_allocator)}) {
				ed_set(&ui, &ui.compose, text)
				for _ in 0 ..< 8 {
					build_layout(&ui, 0)
					box := nendo.element(nendo.id("ComposeBox")).rect
					testing.expect(
						t,
						box.x + box.width <= f32(width) + 0.01,
						"composer fits on every resize frame",
					)
				}
				commands := build_layout(&ui, 0)
				staged := nendo.scroll(nendo.id("StagedRow"))
				testing.expect(t, staged.found && staged.content.height > staged.viewport.height)
				testing.expect(t, staged.viewport.height <= 144)
				thumb := nendo.element(nendo.id("StagedThumb", 0)).rect
				testing.expect(t, thumb.width <= 80 && thumb.height <= 40)
				for id in ([]string{"ChatPane", "ChatHeader", "Composer", "ComposeBox", "StagedRow"}) {
					box := nendo.element(nendo.id(id)).rect
					testing.expect(t, box.x + box.width <= f32(width) + 0.01, id)
				}
				for _, i in ui.staged {
					box := nendo.element(nendo.id("StagedX", u32(i))).rect
					testing.expect(
						t,
						box.x + box.width <= f32(width) + 0.01,
						"attachment removal stays inside the window",
					)
				}
				clip := nendo.element(nendo.id("ComposeClip")).rect
				box := nendo.element(nendo.id("ComposeBox")).rect
				testing.expect(t, box.height <= 240 && box.y + box.height <= 800)
				testing.expect(t, nendo.element(nendo.id("Timeline")).rect.height > 100)
				for _, i in compose_lines(text) {
					row := nendo.element(nendo.id("ComposeLine", u32(i))).rect
					testing.expect(
						t,
						row.x >= clip.x && row.x + row.width <= clip.x + clip.width + 1,
						"wrapped line fits text viewport",
					)
					testing.expect(
						t,
						row.height <= 21,
						"nendo must not wrap a manually wrapped line again",
					)
				}
				for id in ([]string{"ComposeMoreBtn", "AttachBtn", "EmojiBtn", "LocationBtn", "MicBtn", "SendBtn"}) {
					element := nendo.element(nendo.id(id))
					testing.expect(t, element.found, id)
					button := element.rect
					testing.expect(
						t,
						button.y >= clip.y + clip.height,
						"controls sit below the text viewport",
					)
					testing.expect(
						t,
						button.x + button.width <= f32(width),
						"controls fit the pane",
					)
				}
				if nendo.scroll(nendo.id("ComposeClip")).content.height > clip.height {
					data := nendo.scroll(nendo.id("ComposeClip"))
					testing.expect(t, data.position.y < 0, "pasting follows the caret to the end")
					ed_begin(&ui, &ui.compose)
					ui.ed.selection = {0, 0}
					ed_end(&ui, &ui.compose)
					for _ in 0 ..< 3 {build_layout(&ui, 0)}
					testing.expect_value(t, data.position.y, f32(0))
					data.position.y = -40
					build_layout(&ui, 0)
					testing.expect_value(t, data.position.y, f32(-40))
					ui.ed.selection = {len(text), len(text)}
					for _ in 0 ..< 3 {build_layout(&ui, 0)}
					last_line :=
						nendo.element(nendo.id("ComposeLine", u32(len(compose_lines(text)) - 1))).rect
					testing.expect(
						t,
						last_line.y >= clip.y &&
						last_line.y + last_line.height <= clip.y + clip.height + 0.01,
						"caret remains visible",
					)
				}
				if len(text) > 10 {
					commands = build_layout(&ui, 0)
					rl.BeginDrawing()
					draw_frame(commands)
					rl.TakeScreenshot(
						fmt.ctprintf("/tmp/wn-composer-%d-%d.png", width, int(zoom * 100)),
					)
					rl.EndDrawing()
				}
				staged.position.y = staged.viewport.height - staged.content.height
				build_layout(&ui, 0)
				view := nendo.element(nendo.id("StagedRow")).rect
				last := nendo.element(nendo.id("StagedX", u32(len(ui.staged) - 1))).rect
				testing.expect(
					t,
					last.y >= view.y && last.y + last.height <= view.y + view.height + 0.01,
					"last attachment can be scrolled into view for removal",
				)
			}
		}
	}
	// A mention draws as a chip as wide as wrapping and hit tests measure it.
	npub := hex_npub("66675158e6338fe89fda418e42a0bf2a7a2b132504dd347f015a18971b644430")
	defer delete(npub)
	ed_set(&ui, &ui.compose, fmt.tprintf("hi @%s ok", npub))
	build_layout(&ui, 0)
	_, width := compose_atom(string(ui.compose[:]), 3)
	chip := nendo.element(nendo.id("SegMention", 0xE00 * 128 + 1))
	testing.expect(
		t,
		chip.found && abs(chip.rect.width - width) < 0.01,
		"composer mentions render as chips",
	)
	ui.editing = "message"
	build_layout(&ui, 0)
	testing.expect(
		t,
		!nendo.element(nendo.id("LocationBtn")).found,
		"editing cannot attach a location",
	)
	ui.editing = ""
	build_layout(&ui, 0)
	testing.expect(
		t,
		nendo.element(nendo.id("LocationBtn")).found,
		"new messages offer location again",
	)

	// The narrow toolbar keeps the first pins and moves the rest into More.
	testing.expect(t, !nendo.element(nendo.id("DictateBtn")).found)
	ui.compose_more = true
	build_layout(&ui, 0)
	menu := nendo.element(nendo.id("ComposeMoreMenu"))
	dictate := nendo.element(nendo.id("DictateBtn"))
	testing.expect(t, menu.found && dictate.found && dictate.rect.y >= menu.rect.y)
	ui.compose_more = false

	for len(ui.staged) > 0 {remove_staged(&ui, len(ui.staged) - 1)}
	ui.prefs.composer = {}
	ed_set(&ui, &ui.compose, "")
	build_layout(&ui, 0)
	clip := nendo.element(nendo.id("ComposeClip")).rect
	mic := nendo.element(nendo.id("MicBtn"))
	testing.expect(t, mic.found && mic.rect.x > clip.x && mic.rect.y < clip.y + clip.height)
	testing.expect(
		t,
		!nendo.element(nendo.id("SendBtn")).found,
		"voice uses Send's slot when empty",
	)
	ed_set(&ui, &ui.compose, "Two\nlines")
	build_layout(&ui, 0)
	clip = nendo.element(nendo.id("ComposeClip")).rect
	send := nendo.element(nendo.id("SendBtn"))
	testing.expect(
		t,
		send.found && send.rect.y >= clip.y + clip.height,
		"multiline text expands the toolbar",
	)
	testing.expect(t, !nendo.element(nendo.id("MicBtn")).found)

	legacy := `{"order":[5,2,1,3,4,6,7,8,9,10,11],"slots":{"Paste":1,"Files":1,"More":1,"Emoji":2,"Voice":4},"layout":1}`
	if !testing.expect_value(t, json.unmarshal_string(legacy, &ui.prefs.composer), nil) {return}
	if !testing.expect(t, composer_config_load(&ui.prefs.composer)) {return}
	build_layout(&ui, 0)
	attach := nendo.element(nendo.id("AttachBtn"))
	more := nendo.element(nendo.id("ComposeMoreBtn"))
	clip = nendo.element(nendo.id("ComposeClip")).rect
	testing.expect(
		t,
		attach.found &&
		more.found &&
		attach.rect.x < more.rect.x &&
		more.rect.y >= clip.y + clip.height,
		"existing toolbar order and layout survive migration",
	)
	testing.expect(
		t,
		!nendo.element(nendo.id("MicBtn")).found,
		"existing voice placement survives migration",
	)
	ui.compose_more = true
	build_layout(&ui, 0)
	testing.expect(
		t,
		nendo.element(nendo.id("PollBtn")).found &&
		nendo.element(nendo.id("ComposeTimestampBtn")).found &&
		!nendo.element(nendo.id("ComposePasteBtn")).found,
	)
	ui.prefs.reduce_motion = true
	ui.page, ui.settings_section, ui.settings_tab, ui.settings_level =
		.Settings, .General, COMPOSER_TAB, .Sheet
	commands := build_layout(&ui, 0)
	testing.expect(t, nendo.element(nendo.id("ComposerTile", u32(Composer_Action.Poll))).found)
	testing.expect(
		t,
		!nendo.element(nendo.id("ComposerTile", 5)).found,
		"the retired action cannot be pinned again",
	)
	rl.BeginDrawing()
	draw_frame(commands)
	rl.TakeScreenshot("/tmp/wn-composer-no-paste.png")
	rl.EndDrawing()

	poll := nendo.element(nendo.id("ComposerTile", u32(Composer_Action.Poll))).rect
	point := nendo.Vector2{poll.x + poll.width * 0.5, poll.y + poll.height * 0.5}
	nendo.set_pointer(point, .Up)
	forced_press, forced_release = true, true
	defer {forced_press, forced_release = false, false}
	handle_composer_drag(&ui)
	forced_press, forced_release = false, false
	build_layout(&ui, 0)
	testing.expect(
		t,
		nendo.element(nendo.id("ComposerPlace", u32(Composer_Slot.Left))).found,
		"a press and release in the same frame opens the shortcut's placement controls",
	)

	nendo.set_pointer(point, .Down)
	forced_press = true
	if !testing.expect(t, handle_composer_drag(&ui), "the editor owns the tile press") {return}
	ui.page = .Chats
	nendo.set_pointer(point, .Up)
	forced_press, forced_release = false, true
	testing.expect(
		t,
		handle_composer_drag(&ui),
		"leaving settings cannot pass the release to chat",
	)
}
