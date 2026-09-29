#ifndef __OpenBSD__
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#endif
#include "tool_broker.h"
#include "main_sandbox.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __OpenBSD__
extern int __real_execve(const char *, char *const[], char *const[]);
#endif

#define ARG_LIMIT 65536u
#define ARG_COUNT 64u
/* Match the existing image decoder's accepted compressed-input ceiling. */
#define OUTPUT_LIMIT (128u * 1024u * 1024u)
static int broker_fd = -1;
static pid_t broker_pid = -1;
static pthread_mutex_t broker_send = PTHREAD_MUTEX_INITIALIZER;
static char tools[5][PATH_MAX];
static pthread_mutex_t dialog_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_t dialog_thread;
static int dialog_running, dialog_joinable;
static char *tool_environment[48];

static int freeze_environment(void) {
    /* In particular, WN_VAULT_PW and unrelated account/API credentials must
     * never enter a desktop utility's address space. Keep only its platform,
     * locale, TLS and proxy inputs, frozen before the app processes input. */
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
                                       "MESA_SHADER_CACHE_DIR",
                                       "SSL_CERT_FILE",
                                       "SSL_CERT_DIR",
                                       "CURL_CA_BUNDLE",
                                       "http_proxy",
                                       "https_proxy",
                                       "all_proxy",
                                       "no_proxy",
                                       "HTTP_PROXY",
                                       "HTTPS_PROXY",
                                       "ALL_PROXY",
                                       "NO_PROXY",
                                       "GDK_BACKEND",
                                       "GDK_DEBUG",
                                       "GDK_DISABLE"};
    size_t count = 0;
    tool_environment[count++] = strdup("PATH=/usr/local/bin:/usr/bin:/bin");
    if (!tool_environment[0]) {
        return ENOMEM;
    }
    /* GTK's GL fallback uses SysV SHM, which OpenBSD pledge cannot permit. */
    tool_environment[count++] = strdup("GSK_RENDERER=cairo");
    if (!tool_environment[1]) {
        return ENOMEM;
    }
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; ++i) {
        const char *value = getenv(keys[i]);
        if (!value) {
            continue;
        }
        size_t key_length = strlen(keys[i]), value_length = strlen(value);
        if (value_length > ARG_LIMIT - key_length - 2) {
            return E2BIG;
        }
        size_t n = key_length + value_length + 2;
        char *entry = malloc(n);
        if (!entry) {
            return ENOMEM;
        }
        memcpy(entry, keys[i], key_length);
        entry[key_length] = '=';
        memcpy(entry + key_length + 1, value, value_length + 1);
        tool_environment[count++] = entry;
    }
    return 0;
}

struct dialog_request {
    int save, multiple;
    char name[PATH_MAX];
    wn_tool_dialog_callback callback;
    void *userdata;
};

struct request {
    uint32_t operation, count, bytes;
};
struct response {
    int32_t error, status;
    uint32_t output, errors;
};

static int transfer(int fd, void *buffer, size_t length, int writing) {
    unsigned char *p = buffer;
    while (length) {
        ssize_t n = writing ? write(fd, p, length) : read(fd, p, length);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            return -1;
        }
        p += n;
        length -= (size_t)n;
    }
    return 0;
}

static int send_channel(int channel) {
    char byte = 0;
    struct iovec iov = {&byte, 1};
    union {
        struct cmsghdr align;
        char bytes[CMSG_SPACE(sizeof(int))];
    } control = {0};
    struct msghdr message = {0};
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control.bytes;
    message.msg_controllen = sizeof control.bytes;
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof channel);
    memcpy(CMSG_DATA(header), &channel, sizeof channel);
    ssize_t result;
    do {
        result = sendmsg(broker_fd, &message, 0);
    } while (result < 0 && errno == EINTR);
    return result == 1 ? 0 : -1;
}

