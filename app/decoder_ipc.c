/* Bounded process transport only: no document decoder is linked into the UI. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "decoder_ipc.h"
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
#include "decoder_limits.h"
#ifdef __OpenBSD__
/* The standalone transport tests do not link the application's launcher. */
extern int wn_helper_execve(const char *, char *const[], char *const[]) __attribute__((weak));
#endif

enum decoder_kind {
    DECODER_IMAGE,
    DECODER_ARCHIVE,
    DECODER_PDF,
    DECODER_MESH,
    DECODER_MODEL,
    DECODER_MATH
};

struct image_reply {
    unsigned char header[WN_IMAGE_HEADER];
    unsigned char page_header[4];
    unsigned char extra;
    unsigned char *pixels;
    size_t received;
    uint32_t bytes;
    uint32_t width;
    uint32_t height;
    uint32_t dimension;
    uint32_t cap;
    enum decoder_kind kind;
    WnArchiveOp op;
    uint32_t index;
    uint32_t count;
    uint32_t target_height;
    uint32_t sequence;
    int borrowed;
};

/* Read directly into its final destination, with one byte reserved to detect excess. */
static unsigned char *image_buffer(struct image_reply *reply, size_t *size) {
    if (reply->received < WN_IMAGE_HEADER) {
        *size = WN_IMAGE_HEADER - reply->received;
        return reply->header + reply->received;
    }
    size_t offset = reply->received - WN_IMAGE_HEADER;
    if (reply->kind == DECODER_PDF) {
        if (offset < 4) {
            *size = 4 - offset;
            return reply->page_header + offset;
        }
        offset -= 4;
    }
    size_t bytes = reply->bytes - (reply->kind == DECODER_PDF ? 4u : 0u);
    if (offset < bytes) {
        *size = bytes - offset;
        if (*size > 65536) {
            *size = 65536;
        }
        return reply->pixels + offset;
    }
    *size = 1;
    return &reply->extra;
}

static int decoder_header(struct image_reply *reply) {
    const unsigned char *header = reply->header;
    reply->bytes = wn_image_u32(header + 12);
    if (reply->kind == DECODER_MESH || reply->kind == DECODER_MODEL) {
        int mesh = reply->kind == DECODER_MESH;
        if (memcmp(header, mesh ? "MDO1" : "FBO1", 4) ||
            wn_image_u32(header + 4) != (mesh ? 1u : reply->index) ||
            wn_image_u32(header + 8) != (mesh ? 0u : reply->sequence) ||
            reply->bytes > reply->cap) {
            return 0;
        }
    } else if (reply->kind == DECODER_ARCHIVE) {
        reply->count = wn_image_u32(header + 4);
        uint32_t index = wn_image_u32(header + 8);
        if (memcmp(header, "ARO1", 4) || reply->bytes > reply->cap) {
            return 0;
        }
        if (reply->op == WN_ARCHIVE_LIST) {
            if (reply->count > WN_ARCHIVE_COUNT_MAX || index ||
                (uint64_t)reply->count * 17 > reply->bytes || (!reply->count && reply->bytes)) {
                return 0;
            }
        } else if (reply->count || index != reply->index) {
            return 0;
        }
    } else {
        reply->width = wn_image_u32(header + 4);
        reply->height = wn_image_u32(header + 8);
        uint64_t expected = (uint64_t)reply->width * reply->height * 4;
        int pdf = reply->kind == DECODER_PDF;
        const char *magic = pdf ? "PDO1" : reply->kind == DECODER_MATH ? "MAO1" : "WNO1";
        if (memcmp(header, magic, 4) || !reply->width || !reply->height ||
            reply->width > reply->dimension ||
            reply->height > (pdf ? WN_PDF_DIM_MAX : reply->dimension) ||
            (pdf && reply->target_height && reply->height > reply->target_height) ||
            expected > reply->cap || expected + (pdf ? 4u : 0u) != reply->bytes) {
            return 0;
        }
        if (pdf) {
            return 1; /* Validate page count before allocating pixels. */
        }
    }
    if (!reply->borrowed) {
        reply->pixels = malloc(reply->bytes ? reply->bytes : 1);
    }
    return reply->pixels != NULL;
}

