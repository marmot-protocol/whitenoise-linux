#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#else
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0602
#endif
#endif

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#ifdef _WIN32
#include <windows.h>

/* Strip the weekday from the user's long-date pattern, not its date order.
 * Quoted literals are copied unchanged. F adds a weekday explicitly because
 * some locales omit it from their standard long date. */
static int long_date_pattern(wchar_t *out, size_t capacity) {
    wchar_t source[256];
    if (!GetLocaleInfoEx(LOCALE_NAME_USER_DEFAULT, LOCALE_SLONGDATE, source,
                         (int)(sizeof source / sizeof *source))) {
        return 0;
    }
    size_t n = 0;
    int quoted = 0;
    for (size_t i = 0; source[i];) {
        if (source[i] == L'\'') {
            quoted = !quoted;
        } else if (!quoted && source[i] == L'd') {
            size_t end = i;
            while (source[end] == L'd') {
                ++end;
            }
            if (end - i >= 3) {
                i = end;
                while (source[i] == L' ' || source[i] == L',' || source[i] == L'.') {
                    ++i;
                }
                continue;
            }
        }
        if (n + 1 >= capacity) {
            return 0;
        }
        out[n++] = source[i++];
    }
    while (n && (out[n - 1] == L' ' || out[n - 1] == L',')) {
        --n;
    }
    out[n] = 0;
    return n != 0;
}

/* A custom Windows long-time pattern can omit seconds. T/S still need
 * them; preserve its hour cycle and marker placement when adding the field. */
static int long_time_pattern(wchar_t *out, size_t capacity) {
    wchar_t source[256], separator[32];
    if (!GetLocaleInfoEx(LOCALE_NAME_USER_DEFAULT, LOCALE_STIMEFORMAT, source,
                         (int)(sizeof source / sizeof *source))) {
        return 0;
    }
    size_t minute = SIZE_MAX;
    int quoted = 0;
    for (size_t i = 0; source[i]; ++i) {
        if (source[i] == L'\'') {
            quoted = !quoted;
        }
        if (!quoted && source[i] == L's') {
            size_t length = wcslen(source);
            if (length >= capacity) {
                return 0;
            }
            memcpy(out, source, (length + 1) * sizeof *out);
            return 1;
        }
        if (!quoted && source[i] == L'm') {
            minute = i + 1;
        }
    }
    if (minute == SIZE_MAX || !GetLocaleInfoEx(LOCALE_NAME_USER_DEFAULT, LOCALE_STIME, separator,
                                               (int)(sizeof separator / sizeof *separator))) {
        return 0;
    }
    if (minute + 1 >= capacity) {
        return 0;
    }
    memcpy(out, source, minute * sizeof *out);
    size_t n = minute;
    out[n++] = L'\'';
    for (size_t i = 0; separator[i]; ++i) {
        if (n + 2 >= capacity) {
            return 0;
        }
        out[n++] = separator[i];
        if (separator[i] == L'\'') {
            out[n++] = L'\'';
        }
    }
    size_t tail = wcslen(source + minute);
    if (n + 3 + tail >= capacity) {
        return 0;
    }
    out[n++] = L'\'';
    out[n++] = L's';
    out[n++] = L's';
    memcpy(out + n, source + minute, (tail + 1) * sizeof *out);
    return 1;
}

