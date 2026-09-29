#include <assert.h>
#include <curl/curl.h>
#include <stdint.h>
#include <string.h>

static const unsigned char *input;
static size_t remaining;

/* Feed wire bytes through the production frame parser without a network dependency. */
static CURLcode frame_recv(CURL *curl, void *buffer, size_t size, size_t *received) {
    (void)curl;
    *received = size < remaining ? size : remaining;
    memcpy(buffer, input, *received);
    input += *received;
    remaining -= *received;
    return CURLE_OK;
}

#define curl_easy_recv frame_recv
#include "../app/ws_shim.c"
#undef curl_easy_recv

static void check_frame(const unsigned char *wire, size_t size, size_t cap, long expected,
                        const char *text) {
    unsigned char output[256];
    memset(output, 0xa5, sizeof output);
    assert(cap <= sizeof output);
    input = wire;
    remaining = size;
    long result = recv_message(NULL, output, cap, now_ms() + 1000);
    assert(result == expected);
    if (expected > 0) {
        assert(memcmp(output, text, (size_t)expected) == 0);
    }
    for (size_t i = cap; i < sizeof output; ++i) {
        assert(output[i] == 0xa5);
    }
}

int main(void) {
    const unsigned char fragmented[] = {0x01, 2, 'a', 'b', 0x80, 2, 'c', 'd'};
    check_frame(fragmented, sizeof fragmented, 4, 4, "abcd");
    check_frame(fragmented, sizeof fragmented, 3, 0, NULL);
    check_frame(fragmented, sizeof fragmented, 0, 0, NULL);

    const unsigned char extended[] = {0x81, 126, 0, 4, 'a', 'b', 'c', 'd'};
    check_frame(extended, sizeof extended, 4, 4, "abcd");
    check_frame(extended, sizeof extended, 3, 0, NULL);

    const unsigned char wide[] = {0x81, 127, 0, 0, 0, 0, 0, 0, 0, 4, 'a', 'b', 'c', 'd'};
    check_frame(wide, sizeof wide, 4, 4, "abcd");
    check_frame(wide, sizeof wide, 3, 0, NULL);

    /* A preceding fragment makes len + UINT64_MAX wrap below the output cap. */
    unsigned char overflow[3 + 10 + 128] = {0x01, 1, 'a', 0x80, 127};
    memset(overflow + 5, 0xff, 8);
    memset(overflow + 13, 'x', 128);
    check_frame(overflow, sizeof overflow, 32, -1, NULL);
    puts("websocket frames: exact bounds, fragmentation and length overflow passed");
    return 0;
}
