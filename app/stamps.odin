package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

// Every date and clock the app shows goes through this file, so the
// Date format and Time format settings apply everywhere at once:
//
//   date_text   "Oct 3" / "3 Oct" / "2026-10-03"  (+ year on request)
//   clock_text  "2:30 PM" / "14:30"                (+ seconds on request)
//
// Labels cached on rows (messages, chat list, search hits) are rebuilt by
// stamps_refresh when a setting changes or the local date rolls over.

// Local calendar and clock fields of one instant. Layout matches
// wn_local_time in timestamp.c, which fills it for Markdown tokens.
@(private)
Local_Time :: struct {
	year, month, day, weekday, hour, minute, second: i32,
}

@(private)
Date_Year :: enum {
	Omit,
	Show,
}

@(private)
Clock_Seconds :: enum {
	Omit,
	Show,
}

@(private)
MONTH_ABBREV := []string {
	N_("Jan"),
	N_("Feb"),
	N_("Mar"),
	N_("Apr"),
	N_("May"),
	N_("Jun"),
	N_("Jul"),
	N_("Aug"),
	N_("Sep"),
	N_("Oct"),
	N_("Nov"),
	N_("Dec"),
}

// Indexed by Local_Time.weekday, 0 = Sunday.
@(private)
WEEKDAY_NAMES := []string {
	N_("Sunday"),
	N_("Monday"),
	N_("Tuesday"),
	N_("Wednesday"),
	N_("Thursday"),
	N_("Friday"),
	N_("Saturday"),
}

@(private)
now_unix :: proc() -> u64 {
	return u64(time.time_to_unix(time.now()))
}

// Days since the epoch on the local calendar.
@(private)
local_day :: proc(at: u64) -> i64 {
	return i64(local_seconds(at) / 86400)
}

// Wall-clock fields of a timeline timestamp (seconds or millis).
@(private)
local_time :: proc(at: u64) -> Local_Time {
	stamp := time.unix(i64(local_seconds(at)), 0)
	year, month, day := time.date(stamp)
	hour, minute, second := time.clock_from_time(stamp)
	return {
		i32(year),
		i32(month),
		i32(day),
		i32(time.weekday(stamp)),
		i32(hour),
		i32(minute),
		i32(second),
	}
}

// The date per the Date format setting: "Oct 3", "3 Oct" or "2026-10-03".
// Show adds the year to the first two: "Oct 3, 2026", "3 Oct 2026".
@(private)
date_text :: proc(t: Local_Time, year: Date_Year, allocator := context.allocator) -> string {
	month := tr(MONTH_ABBREV[t.month - 1])
	switch g_prefs != nil ? g_prefs.date_format : 2 {
	case 0:
		if year == .Show {
			return fmt.aprintf("%s %d, %d", month, t.day, t.year, allocator = allocator)
		}
		return fmt.aprintf("%s %d", month, t.day, allocator = allocator)
	case 1:
		if year == .Show {
			return fmt.aprintf("%d %s %d", t.day, month, t.year, allocator = allocator)
		}
		return fmt.aprintf("%d %s", t.day, month, allocator = allocator)
	}
	return fmt.aprintf("%04d-%02d-%02d", t.year, t.month, t.day, allocator = allocator)
}

// The clock per the Time format setting: "2:30 PM" or "14:30".
@(private)
clock_text :: proc(
	t: Local_Time,
	seconds: Clock_Seconds,
	allocator := context.allocator,
) -> string {
	if g_prefs == nil || !g_prefs.hour12 {
		if seconds == .Show {
			return fmt.aprintf("%02d:%02d:%02d", t.hour, t.minute, t.second, allocator = allocator)
		}
		return fmt.aprintf("%02d:%02d", t.hour, t.minute, allocator = allocator)
	}
	suffix := t.hour < 12 ? "AM" : "PM"
	hour := t.hour % 12 == 0 ? 12 : t.hour % 12
	if seconds == .Show {
		return fmt.aprintf(
			"%d:%02d:%02d %s",
			hour,
			t.minute,
			t.second,
			suffix,
			allocator = allocator,
		)
	}
	return fmt.aprintf("%d:%02d %s", hour, t.minute, suffix, allocator = allocator)
}

