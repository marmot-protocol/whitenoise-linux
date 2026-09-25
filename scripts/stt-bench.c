// Cached-model benchmark: <cache-dir> <16k-mono.wav> <model> <threads>
#define main stt_helper_main
#include "../app/stt.c"
#undef main
#include <assert.h>

int main(int argc, char **argv) {
    assert(argc == 5 && select_model(argv[3]));
    recognition_threads = atoi(argv[4]);
    assert(recognition_threads > 0 && recognition_threads <= 32);
    const SherpaOnnxWave *wave = SherpaOnnxReadWave(argv[2]);
    assert(wave && wave->sample_rate == SAMPLE_RATE);
    speech_ipc = wn_ipc_create(HEADER_BYTES + TEXT_LIMIT);
    assert(speech_ipc);
    gint64 start = g_get_monotonic_time();
    for (size_t i = 0; i < stt_model->file_count; ++i) {
        char *path = g_build_filename(argv[1], models[i].name, NULL);
        assert(valid_file(path, &models[i]));
        g_free(path);
    }
    fprintf(stderr, "verify_ms=%.1f ", (g_get_monotonic_time() - start) / 1000.0);
    start = g_get_monotonic_time();
    const SherpaOnnxOfflineRecognizer *model = load_model(argv[1]);
    assert(model);
    fprintf(stderr, "load_ms=%.1f threads=%d audio_s=%.2f decode_ms=",
            (g_get_monotonic_time() - start) / 1000.0, recognition_threads,
            wave->num_samples / (double)SAMPLE_RATE);
    for (int i = 0; i < 3; ++i) {
        start = g_get_monotonic_time();
        assert(transcribe(model, wave->samples, wave->num_samples) == 0);
        fprintf(stderr, "%.1f%s", (g_get_monotonic_time() - start) / 1000.0, i == 2 ? "\n" : ",");
    }
    SherpaOnnxDestroyOfflineRecognizer(model);
    SherpaOnnxFreeWave(wave);
    wn_ipc_close(speech_ipc);
    return 0;
}
