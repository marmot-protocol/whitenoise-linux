// Speech runs in a helper so cancellation stops inference and audio immediately.
// The app can kill this helper without leaving inference or audio running.
// memfd header: status, model index, percent; message text starts at byte 3.
#define _GNU_SOURCE
#include <sherpa-onnx/c-api/c-api.h>
#include "tts_models.h"
#include <SDL3/SDL.h>
#include <curl/curl.h>
#include <glib.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

enum { DOWNLOAD_ERROR = 1, GENERATE_ERROR = 2, AUDIO_ERROR = 3 };
enum { CHUNK_BYTES = 240, TEXT_LIMIT = 1024 * 1024, HEADER_BYTES = 3 };

static void status(char value) {
    if (pwrite(STDOUT_FILENO, &value, 1, 0) != 1) {
        exit(GENERATE_ERROR);
    }
}

#include "speech_download.h"

// Bound inference context without truncating long messages or splitting UTF-8.
static size_t chunk_length(const char *text, size_t n) {
    // Start playback at a sentence boundary instead of waiting for a paragraph.
    // ponytail: punctuation heuristic; use a sentence tokenizer if abbreviations matter.
    for (size_t i = 0; i + 1 < n && i < CHUNK_BYTES; ++i) {
        if (i + 3 <= n && i + 3 <= CHUNK_BYTES &&
            (!memcmp(text + i, "。", 3) || !memcmp(text + i, "！", 3) ||
             !memcmp(text + i, "？", 3))) {
            return i + 3;
        }
        if ((text[i] == '.' || text[i] == '!' || text[i] == '?') && g_ascii_isspace(text[i + 1])) {
            return i + 1;
        }
    }
    if (n <= CHUNK_BYTES) {
        return n;
    }
    n = CHUNK_BYTES;
    while (((unsigned char)text[n] & 0xc0) == 0x80) {
        --n;
    }
    for (size_t i = n; i > 0; --i) {
        if (g_ascii_isspace(text[i - 1])) {
            return i;
        }
    }
    return n;
}

