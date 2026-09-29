#include "../app/decoder_ipc.h"
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

static unsigned char pdf[2 * 1024 * 1024];
static size_t pdf_size;
static size_t offsets[WN_PDF_PAGES_MAX + 4];

static void append(const char *format, ...) {
    va_list args;
    va_start(args, format);
    int n = vsnprintf((char *)pdf + pdf_size, sizeof(pdf) - pdf_size, format, args);
    va_end(args);
    assert(n >= 0 && (size_t)n < sizeof(pdf) - pdf_size);
    pdf_size += (size_t)n;
}

static void object(unsigned int id, const char *body) {
    offsets[id] = pdf_size;
    append("%u 0 obj\n%s\nendobj\n", id, body);
}

static void finish(unsigned int objects) {
    size_t xref = pdf_size;
    append("xref\n0 %u\n0000000000 65535 f \n", objects + 1);
    for (unsigned int id = 1; id <= objects; ++id) {
        append("%010zu 00000 n \n", offsets[id]);
    }
    append("trailer\n<< /Size %u /Root 1 0 R >>\nstartxref\n%zu\n%%%%EOF\n", objects + 1, xref);
}

static void fixture(const char *box, unsigned int pages) {
    pdf_size = 0;
    append("%%PDF-1.4\n");
    object(1, "<< /Type /Catalog /Pages 2 0 R >>");
    offsets[2] = pdf_size;
    append("2 0 obj\n<< /Type /Pages /Kids [3 0 R 5 0 R] /Count %u >>\nendobj\n", pages);
    for (unsigned int page = 0; page < 2; ++page) {
        unsigned int id = 3 + 2 * page;
        offsets[id] = pdf_size;
        append("%u 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [%s] "
               "/Resources << /Font << /F1 7 0 R >> >> /Contents %u 0 R >>\nendobj\n",
               id, box, id + 1);
        const char *content =
            page == 0 ? "1 0 0 rg 0 0 100 100 re f\n0 0 0 rg BT /F1 12 Tf 120 75 Td (PDF) Tj ET\n"
                      : "0 0 1 rg 0 0 100 100 re f\n0 0 0 rg BT /F1 12 Tf 120 75 Td (PDF) Tj ET\n";
        offsets[id + 1] = pdf_size;
        append("%u 0 obj\n<< /Length %zu >>\nstream\n%sendstream\nendobj\n", id + 1,
               strlen(content), content);
    }
    object(7, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");
    finish(7);
}

static void fixture_page_limit(void) {
    unsigned int count = WN_PDF_PAGES_MAX + 1;
    pdf_size = 0;
    append("%%PDF-1.4\n");
    object(1, "<< /Type /Catalog /Pages 2 0 R >>");
    offsets[2] = pdf_size;
    append("2 0 obj\n<< /Type /Pages /Count %u /Kids [", count);
    for (unsigned int i = 0; i < count; ++i) {
        append("%u 0 R ", i + 3);
    }
    append("] >>\nendobj\n");
    for (unsigned int i = 0; i < count; ++i) {
        object(i + 3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] >>");
    }
    finish(count + 2);
}

static void expect_pixel(const unsigned char *pixels, unsigned int width, unsigned int x,
                         unsigned int y, unsigned char r, unsigned char g, unsigned char b) {
    const unsigned char *at = pixels + ((size_t)y * width + x) * 4;
    assert(at[0] == r && at[1] == g && at[2] == b && at[3] == 255);
}

static unsigned char *render(const char *helper, const char *fonts, unsigned int page,
                             unsigned int width, unsigned int height, unsigned int expected_w,
                             unsigned int expected_h) {
    unsigned int pages = 0, w = 0, h = 0;
    unsigned char *pixels =
        wn_pdf_render(helper, fonts, pdf, (int)pdf_size, page, width, height, &pages, &w, &h);
    assert(pixels && pages == 2 && w == expected_w && h == expected_h);
    return pixels;
}

static void expect_failure(const char *helper, const char *fonts, const unsigned char *data,
                           int size, unsigned int page, unsigned int width, unsigned int height) {
    unsigned int pages = 99, w = 99, h = 99;
    unsigned char *pixels =
        wn_pdf_render(helper, fonts, data, size, page, width, height, &pages, &w, &h);
    assert(!pixels && pages == 0 && w == 0 && h == 0);
}

/* Deliberately invalid replies exercise the parent independently of Poppler. */
static int hostile_peer(void) {
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    unsigned char request[20];
    if (fread(request, 1, sizeof(request), stdin) != sizeof(request)) {
        return 1;
    }
    int mode = getchar();
    while (getchar() != EOF) {
    }
    unsigned char response[20] = {'P', 'D', 'O', '1'};
    wn_image_put(response + 4, 1);
    wn_image_put(response + 8, 1);
    wn_image_put(response + 12, 8);
    wn_image_put(response + 16, 2);
    switch (mode) {
    case 'd':
        wn_image_put(response + 4, WN_PDF_DIM_MAX + 1);
        break;
    case 'w':
        wn_image_put(response + 4, 2);
        wn_image_put(response + 12, 12);
        break;
    case 'h':
        wn_image_put(response + 8, 2);
        wn_image_put(response + 12, 12);
        break;
    case 'l':
        wn_image_put(response + 12, UINT32_MAX);
        break;
    case 'm':
        response[0] = 'X';
        break;
    case 'z':
        wn_image_put(response + 8, 0);
        break;
    case 'p':
        wn_image_put(response + 16, 0);
        break;
    case 'q':
        wn_image_put(response + 16, WN_PDF_PAGES_MAX + 1);
        break;
    case 'i':
        wn_image_put(response + 16, 1);
        break;
    }
    size_t length = mode == 'b' ? 18 : sizeof(response);
    if (fwrite(response, 1, length, stdout) != length) {
        return 1;
    }
    if (mode == 'b') {
        return 0;
    }
    unsigned char pixels[8] = {9, 8, 7, 255, 9, 8, 7, 255};
    length = (mode == 'w' || mode == 'h') ? 8 : mode == 's' ? 3 : 4;
    if (fwrite(pixels, 1, length, stdout) != length) {
        return 1;
    }
    if (mode == 'x') {
        putchar(0);
    }
    return mode == 'f' ? 1 : 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "__wn_pdf_peer__")) {
        return hostile_peer();
    }
    assert(argc == 2 || argc == 3);
    const char *helper = argv[1];
    const char *fonts = argc == 3 ? argv[2] : "vendor/fonts";
    fixture("0 0 200 100", 2);
    /* Forward, then backward: reparsing never changes the selected page. */
    const unsigned int order[] = {0, 1, 0};
    for (size_t i = 0; i < sizeof(order) / sizeof(order[0]); ++i) {
        unsigned int page = order[i];
        unsigned char *pixels = render(helper, fonts, page, 480, 0, 480, 240);
        expect_pixel(pixels, 480, 120, 120, page ? 0 : 255, 0, page ? 255 : 0);
        expect_pixel(pixels, 480, 360, 120, 255, 255, 255);
        unsigned int ink = 0;
        for (unsigned int y = 20; y < 80; ++y) {
            for (unsigned int x = 280; x < 420; ++x) {
                const unsigned char *p = pixels + ((size_t)y * 480 + x) * 4;
                ink += p[0] < 128 && p[1] < 128 && p[2] < 128;
            }
        }
        assert(ink > 50); /* Real substitute-font glyphs, not an empty text box. */
        free(pixels);
    }
    unsigned char *pixels = render(helper, fonts, 1, 1600, 900, 1600, 800);
    expect_pixel(pixels, 1600, 400, 400, 0, 0, 255);
    free(pixels);
    pixels = render(helper, fonts, 0, 300, 100, 200, 100);
    expect_pixel(pixels, 200, 50, 50, 255, 0, 0);
    free(pixels);
    pixels = render(helper, fonts, 0, 1, 1, 1, 1);
    free(pixels);
    expect_failure(helper, fonts, pdf, (int)pdf_size, 2, 480, 0);
    expect_failure(helper, fonts, pdf, (int)pdf_size, 0, 0, 0);
    expect_failure(helper, fonts, pdf, (int)pdf_size, 0, WN_PDF_DIM_MAX + 1, 0);
    expect_failure(helper, fonts, pdf, (int)pdf_size, 0, 480, WN_PDF_DIM_MAX + 1);
    expect_failure(helper, fonts, pdf, (int)pdf_size, 0, 32768, 32768);
    expect_failure(helper, fonts, pdf, 12, 0, 480, 0);
    expect_failure(helper, fonts, (const unsigned char *)"not a PDF", 9, 0, 480, 0);
    expect_failure("/nonexistent/wn-pdf", fonts, pdf, (int)pdf_size, 0, 480, 0);
    fixture("0 0 1 1000000000", 2);
    expect_failure(helper, fonts, pdf, (int)pdf_size, 0, 480, 0);
    fixture_page_limit();
    expect_failure(helper, fonts, pdf, (int)pdf_size, 0, 480, 0);

    const unsigned char failures[] = {'d', 'w', 'h', 'l', 'm', 'z', 'p',
                                      'q', 'i', 'b', 's', 'x', 'f'};
    for (size_t i = 0; i < sizeof(failures); ++i) {
        expect_failure(argv[0], "__wn_pdf_peer__", failures + i, 1, 1, 1, 1);
    }
    puts("PDF boundary: page navigation, color, fonts, fitted sizes, budgets and hostile replies "
         "passed");
    return 0;
}

#include "../app/helper_main.h"
