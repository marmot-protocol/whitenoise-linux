package main

import "base:runtime"
import "core:os"
import "core:testing"
import rl "sdlrl"

@(test)
test_rail_fits :: proc(t: ^testing.T) {
	for rail_w in ([]int{0, RAIL_W_MIN, RAIL_W_DEFAULT, RAIL_W_MAX, 900}) {
		threshold := f32(clamp(rail_w, RAIL_W_MIN, RAIL_W_MAX)) + GUTTER_W + PAGE_W_MIN
		testing.expect(t, !rail_fits(threshold - 1, rail_w))
		testing.expect(t, rail_fits(threshold, rail_w))
		testing.expect(t, rail_fits(threshold + 1, rail_w))
	}
	testing.expect(t, !rail_fits(780, RAIL_W_MIN), "collapse at the reported window width")
	testing.expect(t, rail_fits(1200, RAIL_W_DEFAULT), "restore the list in a wide window")
}

// A two-card window too narrow for the saved rail collapses it on its
// own; the expand toggle must still open the list there, and collapse
// it again. Settings pins the rail shut, so its toggle flips the pref
// without forcing the list open for the Chats page later.
// SDL_VIDEODRIVER=dummy tests/odin.sh app -define:ODIN_TEST_NAMES=rail_expand_narrow
@(test)
rail_expand_narrow :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "rail_expand_narrow" {return}
	context.allocator = runtime.default_context().allocator
	rl.InitWindow(780, 700, "Rail expand")
	defer rl.CloseWindow()
	UI_ZOOM, UI_SCALE = 1, 1
	home :: "/tmp/wn-odin-rail-test"
	previous_config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", home)
	defer os.set_env("XDG_CONFIG_HOME", previous_config)
	defer os.remove_all(home)

	ui: Ui_State
	ui.page = .Chats
	ui.prefs.rail_w = RAIL_W_MIN
	ui.prefs.reduce_motion = true
	g_prefs = &ui.prefs
	defer g_prefs = nil
	width :: proc(ui: ^Ui_State) -> f32 {
		anim_frame += 1
		return rail_width(ui)
	}

	testing.expect_value(t, width(&ui), f32(RAIL_W_COLLAPSED))
	toggle_rail(&ui)
	testing.expect_value(t, width(&ui), f32(RAIL_W_MIN))
	testing.expect(t, !rail_narrow(&ui), "expanded list must render its rows")
	toggle_rail(&ui)
	testing.expect_value(t, width(&ui), f32(RAIL_W_COLLAPSED))
	testing.expect(t, ui.prefs.rail_collapsed)

	ui.page = .Settings
	toggle_rail(&ui)
	toggle_rail(&ui)
	testing.expect(t, ui.prefs.rail_collapsed, "Settings toggle round-trips the pref")
	testing.expect(t, !ui.rail_peek, "Settings must not force the list open")
	ui.page = .Chats
	testing.expect_value(t, width(&ui), f32(RAIL_W_COLLAPSED))
}

// The two width rules the narrow layout hangs on. Both are pure, so
// the phone breakpoints are checked without a window: 360 points is a
// Librem 5 at scale 2, 612 a Fairphone 5, 1024 the default desktop.
@(test)
test_zoom_for_width :: proc(t: ^testing.T) {
	// Before the window exists GetScreenWidth is 0. Deriving a zoom
	// from that renders the vault gate at 1/360 scale, i.e. black.
	testing.expect_value(t, zoom_for_width(0), f32(1.5))
	testing.expect_value(t, zoom_for_width(1024), f32(1.5)) // desktop unchanged
	testing.expect_value(t, zoom_for_width(360), f32(1.0)) // 360 points -> 360 units
	testing.expect_value(t, zoom_for_width(612), f32(1.5)) // 612 points -> 408 units

	// Whatever the scale, a phone-width window lands under the
	// one-card breakpoint and above the rail's minimum.
	for w in ([]i32{360, 540, 612, 720}) {
		units := f32(w) / zoom_for_width(w)
		testing.expect(t, units < PHONE_W, "phone width must be one-card")
		testing.expect(t, units >= MIN_UNITS, "phone width must clear the rail minimum")
	}
	testing.expect(t, f32(1024) / zoom_for_width(1024) >= PHONE_W, "desktop must stay two-card")
}

