#ifndef __OpenBSD__
#define _GNU_SOURCE
#endif
#include "../app/helper_broker.h"
#include "../app/main_sandbox.h"

#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifdef __OpenBSD__
extern char **environ;
extern int __real_execve(const char *, char *const[], char *const[]);

static char resources[PATH_MAX], helpers[7][PATH_MAX], preload[PATH_MAX + 16];
static char secret[PATH_MAX], font[PATH_MAX], fonts[PATH_MAX];
static char *hostile_environment[] = {preload,
                                      "DYLD_INSERT_LIBRARIES=/attacker.dylib",
                                      "WN_VAULT_PW=secret",
                                      "GTK_PATH=/attacker",
                                      "PATH=/attacker",
                                      "LANG=hostile",
                                      NULL};
struct process {
    pid_t pid;
    int input, output, errors, exec_error;
};

static void join_path(char *out, const char *root, const char *name) {
    assert(snprintf(out, PATH_MAX, "%s/%s", root, name) < PATH_MAX);
}

static void write_all(int fd, const void *bytes, size_t length) {
    const unsigned char *cursor = bytes;
    while (length) {
        ssize_t count = write(fd, cursor, length);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        assert(count > 0);
        cursor += count;
        length -= (size_t)count;
    }
}

static void read_all(int fd, void *bytes, size_t length) {
    unsigned char *cursor = bytes;
    while (length) {
        ssize_t count = read(fd, cursor, length);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        assert(count > 0);
        cursor += count;
        length -= (size_t)count;
    }
}

static void expect_eof(int fd) {
    struct pollfd watch = {fd, POLLIN, 0};
    assert(poll(&watch, 1, 3000) > 0);
    char byte;
    assert(read(fd, &byte, 1) == 0);
}

static void put_file(const char *path, const char *text) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    assert(fd >= 0);
    write_all(fd, text, strlen(text));
    assert(close(fd) == 0);
}

static void remove_tree(const char *path) {
    DIR *dir = opendir(path);
    assert(dir);
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) {
            continue;
        }
        char item[PATH_MAX];
        join_path(item, path, entry->d_name);
        struct stat st;
        assert(lstat(item, &st) == 0);
        if (S_ISDIR(st.st_mode)) {
            remove_tree(item);
        } else {
            assert(unlink(item) == 0);
        }
    }
    assert(closedir(dir) == 0);
    assert(rmdir(path) == 0);
}

/* Installed copies of this executable are deliberately simple real helpers;
 * input, not additional decoder argv, selects their observable behavior. */
static int helper_mode(int argc, char **argv, const char *name) {
    assert(!getenv("LD_PRELOAD") && !getenv("DYLD_INSERT_LIBRARIES"));
    assert(!getenv("WN_VAULT_PW") && !getenv("GTK_PATH"));
    for (int fd = 3; fd < 256; ++fd) {
        assert(fcntl(fd, F_GETFD) < 0 && errno == EBADF);
    }
    if (!strcmp(name, "wn-stt")) {
        assert(argc == 2 && getenv("LANG") && !strcmp(getenv("LANG"), "C"));
        assert(getenv("PATH") && !strcmp(getenv("PATH"), "/usr/local/bin:/usr/bin:/bin"));
        int fd = open(argv[1], O_RDONLY);
        assert(fd < 0 && (errno == ENOENT || errno == EACCES || errno == EPERM));
        write_all(1, "inherited\n", 10);
        return 0;
    }
    assert(!environ[0]);
    /* Required helpers have reset-on-exec authority, unlike optional ones. */
    assert(unveil("/etc", "r") == 0);
    assert(unveil(NULL, NULL) == 0);
    assert(pledge("stdio", NULL) == 0);
    if (!strcmp(name, "wn-pdf")) {
        assert(argc == 2);
        write_all(1, argv[1], strlen(argv[1]));
        return 0;
    }
    if (!strcmp(name, "wn-font")) {
        assert(argc == 2 && !strcmp(argv[1], "--stdin"));
        struct stat st;
        assert(fstat(0, &st) == 0 && S_ISREG(st.st_mode));
        char contents[32];
        ssize_t length = read(0, contents, sizeof contents);
        assert(length == 11 && !memcmp(contents, "pinned-font", 11));
        assert(lseek(0, 0, SEEK_SET) == 0);
        write_all(1, contents, (size_t)length);
        return 0;
    }
    assert(argc == 1);
    char command;
    read_all(0, &command, 1);
    if (command == 'X') {
        return 37;
    }
    if (command == 'S') {
        raise(SIGUSR1);
        return 99;
    }
    if (command == 'P') {
        pid_t self = getpid();
        write_all(1, &self, sizeof self);
        read_all(0, &command, 1);
        assert(command == 'Q');
    }
    write_all(1, &command, 1);
    write_all(2, "isolated\n", 9);
    return 0;
}

