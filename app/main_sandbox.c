#ifndef __OpenBSD__
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#endif
#include "main_sandbox.h"

#include <errno.h>
#include <ctype.h>
#include <dirent.h>
#include <fcntl.h>
#include <fts.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

struct rule {
    char path[PATH_MAX];
    const char *permissions;
};
static struct rule rules[128];
static size_t rule_count;
static char data_path[PATH_MAX], settings_path[PATH_MAX], downloads_path[PATH_MAX];
static char failure[PATH_MAX + 160];
static int prepared;
static char private_home[PATH_MAX];
static int private_home_fd = -1, private_sndio_fd = -1;

static int fail(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(failure, sizeof failure, format, args);
    va_end(args);
    return -1;
}

static int join(char *out, const char *base, const char *name) {
    if (snprintf(out, PATH_MAX, "%s/%s", base, name) >= PATH_MAX) {
        return fail("path too long: %s/%s", base, name);
    }
    return 0;
}

static int within(const char *path, const char *directory) {
    size_t n = strlen(directory);
    return strcmp(directory, "/") == 0 ||
           (strncmp(path, directory, n) == 0 && (path[n] == '/' || path[n] == '\0'));
}

/* Resolve every existing component before creating missing ones. In particular,
 * a symlink followed by '..' must not be lexically collapsed. */
static int directory(const char *input, char *out) {
    char pending[PATH_MAX], current[PATH_MAX], next[PATH_MAX];
    if (!input || !*input || strlen(input) >= sizeof pending) {
        return fail("empty or oversized directory path");
    }
    strcpy(pending, input);
    if (input[0] == '/') {
        strcpy(current, "/");
    } else if (!getcwd(current, sizeof current)) {
        return fail("getcwd: %s", strerror(errno));
    }
    char *save = NULL;
    for (char *part = strtok_r(pending, "/", &save); part; part = strtok_r(NULL, "/", &save)) {
        if (join(next, current, part)) {
            return -1;
        }
        struct stat st;
        if (stat(next, &st) < 0) {
            if (errno != ENOENT || mkdir(next, 0700) < 0) {
                return fail("create directory %s: %s", next, strerror(errno));
            }
        } else if (!S_ISDIR(st.st_mode)) {
            return fail("not a directory: %s", next);
        }
        if (!realpath(next, current)) {
            return fail("resolve %s: %s", next, strerror(errno));
        }
    }
    strcpy(out, current);
    return 0;
}

static int add(const char *path, const char *permissions, int optional) {
    char resolved[PATH_MAX];
    if (!realpath(path, resolved)) {
        if (optional && errno == ENOENT) {
            return 0;
        }
        return fail("resolve %s: %s", path, strerror(errno));
    }
    for (size_t i = 0; i < rule_count; ++i) {
        if (strcmp(rules[i].path, resolved) == 0) {
            if (strcmp(rules[i].permissions, permissions) == 0) {
                return 0;
            }
            return fail("conflicting sandbox permissions: %s", resolved);
        }
        /* Writable trees may never contain code or trusted read-only resources,
         * nor be hidden underneath a more specific read-only rule. */
        if ((strchr(permissions, 'w') != NULL) != (strchr(rules[i].permissions, 'w') != NULL) &&
            (within(resolved, rules[i].path) || within(rules[i].path, resolved))) {
            return fail("overlapping writable and trusted paths: %s and %s", resolved,
                        rules[i].path);
        }
    }
    if (rule_count == sizeof rules / sizeof rules[0]) {
        return fail("too many sandbox paths");
    }
    strcpy(rules[rule_count].path, resolved);
    rules[rule_count++].permissions = permissions;
    return 0;
}

/* Validate the route, not just realpath's destination: a root-owned link may
 * traverse a user-controlled redirect before reaching a root-owned inode.
 * Resolve one component at a time, expanding at most 40 symlinks. */
