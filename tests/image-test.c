#define _POSIX_C_SOURCE 200809L
#include "../app/decoder_ipc.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <webp/encode.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#else
#include <fcntl.h>
#include <time.h>
#include <unistd.h>
#endif
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

static unsigned char encoded[4096];
static size_t encoded_size;

static void collect(void *context, void *data, int size) {
    (void)context;
    assert(size >= 0 && (size_t)size <= sizeof(encoded) - encoded_size);
    memcpy(encoded + encoded_size, data, (size_t)size);
    encoded_size += (size_t)size;
}

static void put32(unsigned char *p, uint32_t value) {
    for (int i = 0; i < 4; ++i) {
        p[i] = (unsigned char)(value >> (i * 8));
    }
}

// A hostile peer exercises the parent's parser, not the image library's checks.
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
    unsigned char response[16] = {'W', 'N', 'O', '1'};
    put32(response + 4, 1);
    put32(response + 8, 1);
    put32(response + 12, 4);
    unsigned char pixel[4] = {9, 8, 7, 255};
    switch (mode) {
    case 'd':
        put32(response + 4, UINT32_MAX);
        break;
    case 'l':
        put32(response + 12, UINT32_MAX);
        break;
    case 'm':
        response[0] = 'X';
        break;
    case 'z':
        put32(response + 8, 0);
        break;
    case 'e':
        if (getenv("WN_IMAGE_TEST_SECRET")) {
            return 1;
        }
#ifndef _WIN32
        if (fcntl(100, F_GETFD) != -1) {
            return 1;
        }
#endif
        break;
    case 't':
#ifdef _WIN32
        Sleep(30000);
#else
        sleep(30);
#endif
        return 1;
    }
    if (fwrite(response, 1, sizeof(response), stdout) != sizeof(response)) {
        return 1;
    }
    size_t size = mode == 's' ? 3 : sizeof(pixel);
    if (fwrite(pixel, 1, size, stdout) != size) {
        return 1;
    }
    if (mode == 'x') {
        putchar(0);
    }
    return mode == 'f' ? 1 : 0;
}

static void expect_failure(const char *helper, const unsigned char *data, int size, int dimension,
                           unsigned int bytes) {
    int w = 99, h = 99;
    unsigned char *pixels = wn_image_decode(helper, data, size, dimension, bytes, &w, &h);
    assert(pixels == NULL && w == 0 && h == 0);
}

int main(int argc, char **argv) {
    if (argc == 1) {
        return hostile_peer();
    }
    assert(argc == 2);
    const char *helper = argv[1];
    const unsigned char rgba[] = {255, 0, 0, 255, 0, 0, 255, 128};
    assert(stbi_write_png_to_func(collect, NULL, 2, 1, 4, rgba, 8));
    int w = 0, h = 0;
    unsigned char *pixels = wn_image_decode(helper, encoded, (int)encoded_size, 2, 8, &w, &h);
    assert(pixels && w == 2 && h == 1 && memcmp(pixels, rgba, sizeof(rgba)) == 0);
    free(pixels);
    expect_failure(helper, encoded, (int)encoded_size, 1, 8);
    expect_failure(helper, encoded, (int)encoded_size, 2, 7);
    expect_failure(helper, encoded, 12, 2, 8);
    expect_failure(helper, encoded, 0, 2, 8);
    expect_failure(helper, encoded, (int)encoded_size, 0, 8);
    expect_failure(helper, encoded, (int)encoded_size, 2, 0);
    expect_failure("/nonexistent/wn-image", encoded, (int)encoded_size, 2, 8);

    unsigned char *webp = NULL;
    size_t webp_size = WebPEncodeLosslessRGBA(rgba, 2, 1, 8, &webp);
    assert(webp_size > 0);
    pixels = wn_image_decode(helper, webp, (int)webp_size, 2, 8, &w, &h);
    assert(pixels && w == 2 && h == 1 && memcmp(pixels, rgba, sizeof(rgba)) == 0);
    free(pixels);
    WebPFree(webp);

    const unsigned char gif[] = {'G', 'I', 'F', '8', '9', 'a', 1,   0,    1, 0, 0x80, 0,
                                 0,   0,   0,   0,   255, 255, 255, 0x2c, 0, 0, 0,    0,
                                 1,   0,   1,   0,   0,   2,   2,   0x44, 1, 0, 0x3b};
    pixels = wn_image_decode(helper, gif, sizeof(gif), 1, 4, &w, &h);
    const unsigned char black[] = {0, 0, 0, 255};
    assert(pixels && w == 1 && h == 1 && memcmp(pixels, black, 4) == 0);
    free(pixels);

    unsigned char rgb[8 * 8 * 3];
    for (size_t i = 0; i < sizeof(rgb); i += 3) {
        rgb[i] = 240;
        rgb[i + 1] = 40;
        rgb[i + 2] = 20;
    }
    encoded_size = 0;
    assert(stbi_write_jpg_to_func(collect, NULL, 8, 8, 3, rgb, 95));
    pixels = wn_image_decode(helper, encoded, (int)encoded_size, 8, 256, &w, &h);
    assert(pixels && w == 8 && h == 8);
    for (int i = 0; i < w * h; ++i) {
        assert(abs(pixels[i * 4] - 240) <= 3);
        assert(abs(pixels[i * 4 + 1] - 40) <= 3);
        assert(abs(pixels[i * 4 + 2] - 20) <= 3);
        assert(pixels[i * 4 + 3] == 255);
    }
    free(pixels);

    const unsigned char failures[] = {'d', 'l', 'm', 'z', 's', 'x', 'f'};
    for (size_t i = 0; i < sizeof(failures); ++i) {
        expect_failure(argv[0], failures + i, 1, 2, 8);
    }
#ifdef _WIN32
    assert(SetEnvironmentVariableA("WN_IMAGE_TEST_SECRET", "not-for-child"));
#else
    assert(setenv("WN_IMAGE_TEST_SECRET", "not-for-child", 1) == 0);
    int fd = open("/dev/null", O_RDONLY);
    assert(fd >= 0 && dup2(fd, 100) == 100);
    close(fd);
#endif
    const unsigned char environment = 'e';
    pixels = wn_image_decode(argv[0], &environment, 1, 2, 8, &w, &h);
    const unsigned char expected[] = {9, 8, 7, 255};
    assert(pixels && w == 1 && h == 1 && memcmp(pixels, expected, 4) == 0);
    free(pixels);
#ifndef _WIN32
    close(100);
#endif
    const unsigned char timeout = 't';
#ifdef _WIN32
    ULONGLONG start = GetTickCount64();
#else
    struct timespec start, end;
    assert(clock_gettime(CLOCK_MONOTONIC, &start) == 0);
#endif
    expect_failure(argv[0], &timeout, 1, 2, 8);
#ifdef _WIN32
    assert(GetTickCount64() - start < 20000);
#else
    assert(clock_gettime(CLOCK_MONOTONIC, &end) == 0);
    assert(end.tv_sec - start.tv_sec < 20);
#endif
    puts("image boundary: formats, budgets, hostile output, inheritance and deadline passed");
    return 0;
}
