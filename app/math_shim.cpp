// One-shot math helper: untrusted TeX to straight-alpha RGBA pixels.
// MicroTeX's process-wide macros, colors and switches die with the process;
// no parser state or parser code is shared with the UI.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef NOGDI
#define NOGDI
#endif
#include "decoder_limits.h"
#include <cairo.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "microtex.h"
#include "utils/utils.h"
#include "wrapper/cwrapper.h"

namespace {

// Text layouts are only requested for text in a non-math main font, and
// none is loaded: \text{} renders from the math font. Any request still
// gets a valid empty box. Path caching is off, so every glyph path is
// emitted in full.
unsigned int no_layout(const char *, FontDesc *) {
    return 0;
}
void no_bounds(unsigned int, TextLayoutBounds *b) {
    microtex_setTextLayoutBounds(b, 0, 0, 0);
}
void no_release(unsigned int) {
}
bool no_cached_path(unsigned int) {
    return false;
}

// Bounds-checked cursor over the command stream (native endian, which
// is what the engine writes).
struct Reader {
    const uint8_t *at;
    const uint8_t *end;
    bool ok = true;

    template <typename T> T take() {
        T value{};
        if (end - at < static_cast<long>(sizeof(T))) {
            ok = false;
            return value;
        }
        std::memcpy(&value, at, sizeof(T));
        at += sizeof(T);
        return value;
    }

    void skip_string() {
        const void *nul = std::memchr(at, 0, end - at);
        if (nul == nullptr) {
            ok = false;
            return;
        }
        at = static_cast<const uint8_t *>(nul) + 1;
    }
};

void set_argb(cairo_t *cr, uint32_t argb) {
    cairo_set_source_rgba(cr, ((argb >> 16) & 0xff) / 255.0, ((argb >> 8) & 0xff) / 255.0,
                          (argb & 0xff) / 255.0, (argb >> 24) / 255.0);
}

void round_rect(cairo_t *cr, float x, float y, float w, float h, float rx, float ry) {
    // One radius for both axes; MicroTeX only emits these for \fbox-style
    // frames, where rx == ry.
    double r = rx < ry ? rx : ry;
    double d = 3.14159265358979 / 180;
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r, y + r, r, -90 * d, 0);
    cairo_arc(cr, x + w - r, y + h - r, r, 0, 90 * d);
    cairo_arc(cr, x + r, y + h - r, r, 90 * d, 180 * d);
    cairo_arc(cr, x + r, y + r, r, 180 * d, 270 * d);
    cairo_close_path(cr);
}

// Default-colored ink on an explicit background: \fcolorbox{noir}{gris}{x}
// fills a light box, then draws x in the default color, which on a dark
// theme is light text. Default ink whose center lands on a recorded
// background it barely contrasts with is drawn black or white instead.
struct Ink {
    uint32_t fg;      // the caller's default color
    uint32_t current; // the color last set by the stream
    struct Box {
        double x0, y0, x1, y1; // device space
        uint32_t argb;
    };
    std::vector<Box> boxes; // filled rectangles in a non-default color
};

enum class Paint { Fill, Stroke };
enum class Shape { Path, Box };

double luma(uint32_t argb) {
    return (0.2126 * ((argb >> 16) & 0xff) + 0.7152 * ((argb >> 8) & 0xff) +
            0.0722 * (argb & 0xff)) /
           255;
}

// The current path's extents in device space.
void device_extents(cairo_t *cr, Paint mode, double *x0, double *y0, double *x1, double *y1) {
    mode == Paint::Fill ? cairo_fill_extents(cr, x0, y0, x1, y1)
                        : cairo_stroke_extents(cr, x0, y0, x1, y1);
    cairo_user_to_device(cr, x0, y0);
    cairo_user_to_device(cr, x1, y1);
}

