#+build !windows
package main

import "base:runtime"
import "core:sync"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

// The user's timezone, loaded once from the system tz database; nil
// means UTC (no database found, or TZ=UTC).
@(private = "file")
local_tz: ^datetime.TZ_Region
@(private = "file")
local_tz_once: sync.Once

// Epoch seconds (or millis) shifted to local wall-clock seconds, so the
// UTC-shaped field math in the formatters below reads local values.
// DST-correct: the offset comes from the tz record covering the instant.
local_seconds :: proc(at: u64) -> u64 {
	seconds := at > 100_000_000_000 ? at / 1000 : at
	sync.once_do(
		&local_tz_once,
		proc() {
			// The shared cache must outlive any caller's temporary or test allocator.
			context.allocator = runtime.default_context().allocator
			local_tz, _ = timezone.region_load("local", reload_allocator())
		},
	)
	if local_tz == nil {
		return seconds
	}
	dt, dok := time.time_to_datetime(time.unix(i64(seconds), 0))
	if !dok {
		return seconds
	}
	local, lok := timezone.datetime_to_tz(dt, local_tz)
	if !lok {
		return seconds
	}
	// Reading the local wall-clock fields back as if they were UTC
	// yields the shifted epoch the formatters below expect.
	local.tz = nil
	shifted, sok := time.datetime_to_time(local)
	if !sok {
		return seconds
	}
	return u64(time.time_to_unix(shifted))
}
