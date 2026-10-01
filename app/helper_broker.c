#ifndef __OpenBSD__
#define _GNU_SOURCE
#endif
#include "helper_broker.h"
#include "main_sandbox.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif

static const char *const helper_names[] = {
    "wn-image",   "wn-archive", "wn-mesh", "wn-fbx", "wn-math",
    "wn-nes",     "wn-pdf",     "wn-font", "wn-stt", "wn-tts",
#ifndef __OpenBSD__
    "wn-webview",
#endif
};
#define HELPER_COUNT (sizeof(helper_names) / sizeof(helper_names[0]))
#define ARG_COUNT 64u
#define ARG_BYTES 16384u
#define JOB_COUNT 128u
#define REQUEST_MS 10000

/* The linker supplies this symbol when all ordinary execve calls are wrapped. */
extern int __real_execve(const char *, char *const[], char *const[]);

enum helper_kind { HELPER_DECODER, HELPER_PDF, HELPER_FONT, HELPER_OPTIONAL };
enum io_direction { IO_READ, IO_WRITE };
struct helper {
    char requested[PATH_MAX], executable[PATH_MAX];
    enum helper_kind kind;
};
struct request {
    uint32_t count, bytes;
};
struct reply {
    int error, status;
};

static struct helper frozen[HELPER_COUNT];
static size_t frozen_count;
static char font_root[PATH_MAX];
static char environment_bytes[ARG_BYTES];
static char *environment[24];
static int launch_fd = -1;
static pid_t launch_pid = -1;
static int descriptor_limit;
static volatile sig_atomic_t stopping;

static void request_stop(int signal_number) {
    (void)signal_number;
    stopping = 1;
}

static void child_changed(int signal_number) {
    /* Wake ppoll; waitpid below owns collection of the exit status. */
    (void)signal_number;
}

static int64_t milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) {
        return -1;
    }
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void close_above(int first) {
#ifdef __OpenBSD__
    closefrom(first);
#else
#ifdef SYS_close_range
    if (!syscall(SYS_close_range, (unsigned)first, ~0u, 0)) {
        return;
    }
#endif
    for (int fd = first; fd < descriptor_limit; ++fd) {
        close(fd);
    }
#endif
}

static int socket_pair(int pair[2]) {
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair)) {
        return -1;
    }
    for (int i = 0; i < 2; ++i) {
        if (pair[i] < 3) {
            int moved = fcntl(pair[i], F_DUPFD_CLOEXEC, 3);
            if (moved < 0) {
                int error = errno;
                close(pair[0]);
                close(pair[1]);
                errno = error;
                return -1;
            }
            close(pair[i]);
            pair[i] = moved;
        }
#ifdef SO_NOSIGPIPE
        int one = 1;
        if (setsockopt(pair[i], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one)) {
            int error = errno;
            close(pair[0]);
            close(pair[1]);
            errno = error;
            return -1;
        }
#endif
    }
    return 0;
}

static int send_flags(void) {
#ifdef MSG_NOSIGNAL
    return MSG_NOSIGNAL;
#else
    return 0;
#endif
}

/* Deadlines cover setup only. A running model session has no lifetime cap. */
static int transfer(int fd, void *bytes, size_t length, enum io_direction direction,
                    int64_t deadline) {
    unsigned char *cursor = bytes;
    while (length) {
        if (deadline) {
            int64_t now = milliseconds();
            if (stopping || now < 0 || now >= deadline) {
                errno = stopping ? ECANCELED : ETIMEDOUT;
                return -1;
            }
            struct pollfd item = {fd, direction == IO_WRITE ? POLLOUT : POLLIN, 0};
            int result = poll(&item, 1, (int)(deadline - now));
            if (result < 0 && errno == EINTR) {
                continue;
            }
            if (result <= 0) {
                if (!result) {
                    errno = ETIMEDOUT;
                }
                return -1;
            }
        }
        ssize_t count = direction == IO_WRITE ? send(fd, cursor, length, send_flags())
                                              : recv(fd, cursor, length, 0);
        if (count < 0 && (errno == EINTR || (deadline && errno == EAGAIN))) {
            continue;
        }
        if (count <= 0) {
            if (!count) {
                errno = EPIPE;
            }
            return -1;
        }
        cursor += count;
        length -= (size_t)count;
    }
    return 0;
}

