#define _POSIX_C_SOURCE 200809L
// Strict POSIX mode hides flock() and LOCK_EX on macOS; this re-exposes
// them. Other platforms ignore it.
#define _DARWIN_C_SOURCE
#include "helper_ipc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif
#endif

struct WnIpc {
    void *data;
    size_t size;
    char name[80];
    int owner;
#ifdef _WIN32
    HANDLE mapping;
#endif
};

static WnIpc *map_memory(const char *name, size_t size, int create) {
    if (!size || size > 128 * 1024 * 1024)
        return NULL;
    WnIpc *ipc = calloc(1, sizeof(*ipc));
    if (!ipc)
        return NULL;
    if (strlen(name) >= sizeof(ipc->name)) {
        free(ipc);
        return NULL;
    }
    strcpy(ipc->name, name);
    ipc->size = size;
    ipc->owner = create;
#ifdef _WIN32
    ipc->mapping = create ? CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0,
                                               (DWORD)size, name)
                          : OpenFileMappingA(FILE_MAP_ALL_ACCESS, FALSE, name);
    if (!ipc->mapping || (create && GetLastError() == ERROR_ALREADY_EXISTS)) {
        if (ipc->mapping)
            CloseHandle(ipc->mapping);
        free(ipc);
        return NULL;
    }
    ipc->data = MapViewOfFile(ipc->mapping, FILE_MAP_ALL_ACCESS, 0, 0, size);
#else
    int fd = shm_open(name, O_RDWR | (create ? O_CREAT | O_EXCL : 0), 0600);
    if (fd < 0) {
        free(ipc);
        return NULL;
    }
    struct stat st;
    if ((create && ftruncate(fd, (off_t)size)) || fstat(fd, &st) || (size_t)st.st_size != size) {
        close(fd);
        if (create)
            shm_unlink(name);
        free(ipc);
        return NULL;
    }
    ipc->data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (ipc->data == MAP_FAILED)
        ipc->data = NULL;
    // Once attached, no future process can reopen the private payload by name.
    if (!create)
        shm_unlink(name);
#endif
    if (!ipc->data) {
        wn_ipc_close(ipc);
        return NULL;
    }
    return ipc;
}

WnIpc *wn_ipc_create(size_t size) {
    // macOS permits at most 31 characters in a POSIX shared-memory name.
    unsigned char random[12];
#ifdef _WIN32
    if (BCryptGenRandom(NULL, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG))
        return NULL;
    const char *prefix = "Local\\wn-";
#else
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0)
        return NULL;
    size_t done = 0;
    while (done < sizeof(random)) {
        ssize_t n = read(fd, random + done, sizeof(random) - done);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0) {
            close(fd);
            return NULL;
        }
        done += (size_t)n;
    }
    close(fd);
    const char *prefix = "/wn-";
#endif
    char name[80];
    size_t offset = strlen(prefix);
    memcpy(name, prefix, offset);
    for (size_t i = 0; i < sizeof(random); ++i)
        snprintf(name + offset + i * 2, 3, "%02x", random[i]);
    return map_memory(name, size, 1);
}

