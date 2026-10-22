#define _GNU_SOURCE
#include <stdatomic.h>
#include <stdint.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/syscall.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include "appimage_update_directory.h"

/* Only this bridge is linked into the UI. Parsing and networking live in a
 * disposable process; no AppImageUpdate/GPG libraries enter the app process. */
static struct {
    pthread_t worker;
    atomic_int phase, progress, stop, apply;
    int active, socket, automatic;
    atomic_int child;
    char image[PATH_MAX], helper[PATH_MAX], home[PATH_MAX], stage[PATH_MAX];
    char version[128], current[128], feed[2048];
    atomic_int status;
} client = {.socket = -1};

enum { OFF, IDLE, CHECKING, DOWNLOADING, READY, FAILED };
enum { STATUS_NONE, STATUS_PROXY, STATUS_DIRECTORY, STATUS_HELPER, STATUS_UPDATE, STATUS_UNSAFE };

static int copy_file(const char *source, const char *destination, mode_t mode) {
    int in = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (in < 0) {
        return 0;
    }
    int out = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode);
    if (out < 0) {
        close(in);
        return 0;
    }
    char bytes[65536];
    ssize_t n;
    int ok = 1;
    while ((n = read(in, bytes, sizeof bytes)) > 0) {
        ssize_t offset = 0;
        while (offset < n) {
            ssize_t written = write(out, bytes + offset, (size_t)(n - offset));
            if (written < 0 && errno == EINTR) {
                continue;
            }
            if (written <= 0) {
                ok = 0;
                break;
            }
            offset += written;
        }
        if (!ok) {
            break;
        }
    }
    if (n < 0) {
        ok = 0;
    }
    if (fchmod(out, mode) || fsync(out)) {
        ok = 0;
    }
    close(in);
    close(out);
    return ok;
}
static int child_command(char command) {
    return client.socket >= 0 && send(client.socket, &command, 1, MSG_NOSIGNAL | MSG_DONTWAIT) == 1;
}
static void cleanup_stage(void) {
    if (!client.stage[0]) {
        return;
    }
    /* Remove only our private workspace. It never contains user-owned files. */
    char libs[PATH_MAX];
    if (snprintf(libs, sizeof libs, "%s/lib", client.stage) >= (int)sizeof libs) {
        return;
    }
    DIR *dir = opendir(libs);
    if (dir) {
        struct dirent *entry;
        while ((entry = readdir(dir))) {
            if (entry->d_name[0] == '.') {
                continue;
            }
            char file[PATH_MAX];
            if (snprintf(file, sizeof file, "%s/%s", libs, entry->d_name) < (int)sizeof file) {
                unlink(file);
            }
        }
        closedir(dir);
        rmdir(libs);
    }
    dir = opendir(client.stage);
    if (dir) {
        struct dirent *entry;
        while ((entry = readdir(dir))) {
            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) {
                continue;
            }
            char file[PATH_MAX];
            if (snprintf(file, sizeof file, "%s/%s", client.stage, entry->d_name) <
                (int)sizeof file) {
                unlink(file);
            }
        }
        closedir(dir);
        rmdir(client.stage);
    }
}
static int stage_helper(char executable[PATH_MAX], char libs[PATH_MAX]) {
    char source[PATH_MAX], destination[PATH_MAX];
    char *slash = strrchr(client.image, '/');
    if (!slash || (size_t)(slash - client.image) >= sizeof source) {
        return 0;
    }
    memcpy(source, client.image, (size_t)(slash - client.image));
    source[slash - client.image] = 0;
    if (!wn_appimage_private_directory(source)) {
        atomic_store(&client.status, STATUS_UNSAFE);
        return 0;
    }
    if (!slash ||
        snprintf(client.stage, sizeof client.stage, "%.*s/.wn-update-XXXXXX",
                 (int)(slash - client.image), client.image) >= (int)sizeof client.stage ||
        !mkdtemp(client.stage)) {
        atomic_store(&client.status, STATUS_DIRECTORY);
        return 0;
    }
    if (snprintf(executable, PATH_MAX, "%s/wn-appimage-update", client.stage) >= PATH_MAX ||
        snprintf(libs, PATH_MAX, "%s/lib", client.stage) >= PATH_MAX || mkdir(libs, 0700)) {
        return 0;
    }
    if (!copy_file(client.helper, executable, 0700)) {
        return 0;
    }
    slash = strrchr(client.helper, '/');
    if (!slash || snprintf(source, sizeof source, "%.*s/appimage-update-lib",
                           (int)(slash - client.helper), client.helper) >= (int)sizeof source) {
        return 0;
    }
    DIR *dir = opendir(source);
    if (!dir) {
        return 0;
    }
    struct dirent *entry;
    int ok = 1;
    while ((entry = readdir(dir))) {
        if (entry->d_name[0] == '.') {
            continue;
        }
        char file[PATH_MAX];
        if (snprintf(file, sizeof file, "%s/%s", source, entry->d_name) >= (int)sizeof file ||
            snprintf(destination, sizeof destination, "%s/%s", libs, entry->d_name) >=
                (int)sizeof destination ||
            !copy_file(file, destination, 0700)) {
            ok = 0;
            break;
        }
    }
    closedir(dir);
    return ok;
}
static void *update_worker(void *argument) {
    int channel = (int)(intptr_t)argument;
    int log_fd = -1;
    char executable[PATH_MAX], libs[PATH_MAX], home[PATH_MAX];
    if (!realpath(client.home, home) || !stage_helper(executable, libs) ||
        atomic_load(&client.stop)) {
        goto failed;
    }
    char log_path[PATH_MAX];
    if (snprintf(log_path, sizeof log_path, "%s/helper.log", client.stage) >=
        (int)sizeof log_path) {
        goto failed;
    }
    log_fd = open(log_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (log_fd < 0) {
        goto failed;
    }
    /* fork's child only uses async-signal-safe operations before exec. */
    char pid[32];
    snprintf(pid, sizeof pid, "%ld", (long)getpid());
    char *args[] = {executable,  client.image, home,         client.current,
                    client.feed, pid,          client.stage, client.automatic ? "1" : "0",
                    NULL};
    extern char **environ;
    size_t count = 0;
    while (environ[count]) {
        ++count;
    }
    char **environment = calloc(count + 2, sizeof(char *));
    char ldpath[PATH_MAX + 32];
    snprintf(ldpath, sizeof ldpath, "LD_LIBRARY_PATH=%s", libs);
    if (!environment) {
        goto failed;
    }
    size_t used = 0;
    for (size_t i = 0; i < count; ++i) {
        if (!strncmp(environ[i], "LD_LIBRARY_PATH=", 16) ||
            !strncmp(environ[i], "LD_PRELOAD=", 11)) {
            continue;
        }
        environment[used++] = environ[i];
    }
    environment[used++] = ldpath;
    client.child = fork();
    if (!client.child) {
        if (setsid() < 0 || chdir(client.stage) != 0 || dup2(channel, STDIN_FILENO) < 0 ||
            dup2(channel, STDOUT_FILENO) < 0 || dup2(log_fd, STDERR_FILENO) < 0) {
            _exit(127);
        }
        /* Includes the parent's instance lock and the UI endpoint. */
        long closed_range = -1;
#ifdef SYS_close_range
        closed_range = syscall(SYS_close_range, 3u, ~0u, 0u);
#endif
        if (closed_range != 0) {
            for (int fd = 3; fd < 65536; ++fd) {
                close(fd);
            }
        }
        execve(executable, args, environment);
        _exit(127);
    }
    close(log_fd);
    log_fd = -1;
    free(environment);
    if (client.child < 0) {
        goto failed;
    }
    close(channel);
    channel = -1;
    FILE *stream = fdopen(dup(client.socket), "r");
    if (!stream) {
        goto failed;
    }
    char line[256];
    while (fgets(line, sizeof line, stream)) {
        if (atomic_load(&client.stop)) {
            break;
        }
        if (line[0] == 'R' && line[1] == ' ') {
            size_t n = strcspn(line + 2, "\r\n");
            if (n >= sizeof client.version) {
                break;
            }
            memcpy(client.version, line + 2, n);
            client.version[n] = 0;
            atomic_store(&client.progress, 100);
            atomic_store(&client.phase, READY);
        } else if (line[0] == 'P') {
            int percent = atoi(line + 1);
            atomic_store(&client.progress, percent < 0 ? -1 : percent > 100 ? 100 : percent);
            atomic_store(&client.phase, DOWNLOADING);
        } else if (line[0] == 'C') {
            atomic_store(&client.phase, CHECKING);
        } else if (line[0] == 'I') {
            atomic_store(&client.phase, IDLE);
        } else if (line[0] == 'E') {
            atomic_store(&client.status, STATUS_UPDATE);
            atomic_store(&client.phase, FAILED);
        } else if (line[0] == 'X' && atomic_load(&client.apply)) {
            fclose(stream);
            return NULL;
        }
    }
    fclose(stream);
failed:
    if (log_fd >= 0) {
        close(log_fd);
    }
    if (channel >= 0) {
        close(channel);
    }
    if (client.child > 0) {
        kill(-client.child, SIGKILL);
        kill(client.child, SIGKILL);
        while (waitpid(client.child, NULL, 0) < 0 && errno == EINTR) {
        }
        client.child = 0;
    }
    if (!atomic_load(&client.stop)) {
        if (!atomic_load(&client.status)) {
            atomic_store(&client.status, STATUS_HELPER);
        }
        atomic_store(&client.phase, FAILED);
    }
    cleanup_stage();
    return NULL;
}
int wn_appimage_start(const char *helper, const char *home, const char *version, const char *feed,
                      int automatic) {
    if (client.active) {
        return 1;
    }
    const char *image = getenv("APPIMAGE"), *appdir = getenv("APPDIR");
    char running[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", running, sizeof running - 1);
    if (!image || !appdir || image[0] != '/' || appdir[0] != '/' || n <= 0) {
        return 0;
    }
    running[n] = 0;
    size_t mount_len = strlen(appdir);
    if (strncmp(running, appdir, mount_len) || running[mount_len] != '/') {
        return 0;
    }
    memset(&client, 0, sizeof client);
    client.socket = -1;
    if (strlen(image) >= sizeof client.image || strlen(helper) >= sizeof client.helper ||
        strlen(home) >= sizeof client.home || strlen(version) >= sizeof client.current ||
        strlen(feed) >= sizeof client.feed) {
        return 0;
    }
    strcpy(client.image, image);
    strcpy(client.helper, helper);
    strcpy(client.home, home);
    strcpy(client.current, version);
    strcpy(client.feed, feed);
    client.automatic = automatic;
    atomic_store(&client.progress, -1);
    atomic_store(&client.phase, IDLE);
    /* CPR and zsync2 do not expose a common SOCKS5h configuration. Never
     * silently leak a request outside the configured app proxy. */
    const char *proxy = getenv("WN_SOCKS5_PROXY");
    if (proxy && *proxy) {
        atomic_store(&client.status, STATUS_PROXY);
        atomic_store(&client.phase, FAILED);
        return 1;
    }
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets)) {
        atomic_store(&client.phase, FAILED);
        return 1;
    }
    client.socket = sockets[0];
    if (pthread_create(&client.worker, NULL, update_worker, (void *)(intptr_t)sockets[1])) {
        close(sockets[0]);
        close(sockets[1]);
        client.socket = -1;
        atomic_store(&client.phase, FAILED);
        return 1;
    }
    client.active = 1;
    return 1;
}
void wn_appimage_stop(void) {
    if (client.active) {
        if (!atomic_load(&client.apply)) {
            atomic_store(&client.stop, 1);
            shutdown(client.socket, SHUT_RDWR);
        }
        pthread_join(client.worker, NULL);
        close(client.socket);
    }
    memset(&client, 0, sizeof client);
    client.socket = -1;
}
int wn_appimage_phase(void) {
    return atomic_load(&client.phase);
}
int wn_appimage_progress(void) {
    return atomic_load(&client.progress);
}
const char *wn_appimage_version(void) {
    return client.version;
}
int wn_appimage_status(void) {
    return atomic_load(&client.status);
}
void wn_appimage_check(void) {
    if (!client.active || atomic_load(&client.phase) == READY) {
        return;
    }
    atomic_store(&client.status, STATUS_NONE);
    atomic_store(&client.progress, -1);
    atomic_store(&client.phase, CHECKING);
    if (!child_command('C')) {
        atomic_store(&client.status, STATUS_HELPER);
        atomic_store(&client.phase, FAILED);
    }
}
void wn_appimage_mode(int automatic) {
    if (client.active) {
        child_command(automatic ? '1' : '0');
    }
}
int wn_appimage_apply(void) {
    if (!client.active || atomic_load(&client.phase) != READY) {
        return 0;
    }
    atomic_store(&client.apply, 1);
    if (child_command('A')) {
        return 1;
    }
    atomic_store(&client.apply, 0);
    atomic_store(&client.phase, FAILED);
    return 0;
}
int wn_appimage_prepare_exit(void) {
    if (atomic_load(&client.apply)) {
        return 1;
    }
    if (!client.active || atomic_load(&client.phase) != READY) {
        return 0;
    }
    atomic_store(&client.apply, 1);
    if (child_command('Q')) {
        return 1;
    }
    atomic_store(&client.apply, 0);
    return 0;
}