size_t wn_timestamp_format(int64_t seconds, int style, char *out, size_t capacity) {
    if (!out || !capacity) {
        return 0;
    }
    out[0] = 0;
    if (style < 0 || style > 7 || capacity > INT_MAX) {
        return 0;
    }
    /* FILETIME starts at 1601. Bound before adding its epoch offset or
     * converting seconds to 100 ns ticks; reject unrepresentable instants. */
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

    wchar_t date[512] = {0}, clock[256] = {0}, weekday[256] = {0}, pattern[256];
    int needs_date = style >= 2;
    int needs_time = style < 2 || style >= 4;
    if (needs_date) {
        int long_date = style == 3 || style == 4 || style == 5;
        if (long_date && !long_date_pattern(pattern, sizeof pattern / sizeof *pattern)) {
            return 0;
        }
        if (!GetDateFormatEx(LOCALE_NAME_USER_DEFAULT, long_date ? 0 : DATE_SHORTDATE, &local,
                             long_date ? pattern : NULL, date, (int)(sizeof date / sizeof *date),
                             NULL)) {
            return 0;
        }
        if (style == 5 && !GetDateFormatEx(LOCALE_NAME_USER_DEFAULT, 0, &local, L"dddd", weekday,
                                           (int)(sizeof weekday / sizeof *weekday), NULL)) {
            return 0;
        }
    }
    if (needs_time) {
        DWORD flags = style == 1 || style == 7 ? 0 : TIME_NOSECONDS;
        const wchar_t *time_pattern = NULL;
        if (style == 1 || style == 7) {
            if (!long_time_pattern(pattern, sizeof pattern / sizeof *pattern)) {
                return 0;
            }
            time_pattern = pattern;
        }
        /* No TIME_FORCE24HOURFORMAT: use the current user's clock settings. */
        if (!GetTimeFormatEx(LOCALE_NAME_USER_DEFAULT, flags, &local, time_pattern, clock,
                             (int)(sizeof clock / sizeof *clock))) {
            return 0;
        }
    }
    wchar_t text[1024];
    size_t n = 0;
    const wchar_t *parts[] = {weekday, date, clock};
    for (size_t i = 0; i < sizeof parts / sizeof *parts; ++i) {
        size_t length = wcslen(parts[i]);
        if (!length) {
            continue;
        }
        if (n + length + 2 > sizeof text / sizeof *text) {
            return 0;
        }
        if (n) {
            text[n++] = L' ';
        }
        memcpy(text + n, parts[i], length * sizeof *text);
        n += length;
    }
    text[n] = 0;
    int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, -1, out, (int)capacity,
                                    NULL, NULL);
    if (!bytes) {
        out[0] = 0;
        return 0;
    }
    return (size_t)bytes - 1;
}

#else
#include <langinfo.h>
#include <locale.h>
#include <time.h>

/* POSIX supplies a short date pattern but no long-date API. Expand its
 * fields into full month/year names while retaining the locale's order.
 * CJK month suffixes already name the month, so retain the numeric field. */
static int long_date_pattern(const char *source, char *out, size_t capacity) {
    size_t n = 0;
    for (size_t i = 0; source[i];) {
        const char *replacement = NULL;
        size_t consumed = 1;
        char directive[5] = {0};
        if (source[i] == '%') {
            size_t end = i + 1;
            if (source[end] == 'E' || source[end] == 'O') {
                ++end;
            }
            if (!source[end]) {
                return 0;
            }
            char field = source[end];
            consumed = end - i + 1;
            if (field == 'm') {
                const char *suffix = source + end + 1;
                replacement = strncmp(suffix, "月", strlen("月")) == 0 ||
                                      strncmp(suffix, "월", strlen("월")) == 0
                                  ? "%m"
                                  : "%B";
            } else if (field == 'b' || field == 'h') {
                replacement = "%B";
            } else if (field == 'y') {
                replacement = "%Y";
            } else if (field == 'D') {
                replacement = "%B %d %Y";
            } else if (field == 'F') {
                replacement = "%Y %B %d";
            } else if (field == 'x' || field == 'c') {
                return 0;
            } else {
                memcpy(directive, source + i, consumed);
                replacement = directive;
            }
        } else if (source[i] == '/' || source[i] == '-' || source[i] == '.') {
            replacement = " ";
        }
        size_t length = replacement ? strlen(replacement) : 1;
        if (n + length >= capacity) {
            return 0;
        }
        if (replacement) {
            memcpy(out + n, replacement, length);
        } else {
            out[n] = source[i];
        }
        n += length;
        i += consumed;
    }
    out[n] = 0;
    return n != 0;
}

static const char *clock_pattern(locale_t locale, int seconds) {
    const char *source = nl_langinfo_l(T_FMT, locale);
    if (strstr(source, "%r")) {
        source = nl_langinfo_l(T_FMT_AMPM, locale);
    }
    const char *hour = strstr(source, "%I");
    if (!hour) {
        hour = strstr(source, "%l");
    }
    if (!hour) {
        hour = strstr(source, "%OI");
    }
    if (!hour) {
        return seconds ? "%H:%M:%S" : "%H:%M";
    }
    const char *period = strstr(source, "%p");
    if (period && period < hour) {
        return seconds ? "%p %I:%M:%S" : "%p %I:%M";
    }
    return seconds ? "%I:%M:%S %p" : "%I:%M %p";
}

