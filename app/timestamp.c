#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#else
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0602
#endif
#endif

#include <stdint.h>

/* Wall-clock fields of one instant; mirrors Local_Time in stamps.odin.
 * Odin formats them per the Date format and Time format settings. */
typedef struct {
    int32_t year, month, day, weekday, hour, minute, second;
} wn_local_time;

#ifdef _WIN32
#include <windows.h>

/* Signed Unix seconds into the device's current timezone, including its DST
 * rule for that year. 0 for instants FILETIME or years 1601..9999 can't
 * hold; the caller keeps the raw token then. */
int wn_timestamp_local(int64_t seconds, wn_local_time *out) {
    if (!out) {
        return 0;
    }
    /* FILETIME starts at 1601. Bound before adding its epoch offset or
     * converting seconds to 100 ns ticks. */
    if (seconds < INT64_C(-11644473600) || seconds > INT64_C(253402300799)) {
        return 0;
    }
    uint64_t ticks = (uint64_t)(seconds + INT64_C(11644473600)) * UINT64_C(10000000);
    FILETIME file = {(DWORD)ticks, (DWORD)(ticks >> 32)};
    SYSTEMTIME utc, local;
    DYNAMIC_TIME_ZONE_INFORMATION zone;
    if (!FileTimeToSystemTime(&file, &utc) ||
        GetDynamicTimeZoneInformation(&zone) == TIME_ZONE_ID_INVALID ||
        !SystemTimeToTzSpecificLocalTimeEx(&zone, &utc, &local) || local.wYear < 1601 ||
        local.wYear > 9999) {
        return 0;
    }
    *out = (wn_local_time){local.wYear, local.wMonth,  local.wDay,   local.wDayOfWeek,
                           local.wHour, local.wMinute, local.wSecond};
    return 1;
}

#else
#include <time.h>

/* Signed Unix seconds into the device's current timezone; tzset re-reads TZ
 * and the zone file on every call. 0 for instants outside years
 * 1..9999 or the platform's time_t; the caller keeps the raw token then. */
int wn_timestamp_local(int64_t seconds, wn_local_time *out) {
    if (!out) {
        return 0;
    }
    /* Bound calendar years and time_t before platform conversion. Local
     * timezone offsets may push a boundary instant outside those years. */
    if (seconds < INT64_C(-62135596800) || seconds > INT64_C(253402300799)) {
        return 0;
    }
    if (sizeof(time_t) < sizeof(int64_t) && (seconds < INT32_MIN || seconds > INT32_MAX)) {
        return 0;
    }
    if ((time_t)-1 > (time_t)0 && seconds < 0) {
        return 0;
    }
    time_t instant = (time_t)seconds;
    struct tm local;
    tzset();
    if (!localtime_r(&instant, &local) || local.tm_year < -1899 || local.tm_year > 8099) {
        return 0;
    }
    *out = (wn_local_time){local.tm_year + 1900, local.tm_mon + 1, local.tm_mday, local.tm_wday,
                           local.tm_hour,        local.tm_min,     local.tm_sec};
    return 1;
}
#endif

static int same_wall_time(int64_t seconds, const wn_local_time *input) {
    wn_local_time local;
    return wn_timestamp_local(seconds, &local) && local.year == input->year &&
           local.month == input->month && local.day == input->day && local.hour == input->hour &&
           local.minute == input->minute && local.second == input->second;
}

int wn_timestamp_unix(const wn_local_time *input, int64_t *out) {
    if (input->year < 1 || input->year > 9999) {
        return 0;
    }
#ifdef _WIN32
    SYSTEMTIME local = {
        (WORD)input->year,   (WORD)input->month,  0, (WORD)input->day, (WORD)input->hour,
        (WORD)input->minute, (WORD)input->second, 0};
    DYNAMIC_TIME_ZONE_INFORMATION zone;
    SYSTEMTIME utc;
    FILETIME file;
    if (GetDynamicTimeZoneInformation(&zone) == TIME_ZONE_ID_INVALID ||
        !TzSpecificLocalTimeToSystemTimeEx(&zone, &local, &utc) ||
        !SystemTimeToFileTime(&utc, &file)) {
        return 0;
    }
    uint64_t ticks = ((uint64_t)file.dwHighDateTime << 32) | file.dwLowDateTime;
    int64_t seconds = (int64_t)(ticks / UINT64_C(10000000)) - INT64_C(11644473600);
    if (same_wall_time(seconds, input)) {
        *out = seconds;
        return 1;
    }
#else
    // Prefer standard time in a fall-back fold. A round trip rejects both
    // nonexistent spring-forward times and normalized dates such as Feb 30.
    tzset();
    for (int isdst = 0; isdst <= 1; ++isdst) {
        struct tm local = {.tm_year = input->year - 1900,
                           .tm_mon = input->month - 1,
                           .tm_mday = input->day,
                           .tm_hour = input->hour,
                           .tm_min = input->minute,
                           .tm_sec = input->second,
                           .tm_isdst = isdst};
        int64_t seconds = (int64_t)mktime(&local);
        if (same_wall_time(seconds, input)) {
            *out = seconds;
            return 1;
        }
    }
#endif
    return 0;
}