static int image_received(struct image_reply *reply, size_t size) {
    if (reply->received >= WN_IMAGE_HEADER + (size_t)reply->bytes &&
        reply->received >= WN_IMAGE_HEADER) {
        return 0;
    }
    reply->received += size;
    if (reply->received == WN_IMAGE_HEADER) {
        return decoder_header(reply);
    }
    if (reply->kind == DECODER_PDF && reply->received == WN_IMAGE_HEADER + 4) {
        reply->count = wn_image_u32(reply->page_header);
        if (!reply->count || reply->count > WN_PDF_PAGES_MAX || reply->index >= reply->count) {
            return 0;
        }
        reply->pixels = malloc(reply->bytes - 4);
        return reply->pixels != NULL;
    }
    return 1;
}

static int image_complete(const struct image_reply *reply) {
    return reply->pixels && reply->received == WN_IMAGE_HEADER + (size_t)reply->bytes;
}

/* Spawn and transport are shared by one-shot decoders and persistent models. */
#ifdef _WIN32
struct decoder_process {
    HANDLE process;
    HANDLE job;
    HANDLE input;
    HANDLE output;
    HANDLE writer;
    HANDLE start_write;
    HANDLE write_done;
    volatile LONG stop;
    const unsigned char *header;
    const unsigned char *data;
    DWORD size;
    DWORD header_size;
    int finish;
    int write_ok;
};

static int64_t image_millis(void) {
    return (int64_t)GetTickCount64();
}

static int image_write_all(struct decoder_process *process, const unsigned char *data, DWORD size) {
    while (size && !InterlockedCompareExchange(&process->stop, 0, 0)) {
        DWORD written = 0;
        DWORD chunk = size > 65536 ? 65536 : size;
        if (!WriteFile(process->input, data, chunk, &written, NULL) || !written) {
            return 0;
        }
        data += written;
        size -= written;
    }
    return size == 0;
}

/* One worker per helper, never one per pose. Closing the job breaks blocked writes;
 * stop plus the wake event also covers a worker idle between transactions. */
