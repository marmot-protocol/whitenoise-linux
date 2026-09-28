/* Untrusted image headers and compressed pixels are only inspected here. */
#include "image_ipc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <webp/decode.h>
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_MAX_DIMENSIONS ((int)WN_IMAGE_DIM_MAX)
#include <stb_image.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#else
#include <sys/resource.h>
#include <unistd.h>
#endif
#ifdef __APPLE__
#include <mach/mach.h>
#endif

static int image_restrict(void) {
#ifdef _WIN32
    HANDLE job = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_PROCESS_TIME;
    limits.ProcessMemoryLimit = WN_IMAGE_MEMORY_MAX;
    limits.BasicLimitInformation.PerProcessUserTimeLimit.QuadPart = 5 * 10000000LL;
    if (!job ||
        !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) ||
        !AssignProcessToJobObject(job, GetCurrentProcess()) ||
        _setmode(_fileno(stdin), _O_BINARY) < 0 || _setmode(_fileno(stdout), _O_BINARY) < 0) {
        return 0;
    }
    /* Keep the job alive until process exit. */
#else
    struct rlimit memory = {WN_IMAGE_MEMORY_MAX, WN_IMAGE_MEMORY_MAX};
    struct rlimit cpu = {5, 5};
    struct rlimit core = {0, 0};
#ifdef __APPLE__
    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) !=
            KERN_SUCCESS ||
        info.virtual_size > RLIM_INFINITY - WN_IMAGE_MEMORY_MAX) {
        return 0;
    }
    memory.rlim_cur += info.virtual_size;
    memory.rlim_max = memory.rlim_cur;
#endif
#ifdef RLIMIT_AS
    if (setrlimit(RLIMIT_AS, &memory)) {
        return 0;
    }
#else
    if (setrlimit(RLIMIT_DATA, &memory)) {
        return 0;
    }
#endif
    if (setrlimit(RLIMIT_CPU, &cpu) || setrlimit(RLIMIT_CORE, &core)) {
        return 0;
    }
#endif
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
    int valid = webp ? WebPGetInfo(input, size, &width, &height)
                     : stbi_info_from_memory(input, (int)size, &width, &height, &channels);
    if (!valid || !image_bounds(width, height, dimension, cap)) {
        free(input);
        return 1;
    }
    int expected_width = width;
    int expected_height = height;
    unsigned char *pixels =
        webp ? WebPDecodeRGBA(input, size, &width, &height)
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
        stbi_image_free(pixels);
    }
    return result;
}

#include "helper_main.h"