static int trusted_ancestors(const char *path) {
    char pending[PATH_MAX], current[PATH_MAX] = "/";
    char next[PATH_MAX], target[PATH_MAX], expanded[PATH_MAX];
    if (!path || !*path || strlen(path) >= sizeof pending) {
        return fail("invalid trusted path");
    }
    if (path[0] == '/') {
        strcpy(pending, path);
    } else {
        char working[PATH_MAX];
        if (!getcwd(working, sizeof working) || join(pending, working, path)) {
            return fail("resolve trusted working directory: %s", strerror(errno));
        }
    }
    struct stat st;
    if (lstat("/", &st) || st.st_uid != 0 || (st.st_mode & 0022)) {
        return fail("runtime root must be root-owned and not group/other writable");
    }
    unsigned links = 0;
    char *part = pending;
    for (;;) {
        part += strspn(part, "/");
        if (!*part) {
            return 0;
        }
        size_t length = strcspn(part, "/");
        char *rest = part + length;
        if (*rest) {
            *rest++ = '\0';
        }
        if (!strcmp(part, ".")) {
            part = rest;
            continue;
        }
        if (!strcmp(part, "..")) {
            char *slash = strrchr(current, '/');
            if (slash == current) {
                slash[1] = '\0';
            } else {
                *slash = '\0';
            }
            part = rest;
            continue;
        }
        if (join(next, current, part) || lstat(next, &st)) {
            return fail("inspect trusted component %s: %s", next, strerror(errno));
        }
        if (st.st_uid != 0 || (!S_ISLNK(st.st_mode) && (st.st_mode & 0022))) {
            return fail("runtime must be root-owned and not group/other writable: %s", next);
        }
        if (S_ISLNK(st.st_mode)) {
            if (++links > 40) {
                return fail("too many trusted symlink expansions: %s", path);
            }
            ssize_t size = readlink(next, target, sizeof target - 1);
            if (size < 0 || (size_t)size == sizeof target - 1) {
                return fail("read trusted symlink %s: %s", next, strerror(errno));
            }
            target[size] = '\0';
            if (join(expanded, target, rest)) {
                return -1;
            }
            if (target[0] == '/') {
                strcpy(current, "/");
            }
            strcpy(pending, expanded);
            part = pending;
            continue;
        }
        if ((!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) || (*rest && !S_ISDIR(st.st_mode))) {
            return fail("invalid trusted path component: %s", next);
        }
        strcpy(current, next);
        part = rest;
    }
}

static int trusted_tree(const char *path) {
    if (trusted_ancestors(path)) {
        return -1;
    }
    char *paths[] = {(char *)path, NULL};
    FTS *tree = fts_open(paths, FTS_LOGICAL | FTS_NOCHDIR, NULL);
    if (!tree) {
        return fail("inspect trusted tree %s: %s", path, strerror(errno));
    }
    FTSENT *entry;
    int result = 0;
    errno = 0;
    while ((entry = fts_read(tree))) {
        if (entry->fts_info == FTS_DP) {
            continue;
        }
        struct stat link;
        if (entry->fts_info == FTS_ERR || entry->fts_info == FTS_DNR || entry->fts_info == FTS_NS ||
            entry->fts_info == FTS_SLNONE || lstat(entry->fts_accpath, &link)) {
            result = fail("cannot inspect trusted resource: %s", entry->fts_path);
            break;
        }
        const struct stat *st = entry->fts_statp;
        if (link.st_uid != 0 || st->st_uid != 0 || (st->st_mode & 0022) ||
            (!S_ISREG(st->st_mode) && !S_ISDIR(st->st_mode))) {
            result = fail("runtime must be root-owned and not group/other writable: %s",
                          entry->fts_path);
            break;
        }
        if (S_ISLNK(link.st_mode) && trusted_ancestors(entry->fts_path)) {
            result = -1;
            break;
        }
        errno = 0;
    }
    if (!result && errno) {
        result = fail("traverse trusted tree %s: %s", path, strerror(errno));
    }
    fts_close(tree);
    return result;
}

enum trust_presence { TRUST_REQUIRED, TRUST_OPTIONAL };

static int trusted_rule(const char *path, const char *permissions, enum trust_presence presence) {
    struct stat st;
    if (lstat(path, &st)) {
        if (presence == TRUST_OPTIONAL && errno == ENOENT) {
            return 0;
        }
        return fail("inspect runtime %s: %s", path, strerror(errno));
    }
    if (trusted_tree(path)) {
        return -1;
    }
    return add(path, permissions, 0);
}