static struct process spawn(const char *path, char *const arguments[], int input_fd) {
    int input[2], output[2], errors[2], handshake[2];
    assert(pipe2(input, O_CLOEXEC) == 0 && pipe2(output, O_CLOEXEC) == 0);
    assert(pipe2(errors, O_CLOEXEC) == 0 && pipe2(handshake, O_CLOEXEC) == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        assert(dup2(input_fd >= 0 ? input_fd : input[0], 0) == 0);
        assert(dup2(output[1], 1) == 1 && dup2(errors[1], 2) == 2);
        /* An ordinary exec error pipe must close only after real exec succeeds.
         * Leave every other inherited descriptor for the broker to eliminate. */
        execve(path, arguments, hostile_environment);
        int error = errno;
        write_all(handshake[1], &error, sizeof error);
        _exit(126);
    }
    close(input[0]);
    close(output[1]);
    close(errors[1]);
    close(handshake[1]);
    struct process process = {child, input[1], output[0], errors[0], handshake[0]};
    return process;
}

static void expect_started(struct process *process) {
    expect_eof(process->exec_error);
    close(process->exec_error);
    process->exec_error = -1;
}

static int finish(struct process *process) {
    close(process->input);
    close(process->output);
    close(process->errors);
    if (process->exec_error >= 0) {
        close(process->exec_error);
    }
    int status;
    assert(waitpid(process->pid, &status, 0) == process->pid);
    return status;
}

static void expect_rejected(const char *path, char *const arguments[], int error, int input) {
    struct process process = spawn(path, arguments, input);
    int actual;
    read_all(process.exec_error, &actual, sizeof actual);
    assert(actual == error);
    int status = finish(&process);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 126);
}

static void confirm_preload(void) {
    int output[2];
    assert(pipe(output) == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        assert(dup2(output[1], 1) == 1);
        close(output[0]);
        close(output[1]);
        char *arguments[] = {helpers[0], NULL};
        __real_execve(helpers[0], arguments, hostile_environment);
        _exit(127);
    }
    close(output[1]);
    char marker[14];
    read_all(output[0], marker, sizeof marker);
    assert(!memcmp(marker, "loader-escape\n", sizeof marker));
    close(output[0]);
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 91);
}

static void expect_dead(pid_t child) {
    for (int i = 0; i < 300; ++i) {
        if (kill(child, 0) < 0 && errno == ESRCH) {
            return;
        }
        struct timespec pause = {0, 10000000};
        assert(nanosleep(&pause, NULL) == 0);
    }
    assert(!"actual helper was not killed and reaped");
}