static const SherpaOnnxOfflineTts *load_model(const char *dir) {
    char *paths[7];
    for (size_t i = 0; i < G_N_ELEMENTS(paths); ++i) {
        paths[i] = g_build_filename(dir, models[i].name, NULL);
    }
    SherpaOnnxOfflineTtsConfig config = {0};
    config.model.num_threads = 2;
    config.model.supertonic = (SherpaOnnxOfflineTtsSupertonicModelConfig){
        .duration_predictor = paths[0],
        .text_encoder = paths[1],
        .vector_estimator = paths[2],
        .vocoder = paths[3],
        .tts_json = paths[4],
        .unicode_indexer = paths[5],
        .voice_style = paths[6],
    };
    const SherpaOnnxOfflineTts *model = SherpaOnnxCreateOfflineTts(&config);
    for (size_t i = 0; i < G_N_ELEMENTS(paths); ++i) {
        g_free(paths[i]);
    }
    return model;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        return GENERATE_ERROR;
    }
    // No orphaned speech if the desktop app crashes or is killed.
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != atoi(argv[3])) {
        return GENERATE_ERROR;
    }
    // Runtime diagnostics can quote input text. Keep private messages out of logs.
    int diagnostics = open("/dev/null", O_WRONLY | O_CLOEXEC);
    if (diagnostics < 0 || dup2(diagnostics, STDERR_FILENO) < 0) {
        return GENERATE_ERROR;
    }
    close(diagnostics);
    umask(0077);
    int voice = -1;
    for (size_t i = 0; i < G_N_ELEMENTS(voices); ++i) {
        if (!strcmp(argv[2], voices[i])) {
            voice = (int)i;
        }
    }
    int language_ok = 0;
    for (size_t i = 0; i < G_N_ELEMENTS(languages); ++i) {
        if (!strcmp(argv[4], languages[i])) {
            language_ok = 1;
        }
    }
    struct stat st;
    if (!language_ok || voice < 0 || fstat(STDIN_FILENO, &st) || st.st_size <= HEADER_BYTES ||
        st.st_size > TEXT_LIMIT + HEADER_BYTES) {
        return GENERATE_ERROR;
    }
    size_t length = (size_t)st.st_size - HEADER_BYTES;
    char *text = g_malloc(length + 1);
    if (pread(STDIN_FILENO, text, length, HEADER_BYTES) != (ssize_t)length ||
        memchr(text, 0, length)) {
        g_free(text);
        return GENERATE_ERROR;
    }
    text[length] = 0;
    if (!g_utf8_validate(text, length, NULL)) {
        g_free(text);
        return GENERATE_ERROR;
    }
    if (curl_global_init(CURL_GLOBAL_DEFAULT)) {
        g_free(text);
        return DOWNLOAD_ERROR;
    }
    int result = DOWNLOAD_ERROR;
    if (g_mkdir_with_parents(argv[1], 0700)) {
        goto done;
    }
    // Serialize cache writes across app instances. An interrupted .part is
    // overwritten on retry and can never be loaded as a completed model.
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
    status('G');
    result = GENERATE_ERROR;
    const SherpaOnnxOfflineTts *ctx = load_model(argv[1]);
    if (!ctx) {
        goto done;
    }
    result = AUDIO_ERROR;
    SDL_AudioSpec spec = {
        .format = SDL_AUDIO_F32, .channels = 1, .freq = SherpaOnnxOfflineTtsSampleRate(ctx)};
    SDL_AudioStream *stream = NULL;
    if (!SDL_InitSubSystem(SDL_INIT_AUDIO) ||
        !(stream =
              SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, NULL, NULL)) ||
        !SDL_ResumeAudioStreamDevice(stream)) {
        goto free_model;
    }
    result = 0;
    for (char *cursor = text; *cursor;) {
        while (length && g_ascii_isspace(*cursor)) {
            ++cursor;
            --length;
        }
        if (!*cursor) {
            break;
        }
        size_t n = chunk_length(cursor, length);
        char saved = cursor[n];
        cursor[n] = 0;
        if (SDL_GetAudioStreamQueued(stream) == 0) {
            status('G');
        }
        char language[32];
        snprintf(language, sizeof(language), "{\"lang\":\"%s\"}", argv[4]);
        SherpaOnnxGenerationConfig params = {
            .sid = voice, .num_steps = 8, .speed = 1, .extra = language};
        const SherpaOnnxGeneratedAudio *audio =
            SherpaOnnxOfflineTtsGenerateWithConfig(ctx, cursor, &params, NULL, NULL);
        cursor[n] = saved;
        cursor += n;
        length -= n;
        if (!audio) {
            result = GENERATE_ERROR;
            break;
        }
        int bytes = audio->n * (int)sizeof(float);
        int queued = audio->sample_rate == spec.freq && audio->n > 0 &&
                     SDL_PutAudioStreamData(stream, audio->samples, bytes) &&
                     SDL_FlushAudioStream(stream);
        SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
        if (!queued) {
            result = AUDIO_ERROR;
            break;
        }
        status('P');
        // Generate ahead during playback, keeping at most two chunks queued.
        int pending;
        while ((pending = SDL_GetAudioStreamQueued(stream)) > bytes) {
            SDL_Delay(20);
        }
        if (pending < 0) {
            result = AUDIO_ERROR;
            break;
        }
    }
    if (!result) {
        int pending;
        while ((pending = SDL_GetAudioStreamQueued(stream)) > 0) {
            SDL_Delay(20);
        }
        if (pending < 0) {
            result = AUDIO_ERROR;
        }
        SDL_Delay(100); // Let the device consume its final buffer before closing.
    }
free_model:
    SDL_DestroyAudioStream(stream);
    SDL_Quit();
    SherpaOnnxDestroyOfflineTts(ctx);
done:
    curl_global_cleanup();
    g_free(text);
    return result;
}
