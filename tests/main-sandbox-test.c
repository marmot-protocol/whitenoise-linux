#ifndef __OpenBSD__
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#endif
#include "../app/main_sandbox.c"
#include <assert.h>
#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/wait.h>

/* Include the implementation to exercise policy preparation on non-OpenBSD
 * hosts too, without replacing or mocking the kernel sandbox entry point. */
static char root[PATH_MAX], home[PATH_MAX], data[PATH_MAX], config[PATH_MAX];
static char settings[PATH_MAX], resources[PATH_MAX], helper[PATH_MAX];

static void make_dir(char *out, const char *parent, const char *name) {
    assert(join(out, parent, name) == 0);
    assert(mkdir(out, 0700) == 0);
}

static void put(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    assert(f);
    assert(fputs(text, f) >= 0);
    assert(fclose(f) == 0);
}

static void setup(void) {
    strcpy(root, "/tmp/wn-sandbox-test.XXXXXX");
    assert(mkdtemp(root));
    make_dir(home, root, "home");
    make_dir(data, home, "data");
    make_dir(config, home, "config");
    assert(join(settings, config, "whitenoise") == 0);
    const char *fixture = getenv("WN_SANDBOX_TEST_RESOURCES");
    assert(fixture && realpath(fixture, resources));
    assert(join(helper, resources, "wn-helper") == 0);
    assert(setenv("HOME", home, 1) == 0);
    assert(unsetenv("DISPLAY") == 0);
    assert(unsetenv("XAUTHORITY") == 0);
    assert(unsetenv("DBUS_SESSION_BUS_ADDRESS") == 0);
}

static int prepare(const char *data_dir) {
    const char *helpers[] = {helper};
    return wn_main_sandbox_prepare(data_dir, settings, resources, helpers, 1);
}

static void remove_tree(const char *path) {
    /* No external rm invocation: tests must also work with a restricted PATH. */
    DIR *dir = opendir(path);
    if (!dir) {
        assert(unlink(path) == 0);
        return;
    }
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) {
            continue;
        }
        char child[PATH_MAX];
        assert(join(child, path, entry->d_name) == 0);
        struct stat st;
        assert(lstat(child, &st) == 0);
        if (S_ISDIR(st.st_mode)) {
            remove_tree(child);
        } else {
            assert(unlink(child) == 0);
        }
    }
    closedir(dir);
    assert(rmdir(path) == 0);
}

static void default_directories(void) {
    assert(prepare(data) == 0);
    char expected[PATH_MAX];
    assert(join(expected, home, "Downloads") == 0);
    assert(!strcmp(wn_main_sandbox_downloads(), expected));
    assert(!strcmp(wn_main_sandbox_data(), data));
    assert(!strcmp(wn_main_sandbox_settings(), settings));
    assert(within(getenv("TMPDIR"), data));
    assert(within(getenv("SQLITE_TMPDIR"), data));
}

static void custom_downloads_and_relative_data(void) {
    char dirs[PATH_MAX], custom[PATH_MAX];
    assert(join(dirs, config, "user-dirs.dirs") == 0);
    put(dirs, "XDG_DOWNLOAD_DIR=\"$HOME/Received Files\"\n");
    assert(chdir(home) == 0);
    assert(prepare("new/../relative-data") == 0);
    assert(join(custom, home, "Received Files") == 0);
    assert(!strcmp(wn_main_sandbox_downloads(), custom));
    assert(join(custom, home, "relative-data") == 0);
    assert(!strcmp(wn_main_sandbox_data(), custom));
}

static void symlink_data(void) {
    char alias[PATH_MAX];
    assert(join(alias, home, "alias") == 0);
    assert(symlink(data, alias) == 0);
    assert(prepare(alias) == 0);
    assert(!strcmp(wn_main_sandbox_data(), data));
}

static void deny_home_downloads(void) {
    char dirs[PATH_MAX];
    assert(join(dirs, config, "user-dirs.dirs") == 0);
    put(dirs, "XDG_DOWNLOAD_DIR=\"$HOME\"\n");
    assert(prepare(data) < 0);
}

static void deny_invalid_downloads(void) {
    char dirs[PATH_MAX];
    assert(join(dirs, config, "user-dirs.dirs") == 0);
    put(dirs, "XDG_DOWNLOAD_DIR=\"relative/Downloads\"\n");
    assert(prepare(data) < 0);
}

