package main

import "core:sys/windows"

// FILETIME counts 100 ns ticks from 1601-01-01; the Unix epoch is
// 11644473600 s later.
@(private = "file")
FILETIME_UNIX_OFFSET :: 11_644_473_600
@(private = "file")
FILETIME_TICKS_PER_SECOND :: 10_000_000

// Epoch seconds (or millis) shifted to local wall-clock seconds, so the
// UTC-shaped field math in the formatters reads local values.
//
// Win32 converts through the active time zone directly. Odin's
// region_load("local") would need icu.dll for the IANA name, which Windows
// 10 1809 and Wine lack.
// ponytail: SystemTimeToTzSpecificLocalTime applies the zone's current DST
// rule to past years; SystemTimeToTzSpecificLocalTimeEx with dynamic zone
// data is the upgrade if historical rule changes ever matter.
local_seconds :: proc(at: u64) -> u64 {
	seconds := at > 100_000_000_000 ? at / 1000 : at
	ticks := (seconds + FILETIME_UNIX_OFFSET) * FILETIME_TICKS_PER_SECOND
	utc_file := windows.FILETIME{windows.DWORD(ticks), windows.DWORD(ticks >> 32)}
	utc, local: windows.SYSTEMTIME
	if !windows.FileTimeToSystemTime(&utc_file, &utc) {
		return seconds
	}
	if !windows.SystemTimeToTzSpecificLocalTime(nil, &utc, &local) {
		return seconds
	}
	local_file: windows.FILETIME
	if !windows.SystemTimeToFileTime(&local, &local_file) {
		return seconds
	}
	local_ticks := u64(local_file.dwHighDateTime) << 32 | u64(local_file.dwLowDateTime)
	return local_ticks / FILETIME_TICKS_PER_SECOND - FILETIME_UNIX_OFFSET
}
