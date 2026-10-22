// AppImageUpdate is deliberately isolated: its network calls are blocking and
// stop() is unimplemented. Killing this process never alters the installed file.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <appimage/update.h>
#include <appimage/appimage.h>
#include <gpgme.h>
#include "appimage_update_policy.h"
#include "appimage_update_directory.h"
#include <sys/syscall.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <linux/fs.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <signal.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <vector>
#include <chrono>
#include <thread>
#include <stdexcept>
#include <cerrno>
#include <cstdlib>
#include <cstring>

namespace fs = std::filesystem;
using Updater = appimage::update::Updater;
static void require(bool value, const char *message) {
    if (!value) {
        throw std::runtime_error(message);
    }
}
static void emit(const std::string &line) {
    std::cout << line << std::endl;
}
static bool unchanged(const struct stat &a, const struct stat &b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
           a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec;
}
static std::string image_version(const std::string &image) {
    char *bytes = nullptr;
    unsigned long size = 0;
    require(appimage_read_file_into_buffer_following_symlinks(image.c_str(), "whitenoise.desktop",
                                                              &bytes, &size),
            "missing version metadata");
    std::unique_ptr<char, decltype(&free)> owner(bytes, free);
    require(size && size < 65536, "invalid desktop metadata");
    std::string desktop(bytes, size), version;
    const std::string key = "X-AppImage-Version=";
    bool group = false;
    for (size_t pos = 0; pos < desktop.size();) {
        auto end = desktop.find('\n', pos);
        std::string line = desktop.substr(pos, end == std::string::npos ? end : end - pos);
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (!line.empty() && line.front() == '[') {
            group = line == "[Desktop Entry]";
        }
        if (group && line.compare(0, key.size(), key) == 0) {
            require(version.empty(), "duplicate version metadata");
            version = line.substr(key.size());
        }
        if (end == std::string::npos) {
            break;
        }
        pos = end + 1;
    }
    uint64_t parsed[4];
    require(version.size() < 128 && wn_appimage_version(version.c_str(), parsed),
            "invalid release version");
    return version;
}
static void sync_file(const std::string &path) {
    int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    require(fd >= 0, "cannot open staged update");
    int result = fsync(fd);
    close(fd);
    require(result == 0, "cannot sync staged update");
}
static void sync_directory(const fs::path &directory) {
    int fd = open(directory.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    require(fd >= 0, "cannot open image folder");
    int result = fsync(fd);
    close(fd);
    require(result == 0, "cannot sync image folder");
}
static void relaunch(const std::string &image, const std::string &home, const std::string &stage) {
    extern char **environ;
    const char *mount_env = getenv("APPDIR");
    std::string mount = mount_env ? mount_env : "";
    std::vector<std::string> values;
    for (char **entry = environ; *entry; ++entry) {
        std::string value(*entry), name = value.substr(0, value.find('='));
        if (name == "APPIMAGE" || name == "APPDIR" || name == "ARGV0" || name == "OWD" ||
            name == "APPIMAGELAUNCHER_DISABLE" || name == "LD_LIBRARY_PATH" ||
            name == "LD_PRELOAD" || name == "GIO_EXTRA_MODULES" ||
            name == "GDK_PIXBUF_MODULE_FILE" || name == "GDK_PIXBUF_MODULEDIR" ||
            name == "GTK_PATH" || name == "GTK_EXE_PREFIX" || name == "GTK_DATA_PREFIX" ||
            name == "QT_PLUGIN_PATH" || name == "QT_QPA_PLATFORM_PLUGIN_PATH" ||
            name == "PYTHONHOME" || name == "PYTHONPATH") {
            continue;
        }
        if ((!mount.empty() && value.find(mount) != std::string::npos) ||
            value.find(stage) != std::string::npos) {
            continue;
        }
        values.push_back(std::move(value));
    }
    // Restart an installed image without desktop integration renaming it again.
    values.emplace_back("APPIMAGELAUNCHER_DISABLE=1");
    std::vector<char *> environment;
    for (auto &value : values) {
        environment.push_back(value.data());
    }
    environment.push_back(nullptr);
    char *args[] = {const_cast<char *>(image.c_str()), const_cast<char *>(home.c_str()), nullptr};
    // No cwd, loader path or open descriptors may retain the old mount.
    require(chdir(fs::path(image).parent_path().c_str()) == 0, "cannot leave old mount");
    std::error_code error;
    fs::remove_all(stage, error);
    long closed_range = -1;
#ifdef SYS_close_range
    closed_range = syscall(SYS_close_range, 3u, ~0u, 0u);
#endif
    if (closed_range != 0) {
        for (int fd = 3; fd < 65536; ++fd) {
            close(fd);
        }
    }
    execve(image.c_str(), args, environment.data());
    throw std::runtime_error("cannot relaunch updated AppImage");
}
int main(int argc, char **argv) {
    // source, resolved data home, compiled current version, optional explicit
    // test zsync URL, parent PID, private workspace, consent mode.
    if (argc != 8) {
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    const std::string source = argv[1], home = argv[2], current = argv[3], feed = argv[4],
                      stage = argv[6];
    try {
        require(fs::canonical(source) == fs::path(source), "AppImage path must not be a symlink");
        require(wn_appimage_private_directory(fs::path(source).parent_path().c_str()),
                "AppImage folder has unsafe ownership or permissions");
        require(fs::canonical(home) == fs::path(home), "data directory must be resolved");
        struct stat original{}, workspace{};
        require(lstat(source.c_str(), &original) == 0 && S_ISREG(original.st_mode) &&
                    (original.st_mode & 0111),
                "not an executable image");
        require(lstat(stage.c_str(), &workspace) == 0 && S_ISDIR(workspace.st_mode) &&
                    workspace.st_uid == getuid() && (workspace.st_mode & 0777) == 0700,
                "unsafe workspace");
        require(fs::path(stage).parent_path() == fs::path(source).parent_path(),
                "workspace must share image filesystem");
        require(chdir(stage.c_str()) == 0, "cannot leave AppImage mount");
        // Linux pidfds wait for this exact process, not a reused PID, and become
        // readable only after normal shutdown has closed the instance lock.
        char *end = nullptr;
        long parent = strtol(argv[5], &end, 10);
        require(end && !*end && parent > 1 && parent == getppid(), "invalid parent");
#ifdef SYS_pidfd_open
        int parent_fd = static_cast<int>(syscall(SYS_pidfd_open, parent, 0));
#else
        int parent_fd = -1;
#endif
        require(parent_fd >= 0, "kernel does not support safe update restart");
        const char *proxy = getenv("WN_SOCKS5_PROXY");
        require(!proxy || !*proxy, "SOCKS5 updates unavailable; refusing direct network");
        // Ignore ambient proxy overrides: only explicit app policy may select
        // network routing. A configured WN SOCKS5 proxy is rejected above.
        for (const char *name : {"http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY",
                                 "HTTPS_PROXY", "ALL_PROXY", "no_proxy", "NO_PROXY"}) {
            unsetenv(name);
        }
        if (!feed.empty()) {
            const char *authorized = getenv("WN_TEST_UPDATE_FEED");
            require(authorized && feed == authorized && wn_appimage_test_feed(feed.c_str()),
                    "test feed is not explicitly authorized loopback/local URL");
        }
        require(gpgme_check_version("1.10.0") != nullptr, "GPGME initialization failed");
        std::string gpg = stage + "/lib/gpg";
        require(gpgme_set_engine_info(GPGME_PROTOCOL_OpenPGP, gpg.c_str(), nullptr) ==
                    GPG_ERR_NO_ERROR,
                "cannot configure bundled signature verifier");
        // Isolate even the seed inode: malicious zsync filenames must not let
        // library writes touch the installed AppImage. Reflink when supported.
        std::string seed = stage + "/installed.AppImage";
        int lock = open(source.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        require(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0,
                "another updater owns this image");
        int seed_fd = open(seed.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0700);
        require(seed_fd >= 0, "cannot create isolated image seed");
        bool cloned = ioctl(seed_fd, FICLONE, lock) == 0;
        close(seed_fd);
        if (!cloned) {
            require(fs::copy_file(source, seed, fs::copy_options::overwrite_existing),
                    "cannot copy installed AppImage");
        }
        require(image_version(seed) == current, "installed image version differs from running app");
        bool automatic = !strcmp(argv[7], "1");
        bool requested = automatic || !feed.empty();
        std::unique_ptr<Updater> updater;
        std::string candidate, version;
        auto next_check = std::chrono::steady_clock::now() + std::chrono::hours(6);
        for (;;) {
            if (requested && candidate.empty()) {
                requested = false;
                emit("C");
                try {
                    updater = std::make_unique<Updater>(seed, false);
                    if (!feed.empty()) {
                        updater->setUpdateInformation("zsync|" + feed);
                    }
                    bool available = false;
                    require(updater->checkForChanges(available), "update check failed");
                    if (!available) {
                        emit("I");
                    } else {
                        require(updater->start(), "update start failed");
                        emit("P-1");
                        int previous = -2;
                        while (!updater->isDone()) {
                            double progress = 0;
                            if (updater->progress(progress)) {
                                int percent = static_cast<int>(progress * 100);
                                if (percent != previous) {
                                    emit("P" + std::to_string(percent));
                                    previous = percent;
                                }
                            }
                            std::this_thread::sleep_for(std::chrono::milliseconds(100));
                        }
                        require(!updater->hasError(), "download failed");
                        std::string downloaded;
                        require(updater->pathToNewFile(downloaded), "missing downloaded file");
                        fs::path resolved = fs::canonical(downloaded);
                        require(resolved.parent_path() == fs::path(stage) &&
                                    resolved != fs::path(seed),
                                "unsafe download destination");
                        require(updater->validateSignature() == Updater::VALIDATION_PASSED,
                                "signature missing, invalid or signing key changed");
                        version = image_version(resolved.string());
                        require(wn_appimage_newer(current.c_str(), version.c_str()),
                                "release is not strictly newer");
                        struct stat now{}, downloaded_stat{};
                        require(lstat(source.c_str(), &now) == 0 && unchanged(original, now),
                                "installed image changed");
                        require(lstat(resolved.c_str(), &downloaded_stat) == 0 &&
                                    S_ISREG(downloaded_stat.st_mode) &&
                                    downloaded_stat.st_nlink == 1,
                                "unsafe staged image");
                        require(chmod(resolved.c_str(), original.st_mode & 0777) == 0,
                                "cannot preserve image permissions");
                        sync_file(resolved.string());
                        candidate = resolved.string();
                        emit("R " + version);
                    }
                } catch (const std::exception &error) {
                    std::cerr << "AppImage update: " << error.what() << '\n';
                    emit("E");
                    candidate.clear();
                    updater.reset();
                }
                next_check = std::chrono::steady_clock::now() + std::chrono::hours(6);
            }
            struct pollfd input{STDIN_FILENO, POLLIN, 0};
            int result = poll(&input, 1, 1000);
            if (result < 0 && errno == EINTR) {
                continue;
            }
            require(result >= 0, "control channel failed");
            if (result && (input.revents & (POLLHUP | POLLERR | POLLNVAL))) {
                return 0;
            }
            if (result && (input.revents & POLLIN)) {
                char command;
                if (read(STDIN_FILENO, &command, 1) != 1) {
                    return 0;
                }
                if (command == 'C') {
                    requested = true;
                } else if (command == '0') {
                    automatic = false;
                } else if (command == '1') {
                    automatic = true;
                    requested = true;
                } else if (command == 'A' || command == 'Q') {
                    require(!candidate.empty() && updater, "no verified update");
                    emit("X");
                    struct pollfd exited{parent_fd, POLLIN, 0};
                    do {
                        result = poll(&exited, 1, -1);
                    } while (result < 0 && errno == EINTR);
                    require(result > 0 && (exited.revents & POLLIN), "cannot wait for parent exit");
                    struct stat now{};
                    require(wn_appimage_private_directory(fs::path(source).parent_path().c_str()),
                            "AppImage folder permissions changed before apply");
                    require(lstat(source.c_str(), &now) == 0 && unchanged(original, now),
                            "installed image changed before apply");
                    require(updater->validateSignature() == Updater::VALIDATION_PASSED,
                            "signature changed before apply");
                    require(image_version(candidate) == version &&
                                wn_appimage_newer(current.c_str(), version.c_str()),
                            "version changed before apply");
                    const std::string rollback = source + ".rollback." + std::to_string(getpid());
                    require(link(source.c_str(), rollback.c_str()) == 0,
                            "cannot preserve rollback image");
                    sync_directory(fs::path(source).parent_path());
                    require(rename(candidate.c_str(), source.c_str()) == 0,
                            "atomic update replacement failed");
                    sync_directory(fs::path(source).parent_path());
                    if (command == 'A') {
                        relaunch(source, home, stage);
                    }
                    std::error_code cleanup_error;
                    fs::remove_all(stage, cleanup_error);
                    return 0;
                }
            }
            if (automatic && candidate.empty() && std::chrono::steady_clock::now() >= next_check) {
                requested = true;
            }
        }
    } catch (const std::exception &error) {
        std::cerr << "AppImage update: " << error.what() << '\n';
        emit("E");
        return 1;
    }
}
