package main

import "core:testing"

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

	ui.page = .Settings
	testing.expect(t, !phone_detail(&ui), "settings opens on its section list")
	ui.sett_open = true
	testing.expect(t, phone_detail(&ui), "a picked section shows the page card")
	phone_back_action(&ui)
	testing.expect(t, !phone_detail(&ui), "back returns to the section list")
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