/* strftime emits the locale's codeset, which need not be UTF-8. Decode with
 * that thread-local locale and write UTF-8 without changing process locale. */
static size_t locale_to_utf8(const char *source, locale_t locale, char *out, size_t capacity) {
    locale_t previous = uselocale(locale);
    if (!previous) {
        return 0;
    }
    mbstate_t state = {0};
    size_t n = 0, remaining = strlen(source);
    while (remaining) {
        wchar_t wide;
        size_t consumed = mbrtowc(&wide, source, remaining, &state);
        if (consumed == (size_t)-1 || consumed == (size_t)-2 || consumed == 0) {
            n = 0;
            break;
        }
        uint32_t rune = (uint32_t)wide;
        unsigned char bytes[4];
        size_t count;
        if (rune <= 0x7f) {
            bytes[0] = (unsigned char)rune;
            count = 1;
        } else if (rune <= 0x7ff) {
            bytes[0] = 0xc0 | (rune >> 6);
            bytes[1] = 0x80 | (rune & 0x3f);
            count = 2;
        } else if (rune <= 0xffff && !(rune >= 0xd800 && rune <= 0xdfff)) {
            bytes[0] = 0xe0 | (rune >> 12);
            bytes[1] = 0x80 | ((rune >> 6) & 0x3f);
            bytes[2] = 0x80 | (rune & 0x3f);
            count = 3;
        } else if (rune >= 0x10000 && rune <= 0x10ffff) {
            bytes[0] = 0xf0 | (rune >> 18);
            bytes[1] = 0x80 | ((rune >> 12) & 0x3f);
            bytes[2] = 0x80 | ((rune >> 6) & 0x3f);
            bytes[3] = 0x80 | (rune & 0x3f);
            count = 4;
        } else {
            n = 0;
            break;
        }
        if (n + count >= capacity) {
            n = 0;
            break;
        }
        memcpy(out + n, bytes, count);
        n += count;
        source += consumed;
        remaining -= consumed;
    }
    uselocale(previous);
    out[n] = 0;
    return n;
}

size_t wn_timestamp_format(int64_t seconds, int style, char *out, size_t capacity) {
    if (!out || !capacity) {
        return 0;
    }
    out[0] = 0;
    if (style < 0 || style > 7) {
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
#ifdef __OpenBSD__
    /* ponytail: OpenBSD strftime_l only supports C dates. Use native
     * localized dates if added, or ICU if it becomes a project dependency. */
    locale_t locale = newlocale(LC_CTYPE_MASK, "", (locale_t)0);
#else
    locale_t locale = newlocale(LC_TIME_MASK | LC_CTYPE_MASK, "", (locale_t)0);
#endif
    if (!locale) {
        return 0;
    }
    char date[256], pattern[512], text[4096];
    const char *short_date = nl_langinfo_l(D_FMT, locale);
    const char *clock = clock_pattern(locale, style == 1 || style == 7);
    int valid = 1;
    switch (style) {
    case 0:
    case 1: {
        int length = snprintf(pattern, sizeof pattern, "%s", clock);
        valid = length > 0 && (size_t)length < sizeof pattern;
        break;
    }
    case 2: {
        int length = snprintf(pattern, sizeof pattern, "%s", short_date);
        valid = length > 0 && (size_t)length < sizeof pattern;
        break;
    }
    case 3:
    case 4:
    case 5:
        valid = long_date_pattern(short_date, date, sizeof date);
        if (valid) {
            int length = snprintf(pattern, sizeof pattern, "%s%s%s%s", style == 5 ? "%A " : "",
                                  date, style >= 4 ? " " : "", style >= 4 ? clock : "");
            valid = length > 0 && (size_t)length < sizeof pattern;
        }
        break;
    case 6:
    case 7: {
        int length = snprintf(pattern, sizeof pattern, "%s %s", short_date, clock);
        valid = length > 0 && (size_t)length < sizeof pattern;
        break;
    }
    }
    size_t length = 0;
    if (valid && strftime_l(text, sizeof text, pattern, &local, locale)) {
        length = locale_to_utf8(text, locale, out, capacity);
    }
    freelocale(locale);
    return length;
}
#endif
