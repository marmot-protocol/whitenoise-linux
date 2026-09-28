/* Process transport only: no image parser or decoder is linked into the UI. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "image_ipc.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif
#ifdef __APPLE__
#include <spawn.h>
#endif
#endif

struct image_reply {
    unsigned char header[WN_IMAGE_HEADER];
    unsigned char extra;
    unsigned char *pixels;
    size_t received;
    uint32_t bytes;
    uint32_t width;
    uint32_t height;
    uint32_t dimension;
    uint32_t cap;
};

/* Read directly into its final destination, with one byte reserved to detect excess. */
static unsigned char *image_buffer(struct image_reply *reply, size_t *size) {
    if (reply->received < WN_IMAGE_HEADER) {
        *size = WN_IMAGE_HEADER - reply->received;
        return reply->header + reply->received;
    }
    size_t offset = reply->received - WN_IMAGE_HEADER;
    if (offset < reply->bytes) {
        *size = reply->bytes - offset;
        if (*size > 65536) {
            *size = 65536;
        }
        return reply->pixels + offset;
    }
    *size = 1;
    return &reply->extra;
}

static int image_received(struct image_reply *reply, size_t size) {
    if (reply->received >= WN_IMAGE_HEADER + (size_t)reply->bytes &&
        reply->received >= WN_IMAGE_HEADER) {
        return 0;
    }
    reply->received += size;
    if (reply->received == WN_IMAGE_HEADER) {
        if (memcmp(reply->header, "WNO1", 4)) {
            return 0;
        }
        reply->width = wn_image_u32(reply->header + 4);
        reply->height = wn_image_u32(reply->header + 8);
        reply->bytes = wn_image_u32(reply->header + 12);
        uint64_t expected = (uint64_t)reply->width * reply->height * 4;
        if (!reply->width || !reply->height || reply->width > reply->dimension ||
            reply->height > reply->dimension || expected > reply->cap || expected != reply->bytes) {
            return 0;
        }
        reply->pixels = malloc(reply->bytes);
        if (!reply->pixels) {
            return 0;
        }
    }
    return 1;
}

static int image_complete(const struct image_reply *reply) {
    return reply->pixels && reply->received == WN_IMAGE_HEADER + (size_t)reply->bytes;
}

#ifdef _WIN32
struct image_writer {
    HANDLE pipe;
    const unsigned char *header;
    const unsigned char *data;
    DWORD size;
};

static int image_write_all(HANDLE pipe, const unsigned char *data, DWORD size) {
    while (size) {
        DWORD written = 0;
        DWORD chunk = size > 65536 ? 65536 : size;
        if (!WriteFile(pipe, data, chunk, &written, NULL) || !written) {
            return 0;
        }
        data += written;
        size -= written;
    }
    return 1;
}

static DWORD WINAPI image_write_thread(LPVOID context) {
    struct image_writer *writer = context;
    int ok = image_write_all(writer->pipe, writer->header, WN_IMAGE_HEADER) &&
             image_write_all(writer->pipe, writer->data, writer->size);
    CloseHandle(writer->pipe);
    return ok ? 0 : 1;
}

static wchar_t *image_wide(const char *text) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (!count) {
        return NULL;
    }
    wchar_t *wide = malloc((size_t)count * sizeof(*wide));
    if (wide && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide, count)) {
        free(wide);
        wide = NULL;
    }
    return wide;
}

static HANDLE image_job(void) {
    HANDLE job = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_PROCESS_MEMORY |
        JOB_OBJECT_LIMIT_PROCESS_TIME | JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
    limits.ProcessMemoryLimit = WN_IMAGE_MEMORY_MAX;
    limits.BasicLimitInformation.PerProcessUserTimeLimit.QuadPart = 5 * 10000000LL;
    limits.BasicLimitInformation.ActiveProcessLimit = 1;
    if (job &&
        !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
        CloseHandle(job);
        job = NULL;
    }
    return job;
}

