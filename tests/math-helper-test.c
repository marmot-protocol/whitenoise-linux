#define _POSIX_C_SOURCE 200809L
#include "../app/decoder_ipc.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#else
#include <fcntl.h>
#include <time.h>
#include <unistd.h>
#endif

static const unsigned char source[] = "x^2";

/* A separate hostile process can violate the protocol even when wn-math cannot. */
static int hostile_peer(void) {
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    unsigned char request[24];
    if (fread(request, 1, sizeof(request), stdin) != sizeof(request)) {
        return 1;
    }
    int mode = getchar();
    while (getchar() != EOF) {
    }
    unsigned char response[16] = {'M', 'A', 'O', '1'};
    wn_image_put(response + 4, 1);
    wn_image_put(response + 8, 1);
    wn_image_put(response + 12, 4);
    switch (mode) {
    case 'd':
        wn_image_put(response + 4, UINT32_MAX);
        break;
    case 'l':
        wn_image_put(response + 12, UINT32_MAX);
        break;
    case 'm':
        response[0] = 'X';
        break;
    case 'i':
        memcpy(response, "WNO1", 4);
        break;
    case 'z':
        wn_image_put(response + 8, 0);
        break;
    case 'w':
        wn_image_put(response + 4, 2);
        wn_image_put(response + 12, 8);
        break;
    case 'h':
        wn_image_put(response + 8, 2);
        wn_image_put(response + 12, 8);
        break;
    case 'b':
        wn_image_put(response + 4, 2);
        wn_image_put(response + 8, 2);
        wn_image_put(response + 12, 16);
        break;
    case 'e':
        if (getenv("WN_MATH_TEST_SECRET")) {
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
    size_t header_size = mode == 'r' ? 15 : sizeof(response);
    if (fwrite(response, 1, header_size, stdout) != header_size) {
        return 1;
    }
    if (mode == 'r') {
        return 0;
    }
    const unsigned char pixels[16] = {9, 8, 7, 255};
    size_t size = mode == 's' ? 3 : mode == 'w' || mode == 'h' ? 8 : mode == 'b' ? 16 : 4;
    if (fwrite(pixels, 1, size, stdout) != size) {
        return 1;
    }
    if (mode == 'x') {
        putchar(0);
    }
    return mode == 'f' ? 1 : 0;
}

static void expect_failure(const char *helper, const unsigned char *data, int size, float font,
                           unsigned int side, unsigned int bytes) {
    int w = 99, h = 99;
    unsigned char *pixels =
        wn_math_render(helper, data, size, font, 0xff3366cc, side, bytes, &w, &h);
    assert(!pixels && w == 0 && h == 0);
}

static void expect_opaque_ink(const unsigned char *pixels, int count) {
    int ink = 0;
    for (int i = 0; i < count; ++i) {
        if (pixels[i * 4 + 3] >= 250) {
            assert(abs(pixels[i * 4] - 0x33) <= 2);
            assert(abs(pixels[i * 4 + 1] - 0x66) <= 2);
            assert(abs(pixels[i * 4 + 2] - 0xcc) <= 2);
            ink = 1;
        }
    }
    assert(ink);
}

static unsigned char *render(const char *helper, float font, unsigned int argb, unsigned int side,
                             unsigned int bytes, int *w, int *h) {
    return wn_math_render(helper, source, sizeof(source) - 1, font, argb, side, bytes, w, h);
}

int main(int argc, char **argv) {
    if (argc == 1) {
        return hostile_peer();
    }
    assert(argc == 2);
    const char *helper = argv[1];
    const int source_size = sizeof(source) - 1;
    int w = 0, h = 0;
    unsigned char *pixels =
        render(helper, 20, 0xff3366cc, WN_MATH_DIM_MAX, WN_MATH_OUTPUT_MAX, &w, &h);
    assert(pixels && w > 0 && h > 0);
    expect_opaque_ink(pixels, w * h);
    free(pixels);
    unsigned int side = (unsigned int)(w > h ? w : h);
    unsigned int bytes = (unsigned int)w * (unsigned int)h * 4;
    int exact_w = 0, exact_h = 0;
    pixels = render(helper, 20, 0xff3366cc, side, bytes, &exact_w, &exact_h);
    assert(pixels && exact_w == w && exact_h == h);
    free(pixels);
    expect_failure(helper, source, source_size, 20, side - 1, bytes);
    expect_failure(helper, source, source_size, 20, side, bytes - 1);
    pixels =
        render(helper, 40, 0xff3366cc, WN_MATH_DIM_MAX, WN_MATH_OUTPUT_MAX, &exact_w, &exact_h);
    assert(pixels && exact_w > w && exact_h > h);
    free(pixels);
    pixels =
        render(helper, 20, 0x803366cc, WN_MATH_DIM_MAX, WN_MATH_OUTPUT_MAX, &exact_w, &exact_h);
    assert(pixels && exact_w == w && exact_h == h);
    int ink = 0;
    for (int i = 0; i < exact_w * exact_h; ++i) {
        unsigned char *pixel = pixels + i * 4;
        assert(pixel[3] <= 128);
        if (pixel[3] >= 125) {
            /* Color channels must be straight, not multiplied by alpha. */
            assert(abs(pixel[0] - 0x33) <= 3);
            assert(abs(pixel[1] - 0x66) <= 3);
            assert(abs(pixel[2] - 0xcc) <= 3);
            ink = 1;
        }
    }
    assert(ink);
    free(pixels);

    /* Spaces and nested commands exercise lazy character-classification state. */
    static const unsigned char quadratic[] = "x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}";
    pixels = wn_math_render(helper, quadratic, sizeof(quadratic) - 1, 20, 0xff3366cc,
                            WN_MATH_DIM_MAX, WN_MATH_OUTPUT_MAX, &exact_w, &exact_h);
    assert(pixels && exact_w > 0 && exact_h > 0);
    expect_opaque_ink(pixels, exact_w * exact_h);
    free(pixels);

    expect_failure(NULL, source, source_size, 20, side, bytes);
    expect_failure("", source, source_size, 20, side, bytes);
    expect_failure(helper, NULL, source_size, 20, side, bytes);
    expect_failure(helper, source, 0, 20, side, bytes);
    expect_failure(helper, source, -1, 20, side, bytes);
    unsigned char oversized[WN_MATH_INPUT_MAX + 1];
    memset(oversized, 'x', sizeof(oversized));
    expect_failure(helper, oversized, sizeof(oversized), 20, side, bytes);
    const unsigned char nul[] = {'x', 0, 'y'};
    expect_failure(helper, nul, sizeof(nul), 20, side, bytes);
    const float invalid_fonts[] = {0, -1, NAN, INFINITY, -INFINITY, WN_MATH_DIM_MAX + 1};
    for (size_t i = 0; i < sizeof(invalid_fonts) / sizeof(invalid_fonts[0]); ++i) {
        expect_failure(helper, source, source_size, invalid_fonts[i], side, bytes);
    }
    expect_failure(helper, source, source_size, 20, 0, bytes);
    expect_failure(helper, source, source_size, 20, WN_MATH_DIM_MAX + 1, bytes);
    expect_failure(helper, source, source_size, 20, side, 0);
    expect_failure(helper, source, source_size, 20, side, WN_MATH_OUTPUT_MAX + 1);
    w = h = 99;
    assert(!wn_math_render(helper, source, source_size, 20, 0, side, bytes, NULL, &h) && h == 0);
    assert(!wn_math_render(helper, source, source_size, 20, 0, side, bytes, &w, NULL) && w == 0);

    const unsigned char failures[] = {'d', 'l', 'm', 'i', 'z', 'r', 's', 'x', 'f', 'w', 'h', 'b'};
    for (size_t i = 0; i < sizeof(failures); ++i) {
        unsigned int cap_side = failures[i] == 'b' ? 2 : 1;
        expect_failure(argv[0], failures + i, 1, 20, cap_side, 8);
    }
#ifdef _WIN32
    assert(SetEnvironmentVariableA("WN_MATH_TEST_SECRET", "not-for-child"));
#else
    assert(setenv("WN_MATH_TEST_SECRET", "not-for-child", 1) == 0);
    int fd = open("/dev/null", O_RDONLY);
    assert(fd >= 0 && dup2(fd, 100) == 100);
    close(fd);
#endif
    const unsigned char environment = 'e';
    pixels = wn_math_render(argv[0], &environment, 1, 20, 0, 1, 4, &w, &h);
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
    expect_failure(argv[0], &timeout, 1, 20, 1, 4);
#ifdef _WIN32
    assert(GetTickCount64() - start < 20000);
#else
    assert(clock_gettime(CLOCK_MONOTONIC, &end) == 0);
    assert(end.tv_sec - start.tv_sec < 20);
#endif
    puts("math boundary: rendering, color, size, budgets, arguments, hostile output, inheritance "
         "and deadline passed");
    return 0;
}
