#define _POSIX_C_SOURCE 200809L
#include "../app/decoder_ipc.h"
#include <archive.h>
#include <archive_entry.h>
#include <assert.h>
#include <locale.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

struct fixture {
    struct archive *writer;
    unsigned char *data;
    size_t size, capacity;
};

static la_ssize_t collect(struct archive *a, void *context, const void *data, size_t size) {
    (void)a;
    struct fixture *fixture = context;
    assert(size <= WN_ARCHIVE_INPUT_MAX - fixture->size);
    size_t needed = fixture->size + size;
    if (needed > fixture->capacity) {
        size_t capacity = fixture->capacity ? fixture->capacity * 2 : 65536;
        if (capacity < needed) {
            capacity = needed;
        }
        unsigned char *next = realloc(fixture->data, capacity);
        assert(next);
        fixture->data = next;
        fixture->capacity = capacity;
    }
    memcpy(fixture->data + fixture->size, data, size);
    fixture->size += size;
    return (la_ssize_t)size;
}

static void start(struct fixture *fixture, int gzip) {
    memset(fixture, 0, sizeof(*fixture));
    fixture->writer = archive_write_new();
    assert(fixture->writer);
    assert(archive_write_set_format_pax_restricted(fixture->writer) == ARCHIVE_OK);
    if (gzip) {
        assert(archive_write_add_filter_gzip(fixture->writer) == ARCHIVE_OK);
    }
    assert(archive_write_open(fixture->writer, fixture, NULL, collect, NULL) == ARCHIVE_OK);
}

static void add(struct fixture *fixture, const char *name, int type, const char *target,
                const void *data, size_t size) {
    struct archive_entry *entry = archive_entry_new();
    assert(entry);
    archive_entry_set_pathname(entry, name);
    archive_entry_set_filetype(entry, type);
    archive_entry_set_perm(entry, 0644);
    archive_entry_set_size(entry, (la_int64_t)size);
    if (target) {
        if (type == AE_IFLNK) {
            archive_entry_set_symlink(entry, target);
        } else {
            archive_entry_set_hardlink(entry, target);
        }
    }
    assert(archive_write_header(fixture->writer, entry) == ARCHIVE_OK);
    if (size && data) {
        assert(archive_write_data(fixture->writer, data, size) == (la_ssize_t)size);
    }
    assert(archive_write_finish_entry(fixture->writer) == ARCHIVE_OK);
    archive_entry_free(entry);
}

static void finish(struct fixture *fixture) {
    assert(archive_write_close(fixture->writer) == ARCHIVE_OK);
    assert(archive_write_free(fixture->writer) == ARCHIVE_OK);
    fixture->writer = NULL;
}

static void reject(const char *helper, const unsigned char *data, int size, WnArchiveOp op,
                   unsigned int index) {
    unsigned int count = 99, length = 99;
    unsigned char *result = wn_archive_read(helper, data, size, op, index, &count, &length);
    assert(!result && count == 0 && length == 0);
}

static void entry_bytes(const char *helper, struct fixture *fixture, unsigned int index,
                        const void *expected, unsigned int expected_size) {
    unsigned int count = 99, length = 99;
    unsigned char *result = wn_archive_read(helper, fixture->data, (int)fixture->size,
                                            WN_ARCHIVE_ENTRY, index, &count, &length);
    assert(result && count == 0 && length == expected_size);
    assert(!length || !memcmp(result, expected, length));
    free(result);
}

static unsigned char *listing(const char *helper, struct fixture *fixture,
                              unsigned int expected_count, unsigned int *length) {
    unsigned int count = 99;
    unsigned char *result = wn_archive_read(helper, fixture->data, (int)fixture->size,
                                            WN_ARCHIVE_LIST, 0, &count, length);
    assert(result && count == expected_count);
    return result;
}

static void record(const unsigned char *data, unsigned int index, const char *name, uint64_t size) {
    size_t length = strlen(name);
    assert(wn_image_u32(data) == index && wn_image_u32(data + 4) == length);
    assert(wn_image_u32(data + 8) == (uint32_t)size);
    assert(wn_image_u32(data + 12) == (uint32_t)(size >> 32));
    assert(!memcmp(data + 16, name, length));
}

