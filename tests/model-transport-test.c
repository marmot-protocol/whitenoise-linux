#define _POSIX_C_SOURCE 200809L
#include "../app/decoder_ipc.h"
#include "../app/decoder_limits.h"
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <tlhelp32.h>
#else
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

static uint64_t millis(void) {
#ifdef _WIN32
    return GetTickCount64();
#else
    struct timespec now;
    assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
#endif
}

static void pause_seconds(unsigned int seconds) {
#ifdef _WIN32
    Sleep(seconds * 1000);
#else
    while ((seconds = sleep(seconds)) != 0) {
    }
#endif
}

static uint32_t process_id(void) {
#ifdef _WIN32
    return GetCurrentProcessId();
#else
    return (uint32_t)getpid();
#endif
}

static int consume(uint32_t size) {
    unsigned char bytes[4096];
    while (size) {
        size_t count = size > sizeof(bytes) ? sizeof(bytes) : size;
        if (fread(bytes, 1, count, stdin) != count) {
            return 0;
        }
        size -= (uint32_t)count;
    }
    return 1;
}

/* This executable is also the hostile helper. It has no inherited test settings:
 * the selected behavior and test handle travel through the actual request. */
static int peer(void) {
#ifdef _WIN32
    if (_setmode(_fileno(stdin), _O_BINARY) < 0 || _setmode(_fileno(stdout), _O_BINARY) < 0) {
        return 1;
    }
#endif
    unsigned char request[16];
    uint32_t sequence = 0;
    int session = 0;
    while (fread(request, 1, sizeof(request), stdin) == sizeof(request)) {
        int mesh = !memcmp(request, "MDI1", 4);
        if (!mesh && memcmp(request, "FBI1", 4)) {
            return 1;
        }
        uint32_t size = wn_image_u32(request + (mesh ? 4 : 8));
        uint32_t operation = wn_image_u32(request + (mesh ? 8 : 4));
        if (!size || size > WN_MODEL_INPUT_MAX ||
            (mesh && (operation < WN_MESH_STL || operation > WN_MESH_GCODE)) ||
            (!mesh && operation > WN_MODEL_POSE) ||
            wn_image_u32(request + 12) != (mesh ? 0 : ++sequence)) {
            return 1;
        }
        if (!session && !wn_decoder_limits(mesh ? WN_DECODER_ONESHOT : WN_DECODER_SESSION)) {
            return 1;
        }
        session = !mesh;
        int mode = getchar();
        if (mode == EOF) {
            return 1;
        }
        --size;
        uint32_t input_size = size + 1;
        if (mode == 'w') {
            pause_seconds(30); /* Never drain the request: exercises bounded writes. */
            return 1;
        }
        if (mode == 'e') {
            unsigned char handle_bytes[8];
            if (size < sizeof(handle_bytes) ||
                fread(handle_bytes, 1, sizeof(handle_bytes), stdin) != sizeof(handle_bytes) ||
                getenv("WN_MODEL_TEST_SECRET")) {
                return 1;
            }
            size -= sizeof(handle_bytes);
#ifdef _WIN32
            uintptr_t handle = (uintptr_t)wn_image_u32(handle_bytes) |
                               (uintptr_t)((uint64_t)wn_image_u32(handle_bytes + 4) << 32);
            if (SetEvent((HANDLE)handle)) {
                return 1;
            }
#else
            if (fcntl(100, F_GETFD) != -1 || errno != EBADF) {
                return 1;
            }
#endif
        }
        unsigned char response[33] = {0};
        memcpy(response, mesh ? "MDO1" : "FBO1", 4);
        wn_image_put(response + 4, mesh ? 1 : operation);
        wn_image_put(response + 8, mesh ? 0 : sequence);
        wn_image_put(response + 12, 16);
        response[16] = (unsigned char)mode;
        response[17] = (unsigned char)operation;
        response[18] = 0x99;
        response[19] = 0x55;
        wn_image_put(response + 20, mesh ? 0 : sequence);
        wn_image_put(response + 24, process_id());
        wn_image_put(response + 28, input_size);
        if (mode == 'b') {
            /* Return a pipe-filling body before reading a pipe-filling request. */
            wn_image_put(response + 12, 1024 * 1024);
            if (fwrite(response, 1, 16, stdout) != 16) {
                return 1;
            }
            unsigned char block[4096];
            memset(block, 0x5a, sizeof(block));
            for (unsigned int i = 0; i < 256; ++i) {
                if (fwrite(block, 1, sizeof(block), stdout) != sizeof(block)) {
                    return 1;
                }
            }
            if (fflush(stdout) || !consume(size) || (mesh && getchar() != EOF)) {
                return 1;
            }
            if (mesh) {
                return 0;
            }
            continue;
        }
        if (!consume(size) || (mesh && getchar() != EOF)) {
            return 1;
        }
        if (mode == 't') {
            pause_seconds(30);
            return 1;
        }
        if (mode == 'd') {
            pause_seconds(6);
        }
        if (mode == 'c') {
            /* Three successful poses exceed the old five-second CPU lifetime. */
            clock_t start = clock();
            if (start == (clock_t)-1) {
                return 1;
            }
            while ((double)(clock() - start) / CLOCKS_PER_SEC < 2.2) {
            }
        }
        switch (mode) {
        case 'm':
            response[0] = 'X';
            break;
        case 'l':
            wn_image_put(response + 12, WN_MODEL_OUTPUT_MAX + 1);
            break;
        case 'o':
            wn_image_put(response + 4, UINT32_MAX);
            break;
        case 'q':
            wn_image_put(response + 8, mesh ? 1 : sequence - 1);
            break;
        case 'h':
            return fwrite(response, 1, 8, stdout) == 8 ? 0 : 1;
        case 's':
            return fwrite(response, 1, 24, stdout) == 24 ? 0 : 1;
        case 'f':
            if (!mesh) {
                return 1;
            }
            break;
        }
        size_t bytes = mode == 'x' ? sizeof(response) : sizeof(response) - 1;
        if (mode == 'z') {
            wn_image_put(response + 12, 0);
            bytes = 16;
        }
        if (fwrite(response, 1, bytes, stdout) != bytes || fflush(stdout)) {
            return 1;
        }
        if (mesh || mode == 'f') {
            return mode == 'f' ? 1 : 0;
        }
    }
    return 1;
}

