// Audio stays in this killable helper. Shared memory: status/model/percent/command,
// P/T reuse model/percent as a little-endian committed UTF-8 byte count.
#define _GNU_SOURCE
#include <sherpa-onnx/c-api/c-api.h>
#include "stt_models.h"
#include <SDL3/SDL.h>
#include <curl/curl.h>
#include <glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "helper_ipc.h"

static WnIpc *speech_ipc;
#include "speech_download.h"

enum { DOWNLOAD_ERROR = 1, RECOGNIZE_ERROR = 2, AUDIO_ERROR = 3, LENGTH_ERROR = 4 };
enum {
    SAMPLE_RATE = 16000,
    MAX_SAMPLES = SAMPLE_RATE * 30,
    CHUNK_SAMPLES = SAMPLE_RATE * 29,
    MAX_AUDIO_SAMPLES = SAMPLE_RATE * 600,
    HEADER_BYTES = 4,
    TEXT_LIMIT = 16384
};

#include "speech_decode.h"

static int set_status(char value) {
    return wn_ipc_write(speech_ipc, &value, 1, 0) == 1;
}

// Zero selects up to eight available CPUs; the benchmark can override it.
static int recognition_threads;

static const SherpaOnnxOfflineRecognizer *load_model(const char *dir) {
    char *paths[G_N_ELEMENTS(models)];
    for (size_t i = 0; i < stt_model->file_count; ++i) {
        paths[i] = g_build_filename(dir, models[i].name, NULL);
    }
    SherpaOnnxOfflineRecognizerConfig config = {0};
    config.feat_config.sample_rate = SAMPLE_RATE;
    config.feat_config.feature_dim = stt_model->feature_dim;
    switch (stt_model->kind) {
    case WHISPER:
        config.model_config.whisper = (SherpaOnnxOfflineWhisperModelConfig){
            .encoder = paths[0],
            .decoder = paths[1],
            .task = "transcribe",
        };
        break;
    case PARAKEET:
        config.model_config.transducer = (SherpaOnnxOfflineTransducerModelConfig){
            .encoder = paths[0],
            .decoder = paths[1],
            .joiner = paths[2],
        };
        config.model_config.model_type = "nemo_transducer";
        break;
    case SENSEVOICE:
        config.model_config.sense_voice = (SherpaOnnxOfflineSenseVoiceModelConfig){
            .model = paths[0],
            .language = "auto",
            .use_itn = 1,
        };
        break;
    }
    config.model_config.tokens = paths[stt_model->file_count - 1];
    config.model_config.num_threads =
        recognition_threads > 0 ? recognition_threads : (int)MAX(1, MIN(8, g_get_num_processors()));
    config.model_config.provider = "cpu";
    config.decoding_method = "greedy_search";
    const SherpaOnnxOfflineRecognizer *model = SherpaOnnxCreateOfflineRecognizer(&config);
    for (size_t i = 0; i < stt_model->file_count; ++i) {
        g_free(paths[i]);
    }
    return model;
}

static int transcribe(const SherpaOnnxOfflineRecognizer *model, const float *samples, int count) {
    if (count <= 0 || count > MAX_AUDIO_SAMPLES) {
        return RECOGNIZE_ERROR;
    }
    GString *text = g_string_new(NULL);
    int code = RECOGNIZE_ERROR;
    // The runtime reserves 0.5 seconds for padding. Stay below 29.5 seconds.
    // ponytail: even windows can split words; use VAD boundaries if needed.
    int chunks = (count + CHUNK_SAMPLES - 1) / CHUNK_SAMPLES;
    int window = (count + chunks - 1) / chunks;
    for (int offset = 0; offset < count; offset += window) {
        const SherpaOnnxOfflineStream *stream = SherpaOnnxCreateOfflineStream(model);
        if (!stream) {
            goto done;
        }
        int n = MIN(window, count - offset);
        SherpaOnnxAcceptWaveformOffline(stream, SAMPLE_RATE, samples + offset, n);
        SherpaOnnxDecodeOfflineStream(model, stream);
        const SherpaOnnxOfflineRecognizerResult *result = SherpaOnnxGetOfflineStreamResult(stream);
        size_t previous = text->len;
        int valid = result && result->text && g_utf8_validate(result->text, -1, NULL) &&
                    text->len + strlen(result->text) + 1 <= TEXT_LIMIT;
        if (valid) {
            if (text->len) {
                g_string_append_c(text, ' ');
            }
            g_string_append(text, result->text);
        }
        SherpaOnnxDestroyOfflineRecognizerResult(result);
        SherpaOnnxDestroyOfflineStream(stream);
        if (!valid) {
            goto done;
        }
        // Append first, then publish the complete segment. Readers ignore uncommitted bytes.
        unsigned char update[] = {'P', text->len & 255, text->len >> 8};
        if (wn_ipc_write(speech_ipc, text->str + previous, text->len - previous,
                         HEADER_BYTES + previous) != (intptr_t)(text->len - previous) ||
            wn_ipc_write(speech_ipc, update, sizeof(update), 0) != sizeof(update)) {
            goto done;
        }
    }
    if (set_status('T')) {
        code = 0;
    }
done:
    g_string_free(text, TRUE);
    return code;
}

