// Date and clock labels follow the settings and the local calendar.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:fmt"
import "core:sync"
import "core:testing"

@(test)
stamps_follow_formats :: proc(t: ^testing.T) {
	// g_prefs is process-global; other tests point it at their own state.
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	ui: Ui_State
	g_prefs = &ui.prefs
	defer {g_prefs = nil}
	day := Local_Time {
		year   = 2026,
		month  = 10,
		day    = 3,
		hour   = 0,
		minute = 5,
		second = 9,
	}
	dates := [3][2]string {
		{"Oct 3", "Oct 3, 2026"},
		{"3 Oct", "3 Oct 2026"},
		{"2026-10-03", "2026-10-03"},
	}
	for want, format in dates {
		ui.prefs.date_format = format
		testing.expect_value(t, date_text(day, .Omit, context.temp_allocator), want[0])
		testing.expect_value(t, date_text(day, .Show, context.temp_allocator), want[1])
	}
	testing.expect_value(t, clock_text(day, .Omit, context.temp_allocator), "00:05")
	ui.prefs.hour12 = true
	testing.expect_value(t, clock_text(day, .Show, context.temp_allocator), "12:05:09 AM")
	day.hour = 12
	testing.expect_value(t, clock_text(day, .Omit, context.temp_allocator), "12:05 PM")
	day.hour = 23
	testing.expect_value(t, clock_text(day, .Omit, context.temp_allocator), "11:05 PM")
}

// Cached labels pick up a changed clock, and a new local day moves
// "Today" without a reload.
@(test)
stamps_refresh_rows :: proc(t: ^testing.T) {
	// g_prefs is process-global; other tests point it at their own state.
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	ui: Ui_State
	g_prefs = &ui.prefs
	defer {g_prefs = nil}
	now := now_unix()
	// Local noons keep each instant inside its day across a DST shift.
	wall := local_seconds(now)
	yesterday := now - (wall - (wall / 86400 - 1) * 86400 - 43200)
	older := now - (wall - (wall / 86400 - 3) * 86400 - 43200)

	// Formatted yesterday, when `yesterday` was still today.
	append(
		&ui.messages,
		Msg_Ui {
			at = format_when(yesterday),
			at_full = format_full(yesterday),
			day = fmt.aprint("Today"),
			sort_at = yesterday,
		},
	)
	append(&ui.chats, Chat_Row_Ui{at = format_when(yesterday), activity_at = yesterday})
	append(&ui.chats, Chat_Row_Ui{at = format_when(older), activity_at = older})
	append(&ui.gs_hits, Gs_Hit{at = format_full(older), when_at = older})
	ui.stamp_day = local_day(now) - 1
	defer {
		for msg in ui.messages {delete(msg.at); delete(msg.at_full); delete(msg.day)}
		for chat in ui.chats {delete(chat.at)}
		for hit in ui.gs_hits {delete(hit.at)}
		delete(ui.messages); delete(ui.chats); delete(ui.gs_hits)
	}

	stamps_tick(&ui)
	testing.expect_value(t, ui.stamp_day, local_day(now))
	testing.expect(t, ui.messages[0].day != "Today", "yesterday's divider still says Today")
	testing.expect_value(t, ui.chats[0].at, "Yesterday")
	older_date := date_text(local_time(older), .Omit, context.temp_allocator)
	if local_time(older).year != local_time(now).year {
		older_date = date_text(local_time(older), .Show, context.temp_allocator)
	}
	testing.expect_value(t, ui.chats[1].at, older_date)
	testing.expect_value(
		t,
		ui.gs_hits[0].at,
		fmt.tprintf(
			"%s · %s",
			older_date,
			clock_text(local_time(older), .Omit, context.temp_allocator),
		),
	)

	// A clock change reaches the open chat once the handler zeroes the day.
	ui.prefs.hour12 = !ui.prefs.hour12
	stale_copy := fmt.tprint(ui.messages[0].at)
	ui.stamp_day = 0
	stamps_tick(&ui)
	testing.expect(t, ui.messages[0].at != stale_copy, "the open chat kept the old clock")
	testing.expect_value(
		t,
		ui.messages[0].at,
		clock_text(local_time(yesterday), .Omit, context.temp_allocator),
	)
}
