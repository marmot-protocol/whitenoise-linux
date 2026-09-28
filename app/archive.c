/* Archive bytes are parsed only in this one-shot, memory-only helper. */
#include "decoder_ipc.h"
#include "decoder_limits.h"
#include <archive.h>
#include <archive_entry.h>
#include <stdint.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __OpenBSD__
#include <unistd.h>
#endif
static int arc_filters(struct archive *archive) {
    const int filters[] = {
        ARCHIVE_FILTER_BZIP2, ARCHIVE_FILTER_COMPRESS, ARCHIVE_FILTER_GZIP,  ARCHIVE_FILTER_LZIP,
        ARCHIVE_FILTER_LZMA,  ARCHIVE_FILTER_XZ,       ARCHIVE_FILTER_UU,    ARCHIVE_FILTER_RPM,
        ARCHIVE_FILTER_LRZIP, ARCHIVE_FILTER_LZOP,     ARCHIVE_FILTER_GRZIP, ARCHIVE_FILTER_LZ4,
        ARCHIVE_FILTER_ZSTD,
    };
    /* Registration returning WARN installs an external-program fallback.
     * Probe on a reader that never sees input; register only native codecs
     * on the real reader, on every OS (not only where pledge denies exec). */
    struct archive *probe = archive_read_new();
    if (!probe) {
        return 0;
    }
    int ok = 1;
    for (size_t i = 0; i < sizeof(filters) / sizeof(filters[0]); ++i) {
        int status = archive_read_support_filter_by_code(probe, filters[i]);
        if (status == ARCHIVE_OK) {
            if (archive_read_support_filter_by_code(archive, filters[i]) != ARCHIVE_OK) {
                ok = 0;
                break;
            }
        } else if (status != ARCHIVE_WARN) {
            ok = 0;
            break;
        }
    }
    archive_read_free(probe);
    return ok;
}

static int arc_locale(void) {
    /* Explicit trusted locale names: the child intentionally inherits no
     * environment, and C-locale conversion rejects valid UTF-8 filenames. */
    return setlocale(LC_CTYPE, "C.UTF-8") != NULL || setlocale(LC_CTYPE, "en_US.UTF-8") != NULL ||
           setlocale(LC_CTYPE, ".UTF-8") != NULL;
}

struct arc_output {
    unsigned char *data;
    uint32_t size, capacity, count;
};

static int arc_reserve(struct arc_output *out, uint32_t extra, uint32_t limit) {
    if (extra > limit - out->size) {
        return 0;
    }
    uint32_t needed = out->size + extra;
    if (needed <= out->capacity) {
        return 1;
    }
    uint32_t capacity = out->capacity ? out->capacity : 4096;
    while (capacity < needed) {
        capacity = capacity > limit / 2 ? limit : capacity * 2;
    }
    unsigned char *data = realloc(out->data, capacity);
    if (!data) {
        return 0;
    }
    out->data = data;
    out->capacity = capacity;
    return 1;
}

static int arc_regular(struct archive_entry *entry) {
    return archive_entry_filetype(entry) == AE_IFREG && !archive_entry_hardlink(entry) &&
           !archive_entry_symlink(entry);
}

static int arc_record(struct arc_output *out, struct archive_entry *entry, uint32_t index) {
    const char *name = archive_entry_pathname_utf8(entry);
    if (!name || out->count >= WN_ARCHIVE_COUNT_MAX) {
        return 0;
    }
    uint32_t length = 0;
    while (length <= WN_ARCHIVE_NAME_MAX && name[length]) {
        ++length;
    }
    int64_t declared = archive_entry_size_is_set(entry) ? archive_entry_size(entry) : -1;
    if (!length || length > WN_ARCHIVE_NAME_MAX || declared < -1 ||
        !arc_reserve(out, 16 + length, WN_ARCHIVE_LIST_MAX)) {
        return 0;
    }
    unsigned char *record = out->data + out->size;
    wn_image_put(record, index);
    wn_image_put(record + 4, length);
    uint64_t size = (uint64_t)declared;
    wn_image_put(record + 8, (uint32_t)size);
    wn_image_put(record + 12, (uint32_t)(size >> 32));
    memcpy(record + 16, name, length);
    out->size += 16 + length;
    ++out->count;
    return 1;
}