static int image_run(const char *helper, const unsigned char *data, int size,
                     const unsigned char *header, struct image_reply *reply) {
    ULONGLONG deadline = GetTickCount64() + WN_IMAGE_SECONDS * 1000;
    SECURITY_ATTRIBUTES security = {sizeof(security), NULL, TRUE};
    HANDLE child_in = NULL, input = NULL, output = NULL, child_out = NULL;
    HANDLE null = INVALID_HANDLE_VALUE, job = NULL, writer = NULL;
    PROCESS_INFORMATION process = {0};
    STARTUPINFOEXW start = {0};
    SIZE_T attribute_size = 0;
    int attributes_ready = 0;
    int ok = 0;
    wchar_t *path = image_wide(helper);
    wchar_t *command = NULL;
    struct image_writer request = {0};
    if (!path || wcschr(path, L'"')) {
        goto done;
    }
    size_t length = wcslen(path);
    command = malloc((length + 3) * sizeof(*command));
    if (!command) {
        goto done;
    }
    command[0] = L'"';
    memcpy(command + 1, path, length * sizeof(*path));
    command[length + 1] = L'"';
    command[length + 2] = 0;
    if (!CreatePipe(&child_in, &input, &security, 0) ||
        !SetHandleInformation(input, HANDLE_FLAG_INHERIT, 0) ||
        !CreatePipe(&output, &child_out, &security, 0) ||
        !SetHandleInformation(output, HANDLE_FLAG_INHERIT, 0)) {
        goto done;
    }
    null = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &security,
                       OPEN_EXISTING, 0, NULL);
    job = image_job();
    if (null == INVALID_HANDLE_VALUE || !job) {
        goto done;
    }
    InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_size);
    start.lpAttributeList = malloc(attribute_size);
    if (!start.lpAttributeList ||
        !InitializeProcThreadAttributeList(start.lpAttributeList, 1, 0, &attribute_size)) {
        goto done;
    }
    attributes_ready = 1;
    HANDLE inherited[3] = {child_in, child_out, null};
    if (!UpdateProcThreadAttribute(start.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                   inherited, sizeof(inherited), NULL, NULL)) {
        goto done;
    }
    start.StartupInfo.cb = sizeof(start);
    start.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    start.StartupInfo.hStdInput = child_in;
    start.StartupInfo.hStdOutput = child_out;
    start.StartupInfo.hStdError = null;
    wchar_t environment[2] = {0, 0};
    if (!CreateProcessW(path, command, NULL, NULL, TRUE,
                        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT |
                            CREATE_NO_WINDOW | CREATE_SUSPENDED,
                        environment, NULL, &start.StartupInfo, &process)) {
        goto done;
    }
    if (!AssignProcessToJobObject(job, process.hProcess) ||
        ResumeThread(process.hThread) == (DWORD)-1) {
        goto done;
    }
    CloseHandle(child_in);
    child_in = NULL;
    CloseHandle(child_out);
    child_out = NULL;
    request.pipe = input;
    request.header = header;
    request.data = data;
    request.size = (DWORD)size;
    writer = CreateThread(NULL, 0, image_write_thread, &request, 0, NULL);
    if (!writer) {
        goto done;
    }
    input = NULL; /* The writer owns this handle until its thread terminates. */
    int eof = 0;
    while (GetTickCount64() < deadline) {
        DWORD available = 0;
        if (!eof && !PeekNamedPipe(output, NULL, 0, NULL, &available, NULL)) {
            if (GetLastError() != ERROR_BROKEN_PIPE) {
                goto done;
            }
            eof = 1;
        }
        if (available) {
            size_t capacity;
            unsigned char *buffer = image_buffer(reply, &capacity);
            DWORD count = 0;
            if (capacity > available) {
                capacity = available;
            }
            if (!ReadFile(output, buffer, (DWORD)capacity, &count, NULL) || !count ||
                !image_received(reply, count)) {
                goto done;
            }
            continue;
        }
        if (eof && WaitForSingleObject(process.hProcess, 0) == WAIT_OBJECT_0 &&
            WaitForSingleObject(writer, 0) == WAIT_OBJECT_0) {
            DWORD status = 1, write_status = 1;
            ok = GetExitCodeProcess(process.hProcess, &status) && status == 0 &&
                 GetExitCodeThread(writer, &write_status) && write_status == 0 &&
                 image_complete(reply);
            break;
        }
        Sleep(1);
    }
