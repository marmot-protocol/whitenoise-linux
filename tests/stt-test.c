// Optional: build/stt-test <model-cache> <audio-file> <expected-substring>
// [tiny|base|small|medium|large-v3|turbo] WN_STT_HELPER=/path/to/wn-stt tests the installed helper
// and its libraries.
#define main stt_helper_main
#include "../app/stt.c"
#undef main
#include <assert.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    assert(transcribe(NULL, NULL, 0) == RECOGNIZE_ERROR);
    assert(transcribe(NULL, NULL, MAX_AUDIO_SAMPLES + 1) == RECOGNIZE_ERROR);
    assert(!select_model("../../unknown"));
    assert(select_model("tiny"));
    if (argc == 1) {
        return 0;
    }
    assert(argc == 4 || argc == 5);
    FILE *audio_file = g_fopen(argv[2], "rb");
    assert(audio_file && !fseek(audio_file, 0, SEEK_END));
    long audio_size = ftell(audio_file);
    assert(audio_size > 0 && audio_size <= 100 * 1024 * 1024);
    rewind(audio_file);
    WnIpc *input = wn_ipc_create((size_t)audio_size);
    assert(input &&
           fread(wn_ipc_data(input), 1, (size_t)audio_size, audio_file) == (size_t)audio_size);
    fclose(audio_file);
    char input_size[32];
    snprintf(input_size, sizeof(input_size), "%ld", audio_size);

    char parent[32];
    snprintf(parent, sizeof(parent), "%d", getpid());
    for (int phase = 0; phase < 2; ++phase) {
        if (speech_ipc)
            wn_ipc_close(speech_ipc);
        speech_ipc = wn_ipc_create(HEADER_BYTES + TEXT_LIMIT);
        assert(speech_ipc && wn_ipc_write(speech_ipc, "G\0\0\0", HEADER_BYTES, 0) == HEADER_BYTES);
        pid_t child = fork();
        assert(child >= 0);
        if (!child) {
            char *args[] = {argv[0],
                            argv[1],
                            parent,
                            phase == 0 ? "download" : "audio",
                            argc == 5 ? argv[4] : "tiny",
                            (char *)wn_ipc_name(speech_ipc),
                            phase == 0 ? "" : (char *)wn_ipc_name(input),
                            phase == 0 ? "0" : input_size,
                            NULL};
            const char *helper = getenv("WN_STT_HELPER");
            if (helper) {
                execv(helper, args);
                _exit(RECOGNIZE_ERROR);
            }
            _exit(stt_helper_main(8, args));
        }
        int status;
        int partial = 0;
        pid_t waited;
        while ((waited = waitpid(child, &status, WNOHANG)) == 0) {
            unsigned char header[3];
            assert(wn_ipc_read(speech_ipc, header, sizeof(header), 0) == sizeof(header));
            if (phase == 1 && header[0] == 'P' && (header[1] || header[2])) {
                char segment[TEXT_LIMIT];
                size_t length = header[1] | ((size_t)header[2] << 8);
                assert(length <= sizeof(segment));
                assert(wn_ipc_read(speech_ipc, segment, length, HEADER_BYTES) == (intptr_t)length);
                assert(g_utf8_validate(segment, length, NULL));
                partial = 1;
            }
            usleep(1000);
        }
        assert(waited == child);
        if (phase == 1 && getenv("WN_STT_PARTIAL")) {
            assert(partial);
        }
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
        if (phase == 0) {
            unsigned char header[HEADER_BYTES];
            assert(wn_ipc_read(speech_ipc, header, sizeof(header), 0) == sizeof(header));
            assert(header[0] == 'T');
        }
    }
    wn_ipc_close(input);
    char text[TEXT_LIMIT + 1] = {0};
    assert(wn_ipc_read(speech_ipc, text, TEXT_LIMIT, HEADER_BYTES) == TEXT_LIMIT);
    char *lower = g_utf8_strdown(text, -1);
    assert(strstr(lower, argv[3]));
    fprintf(stderr, "Transcript: %s\n", text);
    g_free(lower);
    wn_ipc_close(speech_ipc);
    return 0;
}