/* One atomic byte and its rights on the shared stream: fork children never
 * allocate or take a lock that another app thread could have held at fork. */
static int send_channel(int channel) {
    int descriptors[4] = {channel};
    size_t count = 1;
    unsigned char mask = 0;
    for (int fd = 0; fd < 3; ++fd) {
        if (fcntl(fd, F_GETFD) >= 0) {
            descriptors[count++] = fd;
            mask |= (unsigned char)(1u << fd);
        } else if (errno != EBADF) {
            return -1;
        }
    }
    union {
        struct cmsghdr align;
        char bytes[CMSG_SPACE(sizeof descriptors)];
    } control = {0};
    struct iovec vector = {&mask, sizeof mask};
    struct msghdr message = {0};
    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control.bytes;
    message.msg_controllen = CMSG_SPACE(count * sizeof(int));
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(count * sizeof(int));
    memcpy(CMSG_DATA(header), descriptors, count * sizeof(int));
    ssize_t result;
    do {
        result = sendmsg(launch_fd, &message, send_flags());
    } while (result < 0 && errno == EINTR);
    return result == 1 ? 0 : -1;
}

/* Every received descriptor is closed, including truncated or invalid rights.
 * Normalize above 9 so the controller's fixed descriptor layout cannot collide. */
static int receive_channel(int socket, int descriptors[4], unsigned char *mask) {
    union {
        struct cmsghdr align;
        char bytes[CMSG_SPACE(4 * sizeof(int))];
    } control = {0};
    struct iovec vector = {mask, 1};
    struct msghdr message = {0};
    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control.bytes;
    message.msg_controllen = sizeof control.bytes;
    ssize_t bytes = recvmsg(socket, &message, 0);
    if (bytes <= 0) {
        return bytes < 0 && errno == EINTR ? 0 : -1;
    }
    size_t count = 0;
    int invalid = bytes != 1 || (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) || (*mask & ~7u);
    for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header;
         header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS ||
            header->cmsg_len < CMSG_LEN(0)) {
            invalid = 1;
            continue;
        }
        size_t size = header->cmsg_len - CMSG_LEN(0);
        if (size % sizeof(int)) {
            invalid = 1;
        }
        for (size_t offset = 0; offset + sizeof(int) <= size; offset += sizeof(int)) {
            int fd;
            memcpy(&fd, (char *)CMSG_DATA(header) + offset, sizeof fd);
            if (count == 4) {
                close(fd);
                invalid = 1;
            } else {
                descriptors[count++] = fd;
            }
        }
    }
    size_t wanted = 1;
    for (int fd = 0; fd < 3; ++fd) {
        wanted += (*mask >> fd) & 1u;
    }
    if (count != wanted) {
        invalid = 1;
    }
    for (size_t i = 0; i < count; ++i) {
        int moved = invalid ? -1 : fcntl(descriptors[i], F_DUPFD_CLOEXEC, 10);
        close(descriptors[i]);
        descriptors[i] = moved;
        if (moved < 0) {
            invalid = 1;
        }
    }
    if (invalid) {
        for (size_t i = 0; i < count; ++i) {
            if (descriptors[i] >= 0) {
                close(descriptors[i]);
            }
        }
        return 0;
    }
    return (int)count;
}

static int freeze_helpers(const char *const *helpers, size_t count, const char *resources) {
    if (count > HELPER_COUNT || (count && !helpers) || !resources) {
        return EINVAL;
    }
    font_root[0] = '\0';
    for (size_t i = 0; i < count; ++i) {
        if (!helpers[i] || strnlen(helpers[i], PATH_MAX) == PATH_MAX) {
            return EINVAL;
        }
        const char *name = strrchr(helpers[i], '/');
        name = name ? name + 1 : helpers[i];
        size_t kind = 0;
        while (kind < HELPER_COUNT && strcmp(name, helper_names[kind])) {
            ++kind;
        }
        if (kind == HELPER_COUNT) {
            return EPERM;
        }
        for (size_t j = 0; j < i; ++j) {
            const char *previous = strrchr(frozen[j].requested, '/');
            previous = previous ? previous + 1 : frozen[j].requested;
            if (!strcmp(name, previous)) {
                return EINVAL;
            }
        }
        strcpy(frozen[i].requested, helpers[i]);
        if (!realpath(helpers[i], frozen[i].executable)) {
            return errno;
        }
        frozen[i].kind = kind < 6    ? HELPER_DECODER
                         : kind == 6 ? HELPER_PDF
                         : kind == 7 ? HELPER_FONT
                                     : HELPER_OPTIONAL;
        if (frozen[i].kind == HELPER_PDF) {
            char fonts[PATH_MAX];
            if (snprintf(fonts, sizeof fonts, "%s/fonts", resources) >= (int)sizeof fonts) {
                return ENAMETOOLONG;
            }
            if (!realpath(fonts, font_root)) {
                return errno;
            }
        }
    }
    frozen_count = count;
    return 0;
}