static void deny_executable_in_data(void) {
    assert(join(helper, data, "wn-helper") == 0);
    put(helper, "#!/bin/sh\nexit 0\n");
    assert(chmod(helper, 0700) == 0);
    assert(prepare(data) < 0);
}

static void deny_unsafe_resources(void) {
    char unsafe[PATH_MAX];
    make_dir(unsafe, root, "unsafe-resources");
    assert(wn_main_sandbox_prepare(data, settings, unsafe, NULL, 0) < 0);
    assert(strstr(wn_main_sandbox_error(), "root-owned"));
}

static void deny_unsafe_targets(void) {
    char target[PATH_MAX], alias[PATH_MAX];
    assert(join(target, home, "user-font") == 0);
    assert(join(alias, home, "font-link") == 0);
    put(target, "user-owned font");
    assert(symlink(target, alias) == 0);
    assert(trusted_tree(alias) < 0);
}

static void deny_writable_runtime(void) {
    char unsafe[PATH_MAX];
    assert(join(unsafe, resources, "../../bad-mode") == 0);
    assert(trusted_tree(unsafe) < 0);
    assert(strstr(wn_main_sandbox_error(), "root-owned"));
}

static void deny_writable_symlink(void) {
    char unsafe[PATH_MAX];
    assert(join(unsafe, resources, "../../bad-link") == 0);
    assert(trusted_tree(unsafe) < 0);
    assert(strstr(wn_main_sandbox_error(), "root-owned"));
}

static void deny_mutable_symlink_chain(void) {
    char unsafe[PATH_MAX], expected[PATH_MAX], resolved[PATH_MAX];
    assert(join(unsafe, resources, "../../bad-chain") == 0);
    assert(join(expected, resources, "font") == 0);
    assert(realpath(unsafe, resolved) && !strcmp(resolved, expected));
    /* The final inode and its canonical parents are trusted; the intervening
     * mutable directory must still make this root-owned symlink unsafe. */
    assert(trusted_tree(unsafe) < 0);
    assert(strstr(wn_main_sandbox_error(), "root-owned"));
}

static void copy_private_authority(void) {
    char authority[PATH_MAX];
    assert(join(authority, home, ".Xauthority") == 0);
    put(authority, "private X cookie");
    assert(setenv("XDG_CONFIG_HOME", home, 1) == 0);
    assert(setenv("XDG_CACHE_HOME", home, 1) == 0);
    assert(setenv("XDG_DATA_HOME", home, 1) == 0);
    assert(prepare(data) == 0);
    const char *copy = getenv("XAUTHORITY");
    assert(copy && within(copy, data) && strcmp(copy, authority));
    struct stat original, copied;
    assert(stat(authority, &original) == 0 && stat(copy, &copied) == 0);
    assert(original.st_dev != copied.st_dev || original.st_ino != copied.st_ino);
    FILE *file = fopen(copy, "r");
    char bytes[32] = {0};
    assert(file && fread(bytes, 1, sizeof bytes, file) == 16);
    assert(fclose(file) == 0 && !strcmp(bytes, "private X cookie"));
    for (size_t i = 0; i < rule_count; ++i) {
        assert(strcmp(rules[i].path, authority));
    }
    char runtime_home[PATH_MAX];
    assert(strlen(getenv("HOME")) < sizeof runtime_home);
    strcpy(runtime_home, getenv("HOME"));
    const char *variables[] = {"XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"};
    char state[PATH_MAX];
    for (size_t i = 0; i < sizeof variables / sizeof variables[0]; ++i) {
        assert(getenv(variables[i]) && within(getenv(variables[i]), runtime_home));
        assert(join(state, getenv(variables[i]), "gtk-state") == 0);
        put(state, "runtime-only state");
    }
    char outside[PATH_MAX], untouched[PATH_MAX], alias[PATH_MAX];
    make_dir(outside, root, "outside-runtime");
    assert(join(untouched, outside, "keep") == 0);
    put(untouched, "not runtime state");
    assert(join(alias, getenv("XDG_CACHE_HOME"), "outside-link") == 0);
    assert(symlink(outside, alias) == 0);
    assert(wn_main_sandbox_cleanup() == 0);
    assert(access(copy, F_OK) < 0 && errno == ENOENT);
    assert(access(runtime_home, F_OK) < 0 && errno == ENOENT);
    assert(stat(authority, &copied) == 0);
    assert(original.st_dev == copied.st_dev && original.st_ino == copied.st_ino);
    assert(access(untouched, F_OK) == 0);
}