// Absolute date and clock: "Oct 3, 2026 · 2:30 PM".
@(private)
date_clock_text :: proc(
	t: Local_Time,
	seconds: Clock_Seconds,
	allocator := context.allocator,
) -> string {
	date := date_text(t, .Show, context.temp_allocator)
	clock := clock_text(t, seconds, context.temp_allocator)
	return fmt.aprintf("%s · %s", date, clock, allocator = allocator)
}

// Message stamp beside the bubble: "2:30 PM".
@(private)
format_when :: proc(at: u64) -> string {
	return clock_text(local_time(at), .Omit)
}

// Hover tooltips and exports: "Oct 3, 2026 · 2:30 PM".
@(private)
format_full :: proc(at: u64) -> string {
	return date_clock_text(local_time(at), .Omit)
}

// Day divider: "Today", else the date, with the year only when it is
// not this one.
@(private)
format_day :: proc(at: u64) -> string {
	now := now_unix()
	if local_day(at) == local_day(now) {
		return strings.clone(tr("Today"))
	}
	t := local_time(at)
	return date_text(t, t.year == local_time(now).year ? .Omit : .Show)
}

// Search and mention hits, dated the way the chat's divider dates them:
// "Today · 2:30 PM", "Oct 3 · 2:30 PM".
@(private)
format_day_clock :: proc(at: u64) -> string {
	day := format_day(at)
	defer delete(day)
	clock := clock_text(local_time(at), .Omit, context.temp_allocator)
	return fmt.aprintf("%s · %s", day, clock)
}

// Chat list: the clock for today, "Yesterday", else the date, so an older
// evening never reads newer than a later morning.
@(private)
format_activity :: proc(at: u64) -> string {
	now := now_unix()
	switch local_day(now) - local_day(at) {
	case 0:
		return format_when(at)
	case 1:
		return strings.clone(tr("Yesterday"))
	}
	t := local_time(at)
	return date_text(t, t.year == local_time(now).year ? .Omit : .Show)
}

@(private = "file")
restamp :: proc(stamp: ^string, fresh: string) {
	mem.zero_slice(transmute([]u8)stamp^)
	delete(stamp^)
	stamp^ = fresh
}

// Reformat every cached stamp. Runs at the top of a frame, never inside
// a handler: the previous labels may still back this frame's layout.
// Setting handlers request it by zeroing ui.stamp_day.
@(private)
stamps_refresh :: proc(ui: ^Ui_State) {
	ui.stamp_day = local_day(now_unix())
	for &msg in ui.messages {
		restamp(&msg.at, format_when(msg.sort_at))
		restamp(&msg.at_full, format_full(msg.sort_at))
		restamp(&msg.day, format_day(msg.sort_at))
	}
	for rows in ([]^[dynamic]Chat_Row_Ui{&ui.chats, &ui.archived, &ui.gs_chats}) {
		for &chat in rows {restamp(&chat.at, format_activity(chat.activity_at))}
	}
	for &hit in ui.gs_hits {restamp(&hit.at, format_day_clock(hit.when_at))}
	for &hit in ui.mi_hits {restamp(&hit.at, format_day_clock(hit.when_at))}
}

// Per frame: a requested refresh, or a new local date moving "Today".
// True when stamps were reformatted: chat-list previews bake Markdown
// timestamp labels in when read, so the caller re-reads the list too.
@(private)
stamps_tick :: proc(ui: ^Ui_State) -> bool {
	if ui.stamp_day == local_day(now_unix()) {return false}
	stamps_refresh(ui)
	return true
}