#ifdef _WIN32
typedef HANDLE Child;
static Child watch_child(uint32_t pid) {
    Child child = OpenProcess(SYNCHRONIZE, FALSE, pid);
    assert(child);
    return child;
}
static void expect_reaped(Child child) {
    assert(WaitForSingleObject(child, 0) == WAIT_OBJECT_0);
    CloseHandle(child);
}
static unsigned int thread_count(void) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    assert(snapshot != INVALID_HANDLE_VALUE);
    THREADENTRY32 entry = {0};
    entry.dwSize = sizeof(entry);
    unsigned int count = 0;
    assert(Thread32First(snapshot, &entry));
    do {
        if (entry.th32OwnerProcessID == GetCurrentProcessId()) {
            ++count;
        }
    } while (Thread32Next(snapshot, &entry));
    CloseHandle(snapshot);
    return count;
}
#else
typedef pid_t Child;
static Child watch_child(uint32_t pid) {
    return (pid_t)pid;
}
static void expect_reaped(Child child) {
    errno = 0;
    assert(waitpid(child, NULL, WNOHANG) == -1 && errno == ECHILD);
    errno = 0;
    assert(kill(child, 0) == -1 && errno == ESRCH);
}
#endif

static void check_payload(const unsigned char *bytes, unsigned int length, unsigned char mode,
                          unsigned int operation, unsigned int sequence, unsigned int size) {
    assert(bytes && length == 16 && bytes[0] == mode && bytes[1] == operation && bytes[2] == 0x99 &&
           bytes[3] == 0x55 && wn_image_u32(bytes + 4) == sequence &&
           wn_image_u32(bytes + 12) == size);
}

static WnModelSession *open_session(const char *helper, Child *child) {
    WnModelSession *session = wn_model_start(helper);
    assert(session);
    unsigned char mode = 'v';
    unsigned int length = 999;
    unsigned char *reply = wn_model_exchange(session, WN_MODEL_OPEN, &mode, 1, NULL, 0, &length);
    check_payload(reply, length, mode, WN_MODEL_OPEN, 1, 1);
    *child = watch_child(wn_image_u32(reply + 8));
    free(reply);
    return session;
}