static DWORD WINAPI image_write_thread(LPVOID context) {
    struct decoder_process *process = context;
    while (WaitForSingleObject(process->start_write, INFINITE) == WAIT_OBJECT_0) {
        if (InterlockedCompareExchange(&process->stop, 0, 0)) {
            break;
        }
        process->write_ok = image_write_all(process, process->header, process->header_size) &&
                            image_write_all(process, process->data, process->size);
        if (process->finish) {
            CloseHandle(process->input);
            process->input = NULL;
        }
        SetEvent(process->write_done);
    }
    return 0;
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

static HANDLE image_job(WnDecoderLifetime lifetime) {
    HANDLE job = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
                                              JOB_OBJECT_LIMIT_PROCESS_MEMORY |
                                              JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
    limits.ProcessMemoryLimit = WN_IMAGE_MEMORY_MAX;
    if (lifetime == WN_DECODER_ONESHOT) {
        limits.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_PROCESS_TIME;
        limits.BasicLimitInformation.PerProcessUserTimeLimit.QuadPart = 5 * 10000000LL;
    }
    limits.BasicLimitInformation.ActiveProcessLimit = 1;
    if (job &&
        !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
        CloseHandle(job);
        job = NULL;
    }
    return job;
}

/* Quote one CRT argv element, including quotes and trailing backslashes. */
static wchar_t *decoder_quote(wchar_t *out, const wchar_t *text) {
    *out++ = L'"';
    while (*text) {
        size_t slashes = 0;
        while (*text == L'\\') {
            ++slashes;
            ++text;
        }
        size_t copies = (*text == L'"' || !*text) ? slashes * 2 : slashes;
        while (copies--) {
            *out++ = L'\\';
        }
        if (!*text) {
            break;
        }
        if (*text == L'"') {
            *out++ = L'\\';
        }
        *out++ = *text++;
    }
    *out++ = L'"';
    return out;
}

static void decoder_stop(struct decoder_process *process) {
    InterlockedExchange(&process->stop, 1);
    if (process->process) {
        TerminateProcess(process->process, 1);
    }
    if (process->job) {
        CloseHandle(process->job);
        process->job = NULL;
    }
    if (process->writer) {
        SetEvent(process->start_write);
        CancelSynchronousIo(process->writer);
        WaitForSingleObject(process->writer, INFINITE);
        CloseHandle(process->writer);
        process->writer = NULL;
    }
    if (process->process) {
        WaitForSingleObject(process->process, INFINITE);
        CloseHandle(process->process);
        process->process = NULL;
    }
    if (process->input) {
        CloseHandle(process->input);
        process->input = NULL;
    }
    if (process->output) {
        CloseHandle(process->output);
        process->output = NULL;
    }
    if (process->start_write) {
        CloseHandle(process->start_write);
        process->start_write = NULL;
    }
    if (process->write_done) {
        CloseHandle(process->write_done);
        process->write_done = NULL;
    }
}

static int decoder_start(struct decoder_process *child, const char *helper, const char *argument,
                         WnDecoderLifetime lifetime) {
    memset(child, 0, sizeof(*child));
    SECURITY_ATTRIBUTES security = {sizeof(security), NULL, TRUE};
    HANDLE child_in = NULL, child_out = NULL, null = INVALID_HANDLE_VALUE;
    PROCESS_INFORMATION process = {0};
    STARTUPINFOEXW start = {0};
    SIZE_T attribute_size = 0;
    int attributes_ready = 0;
    int ok = 0;
    wchar_t *path = image_wide(helper);
    wchar_t *arg = argument ? image_wide(argument) : NULL;
    wchar_t *command = NULL;
    if (!path || wcschr(path, L'"') || (argument && !arg)) {
        goto done;
    }
    size_t length = wcslen(path);
    size_t arg_length = arg ? wcslen(arg) : 0;
    if (length > 32767 || arg_length > 32767) {
        goto done;
    }
    command = malloc((length + arg_length * 2 + 7) * sizeof(*command));
    if (!command) {
        goto done;
    }
    command[0] = L'"';
    memcpy(command + 1, path, length * sizeof(*path));
    command[length + 1] = L'"';
    wchar_t *end = command + length + 2;
    if (arg) {
        *end++ = L' ';
        end = decoder_quote(end, arg);
    }
    *end = 0;
    if (!CreatePipe(&child_in, &child->input, &security, 0) ||
        !SetHandleInformation(child->input, HANDLE_FLAG_INHERIT, 0) ||
        !CreatePipe(&child->output, &child_out, &security, 0) ||
        !SetHandleInformation(child->output, HANDLE_FLAG_INHERIT, 0)) {
        goto done;
    }
    null = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &security,
                       OPEN_EXISTING, 0, NULL);
    child->job = image_job(lifetime);
    if (null == INVALID_HANDLE_VALUE || !child->job) {
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
    child->process = process.hProcess;
    if (!AssignProcessToJobObject(child->job, process.hProcess) ||
        ResumeThread(process.hThread) == (DWORD)-1) {
        goto done;
    }
    child->start_write = CreateEventW(NULL, FALSE, FALSE, NULL);
    child->write_done = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!child->start_write || !child->write_done) {
        goto done;
    }
    child->writer = CreateThread(NULL, 0, image_write_thread, child, 0, NULL);
    ok = child->writer != NULL;
done:
    if (child_in) {
        CloseHandle(child_in);
    }
    if (child_out) {
        CloseHandle(child_out);
    }
    if (null != INVALID_HANDLE_VALUE) {
        CloseHandle(null);
    }
    if (process.hThread) {
        CloseHandle(process.hThread);
    }
    if (attributes_ready) {
        DeleteProcThreadAttributeList(start.lpAttributeList);
    }
    free(start.lpAttributeList);
    free(command);
    free(path);
    free(arg);
    if (!ok) {
        decoder_stop(child);
    }
    return ok;
}

