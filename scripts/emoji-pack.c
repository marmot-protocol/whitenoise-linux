#define _POSIX_C_SOURCE 200809L
// Tile side; matches EMOJI_SIDE in scripts/build.sh and app/emoji.odin.
#define SIDE 128
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_MAX_DIMENSIONS SIDE
#include "stb_image.h"
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define PIXELS (SIDE * SIDE * 4)
static char *temporary;
static void cleanup(void) {
    if (temporary) {
        unlink(temporary);
    }
}
static void fail(const char *what) {
    fprintf(stderr, "emoji-pack: %s\n", what);
    exit(1);
}
static void io_fail(const char *path) {
    perror(path);
    exit(1);
}

// The staged tile name (scripts/build.sh emoji_stage): lowercase hex
// codepoints joined by '-', VS16 dropped (U+23 U+FE0F U+20E3 -> 23-20e3.png).
static void filename(char *name, size_t capacity, const unsigned char *s, size_t len) {
    size_t used = 0;
    while (len) {
        uint32_t cp = *s++;
        len--;
        unsigned extra = cp < 0x80                  ? 0
                         : cp >= 0xc2 && cp <= 0xdf ? 1
                         : cp >= 0xe0 && cp <= 0xef ? 2
                         : cp >= 0xf0 && cp <= 0xf4 ? 3
                                                    : 4;
        if (extra == 4 || extra > len) {
            fail("invalid catalog UTF-8");
        }
        uint32_t minimum = extra == 1 ? 0x80 : extra == 2 ? 0x800 : extra == 3 ? 0x10000 : 0;
        if (extra) {
            cp &= (1u << (6 - extra)) - 1;
        }
        for (unsigned i = 0; i < extra; i++) {
            if ((*s & 0xc0) != 0x80) {
                fail("invalid catalog UTF-8");
            }
            cp = (cp << 6) | (*s++ & 0x3f);
            len--;
        }
        if (cp < minimum || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) {
            fail("invalid catalog UTF-8");
        }
        if (cp == 0xfe0f) {
            continue;
        }
        int n = snprintf(name + used, capacity - used, "%s%x", used ? "-" : "", (unsigned)cp);
        if (n < 0 || (size_t)n >= capacity - used) {
            fail("emoji filename too long");
        }
        used += (size_t)n;
    }
    if (snprintf(name + used, capacity - used, ".png") >= (int)(capacity - used)) {
        fail("emoji filename too long");
    }
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fail("usage: emoji-pack CATALOG EMOJI_DIR OUTPUT");
    }
    FILE *catalog = fopen(argv[1], "rb");
    if (!catalog) {
        io_fail(argv[1]);
    }
    temporary = malloc(strlen(argv[3]) + 8);
    if (!temporary) {
        io_fail("malloc");
    }
    sprintf(temporary, "%s.XXXXXX", argv[3]);
    int fd = mkstemp(temporary);
    if (fd < 0) {
        io_fail(temporary);
    }
    if (atexit(cleanup)) {
        unlink(temporary);
        fail("cannot register cleanup");
    }
    FILE *out = fdopen(fd, "w+b");
    if (!out) {
        io_fail(temporary);
    }
    unsigned char header[8] = {'W', 'N', 'E', '1', 0, 0, 0, 0};
    if (fwrite(header, 1, sizeof(header), out) != sizeof(header)) {
        io_fail(temporary);
    }
    char *line = NULL;
    size_t capacity = 0;
    ssize_t length;
    uint32_t count = 0, missing = 0;
    while ((length = getline(&line, &capacity, catalog)) >= 0) {
        char *tab = memchr(line, '\t', (size_t)length);
        if (!tab || tab == line) {
            continue;
        }
        if (count == UINT32_MAX) {
            fail("too many catalog rows");
        }
        char name[1024], path[4096];
        filename(name, sizeof(name), (unsigned char *)line, (size_t)(tab - line));
        int n = snprintf(path, sizeof(path), "%s/%s", argv[2], name);
        if (n < 0 || (size_t)n >= sizeof(path)) {
            fail("emoji path too long");
        }
        FILE *png = fopen(path, "rb");
        if (!png && errno != ENOENT) {
            io_fail(path);
        }
        static const unsigned char zeroes[PIXELS] = {0};
        unsigned char available = png != NULL;
        unsigned char *pixels = NULL;
        if (png) {
            int width, height, channels;
            pixels = stbi_load_from_file(png, &width, &height, &channels, 4);
            if (ferror(png)) {
                io_fail(path);
            }
            if (fclose(png)) {
                io_fail(path);
            }
            if (!pixels || width != SIDE || height != SIDE) {
                fprintf(stderr, "emoji-pack: invalid %dx%d PNG: %s\n", SIDE, SIDE, path);
                exit(1);
            }
        } else {
            missing++;
        }
        if (fwrite(&available, 1, 1, out) != 1 ||
            fwrite(pixels ? pixels : zeroes, 1, PIXELS, out) != PIXELS) {
            io_fail(temporary);
        }
        stbi_image_free(pixels);
        count++;
    }
    if (!feof(catalog) || ferror(catalog)) {
        io_fail(argv[1]);
    }
    if (fclose(catalog)) {
        io_fail(argv[1]);
    }
    free(line);
    for (unsigned i = 0; i < 4; i++) {
        header[4 + i] = (unsigned char)(count >> (8 * i));
    }
    if (fseek(out, 0, SEEK_SET) || fwrite(header, 1, sizeof(header), out) != sizeof(header) ||
        fflush(out) || fchmod(fd, 0644) || fclose(out)) {
        io_fail(temporary);
    }
    if (rename(temporary, argv[3])) {
        io_fail(argv[3]);
    }
    free(temporary);
    temporary = NULL;
    printf("Emoji pack: %u rows, %u missing (%s)\n", (unsigned)count, (unsigned)missing, argv[3]);
    return 0;
}