static void content_cases(const char *helper) {
    struct fixture fixture;
    start(&fixture, 0);
    add(&fixture, "dir/", AE_IFDIR, NULL, NULL, 0);
    const unsigned char body[] = {0, 1, 2, 255, '\n'};
    add(&fixture, "dir/file.bin", AE_IFREG, NULL, body, sizeof(body));
    add(&fixture, "symlink", AE_IFLNK, "dir/file.bin", NULL, 0);
    add(&fixture, "hardlink", AE_IFREG, "dir/file.bin", NULL, 0);
    add(&fixture, "empty", AE_IFREG, NULL, NULL, 0);
    finish(&fixture);
    unsigned int length;
    unsigned char *result = listing(helper, &fixture, 2, &length);
    assert(length == 16 + strlen("dir/file.bin") + 16 + strlen("empty"));
    record(result, 1, "dir/file.bin", sizeof(body));
    record(result + 16 + strlen("dir/file.bin"), 4, "empty", 0);
    free(result);
    entry_bytes(helper, &fixture, 1, body, sizeof(body));
    entry_bytes(helper, &fixture, 4, NULL, 0);
    const unsigned int rejected[] = {0, 2, 3, 5, WN_ARCHIVE_SCAN_MAX, UINT32_MAX};
    for (size_t i = 0; i < sizeof(rejected) / sizeof(rejected[0]); ++i) {
        reject(helper, fixture.data, (int)fixture.size, WN_ARCHIVE_ENTRY, rejected[i]);
    }
    reject(helper, fixture.data, 100, WN_ARCHIVE_LIST, 0);
    /* The first regular header is intact, but its bytes are truncated. */
    reject(helper, fixture.data, 1026, WN_ARCHIVE_ENTRY, 1);
    reject(helper, fixture.data, 1026, WN_ARCHIVE_LIST, 0);
    reject(helper, fixture.data, 0, WN_ARCHIVE_LIST, 0);
    reject(helper, fixture.data, (int)fixture.size, (WnArchiveOp)2, 0);
    reject(helper, fixture.data, (int)fixture.size, WN_ARCHIVE_LIST, 1);
    memset(fixture.data, 0xff, fixture.size);
    reject(helper, fixture.data, (int)fixture.size, WN_ARCHIVE_LIST, 0);
    free(fixture.data);
    start(&fixture, 0);
    finish(&fixture);
    result = listing(helper, &fixture, 0, &length);
    assert(length == 0);
    free(result);
    free(fixture.data);
    start(&fixture, 0);
    const char unicode_name[] = "日本語/café.txt";
    add(&fixture, unicode_name, AE_IFREG, NULL, body, sizeof(body));
    finish(&fixture);
    result = listing(helper, &fixture, 1, &length);
    assert(length == 16 + strlen(unicode_name));
    record(result, 0, unicode_name, sizeof(body));
    free(result);
    entry_bytes(helper, &fixture, 0, body, sizeof(body));
    free(fixture.data);
}

