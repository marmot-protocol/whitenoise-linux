package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:testing"
import rl "sdlrl"

@(private = "file")
SIGNAL_V0 :: "rxqb-hxff-pkqx-cxxt-bcpd-xnmx-szgz-ctzb"
@(private = "file")
SIGNAL_V1 :: "rxqbhxff-pkqxcxxt-bcpdxnmx-szgzctzb-bc-bbbbbbbc"
@(private = "file")
SIGNAL_URL :: "https://signal.link/call/#key=" + SIGNAL_V0

@(test)
signal_call_links :: proc(t: ^testing.T) {
	for c in ([]struct {
			url, key: string,
		}{{SIGNAL_URL, SIGNAL_V0}, {"https://signal.link/call#key=" + SIGNAL_V0, SIGNAL_V0}, {"https://signal.link/call/#key=" + SIGNAL_V1, SIGNAL_V1}, {"https://signal.link/call/#epk=abc&key=" + SIGNAL_V1, SIGNAL_V1}, {"https://signal.link/call/#key=" + SIGNAL_V0 + "&flag", SIGNAL_V0}}) {
		key, ok := signal_call_key(c.url)
		testing.expect(t, ok, c.url)
		testing.expect_value(t, key, c.key)
	}
	for url in ([]string{"http://signal.link/call/#key=" + SIGNAL_V0, "https://signal.link.evil/call/#key=" + SIGNAL_V0, "https://evil.example/https://signal.link/call/#key=" + SIGNAL_V0, "https://signal.link/call/?key=" + SIGNAL_V0, "https://signal.link/call/#", "https://signal.link/call/#key", "https://signal.link/call/#key=", "https://signal.link/call/#other=" + SIGNAL_V0, "https://signal.link/call/#key=" + SIGNAL_V0 + "-", "https://signal.link/call/#key=rxqb-hxff-pkqx-cxxt-bcpd-xnmx-szgz", "https://signal.link/call/#key=rxqbhxff-pkqx-cxxt-bcpd-xnmx-szgz-ctzb", "https://signal.link/call/#key=axqb-hxff-pkqx-cxxt-bcpd-xnmx-szgz-ctzb", "https://signal.link/call/#key=RXQB-HXFF-PKQX-CXXT-BCPD-XNMX-SZGZ-CTZB", "https://signal.link/call/#key=" + SIGNAL_V0 + "&key=" + SIGNAL_V0, "https://signal.link/call/#key=" + SIGNAL_V0 + "&&a=1", "https://signal.link/call/#key=" + SIGNAL_V0 + "=x"}) {
		_, ok := signal_call_key(url)
		testing.expect(t, !ok, url)
	}

	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	defer wrap_clear()
	text := "Join " + SIGNAL_URL + ". Then\n" + SIGNAL_URL
	for width in ([]f32{0, 120, 1200}) {
		cards := 0
		for line in wrapped_lines(text, width, 14, .Cards) {
			part := text[line.start:line.end]
			if _, ok := signal_call_key(part); ok {
				testing.expect_value(t, part, SIGNAL_URL)
				cards += 1
			}
		}
		testing.expect_value(t, cards, 2)
	}
	testing.expect_value(t, len(wrapped_lines(text, 0, 14, .Text)), 2)
}

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=signal_layout
@(test)
signal_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "signal_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(600, 400, "Signal call cards")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	load_themes()
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {600, 400})
	defer delete(memory)
	defer wrap_clear()
	ui: Ui_State
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	gh_cards_on = true
	defer {gh_cards_on = false}
	for theme in ([]int{0, 1}) {
		apply_theme(theme, 0)
		for width in ([]f32{240, 360}) {
			for frame in 0 ..< 3 {
				clay.SetPointerState({24, 24}, false)
				link_hover = ""
				clay.BeginLayout()
				if clay.UI(clay.ID("Timeline"))(
				{
					layout = {
						sizing = {
							width = clay.SizingFixed(width + 78),
							height = clay.SizingGrow(),
						},
						layoutDirection = .TopToBottom,
						padding = clay.PaddingAll(20),
						childGap = 16,
					},
					backgroundColor = CARD,
				},
				) {
					body_line(1, SIGNAL_URL, 14, TEXT, {5, 15})
				}
				commands := clay.EndLayout(0)
				if frame < 2 {continue}
				testing.expect_value(t, link_hover, SIGNAL_URL)
				data := clay.GetElementData(clay.ID("SignalCard", 128))
				testing.expect(t, data.found)
				testing.expect(t, data.boundingBox.width <= width)
				rl.BeginDrawing()
				clay_raylib_render(&commands)
				rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-signal-%d-%d.png", theme, int(width)))
				rl.EndDrawing()
			}
		}
	}
}