static int freeze_environment(void) {
    static const char *const keys[] = {"HOME",
                                       "DISPLAY",
                                       "XAUTHORITY",
                                       "DBUS_SESSION_BUS_ADDRESS",
                                       "XDG_CONFIG_HOME",
                                       "XDG_DATA_HOME",
                                       "XDG_CACHE_HOME",
                                       "XDG_RUNTIME_DIR",
                                       "LANG",
                                       "LANGUAGE",
                                       "LC_ALL",
                                       "LC_CTYPE",
                                       "LC_MESSAGES",
                                       "TZ",
                                       "TMPDIR",
                                       "SQLITE_TMPDIR",
                                       "MESA_SHADER_CACHE_DIR"};
    size_t used = 0, count = 0;
    environment[count++] = "PATH=/usr/local/bin:/usr/bin:/bin";
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; ++i) {
        const char *value = getenv(keys[i]);
        if (!value) {
            continue;
        }
        size_t key = strlen(keys[i]), length = strnlen(value, ARG_BYTES);
        if (length > sizeof environment_bytes - used ||
            key + length + 2 > sizeof environment_bytes - used) {
            return E2BIG;
        }
        char *entry = environment_bytes + used;
        memcpy(entry, keys[i], key);
        entry[key] = '=';
        memcpy(entry + key + 1, value, length + 1);
        environment[count++] = entry;
        used += key + length + 2;
    }
    environment[count] = NULL;
    return 0;
}

static void child_failure(int error) {
    while (write(3, &error, sizeof error) < 0 && errno == EINTR) {
    }
    _exit(127);
}

static void execute_helper(struct helper *helper, char **argv, unsigned char mask, int error_fd) {
    /* Child group membership is established before acknowledging exec, so a
     * vanished proxy always kills the helper and any ordinary descendants. */
    if (setsid() < 0) {
        int error = errno;
        if (dup2(error_fd, 3) < 0) {
            _exit(127);
        }
        child_failure(error);
    }
    if (dup2(error_fd, 3) < 0 || fcntl(3, F_SETFD, FD_CLOEXEC)) {
        _exit(127);
    }
    for (int fd = 0; fd < 3; ++fd) {
        if (mask & (1u << fd)) {
            if (dup2(fd + 4, fd) < 0) {
                child_failure(errno);
            }
        } else {
            close(fd);
        }
    }
    close_above(4);
    struct sigaction action = {0};
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) || sigaction(SIGPIPE, &action, NULL)) {
        child_failure(errno);
    }
    sigset_t empty;
    sigemptyset(&empty);
    if (sigprocmask(SIG_SETMASK, &empty, NULL)) {
        child_failure(errno);
    }
    if (helper->kind == HELPER_OPTIONAL && wn_main_sandbox_keep_exec()) {
        child_failure(EPERM);
    }
    char *empty_environment[] = {NULL};
    __real_execve(helper->executable, argv,
                  helper->kind == HELPER_OPTIONAL ? environment : empty_environment);
    child_failure(errno);
}

static void kill_helper(pid_t child) {
    /* Kill the PID too: cancellation can precede the child's setsid(). */
    kill(-child, SIGKILL);
    kill(child, SIGKILL);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {
    }
}