static int socket_rule(const char *path, int optional) {
    struct stat st;
    if (stat(path, &st)) {
        if (optional && errno == ENOENT) {
            return 0;
        }
        return fail("inspect socket %s: %s", path, strerror(errno));
    }
    if (!S_ISSOCK(st.st_mode)) {
        return fail("not a socket: %s", path);
    }
    return add(path, "rw", 0);
}

static int copy_authority(const char *source, const char *destination) {
    int input = open(source, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (input < 0) {
        if (errno == ENOENT) {
            return 0;
        }
        return fail("open authority %s: %s", source, strerror(errno));
    }
    struct stat st;
    if (fstat(input, &st) || !S_ISREG(st.st_mode) || st.st_size > 1024 * 1024) {
        close(input);
        return fail("invalid authority file: %s", source);
    }
    char temporary[PATH_MAX];
    if (snprintf(temporary, sizeof temporary, "%s.XXXXXX", destination) >= PATH_MAX) {
        close(input);
        return fail("authority path too long");
    }
    int output = mkstemp(temporary);
    if (output < 0) {
        close(input);
        return fail("create private authority: %s", strerror(errno));
    }
    char bytes[4096];
    size_t total = 0;
    int result = 0;
    for (;;) {
        ssize_t size = read(input, bytes, sizeof bytes);
        if (size < 0 && errno == EINTR) {
            continue;
        }
        if (size < 0 || (total += (size_t)size) > 1024 * 1024) {
            result = fail("read authority %s", source);
            break;
        }
        if (!size) {
            break;
        }
        for (ssize_t done = 0; done < size;) {
            ssize_t n = write(output, bytes + done, (size_t)(size - done));
            if (n < 0 && errno == EINTR) {
                continue;
            }
            if (n <= 0) {
                result = fail("write private authority: %s", strerror(errno));
                break;
            }
            done += n;
        }
        if (result) {
            break;
        }
    }
    close(input);
    if (close(output) && !result) {
        result = fail("close private authority: %s", strerror(errno));
    }
    if (!result && rename(temporary, destination)) {
        result = fail("install private authority: %s", strerror(errno));
    }
    if (result) {
        unlink(temporary);
    }
    return result;
}

/* Traverse only this generated runtime HOME, with no symlink following. GTK
 * state is ephemeral too; credentials must not persist because caches exist. */
static int clear_runtime_dir(int directory_fd, unsigned depth) {
    if (depth > 64) {
        return ELOOP;
    }
    int scan_fd = dup(directory_fd);
    if (scan_fd < 0) {
        return errno;
    }
    DIR *directory = fdopendir(scan_fd);
    if (!directory) {
        int error = errno;
        close(scan_fd);
        return error;
    }
    int error = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (!entry) {
            if (errno) {
                error = errno;
            }
            break;
        }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) {
            continue;
        }
        struct stat st;
        if (fstatat(directory_fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW)) {
            error = errno;
            continue;
        }
        if (S_ISDIR(st.st_mode)) {
            int child = openat(directory_fd, entry->d_name,
                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (child < 0) {
                error = errno;
                continue;
            }
            int child_error = clear_runtime_dir(child, depth + 1);
            close(child);
            if (child_error) {
                error = child_error;
            }
            if (unlinkat(directory_fd, entry->d_name, AT_REMOVEDIR)) {
                error = errno;
            }
        } else if (unlinkat(directory_fd, entry->d_name, 0)) {
            error = errno;
        }
    }
    closedir(directory);
    return error;
}

int wn_main_sandbox_cleanup(void) {
    int error = 0;
    if (private_sndio_fd >= 0) {
        if (unlinkat(private_sndio_fd, "cookie", 0) && errno != ENOENT) {
            error = errno;
        }
        close(private_sndio_fd);
        private_sndio_fd = -1;
    }
    if (private_home_fd >= 0) {
        if (unlinkat(private_home_fd, ".Xauthority", 0) && errno != ENOENT) {
            error = errno;
        }
        int tree_error = clear_runtime_dir(private_home_fd, 0);
        if (tree_error) {
            error = tree_error;
        }
        close(private_home_fd);
        private_home_fd = -1;
    }
    if (*private_home) {
        if (rmdir(private_home) && errno != ENOENT) {
            error = errno;
        }
        private_home[0] = '\0';
    }
    return error ? fail("remove private runtime home: %s", strerror(error)) : 0;
}