static int decoder_transfer(struct decoder_process *process, const unsigned char *data,
                            unsigned int size, const unsigned char *header, size_t header_size,
                            struct image_reply *reply, int finish, int64_t deadline) {
    DWORD available = 0;
    if (!PeekNamedPipe(process->output, NULL, 0, NULL, &available, NULL) || available ||
        WaitForSingleObject(process->process, 0) != WAIT_TIMEOUT) {
        return 0;
    }
    process->header = header;
    process->header_size = (DWORD)header_size;
    process->data = data;
    process->size = size;
    process->finish = finish;
    process->write_ok = 0;
    if (!ResetEvent(process->write_done) || !SetEvent(process->start_write)) {
        return 0;
    }
    int eof = 0;
    while (image_millis() < deadline) {
        available = 0;
        if (!eof && !PeekNamedPipe(process->output, NULL, 0, NULL, &available, NULL)) {
            if (GetLastError() != ERROR_BROKEN_PIPE) {
                return 0;
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
            if (!ReadFile(process->output, buffer, (DWORD)capacity, &count, NULL) || !count ||
                !image_received(reply, count)) {
                return 0;
            }
            continue;
        }
        int written = WaitForSingleObject(process->write_done, 0) == WAIT_OBJECT_0;
        if (written && !process->write_ok) {
            return 0;
        }
        if (!finish) {
            if (eof || WaitForSingleObject(process->process, 0) != WAIT_TIMEOUT) {
                return 0;
            }
            if (written && image_complete(reply)) {
                return 1;
            }
        } else if (eof && written && WaitForSingleObject(process->process, 0) == WAIT_OBJECT_0) {
            DWORD status = 1;
            return GetExitCodeProcess(process->process, &status) && status == 0 &&
                   image_complete(reply);
        }
        Sleep(1);
    }
    return 0;
}
#else
struct decoder_process {
    pid_t child;
    int socket;
    int reaped;
};

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

static pid_t image_spawn(const char *helper, const char *argument, int socket, int null) {
    char *args[] = {(char *)helper, (char *)argument, NULL};
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
        !posix_spawnattr_setpgroup(&attributes, 0) &&
        !posix_spawnattr_setflags(&attributes,
                                  POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)) {
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
    if (setpgid(0, 0) || dup2(socket, STDIN_FILENO) < 0 || dup2(socket, STDOUT_FILENO) < 0 ||
        dup2(null, STDERR_FILENO) < 0) {
        _exit(1);
    }
#ifdef __OpenBSD__
    if (wn_helper_execve) {
        wn_helper_execve(helper, args, environment);
        if (errno != ENOSYS) {
            _exit(1);
        }
    }
    closefrom(STDERR_FILENO + 1);
#elif defined(__linux__)
#ifdef SYS_close_range
    if (syscall(SYS_close_range, STDERR_FILENO + 1, ~0u, 0)) {
        _exit(1);
    }
#else
#error "Decoder isolation requires Linux close_range support"
#endif
#else
#error "Decoder isolation needs a close-all-descriptors implementation on this target"
#endif
    execve(helper, args, environment);
    _exit(1);
#endif
}

static void decoder_stop(struct decoder_process *process) {
    if (process->socket >= 0) {
        close(process->socket);
        process->socket = -1;
    }
    if (process->child > 0) {
        if (!process->reaped) {
            /* Signal the private group only while its leader's PID is still owned. */
            kill(-process->child, SIGKILL);
            kill(process->child, SIGKILL);
            while (waitpid(process->child, NULL, 0) < 0 && errno == EINTR) {
            }
        }
        process->child = -1;
    }
}

static int decoder_start(struct decoder_process *process, const char *helper, const char *argument,
                         WnDecoderLifetime lifetime) {
    (void)lifetime; /* POSIX helpers install their own limits before parsing input. */
    process->child = -1;
    process->socket = -1;
    process->reaped = 0;
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
    /* Darwin has no atomic SOCK_CLOEXEC; spawns also use CLOEXEC_DEFAULT. */
    if (fcntl(pair[0], F_SETFD, FD_CLOEXEC) || fcntl(pair[1], F_SETFD, FD_CLOEXEC)) {
        close(pair[0]);
        close(pair[1]);
        return 0;
    }
#endif
    pair[0] = image_high_fd(pair[0]);
    pair[1] = image_high_fd(pair[1]);
    int null = image_high_fd(open("/dev/null", O_WRONLY | O_CLOEXEC));
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
    process->child = image_spawn(helper, argument, pair[1], null);
    if (process->child < 0) {
        goto done;
    }
    process->socket = pair[0];
    pair[0] = -1;
    ok = 1;
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
    return ok;
}

static int decoder_transfer(struct decoder_process *process, const unsigned char *data,
                            unsigned int size, const unsigned char *header, size_t header_size,
                            struct image_reply *reply, int finish, int64_t deadline) {
    unsigned char extra;
    ssize_t pending = recv(process->socket, &extra, 1, MSG_PEEK);
    if (pending >= 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
        return 0;
    }
    size_t sent = 0;
    size_t total = header_size + (size_t)size;
    int eof = 0;
    while (1) {
        int64_t now = image_millis();
        if (now < 0 || now >= deadline) {
            return 0;
        }
        if (!finish && sent == total && image_complete(reply)) {
            pending = recv(process->socket, &extra, 1, MSG_PEEK);
            if (pending < 0 && errno == EINTR) {
                continue;
            }
            return pending < 0 && (errno == EAGAIN || errno == EWOULDBLOCK);
        }
        if (eof) {
            int status;
            pid_t waited = waitpid(process->child, &status, WNOHANG);
            if (waited == process->child) {
                process->reaped = 1;
                return sent == total && image_complete(reply) && WIFEXITED(status) &&
                       WEXITSTATUS(status) == 0;
            }
            if (waited < 0 && errno != EINTR) {
                if (errno == ECHILD) {
                    process->reaped = 1;
                }
                return 0;
            }
            struct timespec pause = {0, 1000000};
            nanosleep(&pause, NULL);
            continue;
        }
        struct pollfd pollfd = {process->socket, POLLIN, 0};
        if (sent < total) {
            pollfd.events |= POLLOUT;
        }
        int ready = poll(&pollfd, 1, (int)(deadline - now));
        if (ready < 0 && errno == EINTR) {
            continue;
        }
        if (ready <= 0 || (pollfd.revents & POLLNVAL)) {
            return 0;
        }
        if (pollfd.revents & (POLLIN | POLLHUP | POLLERR)) {
            size_t capacity;
            unsigned char *buffer = image_buffer(reply, &capacity);
            ssize_t count = recv(process->socket, buffer, capacity, 0);
            if (count > 0) {
                if (!image_received(reply, (size_t)count)) {
                    return 0;
                }
            } else if (count == 0) {
                eof = 1;
                if (!finish || !image_complete(reply) || sent != total) {
                    return 0;
                }
            } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                return 0;
            }
        }
        if ((pollfd.revents & POLLOUT) && sent < total) {
            const unsigned char *buffer;
            size_t count;
            if (sent < header_size) {
                buffer = header + sent;
                count = header_size - sent;
            } else {
                buffer = data + sent - header_size;
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
            ssize_t written = send(process->socket, buffer, count, send_flags);
            if (written > 0) {
                sent += (size_t)written;
                if (finish && sent == total && shutdown(process->socket, SHUT_WR)) {
                    return 0;
                }
            } else if (written == 0 ||
                       (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
                return 0;
            }
        }
    }
}
#endif

static int image_run(const char *helper, const char *argument, const unsigned char *data, int size,
                     const unsigned char *header, size_t header_size, struct image_reply *reply) {
    int64_t start = image_millis();
    struct decoder_process process;
    if (start < 0 || !decoder_start(&process, helper, argument, WN_DECODER_ONESHOT)) {
        return 0;
    }
    int ok = decoder_transfer(&process, data, (unsigned int)size, header, header_size, reply, 1,
                              start + WN_IMAGE_SECONDS * 1000);
    decoder_stop(&process);
    return ok;
}

struct WnModelSession {
    struct decoder_process process;
    int active;
    uint32_t sequence;
};

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
    if (!image_run(helper, NULL, data, size, header, sizeof(header), &reply)) {
        free(reply.pixels);
        return NULL;
    }
    *width = (int)reply.width;
    *height = (int)reply.height;
    return reply.pixels;
}

unsigned char *wn_math_render(const char *helper, const unsigned char *data, int size,
                              float font_size, unsigned int argb, unsigned int max_side,
                              unsigned int max_bytes, int *width, int *height) {
    if (width) {
        *width = 0;
    }
    if (height) {
        *height = 0;
    }
    if (!width || !height || !helper || !*helper || !data || size <= 0 ||
        (unsigned int)size > WN_MATH_INPUT_MAX ||
        !(font_size > 0 && font_size <= WN_MATH_DIM_MAX) || !max_side ||
        max_side > WN_MATH_DIM_MAX || !max_bytes || max_bytes > WN_MATH_OUTPUT_MAX ||
        memchr(data, 0, (size_t)size)) {
        return NULL;
    }
    uint32_t font_bits;
    _Static_assert(sizeof(font_size) == sizeof(font_bits), "math wire requires 32-bit float");
    memcpy(&font_bits, &font_size, sizeof(font_bits));
    unsigned char header[WN_MATH_REQUEST_HEADER];
    memcpy(header, "MAI1", 4);
    wn_image_put(header + 4, (uint32_t)size);
    wn_image_put(header + 8, font_bits);
    wn_image_put(header + 12, argb);
    wn_image_put(header + 16, max_side);
    wn_image_put(header + 20, max_bytes);
    struct image_reply reply = {0};
    reply.kind = DECODER_MATH;
    reply.dimension = max_side;
    reply.cap = max_bytes;
    if (!image_run(helper, NULL, data, size, header, sizeof(header), &reply)) {
        free(reply.pixels);
        return NULL;
    }
    *width = (int)reply.width;
    *height = (int)reply.height;
    return reply.pixels;
}

unsigned char *wn_archive_read(const char *helper, const unsigned char *data, int size,
                               WnArchiveOp op, unsigned int index, unsigned int *count,
                               unsigned int *length) {
    if (count) {
        *count = 0;
    }
    if (length) {
        *length = 0;
    }
    if (!count || !length || !helper || !*helper || !data || size <= 0 ||
        (unsigned int)size > WN_ARCHIVE_INPUT_MAX ||
        (op != WN_ARCHIVE_LIST && op != WN_ARCHIVE_ENTRY) || (op == WN_ARCHIVE_LIST && index) ||
        index >= WN_ARCHIVE_SCAN_MAX) {
        return NULL;
    }
    unsigned char header[16];
    memcpy(header, "ARI1", 4);
    wn_image_put(header + 4, (uint32_t)size);
    wn_image_put(header + 8, (uint32_t)op);
    wn_image_put(header + 12, index);
    struct image_reply reply = {0};
    reply.kind = DECODER_ARCHIVE;
    reply.op = op;
    reply.index = index;
    reply.cap = op == WN_ARCHIVE_LIST ? WN_ARCHIVE_LIST_MAX : WN_ARCHIVE_ENTRY_MAX;
    if (!image_run(helper, NULL, data, size, header, sizeof(header), &reply)) {
        free(reply.pixels);
        return NULL;
    }
    *count = reply.count;
    *length = reply.bytes;
    return reply.pixels;
}

unsigned char *wn_pdf_render(const char *helper, const char *font_dir, const unsigned char *data,
                             int size, unsigned int page, unsigned int width, unsigned int height,
                             unsigned int *pages, unsigned int *out_width,
                             unsigned int *out_height) {
    if (pages) {
        *pages = 0;
    }
    if (out_width) {
        *out_width = 0;
    }
    if (out_height) {
        *out_height = 0;
    }
    if (!pages || !out_width || !out_height || !helper || !*helper || !data || size <= 0 ||
        (unsigned int)size > WN_PDF_INPUT_MAX || page >= WN_PDF_PAGES_MAX || !width ||
        width > WN_PDF_DIM_MAX || height > WN_PDF_DIM_MAX) {
        return NULL;
    }
    unsigned char header[20];
    memcpy(header, "PDI1", 4);
    wn_image_put(header + 4, (uint32_t)size);
    wn_image_put(header + 8, page);
    wn_image_put(header + 12, width);
    wn_image_put(header + 16, height);
    struct image_reply reply = {0};
    reply.kind = DECODER_PDF;
    reply.index = page;
    reply.dimension = width;
    reply.target_height = height;
    reply.cap = WN_PDF_OUTPUT_MAX;
    if (!image_run(helper, font_dir, data, size, header, sizeof(header), &reply)) {
        free(reply.pixels);
        return NULL;
    }
    *pages = reply.count;
    *out_width = reply.width;
    *out_height = reply.height;
    return reply.pixels;
}

unsigned char *wn_mesh_decode(const char *helper, const unsigned char *data, int size,
                              unsigned int format, unsigned int *length) {
    if (length) {
        *length = 0;
    }
    if (!length || !helper || !*helper || !data || size <= 0 ||
        (unsigned int)size > WN_MODEL_INPUT_MAX || format < WN_MESH_STL || format > WN_MESH_GCODE) {
        return NULL;
    }
    unsigned char header[16];
    memcpy(header, "MDI1", 4);
    wn_image_put(header + 4, (uint32_t)size);
    wn_image_put(header + 8, format);
    wn_image_put(header + 12, 0);
    struct image_reply reply = {0};
    reply.kind = DECODER_MESH;
    reply.cap = WN_MODEL_OUTPUT_MAX;
    if (!image_run(helper, NULL, data, size, header, sizeof(header), &reply)) {
        free(reply.pixels);
        return NULL;
    }
    *length = reply.bytes;
    return reply.pixels;
}

WnModelSession *wn_model_start(const char *helper) {
    if (!helper || !*helper) {
        return NULL;
    }
    WnModelSession *session = calloc(1, sizeof(*session));
    if (!session) {
        return NULL;
    }
    if (!decoder_start(&session->process, helper, NULL, WN_DECODER_SESSION)) {
        free(session);
        return NULL;
    }
    session->active = 1;
    return session;
}

unsigned char *wn_model_exchange(WnModelSession *session, unsigned int operation,
                                 const unsigned char *data, unsigned int size,
                                 unsigned char *output, unsigned int capacity,
                                 unsigned int *length) {
    if (length) {
        *length = 0;
    }
    if (!session || !session->active) {
        return NULL;
    }
    int64_t start = image_millis();
    if (!length || (size && !data) || size > WN_MODEL_INPUT_MAX || operation > WN_MODEL_POSE ||
        session->sequence == UINT32_MAX || start < 0) {
        decoder_stop(&session->process);
        session->active = 0;
        return NULL;
    }
    unsigned char header[16];
    memcpy(header, "FBI1", 4);
    wn_image_put(header + 4, operation);
    wn_image_put(header + 8, size);
    wn_image_put(header + 12, ++session->sequence);
    struct image_reply reply = {0};
    reply.kind = DECODER_MODEL;
    reply.index = operation;
    reply.sequence = session->sequence;
    reply.cap = output && capacity < WN_MODEL_OUTPUT_MAX ? capacity : WN_MODEL_OUTPUT_MAX;
    reply.pixels = output;
    reply.borrowed = output != NULL;
    if (!decoder_transfer(&session->process, data, size, header, sizeof(header), &reply, 0,
                          start + WN_IMAGE_SECONDS * 1000)) {
        decoder_stop(&session->process);
        session->active = 0;
        if (!reply.borrowed) {
            free(reply.pixels);
        }
        return NULL;
    }
    *length = reply.bytes;
    return reply.pixels;
}

void wn_model_close(WnModelSession *session) {
    if (session) {
        if (session->active) {
            decoder_stop(&session->process);
        }
        free(session);
    }
}
