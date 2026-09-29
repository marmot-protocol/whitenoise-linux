#ifndef WN_DECODER_IPC_H
#define WN_DECODER_IPC_H

#include <stdint.h>

#define WN_IMAGE_INPUT_MAX (128u * 1024u * 1024u)
#define WN_IMAGE_OUTPUT_MAX (256u * 1024u * 1024u)
#define WN_IMAGE_DIM_MAX 32768u
#define WN_IMAGE_MEMORY_MAX (1024u * 1024u * 1024u)
#define WN_IMAGE_SECONDS 10u
#define WN_IMAGE_HEADER 16u
#define WN_ARCHIVE_INPUT_MAX WN_IMAGE_INPUT_MAX
#define WN_ARCHIVE_ENTRY_MAX (64u * 1024u * 1024u)
#define WN_ARCHIVE_LIST_MAX (8u * 1024u * 1024u)
#define WN_ARCHIVE_COUNT_MAX 2000u
#define WN_ARCHIVE_SCAN_MAX 65536u
#define WN_ARCHIVE_NAME_MAX 4096u
#define WN_PDF_INPUT_MAX WN_IMAGE_INPUT_MAX
#define WN_PDF_OUTPUT_MAX (64u * 1024u * 1024u)
#define WN_PDF_DIM_MAX 32768u
#define WN_PDF_PAGES_MAX 10000u
#define WN_MODEL_INPUT_MAX WN_IMAGE_INPUT_MAX
#define WN_MODEL_OUTPUT_MAX (512u * 1024u * 1024u)
#define WN_MATH_INPUT_MAX 4096u
#define WN_MATH_DIM_MAX 4096u
#define WN_MATH_OUTPUT_MAX (8u * 1024u * 1024u)
#define WN_MATH_REQUEST_HEADER 24u

typedef enum {
    WN_MESH_STL = 1,
    WN_MESH_OBJ = 2,
    WN_MESH_GLB = 3,
    WN_MESH_GCODE = 4,
} WnMeshFormat;
typedef enum { WN_MODEL_OPEN = 0, WN_MODEL_POSE = 1 } WnModelOp;

/* Wire integers are little endian; both streams must end at their declared size. */
static inline uint32_t wn_image_u32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static inline void wn_image_put(unsigned char *p, uint32_t n) {
    p[0] = (unsigned char)n;
    p[1] = (unsigned char)(n >> 8);
    p[2] = (unsigned char)(n >> 16);
    p[3] = (unsigned char)(n >> 24);
}

#ifdef __cplusplus
extern "C" {
#endif

/* Returns malloc-owned RGBA; on failure returns NULL and zeros both dimensions. */
unsigned char *wn_image_decode(const char *helper, const unsigned char *data, int size,
                               int max_dimension, unsigned int max_bytes, int *width, int *height);

/* MAI1,size,font-size bits,ARGB,side,bytes + source + EOF -> MAO1,width,height,bytes
 * + straight RGBA + EOF. Source must not contain NUL. Failure zeros dimensions. */
unsigned char *wn_math_render(const char *helper, const unsigned char *data, int size,
                              float font_size, unsigned int argb, unsigned int max_side,
                              unsigned int max_bytes, int *width, int *height);

typedef enum { WN_ARCHIVE_LIST = 0, WN_ARCHIVE_ENTRY = 1 } WnArchiveOp;
/* Successful empty payloads still return malloc-owned memory. */
unsigned char *wn_archive_read(const char *helper, const unsigned char *data, int size,
                               WnArchiveOp op, unsigned int index, unsigned int *count,
                               unsigned int *length);
/* Returns only RGBA, consuming the page-count prefix separately. Outputs zero on failure. */
unsigned char *wn_pdf_render(const char *helper, const char *font_dir, const unsigned char *data,
                             int size, unsigned int page, unsigned int width, unsigned int height,
                             unsigned int *pages, unsigned int *out_width,
                             unsigned int *out_height);

/* MDI1,size,format,0 + source + EOF -> MDO1,1,0,size + opaque payload + EOF. */
unsigned char *wn_mesh_decode(const char *helper, const unsigned char *data, int size,
                              unsigned int format, unsigned int *length);

typedef struct WnModelSession WnModelSession;
/* A session owns one isolated helper; calls on the same session must be serialized. */
WnModelSession *wn_model_start(const char *helper);
/* FBI1,operation,size,sequence + source -> FBO1,operation,sequence,size + opaque payload.
 * Sequence starts at one and increases without wrapping, rejecting stale replies.
 * NULL output allocates a malloc-owned reply; otherwise the returned pointer is output.
 * Failure returns NULL, zeros length and invalidates the session until close.
 * Scratch may contain partial bytes on failure: consumers must publish only on success. */
unsigned char *wn_model_exchange(WnModelSession *session, unsigned int operation,
                                 const unsigned char *data, unsigned int size,
                                 unsigned char *output, unsigned int capacity,
                                 unsigned int *length);
void wn_model_close(WnModelSession *session);

#ifdef __cplusplus
}
#endif

#endif