static void invalidated(WnModelSession *session, Child child) {
    unsigned char mode = 'v';
    unsigned int length = 999;
    assert(!wn_model_exchange(session, WN_MODEL_POSE, &mode, 1, NULL, 0, &length));
    assert(length == 0);
    expect_reaped(child);
    wn_model_close(session);
}

static void static_failure(const char *helper, unsigned char mode) {
    unsigned int length = 999;
    unsigned char *reply = wn_mesh_decode(helper, &mode, 1, WN_MESH_STL, &length);
    assert(!reply && length == 0);
}

int main(int argc, char **argv) {
    if (argc == 1) {
        return peer();
    }
    assert(argc == 2 && !strcmp(argv[1], "--test"));
    const char *helper = argv[0];
#ifdef _WIN32
    DWORD handles_before;
    assert(GetProcessHandleCount(GetCurrentProcess(), &handles_before));
    unsigned int threads_before = thread_count();
#endif
    unsigned char mode = 'v';
    unsigned int length;
    for (unsigned int format = WN_MESH_STL; format <= WN_MESH_GCODE; ++format) {
        length = 999;
        unsigned char *reply = wn_mesh_decode(helper, &mode, 1, format, &length);
        check_payload(reply, length, mode, format, 0, 1);
        free(reply);
    }
    const unsigned char failures[] = {'m', 'l', 'o', 'q', 'h', 's', 'x', 'f'};
    for (size_t i = 0; i < sizeof(failures); ++i) {
        static_failure(helper, failures[i]);
        Child child;
        WnModelSession *session = open_session(helper, &child);
        unsigned char scratch[18];
        memset(scratch, 0x7b, sizeof(scratch));
        length = 999;
        assert(
            !wn_model_exchange(session, WN_MODEL_POSE, failures + i, 1, scratch + 1, 16, &length));
        assert(length == 0 && scratch[0] == 0x7b && scratch[17] == 0x7b);
        invalidated(session, child);
    }
    for (unsigned int format = 0; format <= 5; format += 5) {
        length = 999;
        assert(!wn_mesh_decode(helper, &mode, 1, format, &length) && length == 0);
    }
    length = 999;
    assert(!wn_mesh_decode(helper, &mode, WN_MODEL_INPUT_MAX + 1, WN_MESH_STL, &length));
    assert(length == 0);
    length = 999;
    assert(!wn_mesh_decode(helper, NULL, 1, WN_MESH_STL, &length) && length == 0);
    assert(!wn_model_start(NULL) && !wn_model_start(""));
    length = 999;
    assert(!wn_model_exchange(NULL, 0, &mode, 1, NULL, 0, &length) && length == 0);
    wn_model_close(NULL);
    for (int i = 0; i < 8; ++i) {
        WnModelSession *idle = wn_model_start(helper);
        assert(idle);
        wn_model_close(idle);
    }
    unsigned char empty = 'z';
    unsigned char *empty_reply = wn_mesh_decode(helper, &empty, 1, WN_MESH_OBJ, &length);
    assert(empty_reply && length == 0);
    free(empty_reply);

    Child child;
    WnModelSession *session = open_session(helper, &child);
    unsigned char scratch[18];
    memset(scratch, 0x7b, sizeof(scratch));
    for (unsigned int sequence = 2; sequence < 130; ++sequence) {
        length = 999;
        unsigned char *reply =
            wn_model_exchange(session, WN_MODEL_POSE, &mode, 1, scratch + 1, 16, &length);
        assert(reply == scratch + 1 && scratch[0] == 0x7b && scratch[17] == 0x7b);
        check_payload(reply, length, mode, WN_MODEL_POSE, sequence, 1);
    }
    unsigned char sentinel = 0x7b;
    length = 999;
    assert(wn_model_exchange(session, WN_MODEL_POSE, &empty, 1, &sentinel, 0, &length) ==
           &sentinel);
    assert(length == 0 && sentinel == 0x7b);
    wn_model_close(session);
    expect_reaped(child);

    for (int invalid = 0; invalid < 4; ++invalid) {
        session = open_session(helper, &child);
        length = 999;
        unsigned int op = invalid == 0 ? 2 : WN_MODEL_POSE;
        unsigned int size = invalid == 1 ? WN_MODEL_INPUT_MAX + 1 : 1;
        const unsigned char *data = invalid == 2 ? NULL : &mode;
        unsigned int cap = invalid == 3 ? 15 : 16;
        assert(!wn_model_exchange(session, op, data, size, scratch + 1, cap, &length));
        assert(length == 0 && scratch[0] == 0x7b && scratch[17] == 0x7b);
        invalidated(session, child);
    }

    unsigned char isolation[9] = {'e'};
#ifdef _WIN32
    assert(SetEnvironmentVariableA("WN_MODEL_TEST_SECRET", "not-for-child"));
    SECURITY_ATTRIBUTES security = {sizeof(security), NULL, TRUE};
    HANDLE inherited = CreateEventW(&security, TRUE, FALSE, NULL);
    assert(inherited);
    uintptr_t handle = (uintptr_t)inherited;
    wn_image_put(isolation + 1, (uint32_t)handle);
    wn_image_put(isolation + 5, (uint32_t)((uint64_t)handle >> 32));
#else
    assert(setenv("WN_MODEL_TEST_SECRET", "not-for-child", 1) == 0);
    int fd = open("/dev/null", O_RDONLY);
    assert(fd >= 0 && dup2(fd, 100) == 100);
    if (fd != 100) {
        close(fd);
    }
#endif
    unsigned char *reply =
        wn_mesh_decode(helper, isolation, sizeof(isolation), WN_MESH_STL, &length);
    check_payload(reply, length, 'e', WN_MESH_STL, 0, sizeof(isolation));
    free(reply);
    session = wn_model_start(helper);
    assert(session);
    reply =
        wn_model_exchange(session, WN_MODEL_OPEN, isolation, sizeof(isolation), NULL, 0, &length);
    check_payload(reply, length, 'e', WN_MODEL_OPEN, 1, sizeof(isolation));
    child = watch_child(wn_image_u32(reply + 8));
    free(reply);
    wn_model_close(session);
    expect_reaped(child);
#ifdef _WIN32
    CloseHandle(inherited);
#else
    close(100);
#endif

    unsigned char *large = malloc(1024 * 1024);
    assert(large);
    memset(large, 'b', 1024 * 1024);
    reply = wn_mesh_decode(helper, large, 1024 * 1024, WN_MESH_STL, &length);
    assert(reply && length == 1024 * 1024);
    for (unsigned int i = 0; i < length; ++i) {
        assert(reply[i] == 0x5a);
    }
    free(reply);
    session = open_session(helper, &child);
    unsigned char *large_output = malloc(1024 * 1024);
    assert(large_output);
    reply = wn_model_exchange(session, WN_MODEL_POSE, large, 1024 * 1024, large_output, 1024 * 1024,
                              &length);
    assert(reply == large_output && length == 1024 * 1024);
    for (unsigned int i = 0; i < length; ++i) {
        assert(reply[i] == 0x5a);
    }
    free(large_output);
    wn_model_close(session);
    expect_reaped(child);

    /* Both blocked directions must finish under the parent transaction deadline. */
    for (int writing = 0; writing < 2; ++writing) {
        session = open_session(helper, &child);
        large[0] = writing ? 'w' : 't';
        uint64_t start = millis();
        length = 999;
        assert(!wn_model_exchange(session, WN_MODEL_POSE, large, writing ? 1024 * 1024 : 1,
                                  scratch + 1, 16, &length));
        uint64_t elapsed = millis() - start;
        assert(length == 0 && elapsed >= 9000 && elapsed < 20000);
        invalidated(session, child);
    }
    free(large);

    /* A healthy session outlives ten seconds wall time and five seconds CPU time. */
    session = open_session(helper, &child);
    for (int i = 0; i < 5; ++i) {
        mode = i < 2 ? 'd' : 'c';
        reply = wn_model_exchange(session, WN_MODEL_POSE, &mode, 1, scratch + 1, 16, &length);
        check_payload(reply, length, mode, WN_MODEL_POSE, (unsigned int)i + 2, 1);
    }
    wn_model_close(session);
    expect_reaped(child);
#ifdef _WIN32
    DWORD handles_after;
    assert(GetProcessHandleCount(GetCurrentProcess(), &handles_after));
    assert(handles_after == handles_before && thread_count() == threads_before);
#else
    errno = 0;
    assert(waitpid(-1, NULL, WNOHANG) == -1 && errno == ECHILD);
#endif
    puts("model transport: framing, sequences, scratch bounds, isolation, backpressure, deadlines "
         "and cleanup passed");
    return 0;
}