WnIpc *wn_ipc_open(const char *name, size_t size) {
    return map_memory(name, size, 0);
}
void *wn_ipc_data(WnIpc *ipc) {
    return ipc ? ipc->data : NULL;
}
const char *wn_ipc_name(WnIpc *ipc) {
    return ipc ? ipc->name : "";
}
size_t wn_ipc_size(WnIpc *ipc) {
    return ipc ? ipc->size : 0;
}
void wn_ipc_close(WnIpc *ipc) {
    if (!ipc)
        return;
#ifdef _WIN32
    if (ipc->data)
        UnmapViewOfFile(ipc->data);
    if (ipc->mapping)
        CloseHandle(ipc->mapping);
#else
    if (ipc->data)
        munmap(ipc->data, ipc->size);
    if (ipc->owner)
        shm_unlink(ipc->name);
#endif
    free(ipc);
}
intptr_t wn_ipc_read(WnIpc *ipc, void *data, size_t size, size_t offset) {
    if (!ipc || offset > ipc->size || size > ipc->size - offset)
        return -1;
    if (ipc->size >= 4 && offset <= 4 && size <= 4 - offset) {
        uint32_t header = __atomic_load_n((uint32_t *)ipc->data, __ATOMIC_ACQUIRE);
        memcpy(data, (unsigned char *)&header + offset, size);
    } else {
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        memcpy(data, (unsigned char *)ipc->data + offset, size);
    }
    return (intptr_t)size;
}
intptr_t wn_ipc_write(WnIpc *ipc, const void *data, size_t size, size_t offset) {
    if (!ipc || offset > ipc->size || size > ipc->size - offset)
        return -1;
    if (ipc->size >= 4 && offset <= 4 && size <= 4 - offset) {
        // Speech status/model/length and the parent's stop command share a word.
        // Commit atomically without losing a concurrent command or torn length.
        uint32_t previous = __atomic_load_n((uint32_t *)ipc->data, __ATOMIC_RELAXED);
        uint32_t next;
        do {
            next = previous;
            memcpy((unsigned char *)&next + offset, data, size);
        } while (!__atomic_compare_exchange_n((uint32_t *)ipc->data, &previous, next, 0,
                                              __ATOMIC_RELEASE, __ATOMIC_RELAXED));
    } else {
        memcpy((unsigned char *)ipc->data + offset, data, size);
        __atomic_thread_fence(__ATOMIC_RELEASE);
    }
    return (intptr_t)size;
}

#ifdef _WIN32
static DWORD WINAPI watch_parent(void *handle) {
    WaitForSingleObject(handle, INFINITE);
    ExitProcess(1);
    return 0;
}
#else
static void *watch_parent(void *value) {
    pid_t parent = (pid_t)(uintptr_t)value;
    const struct timespec delay = {0, 100000000};
    while (getppid() == parent)
        nanosleep(&delay, NULL);
    _exit(1);
}
#endif
int wn_helper_guard(unsigned long parent) {
    if (!parent)
        return 0;
#ifdef _WIN32
    HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)parent);
    if (!process || WaitForSingleObject(process, 0) != WAIT_TIMEOUT) {
        if (process)
            CloseHandle(process);
        return 0;
    }
    HANDLE thread = CreateThread(NULL, 0, watch_parent, process, 0, NULL);
    if (!thread) {
        CloseHandle(process);
        return 0;
    }
    CloseHandle(thread);
#else
#ifdef __linux__
    if (prctl(PR_SET_PDEATHSIG, SIGKILL))
        return 0;
#endif
    if (getppid() != (pid_t)parent)
        return 0;
    pthread_t thread;
    if (pthread_create(&thread, NULL, watch_parent, (void *)(uintptr_t)parent))
        return 0;
    pthread_detach(thread);
#endif
    return 1;
}
int wn_helper_silence(void) {
#ifdef _WIN32
    const char *null = "NUL";
#else
    const char *null = "/dev/null";
    umask(0077);
#endif
    return freopen(null, "w", stderr) && freopen(null, "w", stdout);
}

void *wn_model_lock(const char *directory) {
    size_t size = strlen(directory) + 12;
    char *path = malloc(size);
    if (!path)
        return NULL;
    snprintf(path, size, "%s/.lock", directory);
#ifdef _WIN32
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    wchar_t *wide = length ? malloc((size_t)length * sizeof(*wide)) : NULL;
    if (!wide) {
        free(path);
        return NULL;
    }
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, length);
    free(path);
    HANDLE lock;
    for (;;) {
        lock = CreateFileW(wide, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, NULL);
        if (lock != INVALID_HANDLE_VALUE || GetLastError() != ERROR_SHARING_VIOLATION)
            break;
        Sleep(100);
    }
    free(wide);
    return lock == INVALID_HANDLE_VALUE ? NULL : lock;
#else
    int fd = open(path, O_CREAT | O_RDWR, 0600);
    free(path);
    if (fd < 0)
        return NULL;
    while (flock(fd, LOCK_EX)) {
        if (errno == EINTR)
            continue;
        close(fd);
        return NULL;
    }
    return (void *)(uintptr_t)(fd + 1);
#endif
}
void wn_model_unlock(void *lock) {
    if (!lock)
        return;
#ifdef _WIN32
    CloseHandle(lock);
#else
    close((int)(uintptr_t)lock - 1);
#endif
}