// No window in a test run, so GetScreenWidth is 0: the cap must still
// hand clay a usable width rather than a negative one.
@(test)
test_fit_w_floor :: proc(t: ^testing.T) {
	testing.expect(t, fit_w(660) > 0, "a fixed width must never go negative")
	testing.expect(t, fit_w(660) <= 660, "the cap must never widen a card")
	testing.expect(t, fit_w(80) == 80, "a card narrower than the floor is left alone")
}

@(test)
test_phone_detail :: proc(t: ^testing.T) {
	ui: Ui_State
	ui.selected = -1
	ui.selected_contact = -1

	ui.page = .Chats
	testing.expect(t, !phone_detail(&ui), "no chat picked shows the list")
	ui.selected = 0
	testing.expect(t, phone_detail(&ui), "a picked chat shows the page card")

	// Back closes exactly one level, and the innermost first.
	ui.new_chat_open = true
	testing.expect(t, phone_detail(&ui), "the new-chat pane is a detail")
	phone_back_action(&ui)
	testing.expect(t, ui.selected == 0, "the chat under the new-chat pane survives")
	phone_back_action(&ui)
	testing.expect(t, !phone_detail(&ui), "back from the chat shows the list")

	settings_open(&ui, nil, .Appearance, 2)
	testing.expect(t, phone_detail(&ui), "settings uses the page rather than a second sidebar")
	phone_back_action(&ui)
	testing.expect(
		t,
		ui.page == .Settings && ui.settings_section == .Home,
		"back returns to the category home",
	)
	testing.expect(t, phone_detail(&ui), "the category home remains reachable at narrow widths")
	phone_back_action(&ui)
	testing.expect(
		t,
		ui.page == .Chats && !phone_detail(&ui),
		"back from settings returns to the chat list",
	)
}

@(test)
test_keys_tab_clears_secret :: proc(t: ^testing.T) {
	ui := Ui_State {
		page             = .Settings,
		settings_section = .Keys,
		settings_tab     = 2,
		keys_nsec        = string(make([]u8, 63)),
		keys_nsec_show   = true,
		keys_confirm     = "RevealNsecBtn",
	}
	defer keys_forget(&ui)

	settings_open(&ui, nil, .Keys, anchor = "NpubRow")
	testing.expect(
		t,
		len(ui.keys_nsec) == 0 && !ui.keys_nsec_show && ui.keys_confirm == "",
		"Leaving private-key controls must discard the revealed key and confirmation",
	)

	ui.keys_nsec = string(make([]u8, 63))
	ui.keys_nsec_show = true
	ui.settings_section = .Advanced
	handle_pages(&ui, nil)
	testing.expect(
		t,
		len(ui.keys_nsec) == 0 && !ui.keys_nsec_show,
		"Frame cleanup must still wipe a private key outside its settings page",
	)
}

@(test)
test_confirm_survives_frame :: proc(t: ^testing.T) {
	ui := Ui_State {
		page             = .Settings,
		settings_section = .Advanced,
		keys_confirm     = "TrustForgetAll",
	}
	handle_pages(&ui, nil)
	testing.expect(
		t,
		ui.keys_confirm == "TrustForgetAll",
		"An idle frame must preserve a pending settings confirmation",
	)
	settings_open(&ui, nil, .Home)
	testing.expect(t, ui.keys_confirm == "", "Leaving settings controls must disarm them")
}

// A hold that stays put fires once; one that travels never does.
@(test)
test_long_press :: proc(t: ^testing.T) {
	s: Long_Press
	testing.expect(t, !lp_step(&s, true, true, 0, 100, 100), "the press itself is not a hold")
	testing.expect(t, !lp_step(&s, false, true, 0.4, 100, 100), "under the threshold")
	testing.expect(t, lp_step(&s, false, true, 0.6, 100, 100), "past the threshold")
	testing.expect(t, !lp_step(&s, false, true, 0.9, 100, 100), "one menu per press")

	// A drag disqualifies the press, and stays disqualified after it
	// comes back to where it started.
	d: Long_Press
	testing.expect(t, !lp_step(&d, true, true, 0, 100, 100), "")
	testing.expect(t, !lp_step(&d, false, true, 0.1, 100, 120), "travel cancels the hold")
	testing.expect(t, !lp_step(&d, false, true, 0.9, 100, 100), "and does not un-cancel")
}
