package main

import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:testing"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(test)
gh_card_lines :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	defer wrap_clear()
	url :: "https://github.com/marmot-protocol/mdk/pull/1903"
	text := "Before " + url + " after\n" + url + " https://example.com"
	plain := wrapped_lines(text, 0, 14)
	testing.expect_value(t, len(plain), 2)
	for width in ([]f32{0, 120, 1200}) {
		lines := wrapped_lines(text, width, 14, .Cards)
		cards := 0
		for line in lines {
			part := text[line.start:line.end]
			if _, ok := gh_ref(part); ok {
				testing.expect_value(t, part, url)
				cards += 1
			}
		}
		testing.expect_value(t, cards, 2)
	}
	testing.expect_value(t, len(wrapped_lines(text, 0, 14)), 2)
}

// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=gh_card_layout
@(test)
gh_card_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "gh_card_layout" { return }
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(900, 1200, "Pull request cards")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1.5, 1.5
	load_themes()
	init_fonts()
	memory: []u8
	init_layout(&memory, 32768, {600, 800})
	defer delete(memory)
	ui: Ui_State
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer { g_ui, g_prefs = nil, nil }
	refs := [5]Gh_Ref{
		{"marmot-protocol", "whitenoise-android", "2624", "https://github.com/marmot-protocol/whitenoise-android/pull/2624", true},
		{"marmot-protocol", "mdk", "1903", "https://github.com/marmot-protocol/mdk/pull/1903", true},
		{"marmot-protocol", "mdk", "1904", "https://github.com/marmot-protocol/mdk/pull/1904", true},
		{"marmot-protocol", "mdk", "1905", "https://github.com/marmot-protocol/mdk/issues/1905", false},
		{"marmot-protocol", "mdk", "1906", "https://github.com/marmot-protocol/mdk/pull/1906", true},
	}
	cards := [5]Gh_Card{
		{"Reduce repeated conversation presentation work", "open", "dannym-arx"},
		{"Report missing invitation key packages", "merged", "dannym-arx"},
		{"A draft with a longer title that wraps across multiple lines", "draft", "a-long-author-name"},
		{"Restore profile pictures after a restart", "closed", "dannym-arx"},
		{},
	}
	for ref, i in refs { gh_cards[gh_key(ref, context.allocator)] = cards[i] }
	for theme in ([]int{0, 1}) {
		apply_theme(theme, 0)
		for width in ([]f32{240, 360}) {
			for frame in 0 ..< 3 {
				clay.SetPointerState({24, 24}, false)
				link_hover = ""
				clay.BeginLayout()
				if clay.UI(clay.ID("Timeline"))({layout = {sizing = {width = clay.SizingFixed(width + 78), height = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 16}, backgroundColor = CARD}) {
					for ref, i in refs { gh_card(u32(i), ref) }
				}
				commands := clay.EndLayout(0)
				if frame < 2 { continue }
				testing.expect_value(t, link_hover, refs[0].url)
				for _, i in refs {
					box := clay.GetElementData(clay.ID("GhCard", u32(i))).boundingBox
					testing.expect(t, box.width <= width)
					for key in ([]string{"GhCardRepo", "GhCardFoot", "GhCardOpen"}) {
						child := clay.GetElementData(clay.ID(key, u32(i))).boundingBox
						testing.expect(t, child.x >= box.x && child.x + child.width <= box.x + box.width, key)
					}
				}
				rl.BeginDrawing()
				rl.BeginMode2D({zoom = UI_ZOOM})
				clay_raylib_render(&commands)
				rl.EndMode2D()
				rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-pr-cards-%d-%d.png", theme, int(width)))
				rl.EndDrawing()
			}
		}
	}
	gh_cards_on = true
	defer { gh_cards_on = false; wrap_clear() }
	apply_theme(0, 0)
	for width in ([]f32{240, 520}) {
		text := fmt.tprintf("Before the pull request %s after the pull request", refs[0].url)
		for frame in 0 ..< 3 {
			clay.BeginLayout()
			if clay.UI(clay.ID("Timeline"))({layout = {sizing = {width = clay.SizingFixed(width + 78), height = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 8}, backgroundColor = CARD}) {
				body_text(32, text, 14, TEXT, true, width)
			}
			commands := clay.EndLayout(0)
			if frame < 2 { continue }
			lines := wrapped_lines(text, width, 14, .Cards)
			prev: clay.BoundingBox
			for line, i in lines {
				box := clay.GetElementData(clay.ID("BodyLine", 32 * 8 + line.index)).boundingBox
				testing.expect(t, box.x == 20 && box.width <= width)
				if i > 0 { testing.expect(t, box.y >= prev.y + prev.height) }
				prev = box
			}
			rl.BeginDrawing()
			rl.BeginMode2D({zoom = UI_ZOOM})
			clay_raylib_render(&commands)
			rl.EndMode2D()
			rl.TakeScreenshot(fmt.ctprintf("/tmp/wn-pr-body-%d.png", int(width)))
			rl.EndDrawing()
		}
	}
}
