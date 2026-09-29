/* PDF parsing and font loading happen only in this one-shot process. */
#include "decoder_ipc.h"
#include "decoder_limits.h"
#include <cairo.h>
#include <fontconfig/fontconfig.h>
#include <math.h>
#include <poppler.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __OpenBSD__
#include <errno.h>
#include <unistd.h>
#endif

#ifdef __OpenBSD__
static int pdf_font_allow(const char *directory) {
    if (unveil(directory, "r")) {
        return 0;
    }
    /* Per-file grants exceed OpenBSD's unveil name limit on a stock install.
       Keep directory grants to standard font trees and Poppler resources,
       never arbitrary directories discovered through Fontconfig. */
    const char *resources[] = {"/usr/X11R6/lib/X11/fonts", "/usr/local/share/fonts",
                               "/usr/share/fonts", "/usr/local/share/poppler",
                               "/usr/share/poppler"};
    for (size_t i = 0; i < sizeof(resources) / sizeof(resources[0]); ++i) {
        if (unveil(resources[i], "r") && errno != ENOENT) {
            return 0;
        }
    }
    return unveil(NULL, NULL) == 0 && pledge("stdio rpath", NULL) == 0;
}
#endif

static FcConfig *pdf_fonts(const char *directory) {
    /* The transport supplies an empty environment and this trusted bundle path.
       All discovery finishes before PDF bytes can select a font or resource. */
    FcConfig *config = FcInitLoadConfigAndFonts();
    if (!config) {
        config = FcConfigCreate();
    }
    if (!config) {
        return NULL;
    }
    if (!FcConfigAppFontAddDir(config, (const FcChar8 *)directory) ||
        !FcConfigSetRescanInterval(config, 0) || !FcConfigSetCurrent(config)) {
        FcConfigDestroy(config);
        return NULL;
    }
#ifdef __OpenBSD__
    if (!pdf_font_allow(directory)) {
        FcConfigDestroy(config);
        return NULL;
    }
#endif
    return config;
}

static int pdf_dimensions(PopplerPage *page, uint32_t want_w, uint32_t want_h, int *width,
                          int *height, double *scale) {
    double wpt = 0, hpt = 0;
    poppler_page_get_size(page, &wpt, &hpt);
    if (!isfinite(wpt) || !isfinite(hpt) || wpt <= 0 || hpt <= 0) {
        return 0;
    }
    *scale = (double)want_w / wpt;
    if (want_h) {
        *scale = fmin(*scale, (double)want_h / hpt);
    }
    double w = floor(wpt * *scale + 0.5);
    double h = floor(hpt * *scale + 0.5);
    if (!isfinite(*scale) || *scale <= 0 || !isfinite(w) || !isfinite(h) || w > WN_PDF_DIM_MAX ||
        h > WN_PDF_DIM_MAX) {
        return 0;
    }
    *width = (int)fmax(1, w);
    *height = (int)fmax(1, h);
    return (uint32_t)*width <= want_w && (!want_h || (uint32_t)*height <= want_h) &&
           (uint64_t)*width * (uint64_t)*height * 4 <= WN_PDF_OUTPUT_MAX;
}

static int pdf_emit(cairo_surface_t *surface, int width, int height, int pages) {
    unsigned char header[20] = {'P', 'D', 'O', '1'};
    uint32_t bytes = (uint32_t)((uint64_t)width * (uint64_t)height * 4);
    wn_image_put(header + 4, (uint32_t)width);
    wn_image_put(header + 8, (uint32_t)height);
    wn_image_put(header + 12, bytes + 4);
    wn_image_put(header + 16, (uint32_t)pages);
    if (fwrite(header, 1, sizeof(header), stdout) != sizeof(header)) {
        return 0;
    }
    unsigned char *pixels = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);
    for (int y = 0; y < height; ++y) {
        unsigned char *row = pixels + (size_t)y * (size_t)stride;
        for (int x = 0; x < width; ++x) {
            /* Native-endian ARGB32 on an opaque white background. */
            uint32_t argb;
            unsigned char *pixel = row + (size_t)x * 4;
            memcpy(&argb, pixel, sizeof(argb));
            pixel[0] = (unsigned char)(argb >> 16);
            pixel[1] = (unsigned char)(argb >> 8);
            pixel[2] = (unsigned char)argb;
            pixel[3] = 255;
        }
        size_t length = (size_t)width * 4;
        if (fwrite(row, 1, length, stdout) != length) {
            return 0;
        }
    }
    return fflush(stdout) == 0;
}

static int pdf_render(const unsigned char *data, uint32_t size, uint32_t index, uint32_t want_w,
                      uint32_t want_h) {
    GBytes *bytes = g_bytes_new_static(data, size);
    GError *error = NULL;
    PopplerDocument *doc = poppler_document_new_from_bytes(bytes, NULL, &error);
    g_bytes_unref(bytes);
    if (error) {
        g_error_free(error);
    }
    if (!doc) {
        return 0;
    }
    int result = 0;
    int pages = poppler_document_get_n_pages(doc);
    PopplerPage *page = NULL;
    cairo_surface_t *surface = NULL;
    cairo_t *cr = NULL;
    if (pages <= 0 || (unsigned int)pages > WN_PDF_PAGES_MAX || index >= (uint32_t)pages) {
        goto done;
    }
    page = poppler_document_get_page(doc, (int)index);
    int width, height;
    double scale;
    if (!page || !pdf_dimensions(page, want_w, want_h, &width, &height, &scale)) {
        goto done;
    }
    surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        goto done;
    }
    cr = cairo_create(surface);
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_paint(cr);
    cairo_scale(cr, scale, scale);
    poppler_page_render(page, cr);
    cairo_surface_flush(surface);
    if (cairo_status(cr) == CAIRO_STATUS_SUCCESS &&
        cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS) {
        result = pdf_emit(surface, width, height, pages);
    }
done:
    if (cr) {
        cairo_destroy(cr);
    }
    if (surface) {
        cairo_surface_destroy(surface);
    }
    if (page) {
        g_object_unref(page);
    }
    g_object_unref(doc);
    return result;
}

int main(int argc, char **argv) {
    if (argc != 2 || !argv[1][0] || !wn_decoder_limits(WN_DECODER_ONESHOT)) {
        return 1;
    }
    FcConfig *fonts = pdf_fonts(argv[1]);
    if (!fonts) {
        return 1;
    }
    int result = 1;
    unsigned char *input = NULL;
    unsigned char header[20];
    if (fread(header, 1, sizeof(header), stdin) != sizeof(header) || memcmp(header, "PDI1", 4)) {
        goto done;
    }
    uint32_t size = wn_image_u32(header + 4);
    uint32_t page = wn_image_u32(header + 8);
    uint32_t width = wn_image_u32(header + 12);
    uint32_t height = wn_image_u32(header + 16);
    if (!size || size > WN_PDF_INPUT_MAX || page >= WN_PDF_PAGES_MAX || !width ||
        width > WN_PDF_DIM_MAX || height > WN_PDF_DIM_MAX) {
        goto done;
    }
    input = malloc(size);
    if (!input || fread(input, 1, size, stdin) != size || fgetc(stdin) != EOF || ferror(stdin)) {
        goto done;
    }
    if (pdf_render(input, size, page, width, height)) {
        result = 0;
    }
done:
    free(input);
    FcConfigDestroy(fonts);
    return result;
}

#include "helper_main.h"