// Paint the current path. A filled Box not in the default color is also
// recorded as a background.
void paint(cairo_t *cr, Ink &ink, Paint mode, Shape shape) {
    double x0, y0, x1, y1;
    device_extents(cr, mode, &x0, &y0, &x1, &y1);
    if (ink.current != ink.fg) {
        if (shape == Shape::Box && mode == Paint::Fill) {
            ink.boxes.push_back({std::min(x0, x1), std::min(y0, y1), std::max(x0, x1),
                                 std::max(y0, y1), ink.current});
        }
        mode == Paint::Fill ? cairo_fill(cr) : cairo_stroke(cr);
        return;
    }

    double cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
    const Ink::Box *under = nullptr;
    for (const Ink::Box &box : ink.boxes) {
        if (cx >= box.x0 && cx <= box.x1 && cy >= box.y0 && cy <= box.y1) {
            under = &box; // last painted wins
        }
    }
    bool swap = under != nullptr && std::abs(luma(ink.fg) - luma(under->argb)) < 0.4;
    if (swap) {
        set_argb(cr, luma(under->argb) > 0.5 ? 0xff000000 : 0xffffffff);
    }
    mode == Paint::Fill ? cairo_fill(cr) : cairo_stroke(cr);
    if (swap) {
        set_argb(cr, ink.fg);
    }
}

// Command ids and argument layouts are documented beside
// microtex_getDrawingData in lib/wrapper/cwrapper.h.
bool replay(cairo_t *cr, const uint8_t *data, uint32_t fg) {
    Ink ink{fg, fg, {}};
    uint32_t total;
    std::memcpy(&total, data, 4);
    Reader in{data + 4, data + total};
    cairo_matrix_t origin;
    cairo_get_matrix(cr, &origin);
    while (in.ok && in.at < in.end) {
        uint8_t cmd = in.take<uint8_t>();
        switch (cmd) {
        case 0:
            ink.current = in.take<uint32_t>();
            set_argb(cr, ink.current);
            break;
        case 1: {
            float width = in.take<float>();
            float miter = in.take<float>();
            uint32_t cap = in.take<uint32_t>();
            uint32_t join = in.take<uint32_t>();
            static const cairo_line_join_t joins[] = {CAIRO_LINE_JOIN_BEVEL, CAIRO_LINE_JOIN_MITER,
                                                      CAIRO_LINE_JOIN_ROUND};
            cairo_set_line_width(cr, width);
            cairo_set_miter_limit(cr, miter);
            cairo_set_line_cap(cr,
                               cap <= 2 ? static_cast<cairo_line_cap_t>(cap) : CAIRO_LINE_CAP_BUTT);
            cairo_set_line_join(cr, join <= 2 ? joins[join] : CAIRO_LINE_JOIN_MITER);
            break;
        }
        case 2: {
            static const double dash[] = {5, 5};
            cairo_set_dash(cr, dash, in.take<uint8_t>() ? 2 : 0, 0);
            break;
        }
        case 3:
            in.skip_string();
            break; // font family: typeface mode only
        case 4:
            in.take<float>();
            break; // font size: typeface mode only
        case 5: {
            float dx = in.take<float>();
            cairo_translate(cr, dx, in.take<float>());
            break;
        }
        case 6: {
            float sx = in.take<float>();
            cairo_scale(cr, sx, in.take<float>());
            break;
        }
        case 7: {
            float radian = in.take<float>();
            float px = in.take<float>();
            float py = in.take<float>();
            cairo_translate(cr, px, py);
            cairo_rotate(cr, radian);
            cairo_translate(cr, -px, -py);
            break;
        }
        case 8:
            cairo_set_matrix(cr, &origin);
            break;
        case 9:
            in.take<uint16_t>();
            in.take<float>();
            in.take<float>();
            break; // typeface glyph
        case 10:
            in.take<int32_t>();
            cairo_new_path(cr);
            break;
        case 11: {
            float x = in.take<float>();
            cairo_move_to(cr, x, in.take<float>());
            break;
        }
        case 12: {
            float x = in.take<float>();
            cairo_line_to(cr, x, in.take<float>());
            break;
        }
        case 13: {
            float p[6];
            for (float &v : p)
                v = in.take<float>();
            cairo_curve_to(cr, p[0], p[1], p[2], p[3], p[4], p[5]);
            break;
        }
        case 14: {
            // Quadratic to cubic: control points 2/3 of the way to q.
            float qx = in.take<float>(), qy = in.take<float>();
            float x = in.take<float>(), y = in.take<float>();
            double x0 = 0, y0 = 0;
            cairo_get_current_point(cr, &x0, &y0);
            cairo_curve_to(cr, x0 + 2.0 / 3 * (qx - x0), y0 + 2.0 / 3 * (qy - y0),
                           x + 2.0 / 3 * (qx - x), y + 2.0 / 3 * (qy - y), x, y);
            break;
        }
        case 15:
            cairo_close_path(cr);
            break;
        case 16:
            in.take<int32_t>();
            paint(cr, ink, Paint::Fill, Shape::Path);
            break;
        case 17: {
            float p[4];
            for (float &v : p)
                v = in.take<float>();
            cairo_new_path(cr);
            cairo_move_to(cr, p[0], p[1]);
            cairo_line_to(cr, p[2], p[3]);
            paint(cr, ink, Paint::Stroke, Shape::Path);
            break;
        }
        case 18:
        case 19: {
            float p[4];
            for (float &v : p)
                v = in.take<float>();
            cairo_new_path(cr);
            cairo_rectangle(cr, p[0], p[1], p[2], p[3]);
            paint(cr, ink, cmd == 19 ? Paint::Fill : Paint::Stroke, Shape::Box);
            break;
        }
        case 20:
        case 21: {
            float p[6];
            for (float &v : p)
                v = in.take<float>();
            cairo_new_path(cr);
            round_rect(cr, p[0], p[1], p[2], p[3], p[4], p[5]);
            paint(cr, ink, cmd == 21 ? Paint::Fill : Paint::Stroke, Shape::Box);
            break;
        }
        case 22:
            in.take<uint32_t>();
            in.take<float>();
            in.take<float>();
            break; // no layouts exist
        default:
            return false;
        }
    }
    return in.ok;
}