static int receive_channel(int socket) {
    char byte;
    struct iovec iov = {&byte, 1};
    union {
        struct cmsghdr align;
        char bytes[CMSG_SPACE(sizeof(int))];
    } control = {0};
    struct msghdr message = {0};
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control.bytes;
    message.msg_controllen = sizeof control.bytes;
    ssize_t n;
    do {
        n = recvmsg(socket, &message, 0);
    } while (n < 0 && errno == EINTR);
    if (n != 1 || message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) {
        return -1;
    }
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    if (!header || header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS ||
        header->cmsg_len != CMSG_LEN(sizeof(int))) {
        return -1;
    }
    int channel;
    memcpy(&channel, CMSG_DATA(header), sizeof channel);
    return channel;
}

static void close_descriptors(void) {
#ifdef __OpenBSD__
    closefrom(4);
#else
    long max = sysconf(_SC_OPEN_MAX);
    for (int fd = 4; fd < max; ++fd) {
        close(fd);
    }
#endif
}

static void serve_request(int channel) {
    struct request request = {0};
    struct response response = {.error = EINVAL, .status = -1};
    unsigned char *buffers[2] = {NULL, NULL};
    size_t lengths[2] = {0, 0}, capacities[2] = {0, 0};
    char arguments[ARG_LIMIT];
    char *argv[ARG_COUNT + 2];
    if (transfer(channel, &request, sizeof request, 0) || request.operation < WN_TOOL_CURL ||
        request.operation > WN_TOOL_SAVE_DIALOG || request.count > ARG_COUNT ||
        request.bytes > ARG_LIMIT || transfer(channel, arguments, request.bytes, 0)) {
        goto done;
    }
    if (!tools[request.operation][0]) {
        response.error = ENOENT;
        goto done;
    }
    size_t offset = 0;
    argv[0] = tools[request.operation];
    for (uint32_t i = 0; i < request.count; ++i) {
        if (offset >= request.bytes) {
            goto done;
        }
        size_t length = strnlen(arguments + offset, request.bytes - offset);
        if (length == request.bytes - offset) {
            goto done;
        }
        argv[i + 1] = arguments + offset;
        offset += length + 1;
    }
    if (offset != request.bytes) {
        goto done;
    }
    argv[request.count + 1] = NULL;
    int output[2], errors[2];
    if (pipe(output)) {
        response.error = errno;
        goto done;
    }
    if (pipe(errors)) {
        response.error = errno;
        close(output[0]);
        close(output[1]);
        goto done;
    }
    pid_t child = fork();
    if (!child) {
        int input = open("/dev/null", O_RDONLY);
        if (input < 0 || dup2(input, 0) < 0 || dup2(output[1], 1) < 0 || dup2(errors[1], 2) < 0) {
            _exit(126);
        }
        if (input > 2) {
            close(input);
        }
        close(3);
        close_descriptors();
        struct rlimit limit = {128, 128};
        if (setrlimit(RLIMIT_NOFILE, &limit)) {
            _exit(126);
        }
        alarm(request.operation <= WN_TOOL_NOTIFY ? 60 : 600);
        if (wn_main_sandbox_enter_tool(argv[0])) {
            dprintf(2, "White Noise tool confinement: %s\n", wn_main_sandbox_error());
            _exit(126);
        }
#ifdef __OpenBSD__
        /* This prestarted broker retains its locked policy across exec. */
        __real_execve(argv[0], argv, tool_environment);
#else
        execve(argv[0], argv, tool_environment);
#endif
        _exit(127);
    }
    close(output[1]);
    close(errors[1]);
    if (child < 0) {
        response.error = errno;
        close(output[0]);
        close(errors[0]);
        goto done;
    }
    struct pollfd pipes[2] = {{output[0], POLLIN, 0}, {errors[0], POLLIN, 0}};
    int open_count = 2, failed = 0;
    while (open_count && !failed) {
        int ready = poll(pipes, 2, request.operation <= WN_TOOL_NOTIFY ? 65000 : 605000);
        if (ready < 0 && errno == EINTR) {
            continue;
        }
        if (ready <= 0) {
            failed = ready == 0 ? ETIMEDOUT : errno;
            break;
        }
        for (int i = 0; i < 2; ++i) {
            if (pipes[i].fd < 0 || !pipes[i].revents) {
                continue;
            }
            if (lengths[i] == capacities[i] && capacities[i] < OUTPUT_LIMIT) {
                size_t capacity = capacities[i] ? capacities[i] * 2 : 8192;
                unsigned char *buffer = realloc(buffers[i], capacity);
                if (!buffer) {
                    failed = ENOMEM;
                    break;
                }
                buffers[i] = buffer;
                capacities[i] = capacity;
            }
            unsigned char extra;
            size_t available = capacities[i] - lengths[i];
            ssize_t n = read(pipes[i].fd, available ? buffers[i] + lengths[i] : &extra,
                             available ? available : 1);
            if (n > 0) {
                if (!available) {
                    failed = EFBIG;
                    break;
                }
                lengths[i] += (size_t)n;
            } else if (!n) {
                close(pipes[i].fd);
                pipes[i].fd = -1;
                --open_count;
            } else if (errno != EINTR) {
                failed = errno;
                break;
            }
        }
    }
    for (int i = 0; i < 2; ++i) {
        if (pipes[i].fd >= 0) {
            close(pipes[i].fd);
        }
    }
    if (failed) {
        kill(child, SIGKILL);
    }
    int status = 0;
    pid_t waited;
    do {
        waited = waitpid(child, &status, 0);
    } while (waited < 0 && errno == EINTR);
    response.error = failed ? failed : (waited < 0 ? errno : 0);
    response.status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    response.output = (uint32_t)lengths[0];
    response.errors = (uint32_t)lengths[1];
done:
    if (request.operation == WN_TOOL_NOTIFY && (response.error || response.status)) {
        fprintf(stderr, "White Noise confined notification: error %d, exit %d; %.*s\n",
                response.error, response.status, (int)response.errors,
                buffers[1] ? (char *)buffers[1] : "");
    }
    if (!transfer(channel, &response, sizeof response, 1)) {
        transfer(channel, buffers[0], response.output, 1);
        transfer(channel, buffers[1], response.errors, 1);
    }
    free(buffers[0]);
    free(buffers[1]);
}

