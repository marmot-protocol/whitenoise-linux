// Offline checks; optional arguments exercise real downloads and inference:
// SDL_AUDIODRIVER=dummy build/tts-test <cache-dir> F1 "Hello." en
// Add --bench to time verified, fixed-seed preparation of the first chunk.
// WN_TTS_HELPER=/path/to/wn-tts exercises an installed helper instead.
#define main tts_helper_main
#include "../app/tts.c"
#undef main
#include <assert.h>
#include <math.h>
#include <sys/mman.h>

int main(int argc, char **argv) {
    assert(chunk_length("Hello.", 6) == 6);
    assert(chunk_length("こんにちは。次の文です。", strlen("こんにちは。次の文です。")) == strlen("こんにちは。"));
    assert(chunk_length("Hello. Next sentence.", 21) == 6);
    assert(chunk_length("Ready? Yes!", 11) == 6);
    assert(chunk_length("Value 3.14.", 11) == 11);
    char long_text[1000];
    memset(long_text, 'x', sizeof(long_text));
    assert(chunk_length(long_text, sizeof(long_text)) == CHUNK_BYTES);
    long_text[100] = ' ';
    assert(chunk_length(long_text, sizeof(long_text)) == 101);
    // The byte ceiling lands inside a three-byte UTF-8 character.
    memset(long_text, 'x', sizeof(long_text));
    memcpy(long_text + CHUNK_BYTES - 1, "\xe3\x81\x82", 3);
    assert(chunk_length(long_text, sizeof(long_text)) == CHUNK_BYTES - 1);

    char path[] = "/tmp/wn-tts-test-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    assert(write(fd, "abc", 3) == 3);
    ModelFile sample = {"sample", 3, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"};
    assert(valid_file(path, &sample));
    assert(pwrite(fd, "x", 1, 0) == 1);
    assert(!valid_file(path, &sample));

    // Progress is tied to the pinned size, and never overwrites message text.
    int output = dup(STDOUT_FILENO);
    int progress = memfd_create("tts-progress", MFD_CLOEXEC);
    assert(output >= 0 && progress >= 0);
    assert(write(progress, "G\0\0Hello", 8) == 8);
    assert(dup2(progress, STDOUT_FILENO) >= 0);
    Download download = {.file = tmpfile(), .remaining = models[4].size, .model = &models[4]};
    assert(download.file);
    char *bytes = g_malloc0(models[4].size);
    size_t half = models[4].size / 2;
    assert(download_write(bytes, 1, half, &download) == half);
    unsigned char update[8];
    assert(pread(progress, update, sizeof(update), 0) == sizeof(update));
    assert(update[0] == 'D' && update[1] == 4 && update[2] == 100 * half / models[4].size);
    assert(!memcmp(update + HEADER_BYTES, "Hello", 5));
    assert(download_write(bytes, 1, models[4].size - half, &download) == models[4].size - half);
    assert(pread(progress, update, HEADER_BYTES, 0) == HEADER_BYTES && update[2] == 100);
    assert(download_write(bytes, 1, 1, &download) == 0);
    g_free(bytes);
    fclose(download.file);
    assert(dup2(output, STDOUT_FILENO) >= 0);
    close(output);
    close(progress);
    assert(ftruncate(fd, 2) == 0);
    assert(!valid_file(path, &sample));
    close(fd);
    unlink(path);
    assert(!valid_file(path, &sample));

    if (argc == 1) {
        return 0;
    }
    assert(argc == 5 || (argc == 6 && !strcmp(argv[5], "--bench")));
    if (argc == 6) {
        gint64 start = g_get_monotonic_time();
        int voice = -1;
        for (size_t i = 0; i < G_N_ELEMENTS(voices); ++i) {
            if (!strcmp(argv[2], voices[i])) {
                voice = (int)i;
            }
        }
        assert(voice >= 0);
        for (size_t i = 0; i < G_N_ELEMENTS(models); ++i) {
            char *model = g_build_filename(argv[1], models[i].name, NULL);
            assert(valid_file(model, &models[i]));
            g_free(model);
        }
        const SherpaOnnxOfflineTts *ctx = load_model(argv[1]);
        assert(ctx);
        argv[3][chunk_length(argv[3], strlen(argv[3]))] = 0;
        char language[32];
        snprintf(language, sizeof(language), "{\"lang\":\"%s\",\"seed\":123}", argv[4]);
        SherpaOnnxGenerationConfig params = {.sid = voice, .num_steps = 8, .speed = 1, .extra = language};
        const SherpaOnnxGeneratedAudio *audio = SherpaOnnxOfflineTtsGenerateWithConfig(ctx, argv[3], &params, NULL, NULL);
        gint64 ready = g_get_monotonic_time();
        assert(audio && audio->n > 0);
        assert(audio->sample_rate == SherpaOnnxOfflineTtsSampleRate(ctx));
        double energy = 0;
        for (int i = 0; i < audio->n; ++i) {
            assert(isfinite(audio->samples[i]));
            energy += audio->samples[i] * audio->samples[i];
        }
        assert(energy > 0);
        fprintf(stderr, "prepare=%.3f s samples=%d rms=%.6f\n",
                (ready - start) / 1e6, audio->n, sqrt(energy / audio->n));
        SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
        SherpaOnnxDestroyOfflineTts(ctx);
        return 0;
    }
    fd = memfd_create("tts-test", MFD_CLOEXEC);
    assert(fd >= 0);
    assert(write(fd, "G\0\0", HEADER_BYTES) == HEADER_BYTES);
    size_t size = strlen(argv[3]);
    assert(write(fd, argv[3], size) == (ssize_t)size);
    assert(dup2(fd, STDIN_FILENO) >= 0);
    assert(dup2(fd, STDOUT_FILENO) >= 0);
    close(fd);
    char parent[32];
    snprintf(parent, sizeof(parent), "%d", getppid());
    char *args[] = {argv[0], argv[1], argv[2], parent, argv[4], NULL};
    const char *helper = getenv("WN_TTS_HELPER");
    if (helper) {
        execv(helper, args);
        return GENERATE_ERROR;
    }
    return tts_helper_main(5, args);
}
