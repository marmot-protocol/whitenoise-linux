package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "base:runtime"
import "core:testing"
import rl "sdlrl"

@(test)
profile_message_layout :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "profile_message_layout" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(1024, 700, "Profile message")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts(); load_themes(); apply_theme(0, 0)
	memory: []u8
	previous := clay.GetCurrentContext()
	init_layout(&memory, 32768, {1024, 700})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	key :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	ui := Ui_State {
		account_ref = key,
		peer_hex    = key,
		peer_open   = true,
	}
	ui.prefs = default_prefs(); ui.prefs.reduce_motion = true
	locale := g_prefs != nil ? g_prefs.locale : "en"
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil; wrap_clear(); profile_session_clear()}
	defer set_locale(locale)
	for language in ([]string{"en", "it", "de", "ja"}) {
		set_locale(language)
		for width in ([]f32{360, 1024}) {
			clay.SetLayoutDimensions({width, 700})
			for account in ([]string{key, "self"}) {
				ui.account_ref = account
				for _ in 0 ..< 3 {
					anim_tick(1.0 / 60)
					clay.BeginLayout()
					if clay.UI(clay.ID("ProfileMessageRoot"))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(width),
								height = clay.SizingFixed(700),
							},
						},
					},
					) {peer_modal(&ui)}
					clay.EndLayout(0)
				}
				message := clay.GetElementData(clay.ID("PeerMessage"))
				testing.expect_value(t, message.found, account != key)
				if !message.found {continue}
				modal := clay.GetElementData(clay.ID("PeerModal")).boundingBox
				identity :=
					clay.GetElementData(clay.ID("ProfileCardKey", PEER_CARD_ID)).boundingBox
				button := message.boundingBox
				testing.expect(t, button.y >= identity.y + identity.height)
				testing.expect(
					t,
					button.x >= modal.x && button.x + button.width <= modal.x + modal.width,
				)
				testing.expect(t, button.y + button.height <= modal.y + modal.height)
				profile := clay.GetElementData(clay.ID("PeerViewProfile")).boundingBox
				testing.expect(
					t,
					button.x + button.width <= profile.x || button.y + button.height <= profile.y,
				)
				for name in ([]string{"PeerCopyNpub", "PeerViewProfile"}) {
					box := clay.GetElementData(clay.ID(name)).boundingBox
					testing.expect(
						t,
						box.x >= modal.x && box.x + box.width <= modal.x + modal.width,
					)
					testing.expect(
						t,
						box.y >= modal.y && box.y + box.height <= modal.y + modal.height,
					)
					clay.SetPointerState({box.x + box.width / 2, box.y + box.height / 2}, false)
					testing.expect(t, clay.PointerOver(clay.ID(name)))
				}
				clay.SetPointerState(
					{button.x + button.width / 2, button.y + button.height / 2},
					false,
				)
				testing.expect(t, clay.PointerOver(clay.ID("PeerMessage")))
			}
		}
	}
}