int wn_tools_start(void) {
    if (broker_fd >= 0) {
        return EALREADY;
    }
    const char *paths[] = {NULL, "/usr/local/bin/curl", "/usr/local/bin/notify-send",
                           "/usr/local/bin/zenity", "/usr/local/bin/zenity"};
    for (int i = WN_TOOL_CURL; i <= WN_TOOL_SAVE_DIALOG; ++i) {
        if (!realpath(paths[i], tools[i]) || access(tools[i], X_OK)) {
            tools[i][0] = '\0';
        }
    }
    if (!tools[WN_TOOL_CURL][0]) {
        return ENOENT;
    }
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) {
        return errno;
    }
    if (fcntl(sockets[0], F_SETFD, FD_CLOEXEC) || fcntl(sockets[1], F_SETFD, FD_CLOEXEC)) {
        int error = errno;
        close(sockets[0]);
        close(sockets[1]);
        return error;
    }
    broker_pid = fork();
    if (broker_pid < 0) {
        int error = errno;
        close(sockets[0]);
        close(sockets[1]);
        return error;
    }
    if (!broker_pid) {
        close(sockets[0]);
        if (setpgid(0, 0) || dup2(sockets[1], 3) < 0) {
            _exit(1);
        }
        close_descriptors();
        signal(SIGPIPE, SIG_IGN);
        signal(SIGCHLD, SIG_IGN);
        const char *executables[4];
        size_t count = 0;
        for (int i = WN_TOOL_CURL; i <= WN_TOOL_SAVE_DIALOG; ++i) {
            if (tools[i][0]) {
                executables[count++] = tools[i];
            }
        }
        int ready = freeze_environment();
        if (!ready && wn_main_sandbox_prepare_tools(executables, count)) {
            ready = EPERM;
        }
        if (ready) {
            fprintf(stderr, "White Noise tool broker: %s\n", wn_main_sandbox_error());
        }
        if (transfer(3, &ready, sizeof ready, 1) || ready) {
            _exit(1);
        }
        for (;;) {
            int channel = receive_channel(3);
            if (channel < 0) {
                _exit(0);
            }
            pid_t child = fork();
            if (!child) {
                close(3);
                if (dup2(channel, 3) < 0) {
                    _exit(1);
                }
                close_descriptors();
                signal(SIGCHLD, SIG_DFL);
                alarm(610);
                serve_request(3);
                _exit(0);
            }
            close(channel);
        }
    }
    close(sockets[1]);
    broker_fd = sockets[0];
    /* Establish the group in the parent too, before stop can signal it. */
    if (setpgid(broker_pid, broker_pid) && errno != EACCES && errno != ESRCH) {
        int error = errno;
        wn_tools_stop();
        return error;
    }
    int ready;
    if (transfer(broker_fd, &ready, sizeof ready, 0)) {
        ready = EIO;
    }
    if (ready) {
        wn_tools_stop();
        return ready;
    }
    return 0;
}