static void serve_request(unsigned char mask) {
    struct request request;
    struct reply reply = {EINVAL, 0};
    char bytes[ARG_BYTES], *argv[ARG_COUNT + 2];
    sigset_t wait_mask;
    sigemptyset(&wait_mask);
    int64_t now = milliseconds();
    int64_t deadline = now < 0 ? 1 : now + REQUEST_MS;
    int flags = fcntl(3, F_GETFL);
    if (flags < 0 || fcntl(3, F_SETFL, flags | O_NONBLOCK)) {
        return;
    }
    if (transfer(3, &request, sizeof request, IO_READ, deadline) || request.count >= ARG_COUNT ||
        !request.bytes || request.bytes > sizeof bytes ||
        transfer(3, bytes, request.bytes, IO_READ, deadline)) {
        goto reject;
    }
    size_t length = strnlen(bytes, request.bytes);
    if (length == request.bytes) {
        goto reject;
    }
    struct helper *helper = NULL;
    for (size_t i = 0; i < frozen_count; ++i) {
        if (!strcmp(bytes, frozen[i].requested)) {
            helper = &frozen[i];
            break;
        }
    }
    if (!helper) {
        reply.error = EPERM;
        goto reject;
    }
    size_t offset = length + 1;
    argv[0] = helper->executable;
    for (uint32_t i = 0; i < request.count; ++i) {
        if (offset >= request.bytes) {
            goto reject;
        }
        length = strnlen(bytes + offset, request.bytes - offset);
        if (length == request.bytes - offset) {
            goto reject;
        }
        argv[i + 1] = bytes + offset;
        offset += length + 1;
    }
    if (offset != request.bytes || (helper->kind == HELPER_DECODER && request.count != 0) ||
        ((helper->kind == HELPER_PDF || helper->kind == HELPER_FONT) && request.count != 1)) {
        goto reject;
    }
    argv[request.count + 1] = NULL;
    if (helper->kind == HELPER_PDF) {
        argv[1] = font_root;
    } else if (helper->kind == HELPER_FONT) {
        struct stat st;
        if (strcmp(argv[1], "--stdin") || !(mask & 1u) || fstat(4, &st) || !S_ISREG(st.st_mode)) {
            goto reject;
        }
    }
    int errors[2];
    if (pipe2(errors, O_CLOEXEC | O_NONBLOCK)) {
        reply.error = errno;
        goto reject;
    }
    /* Keep the handshake writer away from 3..6, even with absent stdio. */
    int writer = fcntl(errors[1], F_DUPFD_CLOEXEC, 7);
    close(errors[1]);
    if (writer < 0) {
        reply.error = errno;
        close(errors[0]);
        goto reject;
    }
    pid_t child = fork();
    if (!child) {
        execute_helper(helper, argv, mask, writer);
        _exit(127);
    }
    int fork_error = errno;
    close(writer);
    for (int fd = 4; fd < 7; ++fd) {
        if (fd != errors[0]) {
            close(fd);
        }
    }
    if (child < 0) {
        reply.error = fork_error;
        close(errors[0]);
        goto reject;
    }
    struct pollfd watch[2] = {{3, POLLIN, 0}, {errors[0], POLLIN, 0}};
    int executed = 0;
    while (!stopping) {
        now = milliseconds();
        if (now < 0 || now >= deadline) {
            reply.error = ETIMEDOUT;
            break;
        }
        int result = poll(watch, 2, (int)(deadline - now));
        if (result < 0 && errno == EINTR) {
            continue;
        }
        if (result <= 0 || watch[0].revents) {
            reply.error = result == 0 ? ETIMEDOUT : ECANCELED;
            break;
        }
        if (watch[1].revents) {
            ssize_t size = read(errors[0], &reply.error, sizeof reply.error);
            if (!size) {
                executed = 1;
                reply.error = 0;
            } else if (size != (ssize_t)sizeof reply.error) {
                reply.error = EIO;
            }
            break;
        }
    }
    close(errors[0]);
    if (!executed) {
        kill_helper(child);
        goto reject;
    }
    if (transfer(3, &reply, sizeof reply, IO_WRITE, deadline)) {
        kill_helper(child);
        return;
    }
    watch[0].revents = 0;
    for (;;) {
        int status;
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) {
            /* Descendants must not survive a completed helper either. */
            kill(-child, SIGKILL);
            reply.status = status;
            now = milliseconds();
            transfer(3, &reply, sizeof reply, IO_WRITE, now < 0 ? 1 : now + REQUEST_MS);
            return;
        }
        if (result < 0 && errno != EINTR) {
            kill_helper(child);
            return;
        }
        int event = ppoll(watch, 1, NULL, &wait_mask);
        if (stopping || event > 0 || (event < 0 && errno != EINTR)) {
            kill_helper(child);
            return;
        }
    }