static void boundaries(const char *data, const char *settings) {
    const char *paths[7];
    for (size_t i = 0; i < 7; ++i) {
        paths[i] = helpers[i];
    }
    assert(setenv("LANG", "C", 1) == 0);
    assert(setenv("LD_PRELOAD", preload + strlen("LD_PRELOAD="), 1) == 0);
    assert(setenv("WN_VAULT_PW", "secret", 1) == 0);
    assert(setenv("GTK_PATH", "/attacker", 1) == 0);
    assert(wn_main_sandbox_prepare(data, settings, resources, paths, 7) == 0);
    assert(wn_helpers_start(paths, 7, resources) == 0);
    assert(setenv("LANG", "hostile", 1) == 0);
    assert(setenv("PATH", "/attacker", 1) == 0);
    /* The inherited input FD stays an authority even when its pathname is
     * outside the main's veil. High extra FDs must not reach a real helper. */
    int input = open(font, O_RDONLY);
    int private_fd = open(secret, O_RDONLY);
    assert(input >= 0 && private_fd >= 0);
    assert(dup2(private_fd, 100) == 100);
    close(private_fd);
    assert(wn_main_sandbox_enter() == 0);

    char *plain[] = {helpers[0], NULL};
    char *foreign[] = {"/bin/sh", NULL};
    expect_rejected("/bin/sh", foreign, EPERM, -1);
    char *extra[] = {helpers[0], "unexpected", NULL};
    expect_rejected(helpers[0], extra, EINVAL, -1);
    char oversized[16384];
    memset(oversized, 'x', sizeof oversized - 1);
    oversized[sizeof oversized - 1] = '\0';
    char *large_args[] = {helpers[4], oversized, NULL};
    expect_rejected(helpers[4], large_args, E2BIG, -1);
    char *many_args[66];
    many_args[0] = helpers[4];
    for (size_t i = 1; i < 65; ++i) {
        many_args[i] = "x";
    }
    many_args[65] = NULL;
    expect_rejected(helpers[4], many_args, E2BIG, -1);
    char *broken[] = {helpers[6], NULL};
    expect_rejected(helpers[6], broken, ENOEXEC, -1);
    char *missing_font[] = {helpers[3], "/outside/file.ttf", NULL};
    expect_rejected(helpers[3], missing_font, EINVAL, input);
    char *font_args[] = {helpers[3], "--stdin", NULL};
    expect_rejected(helpers[3], font_args, EINVAL, -1);

    pid_t raw = fork();
    assert(raw >= 0);
    if (!raw) {
        __real_execve(helpers[0], plain, hostile_environment);
        _exit(99);
    }
    int status;
    assert(waitpid(raw, &status, 0) == raw);
    assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);

    /* Concurrent fork children exercise the shared atomic channel handoff. */
    struct process concurrent[8];
    for (size_t i = 0; i < 8; ++i) {
        concurrent[i] = spawn(helpers[0], plain, -1);
    }
    for (size_t i = 0; i < 8; ++i) {
        expect_started(&concurrent[i]);
        char command = (char)('a' + i), actual, errors[9];
        write_all(concurrent[i].input, &command, 1);
        read_all(concurrent[i].output, &actual, 1);
        read_all(concurrent[i].errors, errors, sizeof errors);
        assert(actual == command && !memcmp(errors, "isolated\n", sizeof errors));
        expect_eof(concurrent[i].output);
        status = finish(&concurrent[i]);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    for (size_t i = 0; i < 2; ++i) {
        struct process process = spawn(helpers[0], plain, -1);
        expect_started(&process);
        write_all(process.input, i ? "S" : "X", 1);
        expect_eof(process.output);
        status = finish(&process);
        if (i) {
            assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGUSR1);
        } else {
            assert(WIFEXITED(status) && WEXITSTATUS(status) == 37);
        }
    }
    char *pdf_args[] = {helpers[2], "/attacker/fonts", NULL};
    struct process pdf = spawn(helpers[2], pdf_args, -1);
    expect_started(&pdf);
    char actual_fonts[PATH_MAX] = {0};
    read_all(pdf.output, actual_fonts, strlen(fonts));
    assert(!strcmp(actual_fonts, fonts));
    expect_eof(pdf.output);
    status = finish(&pdf);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);

    struct process font_process = spawn(helpers[3], font_args, input);
    expect_started(&font_process);
    char actual_font[11];
    read_all(font_process.output, actual_font, sizeof actual_font);
    assert(!memcmp(actual_font, "pinned-font", sizeof actual_font));
    expect_eof(font_process.output);
    status = finish(&font_process);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    close(input);
    close(100);

    char *optional_args[] = {helpers[4], secret, NULL};
    struct process optional = spawn(helpers[4], optional_args, -1);
    expect_started(&optional);
    char inherited[10];
    read_all(optional.output, inherited, sizeof inherited);
    assert(!memcmp(inherited, "inherited\n", sizeof inherited));
    expect_eof(optional.output);
    status = finish(&optional);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);

    char *session_args[] = {helpers[1], NULL};
    for (size_t i = 0; i < 3; ++i) {
        struct process session = spawn(helpers[1], session_args, -1);
        expect_started(&session);
        write_all(session.input, "P", 1);
        pid_t actual_pid;
        read_all(session.output, &actual_pid, sizeof actual_pid);
        assert(actual_pid != session.pid);
        if (!i) {
            /* A persistent model must survive the request setup deadline. */
            assert(sleep(11) == 0);
            write_all(session.input, "Q", 1);
            char reply;
            read_all(session.output, &reply, 1);
            assert(reply == 'Q');
        } else if (i == 1) {
            assert(kill(session.pid, SIGKILL) == 0);
        } else {
            wn_helpers_stop();
        }
        expect_eof(session.output);
        status = finish(&session);
        if (!i) {
            assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
        } else if (i == 1) {
            assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL);
        } else {
            assert(WIFEXITED(status) && WEXITSTATUS(status) == 127);
        }
        expect_dead(actual_pid);
    }
}