done:
    if (process.hProcess && !ok) {
        TerminateProcess(process.hProcess, 1);
    }
    if (job) {
        CloseHandle(job);
    }
    if (child_in) {
        CloseHandle(child_in);
    }
    if (child_out) {
        CloseHandle(child_out);
    }
    if (writer) {
        CancelSynchronousIo(writer);
        WaitForSingleObject(writer, INFINITE);
        CloseHandle(writer);
    }
    if (process.hProcess) {
        WaitForSingleObject(process.hProcess, INFINITE);
        CloseHandle(process.hProcess);
        CloseHandle(process.hThread);
    }
    if (input) {
        CloseHandle(input);
    }
    if (output) {
        CloseHandle(output);
    }
    if (null != INVALID_HANDLE_VALUE) {
        CloseHandle(null);
    }
    if (attributes_ready) {
        DeleteProcThreadAttributeList(start.lpAttributeList);
    }
    free(start.lpAttributeList);
    free(command);
    free(path);
    return ok;
}
#else
static int64_t image_millis(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) {
        return -1;
    }
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int image_high_fd(int fd) {
    if (fd < 0 || fd > STDERR_FILENO) {
        return fd;
    }
    int high = fcntl(fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
    close(fd);
    return high;
}

static pid_t image_spawn(const char *helper, int socket, int null) {
    char *args[] = {(char *)helper, NULL};
    char *environment[] = {NULL};
#ifdef __APPLE__
    /* CLOEXEC_DEFAULT also excludes descriptors opened concurrently elsewhere. */
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    if (posix_spawn_file_actions_init(&actions)) {
        return -1;
    }
    if (posix_spawnattr_init(&attributes)) {
        posix_spawn_file_actions_destroy(&actions);
        return -1;
    }
    pid_t child = -1;
    if (!posix_spawn_file_actions_adddup2(&actions, socket, STDIN_FILENO) &&
        !posix_spawn_file_actions_adddup2(&actions, socket, STDOUT_FILENO) &&
        !posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO) &&
        !posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT)) {
        if (posix_spawn(&child, helper, &actions, &attributes, args, environment)) {
            child = -1;
        }
    }
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    return child;
#else
    pid_t child = fork();
    if (child != 0) {
        return child;
    }
    /* Only async-signal-safe operations are allowed after a multithreaded fork. */
    if (dup2(socket, STDIN_FILENO) < 0 || dup2(socket, STDOUT_FILENO) < 0 ||
        dup2(null, STDERR_FILENO) < 0) {
        _exit(1);
    }
#ifdef __OpenBSD__
    closefrom(STDERR_FILENO + 1);
#elif defined(__linux__)
#ifdef SYS_close_range
    if (syscall(SYS_close_range, STDERR_FILENO + 1, ~0u, 0)) {
        _exit(1);
    }
#else
#error "Image isolation requires Linux close_range support"
#endif
#else
#error "Image isolation needs a close-all-descriptors implementation on this target"
#endif
    execve(helper, args, environment);
    _exit(1);
#endif
}

static int image_run(const char *helper, const unsigned char *data, int size,
                     const unsigned char *header, struct image_reply *reply) {
    int64_t start = image_millis();
    if (start < 0) {
        return 0;
    }
    int64_t deadline = start + WN_IMAGE_SECONDS * 1000;
    int pair[2];
#ifdef __APPLE__
    int socket_type = SOCK_STREAM;
#else
    int socket_type = SOCK_STREAM | SOCK_CLOEXEC;
#endif
    if (socketpair(AF_UNIX, socket_type, 0, pair)) {
        return 0;
    }
#ifdef __APPLE__
    /* Darwin has no atomic SOCK_CLOEXEC; image spawns also use CLOEXEC_DEFAULT. */
    if (fcntl(pair[0], F_SETFD, FD_CLOEXEC) || fcntl(pair[1], F_SETFD, FD_CLOEXEC)) {
        close(pair[0]);
        close(pair[1]);
        return 0;
    }
#endif
    pair[0] = image_high_fd(pair[0]);
    pair[1] = image_high_fd(pair[1]);
    int null = image_high_fd(open("/dev/null", O_WRONLY | O_CLOEXEC));
    pid_t child = -1;
    int ok = 0;
    if (pair[0] < 0 || pair[1] < 0 || null < 0) {
        goto done;
    }
#ifdef SO_NOSIGPIPE
    int one = 1;
    if (setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one))) {
        goto done;
    }