// Load the embedded .clm2 font after confinement. Its bytes outlive the
// single render; MicroTeX and its process-wide tables live until exit.
bool init_font(const uint8_t *font, unsigned long len) {
    try {
        microtex_registerCallbacks(no_layout, no_bounds, no_release, no_cached_path);
        FontMetaPtr meta = microtex_init(len, font);
        microtex::MicroTeX::setDefaultMathFont(microtex_getFontName(meta));
        microtex_releaseFontMeta(meta);
        microtex_setRenderGlyphUsePath(true);
        return microtex_isInited();
    } catch (...) {
        return false;
    }
}

// Typeset one display-math expression, bounded before drawing allocation.
uint8_t *render_math(const char *tex, float size, uint32_t argb, uint32_t max_side,
                     uint32_t max_bytes, int *w, int *h) {
    RenderPtr render = nullptr;
    DrawingData data = nullptr;
    cairo_surface_t *surface = nullptr;
    uint8_t *out = nullptr;
    try {
        // $$…$$ is display math: big operators with limits above and below,
        // full-size fractions (TexStyle::display is 0).
        render = microtex_parseRender(tex, 0, size, size / 3, argb, false, true, 0);
        // Antialiasing and italic overhang spill a little past the box.
        int pad = static_cast<int>(size / 8) + 1;
        int64_t width = static_cast<int64_t>(microtex_getRenderWidth(render)) + 2 * pad;
        int64_t height = static_cast<int64_t>(microtex_getRenderHeight(render)) + 2 * pad;
        if (width > 2 * pad && height > 2 * pad && width <= max_side && height <= max_side &&
            static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * 4 <= max_bytes) {
            *w = static_cast<int>(width);
            *h = static_cast<int>(height);
            data = microtex_getDrawingData(render, pad, pad);
        }
    } catch (...) {
        data = nullptr;
    }
    try {
        if (render != nullptr) {
            microtex_deleteRender(render);
        }
    } catch (...) {
    }
    if (data == nullptr) {
        return nullptr;
    }

    surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, *w, *h);
    cairo_t *cr = cairo_create(surface);
    set_argb(cr, argb);
    bool drawn = replay(cr, static_cast<const uint8_t *>(data), argb);
    cairo_destroy(cr);
    microtex_freeDrawingData(data);
    cairo_surface_flush(surface);

    if (drawn && cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS) {
        const uint8_t *src = cairo_image_surface_get_data(surface);
        int stride = cairo_image_surface_get_stride(surface);
        out = static_cast<uint8_t *>(std::malloc(static_cast<size_t>(*w) * *h * 4));
        for (int y = 0; out != nullptr && y < *h; y++) {
            for (int x = 0; x < *w; x++) {
                // Native-endian premultiplied ARGB32: B,G,R,A in memory.
                const uint8_t *px = src + y * stride + x * 4;
                uint8_t *dst = out + (static_cast<size_t>(y) * *w + x) * 4;
                uint8_t a = px[3];
                dst[0] = a ? static_cast<uint8_t>(px[2] * 255 / a) : 0;
                dst[1] = a ? static_cast<uint8_t>(px[1] * 255 / a) : 0;
                dst[2] = a ? static_cast<uint8_t>(px[0] * 255 / a) : 0;
                dst[3] = a;
            }
        }
    }
    cairo_surface_destroy(surface);
    return out;
}

