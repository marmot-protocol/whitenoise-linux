// Optional: build/stt-test <model-cache> <audio-file> <expected-substring> [tiny|base|small|medium|large-v3|turbo]
// WN_STT_HELPER=/path/to/wn-stt tests the installed helper and its libraries.
#define main stt_helper_main
#include "../app/stt.c"
#undef main
#include <assert.h>
#include <sys/wait.h>

int main(int argc, char **argv) {
    assert(transcribe(NULL, NULL, 0) == RECOGNIZE_ERROR);
    assert(transcribe(NULL, NULL, MAX_AUDIO_SAMPLES + 1) == RECOGNIZE_ERROR);
    for (size_t i = 0; i < G_N_ELEMENTS(stt_models); ++i) {
        assert(select_model(stt_models[i].name));
        assert(stt_model == &stt_models[i]);
        assert(stt_model->file_count >= 2 && stt_model->file_count <= 4);
        for (size_t j = 0; j < stt_model->file_count; ++j) {
            assert(models[j].size > 0 && strlen(models[j].sha256) == 64);
        }
    }
    assert(!select_model("../../unknown"));
    assert(select_model("tiny"));
    if (argc == 1) { return 0; }
    assert(argc == 4 || argc == 5);
    int fd = memfd_create("stt-test", MFD_CLOEXEC);
    assert(fd >= 0 && dup2(fd, STDOUT_FILENO) >= 0);
    close(fd);
    assert(write(STDOUT_FILENO, "G\0\0\0", HEADER_BYTES) == HEADER_BYTES);
    int input = open(argv[2], O_RDONLY | O_CLOEXEC);
    assert(input >= 0 && dup2(input, STDIN_FILENO) >= 0);

    char parent[32];
    snprintf(parent, sizeof(parent), "%d", getpid());
    for (int phase = 0; phase < 2; ++phase) {
    assert(dup2(phase == 0 ? STDOUT_FILENO : input, STDIN_FILENO) >= 0);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        char *args[] = {argv[0], argv[1], parent, phase == 0 ? "download" : "audio", argc == 5 ? argv[4] : "tiny", NULL};
        const char *helper = getenv("WN_STT_HELPER");
        if (helper) {
            execv(helper, args);
            _exit(RECOGNIZE_ERROR);
        }
        _exit(stt_helper_main(5, args));
    }
    int status;
    int partial = 0;
    pid_t waited;
    while ((waited = waitpid(child, &status, WNOHANG)) == 0) {
        unsigned char header[3];
        assert(pread(STDOUT_FILENO, header, sizeof(header), 0) == sizeof(header));
        if (phase == 1 && header[0] == 'P' && (header[1] || header[2])) {
            char segment[TEXT_LIMIT];
            size_t length = header[1] | ((size_t)header[2] << 8);
            assert(length <= sizeof(segment));
            assert(pread(STDOUT_FILENO, segment, length, HEADER_BYTES) == (ssize_t)length);
            assert(g_utf8_validate(segment, length, NULL));
            partial = 1;
        }
        usleep(1000);
    }
    assert(waited == child);
    if (phase == 1 && getenv("WN_STT_PARTIAL")) { assert(partial); }
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    if (phase == 0) {
        unsigned char header[HEADER_BYTES];
        struct stat output;
        assert(pread(STDOUT_FILENO, header, sizeof(header), 0) == sizeof(header));
        assert(header[0] == 'T');
        assert(!fstat(STDOUT_FILENO, &output) && output.st_size == HEADER_BYTES);
    }
    }
    close(input);
    char text[TEXT_LIMIT + 1] = {0};
    assert(pread(STDOUT_FILENO, text, TEXT_LIMIT, HEADER_BYTES) > 0);
    char *lower = g_utf8_strdown(text, -1);
    assert(strstr(lower, argv[3]));
    fprintf(stderr, "Transcript: %s\n", text);
    g_free(lower);
    return 0;
}