#endif
    int flags = fcntl(pair[0], F_GETFL);
    if (flags < 0 || fcntl(pair[0], F_SETFL, flags | O_NONBLOCK)) {
        goto done;
    }
    child = image_spawn(helper, pair[1], null);
    close(pair[1]);
    pair[1] = -1;
    close(null);
    null = -1;
    if (child < 0) {
        goto done;
    }
    size_t sent = 0;
    size_t total = WN_IMAGE_HEADER + (size_t)size;
    int eof = 0;
    while (1) {
        int64_t now = image_millis();
        if (now < 0 || now >= deadline) {
            break;
        }
        if (eof) {
            int status;
            pid_t waited = waitpid(child, &status, WNOHANG);
            if (waited == child) {
                child = -1;
                ok = sent == total && image_complete(reply) && WIFEXITED(status) &&
                     WEXITSTATUS(status) == 0;
                break;
            }
            if (waited < 0 && errno != EINTR) {
                /* ECHILD means a process-wide SIGCHLD handler already reaped it. */
                if (errno == ECHILD) {
                    child = -1;
                }
                break;
            }
            struct timespec pause = {0, 1000000};
            nanosleep(&pause, NULL);
            continue;
        }
        struct pollfd pollfd = {pair[0], POLLIN, 0};
        if (sent < total) {
            pollfd.events |= POLLOUT;
        }
        int ready = poll(&pollfd, 1, (int)(deadline - now));
        if (ready < 0 && errno == EINTR) {
            continue;
        }
        if (ready <= 0 || (pollfd.revents & POLLNVAL)) {
            break;
        }
        if (pollfd.revents & (POLLIN | POLLHUP | POLLERR)) {
            size_t capacity;
            unsigned char *buffer = image_buffer(reply, &capacity);
            ssize_t count = recv(pair[0], buffer, capacity, 0);
            if (count > 0) {
                if (!image_received(reply, (size_t)count)) {
                    break;
                }
            } else if (count == 0) {
                eof = 1;
                if (!image_complete(reply) || sent != total) {
                    break;
                }
            } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                break;
            }
        }
        if ((pollfd.revents & POLLOUT) && sent < total) {
            const unsigned char *buffer;
            size_t count;
            if (sent < WN_IMAGE_HEADER) {
                buffer = header + sent;
                count = WN_IMAGE_HEADER - sent;
            } else {
                buffer = data + sent - WN_IMAGE_HEADER;
                count = total - sent;
                if (count > 65536) {
                    count = 65536;
                }
            }
#ifdef MSG_NOSIGNAL
            int send_flags = MSG_NOSIGNAL;
#else
            int send_flags = 0;
#endif
            ssize_t written = send(pair[0], buffer, count, send_flags);
            if (written > 0) {
                sent += (size_t)written;
                if (sent == total && shutdown(pair[0], SHUT_WR)) {
                    break;
                }
            } else if (written == 0 ||
                       (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
                break;
            }
        }
    }
done:
    if (pair[0] >= 0) {
        close(pair[0]);
    }
    if (pair[1] >= 0) {
        close(pair[1]);
    }
    if (null >= 0) {
        close(null);
    }
    if (child > 0) {
        kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {
        }
    }
    return ok;
}
#endif

unsigned char *wn_image_decode(const char *helper, const unsigned char *data, int size,
                               int max_dimension, unsigned int max_bytes, int *width, int *height) {
    if (width) {
        *width = 0;
    }
    if (height) {
        *height = 0;
    }
    if (!width || !height || !helper || !*helper || !data || size <= 0 ||
        (unsigned int)size > WN_IMAGE_INPUT_MAX || max_dimension <= 0 ||
        (unsigned int)max_dimension > WN_IMAGE_DIM_MAX || !max_bytes ||
        max_bytes > WN_IMAGE_OUTPUT_MAX) {
        return NULL;
    }
    unsigned char header[WN_IMAGE_HEADER];
    memcpy(header, "WNI1", 4);
    wn_image_put(header + 4, (uint32_t)size);
    wn_image_put(header + 8, (uint32_t)max_dimension);
    wn_image_put(header + 12, max_bytes);
    struct image_reply reply = {0};
    reply.dimension = (uint32_t)max_dimension;
    reply.cap = max_bytes;
    if (!image_run(helper, data, size, header, &reply)) {
        free(reply.pixels);
        return NULL;
    }
    *width = (int)reply.width;
    *height = (int)reply.height;
    return reply.pixels;
}
