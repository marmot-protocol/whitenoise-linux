#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

size_t wn_timestamp_format(int64_t seconds, int style, char *out, size_t capacity);

int main(void) {
    char out[4096];
    assert(setenv("LC_ALL", "C", 1) == 0);
    assert(setenv("TZ", "UTC", 1) == 0);
    assert(wn_timestamp_format(-1, 7, out, sizeof out) > 0);
    assert(strstr(out, "23:59:59") != NULL);
    assert(wn_timestamp_format(INT64_MAX, 5, out, sizeof out) == 0);
    assert(wn_timestamp_format(INT64_MIN, 5, out, sizeof out) == 0);
    assert(wn_timestamp_format(0, 8, out, sizeof out) == 0);
    assert(wn_timestamp_format(0, 0, out, 1) == 0);

    // The same UTC noon uses DST in summer, standard time in winter.
    assert(setenv("TZ", "America/New_York", 1) == 0);
    assert(wn_timestamp_format(1782907200, 1, out, sizeof out) > 0);
    assert(strstr(out, "08:00:00") != NULL);
    assert(wn_timestamp_format(1767268800, 1, out, sizeof out) > 0);
    assert(strstr(out, "07:00:00") != NULL);
    assert(setenv("TZ", "Asia/Tokyo", 1) == 0);
    assert(wn_timestamp_format(1782907200, 1, out, sizeof out) > 0);
    assert(strstr(out, "21:00:00") != NULL);
    puts("timestamp formatting: signed seconds, limits, DST and live timezone passed");
}
