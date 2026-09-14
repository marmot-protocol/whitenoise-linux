// Audio stays in this killable helper. memfd: status/model/percent/command,
// P/T reuse model/percent as a little-endian committed UTF-8 byte count.
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
#include <mpv/client.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include "speech_download.h"

enum { DOWNLOAD_ERROR = 1, RECOGNIZE_ERROR = 2, AUDIO_ERROR = 3, LENGTH_ERROR = 4 };
enum { SAMPLE_RATE = 16000, MAX_SAMPLES = SAMPLE_RATE * 30, CHUNK_SAMPLES = SAMPLE_RATE * 29, MAX_AUDIO_SAMPLES = SAMPLE_RATE * 600, HEADER_BYTES = 4, TEXT_LIMIT = 16384 };

static int set_status(char value) {
    return pwrite(STDOUT_FILENO, &value, 1, 0) == 1;
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
            .encoder = paths[0], .decoder = paths[1], .task = "transcribe",
        };
        break;
    case PARAKEET:
        config.model_config.transducer = (SherpaOnnxOfflineTransducerModelConfig){
            .encoder = paths[0], .decoder = paths[1], .joiner = paths[2],
        };
        config.model_config.model_type = "nemo_transducer";
        break;
    case SENSEVOICE:
        config.model_config.sense_voice = (SherpaOnnxOfflineSenseVoiceModelConfig){
            .model = paths[0], .language = "auto", .use_itn = 1,
        };
        break;
    }
    config.model_config.tokens = paths[stt_model->file_count - 1];
    config.model_config.num_threads = recognition_threads > 0 ? recognition_threads :
        (int)MAX(1, MIN(8, sysconf(_SC_NPROCESSORS_ONLN)));
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
        if (!stream) { goto done; }
        int n = MIN(window, count - offset);
        SherpaOnnxAcceptWaveformOffline(stream, SAMPLE_RATE, samples + offset, n);
        SherpaOnnxDecodeOfflineStream(model, stream);
        const SherpaOnnxOfflineRecognizerResult *result = SherpaOnnxGetOfflineStreamResult(stream);
        size_t previous = text->len;
        int valid = result && result->text && g_utf8_validate(result->text, -1, NULL) &&
            text->len + strlen(result->text) + 1 <= TEXT_LIMIT;
        if (valid) {
            if (text->len) { g_string_append_c(text, ' '); }
            g_string_append(text, result->text);
        }
        SherpaOnnxDestroyOfflineRecognizerResult(result);
        SherpaOnnxDestroyOfflineStream(stream);
        if (!valid) { goto done; }
        // Append first, then publish the complete segment. Readers ignore uncommitted bytes.
        unsigned char update[] = {'P', text->len & 255, text->len >> 8};
        if (pwrite(STDOUT_FILENO, text->str + previous, text->len - previous,
                   HEADER_BYTES + previous) != (ssize_t)(text->len - previous) ||
            pwrite(STDOUT_FILENO, update, sizeof(update), 0) != sizeof(update)) {
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

// Decode the in-memory attachment with the same codecs as playback. The PCM
// output is a memfd, never a plaintext file or an audio-device stream.
static int decode_audio(int pcm) {
    mpv_handle *mpv = mpv_create();
    if (!mpv) { return AUDIO_ERROR; }
    char output[64];
    snprintf(output, sizeof(output), "/proc/self/fd/%d", pcm);
    const char *options[][2] = {
        {"config", "no"}, {"terminal", "no"}, {"load-scripts", "no"},
        {"autoload-files", "no"}, {"access-references", "no"},
        {"demuxer", "lavf"}, {"demuxer-lavf-o", "protocol_whitelist=none"},
        {"vid", "no"}, {"sid", "no"}, {"ao", "pcm"},
        {"ao-pcm-file", output}, {"ao-pcm-waveheader", "no"},
        {"audio-samplerate", "16000"}, {"audio-format", "float"},
        {"audio-channels", "mono"}, {"end", "601"},
    };
    int code = AUDIO_ERROR;
    for (size_t i = 0; i < G_N_ELEMENTS(options); ++i) {
        if (mpv_set_option_string(mpv, options[i][0], options[i][1]) < 0) { goto done; }
    }
    if (mpv_initialize(mpv) < 0) { goto done; }
    const char *args[] = {"loadfile", "/proc/self/fd/0", NULL};
    if (mpv_command(mpv, args) < 0) { goto done; }
    gint64 started = g_get_monotonic_time();
    while (g_get_monotonic_time() - started < 60 * G_USEC_PER_SEC) {
        mpv_event *event = mpv_wait_event(mpv, 0.1);
        if (event->event_id == MPV_EVENT_END_FILE) {
            const mpv_event_end_file *end = event->data;
            if (end && end->reason == MPV_END_FILE_REASON_EOF) { code = 0; }
            break;
        }
    }
done:
    mpv_terminate_destroy(mpv);
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
    if (argc != 5 || !select_model(argv[4]) || (strcmp(argv[3], "dictate") && strcmp(argv[3], "audio") && strcmp(argv[3], "download")) || prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != atoi(argv[2])) {
        return RECOGNIZE_ERROR;
    }
    int diagnostics = open("/dev/null", O_WRONLY | O_CLOEXEC);
    if (diagnostics < 0 || dup2(diagnostics, STDERR_FILENO) < 0) {
        return RECOGNIZE_ERROR;
    }
    close(diagnostics);
    struct stat st;
    int audio = !strcmp(argv[3], "audio");
    if (fstat(STDIN_FILENO, &st) || (audio ? st.st_size <= 0 || st.st_size > 100 * 1024 * 1024 : st.st_size != HEADER_BYTES)) {
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
    for (size_t i = 0; i < stt_model->file_count; ++i) {
        if (!ensure_model(argv[1], &models[i])) {
            close(lock);
            goto done;
        }
    }
    close(lock);
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
        int pcm = memfd_create("wn-stt-pcm", MFD_CLOEXEC);
        code = AUDIO_ERROR;
        // Bound decoder output even for malformed or misleading durations.
        struct rlimit limit;
        if (pcm < 0 || getrlimit(RLIMIT_FSIZE, &limit)) { goto free_pcm; }
        limit.rlim_cur = MIN(limit.rlim_max, (MAX_AUDIO_SAMPLES + SAMPLE_RATE * 2) * sizeof(float));
        if (setrlimit(RLIMIT_FSIZE, &limit) || !set_status('C')) { goto free_pcm; }
        code = decode_audio(pcm);
        if (code) { goto free_pcm; }
        struct stat decoded;
        code = AUDIO_ERROR;
        if (fstat(pcm, &decoded) || decoded.st_size <= 0 || decoded.st_size % sizeof(float)) { goto free_pcm; }
        code = LENGTH_ERROR;
        if (decoded.st_size > MAX_AUDIO_SAMPLES * (off_t)sizeof(float)) { goto free_pcm; }
        code = RECOGNIZE_ERROR;
        float *samples = mmap(NULL, decoded.st_size, PROT_READ, MAP_PRIVATE, pcm, 0);
        if (samples == MAP_FAILED) { goto free_pcm; }
        code = transcribe(model, samples, decoded.st_size / sizeof(float));
        munmap(samples, decoded.st_size);
free_pcm:
        if (pcm >= 0) { close(pcm); }
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
