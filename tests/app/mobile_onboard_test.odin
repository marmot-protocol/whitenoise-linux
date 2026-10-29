package main

import "base:runtime"
import "core:os"
import "core:sync"
import "core:testing"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
Mobile_Onboard_Surface :: enum {
	Login_Menu,
	Login_Form,
	Login_Bunker,
	Login_Pair,
	Gate,
	Password,
	Confirm,
	Palette,
	Link,
	Checklist,
}

@(private)
mobile_onboard_frame :: proc(ui: ^Ui_State, surface: Mobile_Onboard_Surface) {
	clear(&drag_targets)
	anim_tick(1.0 / 60)
	clay.UpdateScrollContainers(false, {}, 1.0 / 60)
	if surface == .Gate {gate_layout(ui); return}
	clay.BeginLayout()
	if clay.UI(clay.ID("MobileOnboardRoot"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			childAlignment = {x = .Center, y = .Center},
		},
	},
	) {
		switch surface {
		case .Login_Menu, .Login_Form, .Login_Bunker, .Login_Pair:
			login_pane(ui)
		case .Password:
			vault_pw_modal(ui)
		case .Confirm:
			confirm_modal(ui)
		case .Palette:
			palette_modal(ui)
		case .Link:
			link_modal(ui)
		case .Checklist:
			get_started_pane(ui)
		case .Gate:
		}
	}
	clay.EndLayout(0)
}

// Like settings_viewport, this owns a headless SDL process and must be
// selected explicitly rather than sharing a window with unrelated tests.
@(test)
mobile_onboard_viewport :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "mobile_onboard_viewport" {return}
	context.allocator = runtime.default_context().allocator
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	home, err := os.make_directory_temp("", "wn-mobile-onboard", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(home)
	previous_home := data_home
	data_home = home
	defer {vault_delete(); data_home = previous_home; gate_close()}

	rl.InitWindow(390, 740, "Mobile onboarding viewport")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	init_fonts()
	load_themes()
	apply_theme(0, 0)
	set_locale("en")
	previous := clay.GetCurrentContext()
	memory: []u8
	init_layout(&memory, 32768, {390, 740})
	defer {clay.SetCurrentContext(previous); delete(memory)}
	ui := Ui_State {
		selected = -1,
		row_menu = -1,
	}
	ui.prefs = default_prefs()
	ui.prefs.reduce_motion = true
	g_ui, g_prefs = &ui, &ui.prefs
	defer {g_ui, g_prefs = nil, nil}
	ui.confirm = {
		kind = .Delete_All,
		name = "A message you are about to delete",
	}
	ui.link_url = "https://a-very-long-untrusted-host.example.org/a/long/path?detail=do-not-truncate-the-trusted-host"
	pal_refresh(&ui)
	defer delete(ui.pal_hits)

	for size in ([][2]i32{{320, 640}, {360, 640}, {390, 740}, {430, 740}, {640, 320}, {740, 280}, {320, 220}, {1280, 800}}) {
		rl.SetWindowSize(size[0], size[1])
		viewport := clay.Dimensions{f32(size[0]), f32(size[1])}
		clay.SetLayoutDimensions(viewport)
		for surface in Mobile_Onboard_Surface {
			ui.login_method = surface == .Login_Menu ? .Menu : .Import
			if surface == .Login_Bunker {ui.login_method = .Bunker}
			if surface == .Login_Pair {ui.login_method = .Pair}
			for _ in 0 ..< 3 {mobile_onboard_frame(&ui, surface)}
			container, action := clay.ID("LoginCard"), clay.ID("LoginProxy")
			switch surface {
			case .Login_Menu:
			case .Login_Form, .Login_Bunker, .Login_Pair:
				action = clay.ID("LoginGo")
			case .Gate:
				container, action = clay.ID("GateCard"), clay.ID("GateGo")
			case .Password:
				container, action = clay.ID("VaultPwBody"), clay.ID("VaultPwNew2Box")
			case .Confirm:
				container, action = clay.ID("ConfirmModal"), clay.ID("ConfirmGo")
			case .Palette:
				container, action =
					clay.ID("PalResults"),
					clay.ID("PalRow", u32(tap_size() ? len(ui.pal_hits) - 1 : PAL_ROWS_MAX - 1))
			case .Link:
				container, action = clay.ID("LinkModal"), clay.ID("LinkGo")
			case .Checklist:
				container, action = clay.ID("GetStarted"), clay.ID("StepChat")
			}
			data := clay.GetElementData(container)
			b := data.boundingBox
			testing.expectf(
				t,
				data.found &&
				b.width > 0 &&
				b.height > 0 &&
				b.x >= -0.1 &&
				b.y >= -0.1 &&
				b.x + b.width <= viewport.width + 0.1 &&
				b.y + b.height <= viewport.height + 0.1,
				"%v viewport %v must fit %v",
				surface,
				b,
				viewport,
			)
			if scroll := clay.GetScrollContainerData(container); scroll.found {
				target := clay.GetElementData(action).boundingBox
				delta := min(target.y - b.y, 0) + max(target.y + target.height - b.y - b.height, 0)
				scroll.scrollPosition.y = clamp(
					scroll.scrollPosition.y - delta,
					-max(
						scroll.contentDimensions.height - scroll.scrollContainerDimensions.height,
						0,
					),
					0,
				)
			}
			mobile_onboard_frame(&ui, surface)
			destination := clay.GetElementData(action)
			r := destination.boundingBox
			testing.expectf(
				t,
				destination.found &&
				r.x >= b.x - 0.1 &&
				r.x + r.width <= b.x + b.width + 0.1 &&
				r.y + r.height <= b.y + b.height + 0.1 &&
				r.y + r.height > b.y,
				"%v final action %v must be reachable by scrolling %v",
				surface,
				r,
				b,
			)
			if tap_size(
				
			) {testing.expectf(t, r.height >= 43.9, "%v must retain a finger-sized final control", surface)}
			if surface == .Password {
				for id in ([]string{"VaultPwClose", "VaultPwCancel", "VaultPwGo"}) {
					control := clay.GetElementData(clay.ID(id))
					box := control.boundingBox
					testing.expectf(
						t,
						control.found && box.y >= 0 && box.y + box.height <= viewport.height + 0.1,
						"Password dialog %s must remain visible with the keyboard",
						id,
					)
				}
			}
		}
	}

	// Existing vaults keep the weaker-password unlock path and the reset
	// action; phone layout must not turn this into the create-only form.
	testing.expect_value(t, vault_create("x"), Vault_Err.None)
	vault_relock()
	rl.SetWindowSize(320, 220)
	clay.SetLayoutDimensions({320, 220})
	mobile_onboard_frame(&ui, .Gate)
	testing.expect(t, clay.GetElementData(clay.ID("GateReset")).found)
	testing.expect(t, !clay.GetElementData(clay.ID("GatePw2Box")).found)
}