static int arc_extract(struct archive *archive, struct archive_entry *entry,
                       struct arc_output *out) {
    int64_t declared = archive_entry_size_is_set(entry) ? archive_entry_size(entry) : -1;
    if (declared < -1 || declared > WN_ARCHIVE_ENTRY_MAX) {
        return 0;
    }
    if (declared > 0 && !arc_reserve(out, (uint32_t)declared, WN_ARCHIVE_ENTRY_MAX)) {
        return 0;
    }
    for (;;) {
        unsigned char extra;
        uint32_t remaining = WN_ARCHIVE_ENTRY_MAX - out->size;
        if (remaining && out->size == out->capacity &&
            !arc_reserve(out, remaining < 65536 ? remaining : 65536, WN_ARCHIVE_ENTRY_MAX)) {
            return 0;
        }
        la_ssize_t n =
            remaining ? archive_read_data(archive, out->data + out->size, out->capacity - out->size)
                      : archive_read_data(archive, &extra, 1);
        if (n < 0 || (uint64_t)n > remaining) {
            return 0;
        }
        if (!n) {
            return declared < 0 || (uint64_t)declared == out->size;
        }
        out->size += (uint32_t)n;
    }
}

static int arc_read(struct archive *archive, uint32_t op, uint32_t requested,
                    struct arc_output *out) {
    for (uint32_t index = 0;; ++index) {
        struct archive_entry *entry = NULL;
        int status = archive_read_next_header(archive, &entry);
        if (status == ARCHIVE_EOF) {
            return op == WN_ARCHIVE_LIST;
        }
        if (status != ARCHIVE_OK || index >= WN_ARCHIVE_SCAN_MAX) {
            return 0;
        }
        if (op == WN_ARCHIVE_ENTRY && index == requested) {
            return arc_regular(entry) && arc_extract(archive, entry, out);
        }
        if (op == WN_ARCHIVE_LIST && arc_regular(entry) && !arc_record(out, entry, index)) {
            return 0;
        }
        if (archive_read_data_skip(archive) != ARCHIVE_OK) {
            return 0;
        }
    }
}

int main(int argc, char **argv) {
    (void)argv;
    if (argc != 1 || !wn_decoder_limits(WN_DECODER_ONESHOT) || !arc_locale()) {
        return 1;
    }
#ifdef __OpenBSD__
    if (unveil(NULL, NULL) || pledge("stdio", NULL)) {
        return 1;
    }
#endif
    unsigned char header[16];
    if (fread(header, 1, sizeof(header), stdin) != sizeof(header) || memcmp(header, "ARI1", 4)) {
        return 1;
    }
    uint32_t size = wn_image_u32(header + 4);
    uint32_t op = wn_image_u32(header + 8);
    uint32_t index = wn_image_u32(header + 12);
    if (!size || size > WN_ARCHIVE_INPUT_MAX || op > WN_ARCHIVE_ENTRY ||
        index >= WN_ARCHIVE_SCAN_MAX || (op == WN_ARCHIVE_LIST && index != 0)) {
        return 1;
    }
    unsigned char *input = malloc(size);
    if (!input) {
        return 1;
    }
    if (fread(input, 1, size, stdin) != size || fgetc(stdin) != EOF || ferror(stdin)) {
        free(input);
        return 1;
    }
    struct archive *archive = archive_read_new();
    struct arc_output out = {0};
    int result = 1;
    if (archive && arc_filters(archive) && archive_read_support_format_all(archive) == ARCHIVE_OK &&
        archive_read_open_memory(archive, input, size) == ARCHIVE_OK &&
        arc_read(archive, op, index, &out)) {
        memcpy(header, "ARO1", 4);
        wn_image_put(header + 4, out.count);
        wn_image_put(header + 8, index);
        wn_image_put(header + 12, out.size);
        if (fwrite(header, 1, sizeof(header), stdout) == sizeof(header) &&
            (!out.size || fwrite(out.data, 1, out.size, stdout) == out.size) && !fflush(stdout)) {
            result = 0;
        }
    }
    if (archive) {
        archive_read_free(archive);
    }
    free(out.data);
    free(input);
    return result;
}

#include "helper_main.h"
