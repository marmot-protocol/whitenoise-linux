#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    int32_t year, month, day, weekday, hour, minute, second;
} wn_local_time;

int wn_timestamp_local(int64_t seconds, wn_local_time *out);

int main(void) {
    wn_local_time t;
    assert(setenv("TZ", "UTC", 1) == 0);
    // One second before the epoch: Wednesday 1969-12-31 23:59:59.
    assert(wn_timestamp_local(-1, &t));
    assert(t.year == 1969 && t.month == 12 && t.day == 31 && t.weekday == 3);
    assert(t.hour == 23 && t.minute == 59 && t.second == 59);
    assert(!wn_timestamp_local(INT64_MAX, &t));
    assert(!wn_timestamp_local(INT64_MIN, &t));
    assert(!wn_timestamp_local(0, NULL));

    // The same UTC noon uses DST in summer, standard time in winter.
    assert(setenv("TZ", "America/New_York", 1) == 0);
    assert(wn_timestamp_local(1782907200, &t) && t.hour == 8);
    assert(wn_timestamp_local(1767268800, &t) && t.hour == 7);
    // A zone change applies on the next call, and can move the date.
    assert(setenv("TZ", "Asia/Tokyo", 1) == 0);
    assert(wn_timestamp_local(1782907200, &t) && t.hour == 21);
    assert(setenv("TZ", "Pacific/Kiritimati", 1) == 0);
    assert(wn_timestamp_local(1791280800, &t) && t.day == 7 && t.hour == 0);
    puts("timestamp local fields: signed seconds, limits, DST and live timezone passed");
}
