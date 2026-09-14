// Optional: build/stt-test <model-cache> <16kHz-wav> <expected-substring>
#define main stt_helper_main
#include "../app/stt.c"
#undef main
#include <assert.h>
#include <sys/mman.h>

int main(int argc, char **argv) {
    assert(transcribe(NULL, NULL, 0) == RECOGNIZE_ERROR);
    assert(transcribe(NULL, NULL, MAX_SAMPLES + 1) == RECOGNIZE_ERROR);
    if (argc == 1) {
        return 0;
    }
    assert(argc == 4);
    int fd = memfd_create("stt-test", MFD_CLOEXEC);
    assert(fd >= 0 && dup2(fd, STDOUT_FILENO) >= 0);
    close(fd);
    assert(write(STDOUT_FILENO, "G\0\0\0", HEADER_BYTES) == HEADER_BYTES);
    assert(curl_global_init(CURL_GLOBAL_DEFAULT) == 0);
    assert(g_mkdir_with_parents(argv[1], 0700) == 0);
    for (size_t i = 0; i < G_N_ELEMENTS(models); ++i) {
        assert(ensure_model(argv[1], &models[i]));
    }
    const SherpaOnnxOfflineRecognizer *model = load_model(argv[1]);
    const SherpaOnnxWave *wave = SherpaOnnxReadWave(argv[2]);
    assert(model && wave && wave->sample_rate == SAMPLE_RATE);
    assert(transcribe(model, wave->samples, wave->num_samples) == 0);
    char text[TEXT_LIMIT + 1] = {0};
    assert(pread(STDOUT_FILENO, text, TEXT_LIMIT, HEADER_BYTES) > 0);
    char *lower = g_utf8_strdown(text, -1);
    assert(strstr(lower, argv[3]));
    fprintf(stderr, "Transcript: %s\n", text);
    g_free(lower);
    SherpaOnnxFreeWave(wave);
    SherpaOnnxDestroyOfflineRecognizer(model);
    curl_global_cleanup();
    return 0;
}