void wn_tools_stop(void) {
    pthread_mutex_lock(&broker_send);
    if (broker_fd >= 0) {
        close(broker_fd);
        broker_fd = -1;
    }
    pthread_mutex_unlock(&broker_send);
    if (broker_pid > 0) {
        kill(-broker_pid, SIGTERM);
        while (waitpid(broker_pid, NULL, 0) < 0 && errno == EINTR) {
        }
        broker_pid = -1;
    }
    if (dialog_joinable) {
        pthread_join(dialog_thread, NULL);
        dialog_joinable = 0;
    }
}

static int open_request(int operation, const char *const *arguments, size_t count, int *channel) {
    if (count > ARG_COUNT) {
        return E2BIG;
    }
    char payload[ARG_LIMIT];
    size_t length = 0;
    for (size_t i = 0; i < count; ++i) {
        if (!arguments[i]) {
            return EINVAL;
        }
        size_t n = strnlen(arguments[i], ARG_LIMIT);
        if (n == ARG_LIMIT || n + 1 > ARG_LIMIT - length) {
            return E2BIG;
        }
        memcpy(payload + length, arguments[i], n + 1);
        length += n + 1;
    }
    int channels[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, channels)) {
        return errno;
    }
    if (fcntl(channels[0], F_SETFD, FD_CLOEXEC) || fcntl(channels[1], F_SETFD, FD_CLOEXEC)) {
        int error = errno;
        close(channels[0]);
        close(channels[1]);
        return error;
    }
    pthread_mutex_lock(&broker_send);
    int sent = broker_fd < 0 ? -1 : send_channel(channels[1]);
    pthread_mutex_unlock(&broker_send);
    close(channels[1]);
    struct request request = {(uint32_t)operation, (uint32_t)count, (uint32_t)length};
    if (sent || transfer(channels[0], &request, sizeof request, 1) ||
        transfer(channels[0], payload, length, 1)) {
        close(channels[0]);
        return EIO;
    }
    *channel = channels[0];
    return 0;
}

int wn_tools_submit_notification(const char *const *arguments, size_t count) {
    if (!tools[WN_TOOL_NOTIFY][0]) {
        return ENOENT;
    }
    int channel;
    int error = open_request(WN_TOOL_NOTIFY, arguments, count, &channel);
    if (!error) {
        close(channel); /* broker owns completion; errors go to stderr */
    }
    return error;
}

int wn_tools_run(int operation, const char *const *arguments, size_t count, unsigned char **output,
                 size_t *output_size, unsigned char **errors, size_t *errors_size, int *exit_code) {
    *output = NULL;
    *errors = NULL;
    *output_size = *errors_size = 0;
    *exit_code = -1;
    int channel;
    int result = open_request(operation, arguments, count, &channel);
    if (result) {
        return result;
    }
    result = EIO;
    struct response response;
    if (transfer(channel, &response, sizeof response, 0)) {
        goto done;
    }
    if (response.output > OUTPUT_LIMIT || response.errors > OUTPUT_LIMIT) {
        goto done;
    }
    if (response.output) {
        *output = malloc(response.output);
        if (!*output) {
            result = ENOMEM;
            goto done;
        }
        if (transfer(channel, *output, response.output, 0)) {
            goto done;
        }
    }
    if (response.errors) {
        *errors = malloc(response.errors);
        if (!*errors) {
            result = ENOMEM;
            goto done;
        }
        if (transfer(channel, *errors, response.errors, 0)) {
            goto done;
        }
    }
    *output_size = response.output;
    *errors_size = response.errors;
    *exit_code = response.status;
    result = response.error;
done:
    close(channel);
    if (result) {
        free(*output);
        free(*errors);
        *output = *errors = NULL;
        *output_size = *errors_size = 0;
    }
    return result;
}

