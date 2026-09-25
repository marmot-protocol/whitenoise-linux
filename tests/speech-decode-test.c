#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <glib.h>
#include "../app/helper_ipc.h"

enum { SAMPLE_RATE = 16000, MAX_AUDIO_SAMPLES = 16000 * 600, AUDIO_ERROR = 3, LENGTH_ERROR = 4 };
#include "../app/speech_decode.h"

static void write_le(unsigned char *out, uint32_t value, int bytes) {
    for (int i = 0; i < bytes; ++i) {
        out[i] = (unsigned char)(value >> (8 * i));
    }
}

static WnIpc *wave_input(int rate, int frames) {
    size_t bytes = (size_t)frames * 2;
    WnIpc *input = wn_ipc_create(44 + bytes);
    assert(input);
    unsigned char *data = wn_ipc_data(input);
    memcpy(data, "RIFF", 4);
    write_le(data + 4, (uint32_t)bytes + 36, 4);
    memcpy(data + 8, "WAVEfmt ", 8);
    write_le(data + 16, 16, 4);
    write_le(data + 20, 1, 2);
    write_le(data + 22, 1, 2);
    write_le(data + 24, (uint32_t)rate, 4);
    write_le(data + 28, (uint32_t)rate * 2, 4);
    write_le(data + 32, 2, 2);
    write_le(data + 34, 16, 2);
    memcpy(data + 36, "data", 4);
    write_le(data + 40, (uint32_t)bytes, 4);
    for (int i = 0; i < frames; ++i) {
        write_le(data + 44 + (size_t)i * 2, 8192, 2);
    }
    return input;
}

int main(void) {
    float *samples = NULL;
    int count = 0;
    WnIpc *input = wave_input(48000, 4800);
    assert(decode_audio(input, &samples, &count) == 0);
    assert(count == 1600);
    for (int i = 32; i < count - 32; ++i) {
        assert(fabsf(samples[i] - 0.25f) < 0.0001f);
    }
    g_free(samples);
    wn_ipc_close(input);

    input = wn_ipc_create(32);
    assert(input);
    memset(wn_ipc_data(input), 0xa5, 32);
    samples = NULL;
    count = 0;
    assert(decode_audio(input, &samples, &count) == AUDIO_ERROR);
    assert(samples == NULL && count == 0);
    wn_ipc_close(input);

    input = wave_input(SAMPLE_RATE, MAX_AUDIO_SAMPLES);
    assert(decode_audio(input, &samples, &count) == 0);
    assert(count == MAX_AUDIO_SAMPLES);
    g_free(samples);
    wn_ipc_close(input);

    input = wave_input(SAMPLE_RATE, MAX_AUDIO_SAMPLES + 1);
    samples = NULL;
    count = 0;
    assert(decode_audio(input, &samples, &count) == LENGTH_ERROR);
    assert(samples == NULL && count == 0);
    wn_ipc_close(input);
    return 0;
}
