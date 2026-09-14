// Audio stays in this killable helper. memfd: status/model/percent/command,
// followed by UTF-8 output only after successful recognition.
#define _GNU_SOURCE
#include <sherpa-onnx/c-api/c-api.h>
#include "stt_models.h"
#include <SDL3/SDL.h>
#include <curl/curl.h>
#include <glib.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include "speech_download.h"

enum { DOWNLOAD_ERROR = 1, RECOGNIZE_ERROR = 2, AUDIO_ERROR = 3 };
enum { SAMPLE_RATE = 16000, MAX_SAMPLES = SAMPLE_RATE * 30, HEADER_BYTES = 4, TEXT_LIMIT = 16384 };

static int set_status(char value) {
    return pwrite(STDOUT_FILENO, &value, 1, 0) == 1;
}

static const SherpaOnnxOfflineRecognizer *load_model(const char *dir) {
    char *paths[G_N_ELEMENTS(models)];
    for (size_t i = 0; i < G_N_ELEMENTS(paths); ++i) {
        paths[i] = g_build_filename(dir, models[i].name, NULL);
    }
    SherpaOnnxOfflineRecognizerConfig config = {0};
    config.feat_config.sample_rate = SAMPLE_RATE;
    config.feat_config.feature_dim = 80;
    config.model_config.whisper = (SherpaOnnxOfflineWhisperModelConfig){
        .encoder = paths[0], .decoder = paths[1], .task = "transcribe",
    };
    config.model_config.tokens = paths[2];
    config.model_config.num_threads = 2;
    config.model_config.provider = "cpu";
    config.decoding_method = "greedy_search";
    const SherpaOnnxOfflineRecognizer *model = SherpaOnnxCreateOfflineRecognizer(&config);
    for (size_t i = 0; i < G_N_ELEMENTS(paths); ++i) {
        g_free(paths[i]);
    }
    return model;
}

static int transcribe(const SherpaOnnxOfflineRecognizer *model, const float *samples, int count) {
    if (count <= 0 || count > MAX_SAMPLES) {
        return RECOGNIZE_ERROR;
    }
    const SherpaOnnxOfflineStream *stream = SherpaOnnxCreateOfflineStream(model);
    if (!stream) {
        return RECOGNIZE_ERROR;
    }
    SherpaOnnxAcceptWaveformOffline(stream, SAMPLE_RATE, samples, count);
    SherpaOnnxDecodeOfflineStream(model, stream);
    const SherpaOnnxOfflineRecognizerResult *result = SherpaOnnxGetOfflineStreamResult(stream);
    int code = RECOGNIZE_ERROR;
    if (result && result->text) {
        size_t n = strlen(result->text);
        if (n <= TEXT_LIMIT && g_utf8_validate(result->text, n, NULL) &&
            pwrite(STDOUT_FILENO, result->text, n, HEADER_BYTES) == (ssize_t)n &&
            ftruncate(STDOUT_FILENO, HEADER_BYTES + n) == 0 && set_status('T')) {
            code = 0;
        }
    }
    SherpaOnnxDestroyOfflineRecognizerResult(result);
    SherpaOnnxDestroyOfflineStream(stream);
    return code;
}

int main(int argc, char **argv) {
    if (argc != 3 || prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != atoi(argv[2])) {
        return RECOGNIZE_ERROR;
    }
    int diagnostics = open("/dev/null", O_WRONLY | O_CLOEXEC);
    if (diagnostics < 0 || dup2(diagnostics, STDERR_FILENO) < 0) {
        return RECOGNIZE_ERROR;
    }
    close(diagnostics);
    struct stat st;
    if (fstat(STDIN_FILENO, &st) || st.st_size != HEADER_BYTES) {
        return RECOGNIZE_ERROR;
    }
    umask(0077);
    if (curl_global_init(CURL_GLOBAL_DEFAULT)) {
        return DOWNLOAD_ERROR;
    }
    int code = DOWNLOAD_ERROR;
    if (g_mkdir_with_parents(argv[1], 0700)) {
        goto done;
    }
    int lock = open(argv[1], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (lock < 0) {
        goto done;
    }
    if (flock(lock, LOCK_EX)) {
        close(lock);
        goto done;
    }
    for (size_t i = 0; i < G_N_ELEMENTS(models); ++i) {
        if (!ensure_model(argv[1], &models[i])) {
            close(lock);
            goto done;
        }
    }
    close(lock);
    code = RECOGNIZE_ERROR;
    if (!set_status('G')) {
        goto done;
    }
    const SherpaOnnxOfflineRecognizer *model = load_model(argv[1]);
    if (!model) {
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
        int got = SDL_GetAudioStreamData(mic, samples + count, (MAX_SAMPLES - count) * sizeof(float));
        if (got < 0 || pread(STDIN_FILENO, &command, 1, 3) != 1) {
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
    return code;
}