int main(int argc, char **argv) {
    const char *name = strrchr(argv[0], '/');
    name = name ? name + 1 : argv[0];
    if (!strncmp(name, "wn-", 3)) {
        return helper_mode(argc, argv, name);
    }
    const char *fixture = getenv("WN_HELPER_TEST_RESOURCES");
    if (!fixture || !*fixture || getuid() == 0 || geteuid() == 0) {
        puts("helper broker kernel tests require a non-root user and WN_HELPER_TEST_RESOURCES");
        return 77;
    }
    assert(realpath(fixture, resources));
    static const char *const names[] = {"wn-image", "wn-fbx",  "wn-pdf",    "wn-font",
                                        "wn-stt",   "wn-math", "wn-archive"};
    for (size_t i = 0; i < 7; ++i) {
        join_path(helpers[i], resources, names[i]);
    }
    char library[PATH_MAX];
    join_path(library, resources, "broker-preload.so");
    assert(snprintf(preload, sizeof preload, "LD_PRELOAD=%s", library) < (int)sizeof preload);
    join_path(fonts, resources, "fonts");
    confirm_preload();
    char *no_broker[] = {helpers[0], NULL};
    assert(wn_helper_execve(helpers[0], no_broker, hostile_environment) < 0 && errno == ENOSYS);

    char root[] = "/tmp/wn-helper-broker.XXXXXX";
    assert(mkdtemp(root));
    char home[PATH_MAX], data[PATH_MAX], settings[PATH_MAX];
    join_path(home, root, "home");
    assert(mkdir(home, 0700) == 0);
    join_path(data, home, "data");
    join_path(settings, home, "config/whitenoise");
    join_path(secret, home, "secret");
    join_path(font, home, "font.ttf");
    put_file(secret, "private");
    put_file(font, "pinned-font");
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        alarm(60);
        struct rlimit no_core = {0, 0};
        assert(setrlimit(RLIMIT_CORE, &no_core) == 0);
        assert(setenv("HOME", home, 1) == 0);
        assert(unsetenv("DISPLAY") == 0 && unsetenv("XAUTHORITY") == 0);
        assert(unsetenv("DBUS_SESSION_BUS_ADDRESS") == 0);
        assert(chdir(home) == 0);
        boundaries(data, settings);
        _exit(0);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    remove_tree(root);
    puts("helper broker exec, authority, isolation and cancellation boundaries passed");
    return 0;
}
#else
int main(void) {
    puts("helper broker kernel tests require OpenBSD");
    return 77;
}
#endif