static int private_environment(void) {
    static const struct {
        const char *variable, *directory;
    } paths[] = {
        {"XDG_CONFIG_HOME", ".config"},
        {"XDG_CACHE_HOME", ".cache"},
        {"XDG_DATA_HOME", ".local/share"},
    };
    for (size_t i = 0; i < sizeof paths / sizeof paths[0]; ++i) {
        char path[PATH_MAX], resolved[PATH_MAX];
        if (join(path, private_home, paths[i].directory) || directory(path, resolved) ||
            !within(resolved, private_home) || setenv(paths[i].variable, resolved, 1)) {
            return fail("prepare private runtime environment: %s", strerror(errno));
        }
    }
    return setenv("HOME", private_home, 1);
}

static int private_authorities(const char *home) {
    char sndio[PATH_MAX], source[PATH_MAX], target[PATH_MAX];
    if (join(private_home, data_path, "runtime-home.XXXXXX") || !mkdtemp(private_home)) {
        private_home[0] = '\0';
        return fail("create private runtime home: %s", strerror(errno));
    }
    private_home_fd = open(private_home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (private_home_fd < 0) {
        int error = errno;
        wn_main_sandbox_cleanup();
        return fail("open private runtime home: %s", strerror(error));
    }
    const char *authority = getenv("XAUTHORITY");
    if (!authority || !*authority) {
        if (join(source, home, ".Xauthority")) {
            wn_main_sandbox_cleanup();
            return -1;
        }
        authority = source;
    }
    if (join(target, private_home, ".Xauthority") || copy_authority(authority, target) ||
        setenv("XAUTHORITY", target, 1) || join(sndio, private_home, ".sndio") ||
        mkdir(sndio, 0700) ||
        (private_sndio_fd = open(sndio, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) < 0 ||
        join(source, home, ".sndio/cookie") || join(target, sndio, "cookie") ||
        copy_authority(source, target) || private_environment()) {
        int error = errno;
        wn_main_sandbox_cleanup();
        return fail("prepare private display/audio authority: %s", strerror(error));
    }
    return 0;
}

static int desktop_bus(void) {
    const char *address = getenv("DBUS_SESSION_BUS_ADDRESS");
    if (!address) {
        return 0;
    }
    for (const char *entry = address; *entry;) {
        size_t length = strcspn(entry, ";");
        if (!strncmp(entry, "unix:", 5)) {
            const char *field = entry + 5, *end = entry + length;
            while (field < end) {
                const char *next = memchr(field, ',', (size_t)(end - field));
                if (!next) {
                    next = end;
                }
                if (next - field > 5 && !strncmp(field, "path=", 5)) {
                    char path[PATH_MAX];
                    size_t n = 0;
                    for (const char *p = field + 5; p < next; ++p) {
                        unsigned char byte = (unsigned char)*p;
                        if (byte == '%') {
                            if (next - p < 3 || !isxdigit((unsigned char)p[1]) ||
                                !isxdigit((unsigned char)p[2])) {
                                return fail("invalid session bus path escape");
                            }
                            char hex[3] = {p[1], p[2], 0};
                            byte = (unsigned char)strtoul(hex, NULL, 16);
                            p += 2;
                        }
                        if (!byte || n == sizeof path - 1) {
                            return fail("invalid session bus path");
                        }
                        path[n++] = (char)byte;
                    }
                    path[n] = '\0';
                    if (path[0] != '/' || socket_rule(path, 0)) {
                        return fail("invalid session bus socket");
                    }
                }
                field = next < end ? next + 1 : end;
            }
        }
        entry += length;
        if (*entry == ';') {
            ++entry;
        }
    }
    return 0;
}

static int writable(const char *path, const char *home) {
    static const char *const protected[] = {"/",    "/tmp",  "/var/tmp", "/usr", "/etc",
                                            "/bin", "/sbin", "/dev",     "/var", "/home"};
    if (within(home, path)) {
        return fail("writable directory exposes HOME: %s", path);
    }
    for (size_t i = 0; i < sizeof protected / sizeof protected[0]; ++i) {
        if (!strcmp(path, protected[i])) {
            return fail("writable directory is too broad: %s", path);
        }
    }
    return add(path, "rwc", 0);
}

/* user-dirs.dirs is data, not a shell script. Accept the XDG quoted absolute
 * path / $HOME convention, including spaces and escaped quotes/backslashes.
 * Invalid explicit settings fail rather than quietly granting another folder. */
static int downloads(const char *config, const char *home, char *out) {
    char file[PATH_MAX], line[PATH_MAX + 64], value[PATH_MAX];
    if (join(file, config, "user-dirs.dirs")) {
        return -1;
    }
    FILE *stream = fopen(file, "r");
    int found = 0;
    if (!stream && errno != ENOENT) {
        return fail("read %s: %s", file, strerror(errno));
    }
    if (stream) {
        while (fgets(line, sizeof line, stream)) {
            char *p = line;
            while (*p == ' ' || *p == '\t') {
                ++p;
            }
            const char key[] = "XDG_DOWNLOAD_DIR=";
            if (strncmp(p, key, sizeof key - 1)) {
                continue;
            }
            p += sizeof key - 1;
            if (found || *p++ != '"') {
                fclose(stream);
                return fail("invalid Downloads entry in %s", file);
            }
            size_t n = 0;
            if (!strncmp(p, "$HOME", 5) && (p[5] == '/' || p[5] == '"')) {
                n = strlen(home);
                memcpy(value, home, n);
                p += 5;
            }
            while (*p && *p != '"' && *p != '\n') {
                if (n >= sizeof value - 1) {
                    break;
                }
                if (*p == '\\') {
                    ++p;
                    if (*p != '\\' && *p != '"' && *p != '$' && *p != '`') {
                        break;
                    }
                } else if (*p == '$' || *p == '`') {
                    break;
                }
                value[n++] = *p++;
            }
            if (*p++ != '"' || n >= sizeof value - 1) {
                fclose(stream);
                return fail("invalid Downloads path in %s", file);
            }
            value[n] = '\0';
            while (*p == ' ' || *p == '\t' || *p == '\r') {
                ++p;
            }
            if ((*p && *p != '\n' && *p != '#') || value[0] != '/') {
                fclose(stream);
                return fail("Downloads must be an absolute directory in %s", file);
            }
            found = 1;
        }
        int bad = ferror(stream);
        fclose(stream);
        if (bad) {
            return fail("read %s failed", file);
        }
    }
    if (!found && join(value, home, "Downloads")) {
        return -1;
    }
    return directory(value, out);
}

int wn_main_sandbox_prepare(const char *data, const char *settings, const char *resources,
                            const char *const *helpers, size_t helper_count) {
    char home[PATH_MAX], config[PATH_MAX], temporary[PATH_MAX], cache[PATH_MAX];
    if (prepared) {
        return fail("sandbox already prepared");
    }
    if (getuid() == 0 || geteuid() == 0) {
        return fail("the confined app must run as a non-root user");
    }
    rule_count = 0;
    const char *env_home = getenv("HOME");
    if (!env_home || !realpath(env_home, home)) {
        return fail("HOME must resolve to an existing directory");
    }
    if (directory(data, data_path) || directory(settings, settings_path)) {
        return -1;
    }
    if (!settings || strlen(settings) >= sizeof config) {
        return fail("invalid settings directory");
    }
    strcpy(config, settings);
    char *slash = strrchr(config, '/');
    if (!slash) {
        strcpy(config, ".");
    } else if (slash == config) {
        slash[1] = '\0';
    } else {
        *slash = '\0';
    }
    if (downloads(config, home, downloads_path) || writable(data_path, home) ||
        writable(settings_path, home) || writable(downloads_path, home) ||
        trusted_rule(resources, "r", TRUST_REQUIRED)) {
        return -1;
    }
    for (size_t i = 0; i < helper_count; ++i) {
        struct stat st;
        if (!helpers[i] || stat(helpers[i], &st) || !S_ISREG(st.st_mode) ||
            access(helpers[i], X_OK)) {
            return fail("helper is not executable: %s", helpers[i] ? helpers[i] : "(null)");
        }
        if (st.st_nlink != 1) {
            return fail("helper has writable hard-link aliases: %s", helpers[i]);
        }
        /* Exact execute grants remain separate from readable resource trees. */
        if (trusted_rule(helpers[i], "x", TRUST_REQUIRED)) {
            return -1;
        }
    }
    /* Libraries may be loaded lazily by SDL, Mesa, mpv and TLS. These trees
     * contain no executable grant: only the exact helpers above receive x. */
    static const char *const readonly[] = {"/usr/lib",
                                           "/usr/libexec/ld.so",
                                           "/usr/local/lib",
                                           "/usr/X11R6/lib",
                                           "/var/run/ld.so.hints",
                                           "/usr/share/fonts",
                                           "/usr/local/share/fonts",
                                           "/usr/X11R6/lib/X11/fonts",
                                           "/etc/fonts",
                                           "/usr/local/etc/fonts",
                                           "/usr/X11R6/share/X11",
                                           "/usr/share/X11",
                                           "/usr/share/locale",
                                           "/usr/share/zoneinfo",
                                           "/etc/localtime",
                                           "/etc/ssl/cert.pem",
                                           "/etc/ssl/certs",
                                           "/etc/resolv.conf",
                                           "/etc/hosts",
                                           "/etc/services",
                                           "/etc/protocols",
                                           "/usr/local/share/glib-2.0/schemas",
                                           "/usr/local/share/icons",
                                           "/usr/local/share/mime",
                                           "/usr/local/share/themes",
                                           "/usr/local/share/locale",
                                           "/usr/local/etc/gtk-4.0",
                                           "/etc/machine-id",
                                           "/var/lib/dbus/machine-id"};
    for (size_t i = 0; i < sizeof readonly / sizeof readonly[0]; ++i) {
        if (trusted_rule(readonly[i], "r", TRUST_OPTIONAL)) {
            return -1;
        }
    }
    if (add("/dev/null", "rw", 0) || add("/dev/urandom", "r", 1)) {
        return -1;
    }
    /* Later display connections use the same exact socket; copy user-owned
     * authority files rather than granting aliases outside writable roots. */
    const char *display = getenv("DISPLAY");
    if (display && (display[0] == ':' || !strncmp(display, "unix:", 5))) {
        const char *number = strchr(display, ':') + 1;
        char *end;
        errno = 0;
        unsigned long index = strtoul(number, &end, 10);
        if (errno || end == number || (*end && *end != '.') || index > 65535) {
            return fail("invalid local DISPLAY");
        }
        char socket_path[64];
        snprintf(socket_path, sizeof socket_path, "/tmp/.X11-unix/X%lu", index);
        if (socket_rule(socket_path, 0)) {
            return -1;
        }
    }
    if (private_authorities(home) || desktop_bus()) {
        return -1;
    }
    /* Existing display/DRM descriptors stay usable. New DRM opens are exact
     * device nodes, never /dev. Audio uses sndiod's socket, not /tmp as a tree. */
    for (unsigned i = 0; i < 16; ++i) {
        char node[64];
        snprintf(node, sizeof node, "/dev/dri/card%u", i);
        if (add(node, "rw", 1)) {
            return -1;
        }
        snprintf(node, sizeof node, "/dev/dri/renderD%u", 128 + i);
        if (add(node, "rw", 1)) {
            return -1;
        }
        snprintf(node, sizeof node, "/tmp/sndio/sock%u", i);
        if (socket_rule(node, 1)) {
            return -1;
        }
    }
    /* SQL temp files and graphics caches must stay within the real data root. */
    if (join(temporary, data_path, "tmp") || directory(temporary, temporary) ||
        join(cache, data_path, "mesa-cache") || directory(cache, cache)) {
        return -1;
    }
    if (!within(temporary, data_path) || !within(cache, data_path)) {
        return fail("temporary/cache directory escapes data directory");
    }
    if (setenv("TMPDIR", temporary, 1) || setenv("SQLITE_TMPDIR", temporary, 1) ||
        setenv("MESA_SHADER_CACHE_DIR", cache, 1)) {
        return fail("set sandbox environment: %s", strerror(errno));
    }
    prepared = 1;
    return 0;
}

const char *wn_main_sandbox_data(void) {
    return data_path;
}
const char *wn_main_sandbox_settings(void) {
    return settings_path;
}
const char *wn_main_sandbox_downloads(void) {
    return downloads_path;
}
const char *wn_main_sandbox_error(void) {
    return failure;
}

#define MAIN_PROMISES                                                                              \
    "stdio rpath wpath cpath inet dns unix proc fattr flock drm prot_exec sendfd recvfd audio "    \
    "getpw"
#define LAUNCH_PROMISES MAIN_PROMISES " exec"
#define TOOL_PROMISES MAIN_PROMISES " exec"

enum sandbox_role { SANDBOX_MAIN, SANDBOX_LAUNCHER };

static int enter_policy(enum sandbox_role role) {
    if (!prepared) {
        return fail("sandbox was not prepared");
    }
#ifdef __OpenBSD__
    for (size_t i = 0; i < rule_count; ++i) {
        if (unveil(rules[i].path, rules[i].permissions)) {
            return fail("unveil %s (%s): %s", rules[i].path, rules[i].permissions, strerror(errno));
        }
    }
    if (unveil(NULL, NULL)) {
        return fail("lock unveil: %s", strerror(errno));
    }
    /* Only the prestarted trusted launcher can reset policy on exec. Main's
     * raw execve syscall is fatal even with an approved executable path. */
    if (pledge(role == SANDBOX_MAIN ? MAIN_PROMISES : LAUNCH_PROMISES, NULL)) {
        return fail("pledge: %s", strerror(errno));
    }
    return 0;
#else
    (void)role;
    return fail("main sandbox requires OpenBSD");
#endif
}

int wn_main_sandbox_enter(void) {
    return enter_policy(SANDBOX_MAIN);
}

int wn_main_sandbox_enter_launcher(void) {
    return enter_policy(SANDBOX_LAUNCHER);
}

int wn_main_sandbox_keep_exec(void) {
#ifdef __OpenBSD__
    if (pledge(LAUNCH_PROMISES, LAUNCH_PROMISES)) {
        return fail("retain helper policy: %s", strerror(errno));
    }
    return 0;
#else
    return fail("helper confinement requires OpenBSD");
#endif
}

static char tool_paths[4][PATH_MAX];
static size_t tool_count;

int wn_main_sandbox_prepare_tools(const char *const *executables, size_t count) {
    if (!prepared || tool_count || count > 4) {
        return fail("invalid broker initialization");
    }
    size_t base_count = rule_count;
    for (size_t i = 0; i < count; ++i) {
        if (!executables[i] || trusted_rule(executables[i], "x", TRUST_REQUIRED) ||
            !realpath(executables[i], tool_paths[i])) {
            return fail("invalid broker executable");
        }
    }
#ifdef __OpenBSD__
    /* Pin directory identities now, not per request: a confined main can
     * rename writable subdirectories but cannot substitute a broader root. */
    for (size_t i = 0; i < base_count; ++i) {
        if (strchr(rules[i].permissions, 'x')) {
            continue;
        }
        if (unveil(rules[i].path, rules[i].permissions)) {
            return fail("broker unveil %s: %s", rules[i].path, strerror(errno));
        }
    }
    for (size_t i = 0; i < count; ++i) {
        if (unveil(tool_paths[i], "x")) {
            return fail("broker executable unveil: %s", strerror(errno));
        }
    }
    if (pledge(TOOL_PROMISES " unveil", TOOL_PROMISES)) {
        return fail("broker pledge: %s", strerror(errno));
    }
    tool_count = count;
    return 0;
#else
    (void)base_count;
    return fail("tool confinement requires OpenBSD");
#endif
}

int wn_main_sandbox_enter_tool(const char *executable) {
    if (!tool_count || !executable) {
        return fail("tool broker was not initialized");
    }
    int selected = 0;
    for (size_t i = 0; i < tool_count; ++i) {
        if (!strcmp(tool_paths[i], executable)) {
            selected = 1;
        }
    }
    if (!selected) {
        return fail("tool is not in the frozen allowlist");
    }
#ifdef __OpenBSD__
    for (size_t i = 0; i < tool_count; ++i) {
        if (strcmp(tool_paths[i], executable) && unveil(tool_paths[i], "")) {
            return fail("remove other tool authority: %s", strerror(errno));
        }
    }
    if (unveil(NULL, NULL) || pledge(TOOL_PROMISES, TOOL_PROMISES)) {
        return fail("lock tool policy: %s", strerror(errno));
    }
    return 0;
#else
    return fail("tool confinement requires OpenBSD");
#endif
}
