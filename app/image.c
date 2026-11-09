/* Untrusted image headers and compressed pixels are only inspected here. */
#include "decoder_limits.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <webp/decode.h>
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_MAX_DIMENSIONS ((int)WN_IMAGE_DIM_MAX)
#include <stb_image.h>

static int image_restrict(void) {
    if (!wn_decoder_limits(WN_DECODER_ONESHOT)) {
        return 0;
    }
#ifdef __OpenBSD__
    if (unveil(NULL, NULL) || pledge("stdio", NULL)) {
        return 0;
    }
#endif
    return 1;
}

static int image_bounds(int w, int h, uint32_t dimension, uint32_t bytes) {
    return w > 0 && h > 0 && (uint32_t)w <= dimension && (uint32_t)h <= dimension &&
           (uint64_t)w * (uint64_t)h * 4 <= bytes;
}

/* Frames a blank-opening GIF may decode while looking for its still:
 * 128 frames at 512x512, or two at 4096x4096. */
#define GIF_SCAN_PIXELS (32u * 1024u * 1024u)

/* Sum of the brightest channel over opaque pixels. *visible reports whether
 * at least 1% of pixels are opaque and not near black. */
static uint64_t frame_light(const unsigned char *rgba, uint64_t count, int *visible) {
    uint64_t lit = 0;
    uint64_t light = 0;
    for (uint64_t i = 0; i < count; ++i) {
        const unsigned char *p = rgba + i * 4;
        if (p[3] < 128) {
            continue;
        }
        unsigned char top = p[0] > p[1] ? p[0] : p[1];
        top = top > p[2] ? top : p[2];
        light += top;
        lit += top >= 24;
    }
    *visible = lit * 100 >= count;
    return light;
}

/* Many GIFs open on a black or empty frame (a fade-in, a sticker drawing
 * itself), which makes the first frame a blank still. Keep a visible first
 * frame; otherwise use the brightest frame within GIF_SCAN_PIXELS. "Restore
 * previous" disposal falls back to the background, as stb's single-frame
 * load does. */
static unsigned char *gif_still(const unsigned char *input, uint32_t size, int *width,
                                int *height) {
    stbi__context context;
    stbi__gif gif;
    memset(&gif, 0, sizeof(gif));
    stbi__start_mem(&context, input, (int)size);
    unsigned char *still = NULL;
    uint64_t best = 0;
    uint64_t scanned = 0;
    int channels = 0;
    for (int index = 0; scanned < GIF_SCAN_PIXELS; ++index) {
        unsigned char *frame = stbi__gif_load_next(&context, &gif, &channels, 4, NULL);
        if (!frame || frame == (unsigned char *)&context) {
            break;
        }
        uint64_t count = (uint64_t)gif.w * (uint64_t)gif.h;
        scanned += count;
        if (index == 0) {
            still = malloc(count * 4);
            if (!still) {
                break;
            }
            *width = gif.w;
            *height = gif.h;
        }
        int visible = 0;
        uint64_t light = frame_light(frame, count, &visible);
        if (index == 0 || light > best) {
            memcpy(still, frame, count * 4);
            best = light;
        }
        if (index == 0 && visible) {
            break;
        }
    }
    STBI_FREE(gif.out);
    STBI_FREE(gif.history);
    STBI_FREE(gif.background);
    return still;
}

int main(int argc, char **argv) {
    (void)argv;
    if (argc != 1 || !image_restrict()) {
        return 1;
    }
    unsigned char header[WN_IMAGE_HEADER];
    if (fread(header, 1, sizeof(header), stdin) != sizeof(header) || memcmp(header, "WNI1", 4)) {
        return 1;
    }
    uint32_t size = wn_image_u32(header + 4);
    uint32_t dimension = wn_image_u32(header + 8);
    uint32_t cap = wn_image_u32(header + 12);
    if (!size || size > WN_IMAGE_INPUT_MAX || !dimension || dimension > WN_IMAGE_DIM_MAX || !cap ||
        cap > WN_IMAGE_OUTPUT_MAX) {
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
    int width = 0;
    int height = 0;
    int channels = 0;
    int webp = size >= 12 && !memcmp(input, "RIFF", 4) && !memcmp(input + 8, "WEBP", 4);
    int gif = size >= 6 && (!memcmp(input, "GIF87a", 6) || !memcmp(input, "GIF89a", 6));
    int valid = webp ? WebPGetInfo(input, size, &width, &height)
                     : stbi_info_from_memory(input, (int)size, &width, &height, &channels);
    if (!valid || !image_bounds(width, height, dimension, cap)) {
        free(input);
        return 1;
    }
    int expected_width = width;
    int expected_height = height;
    unsigned char *pixels =
        webp  ? WebPDecodeRGBA(input, size, &width, &height)
        : gif ? gif_still(input, size, &width, &height)
              : stbi_load_from_memory(input, (int)size, &width, &height, &channels, 4);
    free(input);
    int result = 1;
    if (pixels && width == expected_width && height == expected_height &&
        image_bounds(width, height, dimension, cap)) {
        uint32_t bytes = (uint32_t)((uint64_t)width * (uint64_t)height * 4);
        memcpy(header, "WNO1", 4);
        wn_image_put(header + 4, (uint32_t)width);
        wn_image_put(header + 8, (uint32_t)height);
        wn_image_put(header + 12, bytes);
        if (fwrite(header, 1, sizeof(header), stdout) == sizeof(header) &&
            fwrite(pixels, 1, bytes, stdout) == bytes && !fflush(stdout)) {
            result = 0;
        }
    }
    if (webp) {
        WebPFree(pixels);
    } else {
        /* gif_still allocates with malloc, which is STBI_FREE. */
        stbi_image_free(pixels);
    }
    return result;
}

#include "helper_main.h"