int run(const uint8_t *font, unsigned long length) {
    if (!wn_decoder_limits(WN_DECODER_ONESHOT)) {
        return 1;
    }
#ifdef __OpenBSD__
    // Character classification lazily opens OpenBSD's UTF-8 locale.
    // Initialize the fixed locale before dropping every filesystem path.
    (void)microtex::defaultLocale();
    if (unveil(nullptr, nullptr) || pledge("stdio", nullptr)) {
        return 1;
    }
#endif
    // No input is read until resource and filesystem confinement are locked.
    uint8_t header[24];
    if (fread(header, 1, sizeof(header), stdin) != sizeof(header) ||
        std::memcmp(header, "MAI1", 4)) {
        return 1;
    }
    uint32_t size = wn_image_u32(header + 4);
    uint32_t font_bits = wn_image_u32(header + 8);
    float font_size;
    static_assert(sizeof(font_size) == sizeof(font_bits), "32-bit wire float required");
    std::memcpy(&font_size, &font_bits, sizeof(font_size));
    uint32_t argb = wn_image_u32(header + 12);
    uint32_t max_side = wn_image_u32(header + 16);
    uint32_t max_bytes = wn_image_u32(header + 20);
    if (!size || size > WN_MATH_INPUT_MAX || !std::isfinite(font_size) || font_size <= 0 ||
        font_size > WN_MATH_DIM_MAX || !max_side || max_side > WN_MATH_DIM_MAX || !max_bytes ||
        max_bytes > WN_MATH_OUTPUT_MAX) {
        return 1;
    }
    char source[WN_MATH_INPUT_MAX + 1];
    if (fread(source, 1, size, stdin) != size || fgetc(stdin) != EOF || ferror(stdin) ||
        std::memchr(source, '\0', size)) {
        return 1;
    }
    source[size] = '\0';
    if (!font || !length || !init_font(font, length)) {
        return 1;
    }
    int width = 0, height = 0;
    uint8_t *pixels = render_math(source, font_size, argb, max_side, max_bytes, &width, &height);
    if (!pixels) {
        return 1;
    }
    uint32_t bytes = static_cast<uint32_t>(static_cast<uint64_t>(width) * height * 4);
    uint8_t reply[16];
    std::memcpy(reply, "MAO1", 4);
    wn_image_put(reply + 4, static_cast<uint32_t>(width));
    wn_image_put(reply + 8, static_cast<uint32_t>(height));
    wn_image_put(reply + 12, bytes);
    bool sent = fwrite(reply, 1, sizeof(reply), stdout) == sizeof(reply) &&
                fwrite(pixels, 1, bytes, stdout) == bytes && !fflush(stdout);
    std::free(pixels);
    return sent ? 0 : 1;
}

} // namespace

extern "C" int wn_math_run(const unsigned char *font, unsigned long length) {
    try {
        return run(font, length);
    } catch (...) {
        return 1;
    }
}
