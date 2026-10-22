#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* Release versions are four numeric fields, never lexicographic strings. */
static int wn_appimage_version(const char *text, uint64_t out[4]) {
    if (!text || !*text) {
        return 0;
    }
    for (unsigned field = 0; field < 4; ++field) {
        uint64_t value = 0;
        if (*text < '0' || *text > '9') {
            return 0;
        }
        do {
            unsigned digit = (unsigned)(*text++ - '0');
            if (value > (UINT64_MAX - digit) / 10) {
                return 0;
            }
            value = value * 10 + digit;
        } while (*text >= '0' && *text <= '9');
        out[field] = value;
        if (field < 2) {
            if (*text++ != '.') {
                return 0;
            }
        } else if (field == 2) {
            if (!*text) {
                out[3] = 0;
                break;
            }
            if (*text == '+') {
                ++text;
            } else if (!strncmp(text, "-build.", 7)) {
                text += 7;
            } else {
                return 0;
            }
        } else if (*text) {
            return 0;
        }
    }
    return out[0] >= 2000 && out[1] >= 1 && out[1] <= 12 && out[2] >= 1 && out[2] <= 31;
}
static int wn_appimage_newer(const char *old_version, const char *new_version) {
    uint64_t old_fields[4], new_fields[4];
    if (!wn_appimage_version(old_version, old_fields) ||
        !wn_appimage_version(new_version, new_fields)) {
        return 0;
    }
    for (unsigned i = 0; i < 4; ++i) {
        if (new_fields[i] != old_fields[i]) {
            return new_fields[i] > old_fields[i];
        }
    }
    return 0;
}
/* A test feed is an explicit zsync URL, never an arbitrary update-info type. */
static int wn_appimage_test_feed(const char *url) {
    if (!url || !*url) {
        return 0;
    }
    const char *tail = NULL;
    if (!strncmp(url, "http://127.0.0.1:", 17)) {
        tail = url + 17;
    } else if (!strncmp(url, "http://[::1]:", 13)) {
        tail = url + 13;
    } else if (!strncmp(url, "file:///", 8)) {
        return !strchr(url, '\n') && !strchr(url, '\r') && !strchr(url, '|');
    } else {
        return 0;
    }
    unsigned port = 0, digits = 0;
    while (*tail >= '0' && *tail <= '9') {
        if (++digits > 5) {
            return 0;
        }
        port = port * 10 + (unsigned)(*tail++ - '0');
    }
    return digits && port && port <= 65535 && *tail == '/' && !strchr(tail, '\n') &&
           !strchr(tail, '\r') && !strchr(tail, '|');
}