static void budget_cases(const char *helper) {
    struct fixture fixture;
    unsigned int length;
    char name[WN_ARCHIVE_NAME_MAX + 2];
    memset(name, 'a', sizeof(name));
    name[WN_ARCHIVE_NAME_MAX] = 0;
    start(&fixture, 0);
    for (unsigned int i = 0; i < WN_ARCHIVE_COUNT_MAX; ++i) {
        add(&fixture, name, AE_IFREG, NULL, NULL, 0);
    }
    finish(&fixture);
    unsigned char *result = listing(helper, &fixture, WN_ARCHIVE_COUNT_MAX, &length);
    assert(length == WN_ARCHIVE_COUNT_MAX * (16 + WN_ARCHIVE_NAME_MAX));
    record(result, 0, name, 0);
    record(result + length - 16 - WN_ARCHIVE_NAME_MAX, WN_ARCHIVE_COUNT_MAX - 1, name, 0);
    free(result);
    free(fixture.data);
    start(&fixture, 0);
    for (unsigned int i = 0; i <= WN_ARCHIVE_COUNT_MAX; ++i) {
        add(&fixture, "file", AE_IFREG, NULL, NULL, 0);
    }
    finish(&fixture);
    reject(helper, fixture.data, (int)fixture.size, WN_ARCHIVE_LIST, 0);
    free(fixture.data);
    name[WN_ARCHIVE_NAME_MAX] = 'a';
    name[WN_ARCHIVE_NAME_MAX + 1] = 0;
    start(&fixture, 0);
    add(&fixture, name, AE_IFREG, NULL, NULL, 0);
    finish(&fixture);
    reject(helper, fixture.data, (int)fixture.size, WN_ARCHIVE_LIST, 0);
    free(fixture.data);
    start(&fixture, 0);
    for (unsigned int i = 0; i < WN_ARCHIVE_SCAN_MAX - 1; ++i) {
        add(&fixture, "dir/", AE_IFDIR, NULL, NULL, 0);
    }
    add(&fixture, "last", AE_IFREG, NULL, "x", 1);
    finish(&fixture);
    result = listing(helper, &fixture, 1, &length);
    assert(length == 20);
    record(result, WN_ARCHIVE_SCAN_MAX - 1, "last", 1);
    free(result);
    entry_bytes(helper, &fixture, WN_ARCHIVE_SCAN_MAX - 1, "x", 1);
    free(fixture.data);
    start(&fixture, 0);
    for (unsigned int i = 0; i <= WN_ARCHIVE_SCAN_MAX; ++i) {
        add(&fixture, "dir/", AE_IFDIR, NULL, NULL, 0);
    }
    finish(&fixture);
    reject(helper, fixture.data, (int)fixture.size, WN_ARCHIVE_LIST, 0);
    free(fixture.data);
    /* A highly compressible entry must still obey the expanded-byte limit. */
    start(&fixture, 1);
    add(&fixture, "at-limit", AE_IFREG, NULL, NULL, WN_ARCHIVE_ENTRY_MAX);
    finish(&fixture);
    unsigned int count;
    result = wn_archive_read(helper, fixture.data, (int)fixture.size, WN_ARCHIVE_ENTRY, 0, &count,
                             &length);
    assert(result && count == 0 && length == WN_ARCHIVE_ENTRY_MAX);
    for (unsigned int i = 0; i < length; ++i) {
        assert(result[i] == 0);
    }
    free(result);
    free(fixture.data);
    start(&fixture, 1);
    add(&fixture, "oversized", AE_IFREG, NULL, NULL, (size_t)WN_ARCHIVE_ENTRY_MAX + 1);
    finish(&fixture);
    result = listing(helper, &fixture, 1, &length);
    assert(length == 25);
    record(result, 0, "oversized", (uint64_t)WN_ARCHIVE_ENTRY_MAX + 1);
    free(result);
    reject(helper, fixture.data, (int)fixture.size, WN_ARCHIVE_ENTRY, 0);
    free(fixture.data);
}

static int hostile_peer(void) {
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    unsigned char request[16];
    if (fread(request, 1, sizeof(request), stdin) != sizeof(request)) {
        return 1;
    }
    int mode = getchar();
    while (getchar() != EOF) {
    }
    unsigned char response[16] = {'A', 'R', 'O', '1'};
    uint32_t index = wn_image_u32(request + 12);
    wn_image_put(response + 8, index);
    wn_image_put(response + 12, 1);
    switch (mode) {
    case 'm':
        response[0] = 'X';
        break;
    case 'i':
        wn_image_put(response + 8, index + 1);
        break;
    case 'c':
        wn_image_put(response + 4, WN_ARCHIVE_COUNT_MAX + 1);
        break;
    case 'e':
        wn_image_put(response + 4, 1);
        break;
    case 'l':
        wn_image_put(response + 12, UINT32_MAX);
        break;
    }
    if (fwrite(response, 1, sizeof(response), stdout) != sizeof(response)) {
        return 1;
    }
    if (mode != 's') {
        putchar(0);
    }
    if (mode == 'x') {
        putchar(0);
    }
    return mode == 'f' ? 1 : 0;
}

int main(int argc, char **argv) {
    if (argc == 1) {
        return hostile_peer();
    }
    assert(argc == 2);
    assert(setlocale(LC_CTYPE, "C.UTF-8") || setlocale(LC_CTYPE, "en_US.UTF-8") ||
           setlocale(LC_CTYPE, ".UTF-8"));
    content_cases(argv[1]);
    budget_cases(argv[1]);
    const unsigned char failures[] = {'m', 'i', 'c', 'e', 'l', 's', 'x', 'f'};
    for (size_t i = 0; i < sizeof(failures); ++i) {
        reject(argv[0], failures + i, 1, WN_ARCHIVE_ENTRY, 7);
    }
    const unsigned char list_failures[] = {'m', 'i', 'c', 'l', 's', 'x', 'f'};
    for (size_t i = 0; i < sizeof(list_failures); ++i) {
        reject(argv[0], list_failures + i, 1, WN_ARCHIVE_LIST, 0);
    }
    puts("archive boundary: listings, extraction, empty entries, links, malformed data and budgets "
         "passed");
    return 0;
}