static int select_model(const char *name) {
    for (size_t i = 0; i < G_N_ELEMENTS(stt_models); ++i) {
        if (!strcmp(name, stt_models[i].name)) {
            stt_model = &stt_models[i];
            return 1;
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 8 || !select_model(argv[4]) ||
        (strcmp(argv[3], "dictate") && strcmp(argv[3], "audio") && strcmp(argv[3], "download")) ||
        !wn_helper_guard(strtoul(argv[2], NULL, 10)) || !wn_helper_silence()) {
        return RECOGNIZE_ERROR;
    }
    speech_ipc = wn_ipc_open(argv[5], HEADER_BYTES + TEXT_LIMIT);
    if (!speech_ipc)
        return RECOGNIZE_ERROR;
    int audio = !strcmp(argv[3], "audio");
    size_t audio_size = (size_t)strtoull(argv[7], NULL, 10);
    WnIpc *input = NULL;
    if (audio && (!audio_size || audio_size > 100 * 1024 * 1024 ||
                  !(input = wn_ipc_open(argv[6], audio_size))))
        return RECOGNIZE_ERROR;
    if (curl_global_init(CURL_GLOBAL_DEFAULT)) {
        return DOWNLOAD_ERROR;
    }
    int code = DOWNLOAD_ERROR;
    if (g_mkdir_with_parents(argv[1], 0700)) {
        goto done;
    }
    void *lock = wn_model_lock(argv[1]);
    if (!lock)
        goto done;
    for (size_t i = 0; i < stt_model->file_count; ++i) {
        if (!ensure_model(argv[1], &models[i])) {
            wn_model_unlock(lock);
            goto done;
        }
    }
    wn_model_unlock(lock);
    if (!strcmp(argv[3], "download")) {
        code = set_status('T') ? 0 : DOWNLOAD_ERROR;
        goto done;
    }
    code = RECOGNIZE_ERROR;
    if (!set_status('G')) {
        goto done;
    }
    const SherpaOnnxOfflineRecognizer *model = load_model(argv[1]);
    if (!model) {
        goto done;
    }
    if (audio) {
        float *samples = NULL;
        int count = 0;
        code = AUDIO_ERROR;
        if (set_status('C'))
            code = decode_audio(input, &samples, &count);
        if (!code)
            code = transcribe(model, samples, count);
        g_free(samples);
        SherpaOnnxDestroyOfflineRecognizer(model);
        goto done;
    }
    code = AUDIO_ERROR;
    SDL_AudioSpec spec = {.format = SDL_AUDIO_F32, .channels = 1, .freq = SAMPLE_RATE};
    SDL_AudioStream *mic = NULL;
    float *samples = g_new(float, MAX_SAMPLES);
    if (!SDL_InitSubSystem(SDL_INIT_AUDIO) ||
        !(mic = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_RECORDING, &spec, NULL, NULL)) ||
        !SDL_ResumeAudioStreamDevice(mic) || !set_status('R')) {
        goto free_audio;
    }
    // Whisper's context is 30 seconds; finish automatically at that limit.
    int count = 0;
    Uint64 started = SDL_GetTicks();
    while (count < MAX_SAMPLES) {
        char command;
        int got =
            SDL_GetAudioStreamData(mic, samples + count, (MAX_SAMPLES - count) * sizeof(float));
        if (got < 0 || wn_ipc_read(speech_ipc, &command, 1, 3) != 1) {
            goto free_audio;
        }
        count += got / sizeof(float);
        if (command == 'S' || SDL_GetTicks() - started >= 30000) {
            break;
        }
        SDL_Delay(20);
    }
    SDL_DestroyAudioStream(mic);
    mic = NULL;
    code = RECOGNIZE_ERROR;
    if (set_status('C')) {
        code = transcribe(model, samples, count);
    }
free_audio:
    SDL_DestroyAudioStream(mic);
    SDL_Quit();
    g_free(samples);
    SherpaOnnxDestroyOfflineRecognizer(model);
done:
    curl_global_cleanup();
    wn_ipc_close(input);
    wn_ipc_close(speech_ipc);
    return code;
}

#include "helper_main.h"
