#ifndef __OpenBSD__
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#endif
#include "../app/main_sandbox.h"
#include "../app/tool_broker.h"
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#ifdef __OpenBSD__
static void path(char *out, const char *root, const char *name) {
    assert(snprintf(out, PATH_MAX, "%s/%s", root, name) < PATH_MAX);
}
static void put(const char *path, const char *text) {
    FILE *file = fopen(path, "w");
    assert(file && fputs(text, file) >= 0);
    assert(fclose(file) == 0);
}
static void clean(const char *root) {
    DIR *dir = opendir(root);
    assert(dir);
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) {
            continue;
        }
        char item[PATH_MAX];
        path(item, root, entry->d_name);
        struct stat st;
        assert(lstat(item, &st) == 0);
        if (S_ISDIR(st.st_mode)) {
            clean(item);
        } else {
            assert(unlink(item) == 0);
        }
    }
    closedir(dir);
    assert(rmdir(root) == 0);
}

int main(void) {
    const char *fixture = getenv("WN_SANDBOX_TEST_RESOURCES");
    if (!fixture || getuid() == 0 || geteuid() == 0) {
        fputs("run as non-root with root-installed WN_SANDBOX_TEST_RESOURCES\n", stderr);
        return 77;
    }
    char root[] = "/tmp/wn-broker-test.XXXXXX";
    assert(mkdtemp(root));
    char home[PATH_MAX], data[PATH_MAX], settings[PATH_MAX], resources[PATH_MAX];
    char secret[PATH_MAX], permitted[PATH_MAX], rejected[PATH_MAX], copied[PATH_MAX];
    path(home, root, "home");
    assert(mkdir(home, 0700) == 0);
    path(data, home, "data");
    assert(mkdir(data, 0700) == 0);
    path(settings, home, "config/whitenoise");
    assert(realpath(fixture, resources));
    path(secret, home, "secret");
    put(secret, "private");
    path(permitted, data, "public");
    put(permitted, "permitted");
    path(copied, data, "saved");
    path(rejected, home, "stolen");
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        signal(SIGPIPE, SIG_IGN);
        assert(setenv("HOME", home, 1) == 0);
        assert(unsetenv("DISPLAY") == 0 && unsetenv("XAUTHORITY") == 0);
        assert(unsetenv("DBUS_SESSION_BUS_ADDRESS") == 0);
        assert(wn_main_sandbox_prepare(data, settings, resources, NULL, 0) == 0);
        assert(wn_tools_start() == 0);
        assert(wn_main_sandbox_enter() == 0);
        unsigned char *out, *errors;
        size_t length, errors_length;
        int status;
        char allowed_url[PATH_MAX + 8], denied_url[PATH_MAX + 8];
        assert(snprintf(allowed_url, sizeof allowed_url, "file://%s", permitted) <
               (int)sizeof allowed_url);
        assert(snprintf(denied_url, sizeof denied_url, "file://%s", secret) <
               (int)sizeof denied_url);
        const char *read_allowed[] = {"-q", "-sS", allowed_url};
        assert(wn_tools_run(WN_TOOL_CURL, read_allowed, 3, NULL, &out, &length, &errors,
                            &errors_length, &status) == 0);
        assert(status == 0 && length == 9 && !memcmp(out, "permitted", 9));
        free(out);
        free(errors);
        const char *read_denied[] = {"-q", "-sS", denied_url};
        assert(wn_tools_run(WN_TOOL_CURL, read_denied, 3, NULL, &out, &length, &errors,
                            &errors_length, &status) == 0);
        assert(status != 0 && length == 0);
        free(out);
        free(errors);
        const char *save_allowed[] = {"-q", "-sS", "--output", copied, allowed_url};
        assert(wn_tools_run(WN_TOOL_CURL, save_allowed, 5, NULL, &out, &length, &errors,
                            &errors_length, &status) == 0);
        assert(status == 0);
        free(out);
        free(errors);
        const char *save_denied[] = {"-q", "-sS", "--output", rejected, allowed_url};
        assert(wn_tools_run(WN_TOOL_CURL, save_denied, 5, NULL, &out, &length, &errors,
                            &errors_length, &status) == 0);
        assert(status != 0);
        free(out);
        free(errors);
        assert(wn_tools_run(999, NULL, 0, NULL, &out, &length, &errors, &errors_length, &status) ==
               EINVAL);
        assert(wn_tools_run(WN_TOOL_CURL, NULL, 65, NULL, &out, &length, &errors, &errors_length,
                            &status) == E2BIG);
        assert(wn_tools_run(WN_TOOL_NOTIFY, NULL, 0, "socks5h://127.0.0.1:9050", &out, &length,
                            &errors, &errors_length, &status) == EINVAL);
        assert(wn_tools_run(WN_TOOL_CURL, read_allowed, 3, "http://127.0.0.1:9050", &out, &length,
                            &errors, &errors_length, &status) == EINVAL);
        wn_tools_stop();
        _exit(0);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    assert(access(rejected, F_OK) < 0 && errno == ENOENT);
    FILE *saved = fopen(copied, "r");
    char text[16] = {0};
    assert(saved && fread(text, 1, sizeof text, saved) == 9);
    assert(!strcmp(text, "permitted"));
    fclose(saved);
    clean(root);
    puts("confined tool broker boundaries passed");
    return 0;
}
#else
int main(void) {
    puts("tool broker kernel tests require OpenBSD");
    return 77;
}
#endif