reject:
    transfer(3, &reply, sizeof reply, IO_WRITE, deadline);
}

static void launch_loop(void) {
    pid_t jobs[JOB_COUNT] = {0};
    sigset_t wait_mask;
    sigemptyset(&wait_mask);
    while (!stopping) {
        size_t free_slot = JOB_COUNT;
        for (size_t i = 0; i < JOB_COUNT; ++i) {
            if (jobs[i] && waitpid(jobs[i], NULL, WNOHANG) == jobs[i]) {
                jobs[i] = 0;
            }
            if (!jobs[i] && free_slot == JOB_COUNT) {
                free_slot = i;
            }
        }
        struct pollfd watch = {3, POLLIN, 0};
        int result = ppoll(&watch, 1, NULL, &wait_mask);
        if (result < 0 && errno == EINTR) {
            continue;
        }
        if (result < 0) {
            break;
        }
        int descriptors[4];
        unsigned char mask = 0;
        int count = receive_channel(3, descriptors, &mask);
        if (count < 0) {
            break;
        }
        if (!count) {
            continue;
        }
        pid_t child = free_slot == JOB_COUNT ? -1 : fork();
        if (!child) {
            if (dup2(descriptors[0], 3) < 0) {
                _exit(1);
            }
            size_t index = 1;
            for (int fd = 0; fd < 3; ++fd) {
                if ((mask & (1u << fd)) && dup2(descriptors[index++], fd + 4) < 0) {
                    _exit(1);
                }
            }
            close_above(7);
            serve_request(mask);
            _exit(0);
        }
        if (child > 0) {
            jobs[free_slot] = child;
        }
        for (int i = 0; i < count; ++i) {
            close(descriptors[i]);
        }
    }
    for (size_t i = 0; i < JOB_COUNT; ++i) {
        if (jobs[i]) {
            kill(jobs[i], SIGTERM);
        }
    }
    for (size_t i = 0; i < JOB_COUNT; ++i) {
        if (jobs[i]) {
            while (waitpid(jobs[i], NULL, 0) < 0 && errno == EINTR) {
            }
        }
    }
}

int wn_helpers_start(const char *const *helpers, size_t count, const char *resources) {
    if (launch_fd >= 0) {
        return EALREADY;
    }
    int error = freeze_helpers(helpers, count, resources);
    if (!error) {
        error = freeze_environment();
    }
    if (error) {
        return error;
    }
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit)) {
        return errno;
    }
    descriptor_limit = limit.rlim_max > INT_MAX ? INT_MAX : (int)limit.rlim_max;
    int pair[2];
    if (socket_pair(pair)) {
        return errno;
    }
    launch_pid = fork();
    if (launch_pid < 0) {
        error = errno;
        close(pair[0]);
        close(pair[1]);
        return error;
    }
    if (!launch_pid) {
        if (setsid() < 0 || dup2(pair[1], 3) < 0) {
            _exit(1);
        }
        close_above(4);
        close(0);
        close(1);
        close(2);
        struct sigaction action = {0};
        sigemptyset(&action.sa_mask);
        action.sa_handler = request_stop;
        if (sigaction(SIGTERM, &action, NULL)) {
            _exit(1);
        }
        action.sa_handler = SIG_IGN;
        if (sigaction(SIGPIPE, &action, NULL)) {
            _exit(1);
        }
        action.sa_handler = child_changed;
        if (sigaction(SIGCHLD, &action, NULL)) {
            _exit(1);
        }
        /* Atomically unblock these in ppoll, avoiding lost exit/stop events. */
        sigset_t blocked;
        sigemptyset(&blocked);
        sigaddset(&blocked, SIGCHLD);
        sigaddset(&blocked, SIGTERM);
        if (sigprocmask(SIG_SETMASK, &blocked, NULL)) {
            _exit(1);
        }
        error = wn_main_sandbox_enter_launcher() ? EPERM : 0;
        if (transfer(3, &error, sizeof error, IO_WRITE, 0) || error) {
            _exit(1);
        }
        launch_loop();
        _exit(0);
    }
    close(pair[1]);
    launch_fd = pair[0];
    if (transfer(launch_fd, &error, sizeof error, IO_READ, 0)) {
        error = EIO;
    }
    if (error) {
        wn_helpers_stop();
    }
    return error;
}

