package main

import geo_test_sync "core:sync"
import "core:testing"

@(test)
geo_picker_transitions :: proc(t: ^testing.T) {
	geo_test_sync.lock(&clay_test_mutex)
	defer geo_test_sync.unlock(&clay_test_mutex)
	old_views := geo_views
	geo_views = nil
	defer {
		for key in geo_views {delete(key)}
		delete(geo_views)
		geo_views = old_views
	}
	ui := Ui_State {
		selected    = 0,
		account_ref = "account-a",
		replying    = "reply-a",
	}
	append(&ui.chats, Chat_Row_Ui{group_id = "group-a"})
	append(&ui.compose, ..transmute([]u8)string("unsent draft"))
	append(&ui.staged, Staged_File{name = "unsent.txt"})
	defer {delete(ui.chats); delete(ui.compose); delete(ui.staged)}
	defer geo_picker_close(&ui)

	geo_picker_open(&ui)
	testing.expect(t, geo_picker_valid(&ui))
	testing.expect(t, !ui.location_selected, "the neutral starting point must not be sendable")
	testing.expect(t, !ui.prefs.map_consent, "opening a picker must not grant map consent")

	// A device fix may be outside the map projection's latitude range.
	geo_picker_center(&ui, {-89, 179.5})
	testing.expect_value(t, ui.location_pin, Geo_Point{-89, 179.5})
	testing.expect(t, ui.location_selected)
	request := ui.location_request
	ui.location_busy = true
	geo_picker_select(&ui, geo_settle({1.25, 0.5}))
	testing.expect(
		t,
		ui.location_request > request,
		"manual selection invalidates the pending fix",
	)
	testing.expect(t, !ui.location_busy)
	testing.expect(t, abs(ui.location_pin.lat) < 0.000001)
	testing.expect_value(t, ui.location_pin.lon, f64(-90))

	ui.account_ref = "account-b"
	testing.expect(t, !geo_picker_valid(&ui), "an account change must invalidate the destination")
	ui.account_ref = "account-a"
	ui.chats[0].group_id = "group-b"
	testing.expect(
		t,
		!geo_picker_valid(&ui),
		"a conversation change must invalidate the destination",
	)
	ui.chats[0].group_id = "group-a"
	ui.compose_issue = "issue-a"
	testing.expect(
		t,
		!geo_picker_valid(&ui),
		"an issue route change must invalidate the destination",
	)
	ui.compose_issue = ""
	append(&ui.thread_stack, "thread-a")
	testing.expect(t, !geo_picker_valid(&ui), "a thread change must invalidate the destination")
	delete(ui.thread_stack)
	ui.thread_stack = nil

	geo_picker_close(&ui)
	testing.expect(t, !ui.location_open)
	testing.expect_value(t, string(ui.compose[:]), "unsent draft")
	testing.expect_value(t, ui.staged[0].name, "unsent.txt")
	testing.expect_value(t, ui.replying, "reply-a")
	geo_picker_open(&ui)
	testing.expect(
		t,
		!ui.location_selected,
		"reopening must not reuse a previously selected location",
	)
	ui.editing = "existing-message"
	testing.expect(t, !geo_picker_valid(&ui), "sharing must not send while editing a message")
}