static void deny_temporary_symlink_escape(void) {
    char temporary[PATH_MAX];
    assert(join(temporary, data, "tmp") == 0);
    assert(symlink(home, temporary) == 0);
    assert(prepare(data) < 0);
}

static void deny_broad_data(void) {
    assert(prepare(home) < 0);
}

#ifdef __OpenBSD__
/* Tests link with --wrap=execve; raw kernel policy must bypass that wrapper. */
extern int __real_execve(const char *, char *const[], char *const[]);

static void expect_unveil_denied(void) {
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        struct rlimit no_core = {0, 0};
        assert(setrlimit(RLIMIT_CORE, &no_core) == 0);
        (void)unveil("/", "r");
        _exit(1);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
}

static void expect_exec_denied(const char *path) {
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        struct rlimit no_core = {0, 0};
        assert(setrlimit(RLIMIT_CORE, &no_core) == 0);
        char *const args[] = {(char *)path, NULL};
        char *const env[] = {"LD_PRELOAD=/tmp/untrusted.so", NULL};
        __real_execve(path, args, env);
        _exit(1);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
}

static void launcher_fresh_policy(void) {
    assert(prepare(data) == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        assert(wn_main_sandbox_enter_launcher() == 0);
        char *const args[] = {helper, "--decoder-policy", NULL};
        char *const env[] = {NULL};
        __real_execve(helper, args, env);
        _exit(1);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static void tool_exec_retains_unveil(void) {
    char secret[PATH_MAX], allowed[PATH_MAX];
    assert(join(secret, home, "secret") == 0);
    assert(join(allowed, data, "allowed") == 0);
    put(secret, "private");
    put(allowed, "allowed");
    assert(prepare(data) == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        const char *tools[] = {helper};
        assert(wn_main_sandbox_prepare_tools(tools, 1) == 0);
        assert(wn_main_sandbox_enter_tool(helper) == 0);
        char *const args[] = {helper, "--tool-policy", allowed, secret, NULL};
        char *const env[] = {NULL};
        __real_execve(helper, args, env);
        _exit(1);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static void broker_pins_writable_directory_identity(void) {
    char secret[PATH_MAX], through_link[PATH_MAX], allowed[PATH_MAX];
    assert(join(settings, data, "settings") == 0);
    assert(join(secret, home, "secret") == 0);
    assert(join(through_link, settings, "secret") == 0);
    assert(join(allowed, data, "allowed") == 0);
    put(secret, "private");
    put(allowed, "allowed");
    assert(prepare(data) == 0);
    int ready[2], proceed[2];
    assert(pipe(ready) == 0 && pipe(proceed) == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        const char *tools[] = {helper};
        assert(wn_main_sandbox_prepare_tools(tools, 1) == 0);
        char byte = 0;
        assert(write(ready[1], &byte, 1) == 1);
        assert(read(proceed[0], &byte, 1) == 1);
        assert(wn_main_sandbox_enter_tool(helper) == 0);
        char *const args[] = {helper, "--tool-policy", allowed, through_link, NULL};
        char *const env[] = {NULL};
        __real_execve(helper, args, env);
        _exit(1);
    }
    char byte;
    assert(read(ready[0], &byte, 1) == 1);
    assert(rmdir(settings) == 0 && symlink(home, settings) == 0);
    assert(write(proceed[1], &byte, 1) == 1);
    close(ready[0]);
    close(ready[1]);
    close(proceed[0]);
    close(proceed[1]);
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}
static void kernel_boundaries(void) {
    char secret[PATH_MAX], output[PATH_MAX], resource[PATH_MAX], download[PATH_MAX];
    char executable[PATH_MAX], alias[PATH_MAX], prefs[PATH_MAX];
    assert(join(executable, data, "run") == 0);
    assert(join(alias, data, "helper-alias") == 0);
    assert(join(prefs, settings, "settings.json") == 0);
    put(executable, "#!/bin/sh\nexit 0\n");
    assert(chmod(executable, 0700) == 0);
    assert(join(secret, home, "secret") == 0);
    assert(join(output, data, "vault.db") == 0);
    assert(join(resource, resources, "font") == 0);
    put(secret, "private");
    char authority[PATH_MAX];
    assert(join(authority, home, ".Xauthority") == 0);
    put(authority, "X cookie");
    assert(prepare(data) == 0);
    assert(join(download, wn_main_sandbox_downloads(), "saved") == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        assert(wn_main_sandbox_enter() == 0);
        int fd = open(output, O_CREAT | O_RDWR, 0600);
        assert(fd >= 0);
        close(fd);
        fd = open(download, O_CREAT | O_RDWR, 0600);
        assert(fd >= 0);
        close(fd);
        fd = open(prefs, O_CREAT | O_RDWR, 0600);
        assert(fd >= 0);
        close(fd);
        fd = open(resource, O_RDONLY);
        assert(fd >= 0);
        close(fd);
        assert(open(secret, O_RDONLY) < 0);
        assert(open(resource, O_WRONLY) < 0);
        /* Linking may itself be prohibited. If permitted, DAC still prevents
         * truncation through the writable alias of a root-owned inode. */
        if (link(resource, alias) == 0) {
            assert(open(alias, O_WRONLY | O_TRUNC) < 0);
            assert(unlink(alias) == 0);
        }
        assert(open(authority, O_RDONLY) < 0);
        assert(link(authority, alias) < 0);
        fd = open(getenv("XAUTHORITY"), O_RDONLY);
        assert(fd >= 0);
        close(fd);
        assert(open(helper, O_RDONLY) < 0);
        assert(link(helper, alias) < 0);
        expect_unveil_denied();
        fd = socket(AF_INET, SOCK_STREAM, 0);
        assert(fd >= 0);
        close(fd);
        expect_exec_denied(helper);
        expect_exec_denied("/bin/sh");
        expect_exec_denied(executable);
        assert(wn_main_sandbox_cleanup() == 0);
        assert(access(getenv("XAUTHORITY"), F_OK) < 0 && errno == ENOENT);
        _exit(0);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}
#endif

int main(int argc, char **argv) {
#ifdef __OpenBSD__
    if (argc == 2 && !strcmp(argv[1], "--decoder-policy")) {
        /* These calls fail if the main's locked unveil survived exec. */
        assert(unveil("/", "") == 0);
        assert(unveil(NULL, NULL) == 0);
        assert(pledge("stdio", NULL) == 0);
        return 0;
    }
    if (argc == 4 && !strcmp(argv[1], "--tool-policy")) {
        expect_unveil_denied();
        int fd = open(argv[2], O_RDWR);
        assert(fd >= 0);
        close(fd);
        assert(open(argv[3], O_RDONLY) < 0);
        char *const args[] = {"sh", "-c", "exit 0", NULL};
        assert(execv("/bin/sh", args) < 0);
        return 0;
    }
#else
    (void)argc;
    (void)argv;
#endif
    if (getuid() == 0 || geteuid() == 0) {
        assert(wn_main_sandbox_prepare("/", "/", "/", NULL, 0) < 0);
        assert(strstr(wn_main_sandbox_error(), "non-root"));
        puts("root execution rejected; run boundary tests as an ordinary user");
        return 77;
    }
    if (!getenv("WN_SANDBOX_TEST_RESOURCES")) {
        fputs("set WN_SANDBOX_TEST_RESOURCES to the root-installed fixture\n", stderr);
        return 77;
    }
    void (*cases[])(void) = {
        default_directories,
        custom_downloads_and_relative_data,
        symlink_data,
        deny_home_downloads,
        deny_invalid_downloads,
        deny_executable_in_data,
        deny_temporary_symlink_escape,
        deny_broad_data,
        deny_unsafe_resources,
        deny_unsafe_targets,
        copy_private_authority,
        deny_writable_runtime,
        deny_writable_symlink,
        deny_mutable_symlink_chain,
#ifdef __OpenBSD__
        kernel_boundaries,
        launcher_fresh_policy,
        tool_exec_retains_unveil,
        broker_pins_writable_directory_identity,
#endif
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; ++i) {
        setup();
        pid_t child = fork();
        assert(child >= 0);
        if (!child) {
            cases[i]();
            _exit(0);
        }
        int status;
        assert(waitpid(child, &status, 0) == child);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
        remove_tree(root);
    }
    puts("main sandbox boundaries passed");
    return 0;
}
