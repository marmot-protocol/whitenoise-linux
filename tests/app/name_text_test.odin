package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:fmt"
import "core:os"
import "core:testing"
import rl "sdlrl"
import stbtt "vendor:stb/truetype"

// SDL/font caches are global. Run alone with SDL_VIDEODRIVER=dummy and
// tests/odin.sh app -define:ODIN_TEST_NAMES=contact_name_text
@(test)
contact_name_text :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "contact_name_text" {return}
	rl.InitWindow(600, 280, "Contact name text")
	defer rl.CloseWindow()
	UI_SCALE = 1
	init_fonts()

	samples := [?]struct {
		font, text: string,
	} {
		{
			"NotoSansMath-Regular.ttf",
			"𝓓𝓮𝓮 𝕂𝕒𝕪 𝔦𝔰𝔬𝔩𝔞𝔟𝔢𝔩𝔩𝔞𝔯𝔱",
		},
		{"NotoSansSymbols-Regular.ttf", "🜁"},
		{"NotoSansSymbols2-Regular.ttf", "⭑⭒"},
	}
	for sample in samples {
		data, err := os.read_entire_file(string(res_font(sample.font)), context.allocator)
		testing.expect_value(t, err, nil)
		if err != nil {continue}
		defer delete(data)
		info: stbtt.fontinfo
		testing.expect(t, bool(stbtt.InitFont(&info, raw_data(data), 0)))
		for r in sample.text {
			testing.expect(t, stbtt.FindGlyphIndex(&info, r) != 0, sample.text)
		}
	}

	for scale in ([?]f32{1, 1.5, 2}) {
		rl.SetPixelScale(scale)
		for emoji in ([?]string{"🌻", "👩🏽‍💻", "🇮🇹", "1️⃣", "❤️", "😀"}) {
			testing.expect(t, text_emoji(emoji) != nil, emoji)
			for font in ([?]u16{FONT_BODY, FONT_TITLE, FONT_MONO}) {
				testing.expect_value(t, rl.MeasureTextLine(font, 24, emoji, 2).x, f32(26))
			}
			name := fmt.tprintf("%sX", emoji)
			testing.expect_value(t, hit_plain(name, 13, 24), len(emoji))
			testing.expect_value(t, rune_fit(name, 0, len(name), 1, 24), len(emoji))
		}
	}
	testing.expect(t, text_emoji("1") == nil)
	testing.expect(t, text_emoji("A") == nil)
	testing.expect(t, text_emoji("❤︎") == nil)
	testing.expect_value(
		t,
		rl.MeasureTextLine(FONT_BODY, 24, "A\uFE0E", 0),
		rl.MeasureTextLine(FONT_BODY, 24, "A", 0),
	)
	rl.SetPixelScale(1)
	rl.BeginDrawing()
	for name, i in ([?]string{"🌻 Dee Kay 🌻", "𝓓𝓮𝓮 𝕂𝕒𝕪", "🜁 isolabellart", "👩🏽‍💻 🇮🇹 1️⃣ ❤️ 😀😀", "日本語 · café · ⭑⭒"}) {
		rl.DrawTextLine(FONT_TITLE, 24, name, 24, 20 + f32(i) * 48, 0, {228, 231, 236, 255})
	}
	rl.TakeScreenshot("/tmp/wn-contact-text.png")
	rl.EndDrawing()

	memory: []u8
	init_layout(&memory, 32768, {900, 740})
	defer delete(memory)
	ui := Ui_State {
		page             = .Contacts,
		selected_contact = 0,
		row_menu         = -1,
		member_menu      = -1,
	}
	ui.prefs.rail_w = RAIL_W_MIN
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	append(&ui.accounts, "Test")
	append(
		&ui.contacts,
		Contact_Ui {
			id_hex = "contact",
			name = "🌻 isolabellart",
			npub = "npub17nd4y1234567890f6950x",
		},
	)
	for _ in 0 ..< 6 {
		append(&rel_list, Contact_Relay{url = "wss://relay.isolabellart.it/outbox", inbox = true})
	}
	for width in ([]f32{360, 600, 960, 1200}) {
		UI_ZOOM = 1.875
		rl.SetWindowSize(i32(width * UI_ZOOM), 1388)
		refresh_ui_scale()
		anim_set(clay.ID("RailWidth").id, RAIL_W_MIN)
		page_t = 1
		clay.SetLayoutDimensions({width, 740})
		for _ in 0 ..< 3 {build_layout(&ui, 0)}
		commands := build_layout(&ui, 0)
		for id in ([]string{"ContactPage", "ContactHero", "ContactHeroCol", "NickBox", "StartChatBtn", "CopyNpubBtn", "RelaysCard"}) {
			element := clay.GetElementData(clay.ID(id))
			testing.expect(t, element.found, id)
			testing.expect(
				t,
				element.boundingBox.x + element.boundingBox.width <= width + 0.01,
				fmt.tprintf("%s at %.0f", id, width),
			)
		}
		hero := clay.GetElementData(clay.ID("ContactHero")).boundingBox
		nick := clay.GetElementData(clay.ID("NickBox")).boundingBox
		testing.expect(t, nick.y >= hero.y + hero.height, "nickname has its own row")
		rl.BeginDrawing()
		rl.BeginMode2D({zoom = UI_ZOOM})
		draw_frame(&commands)
		rl.EndMode2D()
		rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-contact-layout-%d.png", int(width)))
		rl.EndDrawing()
	}
}