static void *dialog_worker(void *opaque) {
    struct dialog_request *request = opaque;
    int multiple = request->multiple && !request->save;
    char initial[PATH_MAX];
    int n = snprintf(initial, sizeof initial, "--filename=%s/%s", wn_main_sandbox_downloads(),
                     request->name);
    const char *args[6] = {"--file-selection", initial};
    size_t count = 2;
    if (request->save) {
        args[count++] = "--save";
        /* GTK4's native SAVE chooser owns overwrite confirmation. */
    } else if (request->multiple) {
        args[count++] = "--multiple";
        /* Canonical GFile paths cannot contain repeated separators. */
        args[count++] = "--separator=//";
    }
    unsigned char *output = NULL, *errors = NULL;
    size_t length = 0, errors_length = 0;
    int status = -1;
    int error = n < 0 || n >= (int)sizeof initial
                    ? ENAMETOOLONG
                    : wn_tools_run(request->save ? WN_TOOL_SAVE_DIALOG : WN_TOOL_OPEN_DIALOG, args,
                                   count, &output, &length, &errors, &errors_length, &status);
    char **paths = NULL;
    char *text = NULL;
    if (!error && status == 0) {
        /* zenity appends one newline after the selected path(s). */
        if (length && output[length - 1] == '\n') {
            --length;
        }
        text = malloc(length + 1);
        size_t entries = 1;
        for (size_t i = 0; multiple && i + 1 < length; ++i) {
            if (output[i] == '/' && output[i + 1] == '/') {
                ++entries;
                ++i;
            }
        }
        paths = calloc(entries + 1, sizeof *paths);
        if (!text || !paths) {
            error = ENOMEM;
        } else {
            memcpy(text, output, length);
            text[length] = '\0';
            size_t index = 0;
            if (length) {
                paths[index++] = text;
            }
            for (size_t i = 0; multiple && i + 1 < length; ++i) {
                if (text[i] == '/' && text[i + 1] == '/') {
                    text[i] = '\0';
                    paths[index++] = text + i + 2;
                    ++i;
                }
            }
        }
    } else if (!error && status != 1) {
        error = EIO;
    }
    const char *empty[] = {NULL};
    if (error) {
        fprintf(stderr, "White Noise confined dialog: %s; %.*s\n", strerror(error),
                (int)errors_length, errors ? (char *)errors : "");
    }
    request->callback(request->userdata,
                      error ? NULL : (paths ? (const char *const *)paths : empty), -error);
    free(text);
    free(paths);
    free(output);
    free(errors);
    free(request);
    pthread_mutex_lock(&dialog_lock);
    dialog_running = 0;
    pthread_mutex_unlock(&dialog_lock);
    return NULL;
}

int wn_tools_dialog(int save, int multiple, const char *name, wn_tool_dialog_callback callback,
                    void *userdata) {
    if (!callback) {
        return EINVAL;
    }
    pthread_mutex_lock(&dialog_lock);
    if (dialog_running) {
        pthread_mutex_unlock(&dialog_lock);
        return EBUSY;
    }
    if (dialog_joinable) {
        pthread_join(dialog_thread, NULL);
        dialog_joinable = 0;
    }
    struct dialog_request *request = calloc(1, sizeof *request);
    if (!request) {
        pthread_mutex_unlock(&dialog_lock);
        return ENOMEM;
    }
    if (name && strlen(name) >= sizeof request->name) {
        free(request);
        pthread_mutex_unlock(&dialog_lock);
        return ENAMETOOLONG;
    }
    if (name) {
        /* Suggested names are names, not authority to redirect the picker. */
        const char *base = strrchr(name, '/');
        strcpy(request->name, base ? base + 1 : name);
    }
    request->save = save;
    request->multiple = multiple;
    request->callback = callback;
    request->userdata = userdata;
    dialog_running = 1;
    int error = pthread_create(&dialog_thread, NULL, dialog_worker, request);
    if (error) {
        dialog_running = 0;
        free(request);
    } else {
        dialog_joinable = 1;
    }
    pthread_mutex_unlock(&dialog_lock);
    return error;
}
