#ifndef WN_IMAGE_IPC_H
#define WN_IMAGE_IPC_H

#include <stdint.h>

#define WN_IMAGE_INPUT_MAX (128u * 1024u * 1024u)
#define WN_IMAGE_OUTPUT_MAX (256u * 1024u * 1024u)
#define WN_IMAGE_DIM_MAX 32768u
#define WN_IMAGE_MEMORY_MAX (1024u * 1024u * 1024u)
#define WN_IMAGE_SECONDS 10u
#define WN_IMAGE_HEADER 16u

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

/* Returns malloc-owned RGBA; on failure returns NULL and zeros both dimensions. */
unsigned char *wn_image_decode(const char *helper, const unsigned char *data, int size,
                               int max_dimension, unsigned int max_bytes, int *width, int *height);

#endif
