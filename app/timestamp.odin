package main

import "core:c"
import "core:fmt"

import marmot "../marmot"

foreign import timestamp_lib {WN_BUILD_DIR + "/libwntimestamp.a"}

@(private = "file", default_calling_convention = "c")
foreign timestamp_lib {
	wn_timestamp_local :: proc(seconds: i64, out: ^Local_Time) -> c.int ---
}

@(private)
timestamp_token :: proc(seconds: i64, style: marmot.Markdown_Timestamp_Style) -> string {
	codes := [9]u8{'t', 'T', 'd', 'D', 'f', 'F', 's', 'S', 'R'}
	index := int(style)
	code := index >= 0 && index < len(codes) ? codes[index] : u8('f')
	return fmt.tprintf("<t:%d:%c>", seconds, code)
}

@(private = "file")
timestamp_relative :: proc(seconds, now: i64) -> string {
	// Flipping the sign bit orders signed instants in u64. Subtract in
	// descending order so even the distance between i64 extremes fits.
	at := transmute(u64)seconds ~ (u64(1) << 63)
	current := transmute(u64)now ~ (u64(1) << 63)
	future := at > current
	distance := future ? at - current : current - at
	units := [?]struct {
		seconds:                                      u64,
		past_one, past_many, future_one, future_many: string,
	} {
		{31536000, N_("%d year ago"), N_("%d years ago"), N_("in %d year"), N_("in %d years")},
		{2592000, N_("%d month ago"), N_("%d months ago"), N_("in %d month"), N_("in %d months")},
		{86400, N_("%d day ago"), N_("%d days ago"), N_("in %d day"), N_("in %d days")},
		{3600, N_("%d hour ago"), N_("%d hours ago"), N_("in %d hour"), N_("in %d hours")},
		{60, N_("%d minute ago"), N_("%d minutes ago"), N_("in %d minute"), N_("in %d minutes")},
		{1, N_("%d second ago"), N_("%d seconds ago"), N_("in %d second"), N_("in %d seconds")},
	}
	index := len(units) - 1
	for unit, i in units {
		if distance >= unit.seconds {
			index = i
			break
		}
	}
	unit := units[index]
	count := distance / unit.seconds
	pattern := count == 1 ? unit.past_one : unit.past_many
	if future {pattern = count == 1 ? unit.future_one : unit.future_many}
	return fmt.tprintf(tr(pattern), count)
}

// Resolve at display time: relative labels use the current clock, the
// native lookup re-reads the device's timezone each call, and absolute
// labels follow the Date format and Time format settings:
//
//   t    2:30 PM        f s  Oct 6, 2026 · 2:30 PM
//   T    2:30:00 PM     S    Oct 6, 2026 · 2:30:00 PM
//   d D  Oct 6, 2026    F    Tuesday, Oct 6, 2026 · 2:30 PM
@(private)
timestamp_label :: proc(seconds: i64, style: marmot.Markdown_Timestamp_Style, now: i64) -> string {
	if style == .RELATIVE {return timestamp_relative(seconds, now)}
	local: Local_Time
	if wn_timestamp_local(seconds, &local) == 0 {return timestamp_token(seconds, style)}
	context.allocator = context.temp_allocator
	#partial switch style {
	case .SHORT_TIME:
		return clock_text(local, .Omit)
	case .LONG_TIME:
		return clock_text(local, .Show)
	case .SHORT_DATE, .LONG_DATE:
		return date_text(local, .Show)
	case .SHORT_DATE_TIME, .COMPACT_DATE_TIME:
		return date_clock_text(local, .Omit)
	case .COMPACT_DATE_TIME_SECONDS:
		return date_clock_text(local, .Show)
	case .LONG_DATE_TIME:
		return fmt.aprintf(
			"%s, %s",
			tr(WEEKDAY_NAMES[local.weekday]),
			date_clock_text(local, .Omit),
		)
	}
	return timestamp_token(seconds, style)
}
