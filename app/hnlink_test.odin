package main

import "core:sync"
import "core:testing"
import "base:runtime"
import "core:fmt"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
hn_links :: proc(t: ^testing.T) {
	url :: "https://news.ycombinator.com/item?id=49749369"
	for link in ([]string{url, url + "#comments", url + "&foo=bar", "http://news.ycombinator.com/item?foo=bar&id=049749369"}) {
		testing.expect_value(t, hn_ref(link), "49749369")
	}
	for link in ([]string{
		"https://news.ycombinator.com.evil/item?id=1",
		"https://news.ycombinator.com@evil/item?id=1",
		"https://http://news.ycombinator.com/item?id=1",
		"https://news.ycombinator.com/user?id=1",
		"https://news.ycombinator.com/item?id=",
		"https://news.ycombinator.com/item?id=-1",
		"https://news.ycombinator.com/item?id=0",
		"https://news.ycombinator.com/item?id=1/2",
		"https://news.ycombinator.com/item?id=1&id=2",
		"https://news.ycombinator.com/item?other=1",
		"https://news.ycombinator.com/item#id=1",
	}) {
		testing.expect(t, hn_ref(link) == "", link)
	}
	card := hn_parse(transmute([]u8)string(`{"title":"Ask HN: A &amp; B &#39;test&#39;","by":"author","type":"story"}`))
	defer delete(card.title)
	defer delete(card.author)
	testing.expect_value(t, card.title, "Ask HN: A & B 'test'")
	testing.expect_value(t, card.author, "author")
	plain := hn_parse(transmute([]u8)string(`{"title":"Minimal Phone 2"}`))
	defer delete(plain.title)
	defer delete(plain.author)
	testing.expect_value(t, plain.title, "Minimal Phone 2")
	testing.expect_value(t, plain.author, "")
	for body in ([]string{"null", "[]", "invalid", `{"title":123}`, `{"title":"Hidden","deleted":true}`, `{"title":"Hidden","dead":true}`}) {
		testing.expect_value(t, hn_parse(transmute([]u8)body).title, "")
	}
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	defer wrap_clear()
	text := "Before " + url + " after\n" + url
	for width in ([]f32{0, 120, 1200}) {
		cards := 0
		for line in wrapped_lines(text, width, 14, .Cards) {
			part := text[line.start:line.end]
			if hn_ref(part) != "" {
				testing.expect_value(t, part, url)
				cards += 1
			}
		}
		testing.expect_value(t, cards, 2)
	}
	testing.expect_value(t, len(wrapped_lines(text, 0, 14, .Text)), 2)
	testing.expect_value(t, len(wrapped_lines(text, 0, 14, .Compose)), 2)
}

// SDL_VIDEODRIVER=dummy odin test app -define:ODIN_TEST_NAMES=hn_layout
@(test)
hn_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "hn_layout" { return }
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(600, 600, "Hacker News cards")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes()
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {600, 600})
	defer delete(memory)
	defer wrap_clear()
	ui: Ui_State
	g_ui, g_prefs = &ui, &ui.prefs
	defer { g_ui, g_prefs = nil, nil }
	url :: "https://news.ycombinator.com/item?id=49749369"
	hn_cards["49749369"] = {"Minimal Phone 2", "nashashmi"}
	gh_cards_on = true
	defer { gh_cards_on = false; clear(&hn_cards) }
	for theme in ([]int{0, 1}) {
		apply_theme(theme, 0)
		for width in ([]f32{240, 360}) {
			for frame in 0 ..< 3 {
				clay.SetPointerState({24, 24}, false)
				link_hover = ""
				clay.BeginLayout()
				if clay.UI(clay.ID("Timeline"))({layout = {sizing = {width = clay.SizingFixed(width + 78), height = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 16}, backgroundColor = CARD}) {
					body_line(1, url, 14, TEXT, {5, 15})
					hn_card(2, "49749369", url)
					hn_cards["42"] = {}
					hn_card(3, "42", "https://news.ycombinator.com/item?id=42")
				}
				commands := clay.EndLayout(0)
				if frame < 2 { continue }
				testing.expect_value(t, link_hover, url)
				for id in ([]u32{128, 2, 3}) {
					data := clay.GetElementData(clay.ID("HnCard", id))
					testing.expect(t, data.found)
					testing.expect(t, data.boundingBox.width <= width)
				}
				rl.BeginDrawing()
				clay_raylib_render(&commands)
				rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-hn-%d-%d.png", theme, int(width)))
				rl.EndDrawing()
			}
		}
	}
}