void wn_helpers_stop(void) {
    if (launch_fd >= 0) {
        /* shutdown affects forked aliases too; an idle inherited fd must not
         * keep the launcher or its running children alive after app shutdown. */
        shutdown(launch_fd, SHUT_RDWR);
        close(launch_fd);
        launch_fd = -1;
    }
    if (launch_pid > 0) {
        while (waitpid(launch_pid, NULL, 0) < 0 && errno == EINTR) {
        }
        launch_pid = -1;
    }
}

static void proxy_exit(int status) {
    if (WIFEXITED(status)) {
        _exit(WEXITSTATUS(status));
    }
    if (WIFSIGNALED(status)) {
        int number = WTERMSIG(status);
        struct sigaction action = {0};
        action.sa_handler = SIG_DFL;
        sigemptyset(&action.sa_mask);
        sigaction(number, &action, NULL);
        sigset_t mask;
        sigemptyset(&mask);
        sigaddset(&mask, number);
        sigprocmask(SIG_UNBLOCK, &mask, NULL);
        kill(getpid(), number);
    }
    _exit(127);
}

static void reset_proxy_signals(void) {
    for (int number = 1; number < NSIG; ++number) {
        if (number == SIGKILL || number == SIGSTOP) {
            continue;
        }
        struct sigaction action;
        if (!sigaction(number, NULL, &action) && action.sa_handler != SIG_DFL &&
            action.sa_handler != SIG_IGN) {
            action.sa_handler = SIG_DFL;
            action.sa_flags = 0;
            sigemptyset(&action.sa_mask);
            sigaction(number, &action, NULL);
        }
    }
}

int wn_helper_execve(const char *path, char *const argv[], char *const envp[]) {
    (void)envp;
    if (launch_fd < 0) {
        errno = ENOSYS;
        return -1;
    }
    struct request request = {0};
    char bytes[ARG_BYTES];
    if (!path || !argv || !argv[0]) {
        errno = EINVAL;
        return -1;
    }
    size_t length = strnlen(path, sizeof bytes);
    if (!length || length == sizeof bytes) {
        errno = E2BIG;
        return -1;
    }
    memcpy(bytes, path, length + 1);
    request.bytes = (uint32_t)length + 1;
    while (request.count < ARG_COUNT && argv[request.count + 1]) {
        const char *argument = argv[request.count + 1];
        size_t available = sizeof bytes - request.bytes;
        length = strnlen(argument, available);
        if (length == available) {
            errno = E2BIG;
            return -1;
        }
        memcpy(bytes + request.bytes, argument, length + 1);
        request.bytes += (uint32_t)length + 1;
        ++request.count;
    }
    if (request.count >= ARG_COUNT) {
        errno = E2BIG;
        return -1;
    }
    int pair[2];
    if (socket_pair(pair)) {
        return -1;
    }
    int result = send_channel(pair[1]);
    close(pair[1]);
    struct reply reply;
    if (!result) {
        result = transfer(pair[0], &request, sizeof request, IO_WRITE, 0) ||
                 transfer(pair[0], bytes, request.bytes, IO_WRITE, 0) ||
                 transfer(pair[0], &reply, sizeof reply, IO_READ, 0);
    }
    if (result || reply.error) {
        int error = result ? errno : reply.error;
        close(pair[0]);
        errno = error;
        return -1;
    }
    reset_proxy_signals();
    /* Only now close the caller's CLOEXEC error pipe: EOF means an actual
     * successful exec, not merely a queued request. Drop all proxy pipe copies
     * as well, so only the real helper controls stdin/stdout/stderr EOF. */
    if (dup2(pair[0], 3) < 0) {
        close(pair[0]);
        _exit(127);
    }
    close_above(4);
    close(0);
    close(1);
    close(2);
    if (transfer(3, &reply, sizeof reply, IO_READ, 0)) {
        _exit(127);
    }
    proxy_exit(reply.status);
    return -1;
}

int __wrap_execve(const char *path, char *const argv[], char *const envp[]) {
    if (launch_fd < 0) {
        return __real_execve(path, argv, envp);
    }
    return wn_helper_execve(path, argv, envp);
}
