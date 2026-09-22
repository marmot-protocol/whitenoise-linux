#define _GNU_SOURCE
#include <SDL3/SDL.h>
#include <dlfcn.h>
#include <limits.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Stable C boundary: the window, renderer and native callback trampoline survive
// a reload. Each Odin library owns and shuts down its own runtime and state.
typedef int (*AppRun)(int, char **, int);
typedef void (*AppInit)(void);
static SDL_Window *window;
static SDL_Renderer *renderer;
static void *module, *next_module;
static AppRun run, next_run;
static const char *manifest;
static char loaded[PATH_MAX];
static atomic_int dialogs;
static atomic_int dialog_results;
static volatile sig_atomic_t stopping;
static Uint64 next_poll;
enum ReloadGate { RELOAD_BUSY, RELOAD_READY };
enum ReloadAction { KEEP_RUNNING, RELOAD_APP, STOP_APP };
enum DialogKind { DIALOG_OPEN_ONE, DIALOG_OPEN_MANY, DIALOG_SAVE };

static void stop(int sig) {
    (void)sig;
    stopping = 1;
}

SDL_Window *wn_dev_window(int width, int height, const char *title, SDL_Renderer **out) {
    if (!window) {
        if (!SDL_Init(SDL_INIT_VIDEO)) {
            return NULL;
        }
        SDL_CreateWindowAndRenderer(title, width, height,
                                    SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY, &window,
                                    &renderer);
        if (window) {
            fprintf(stderr, "dev: window=%u\n", SDL_GetWindowID(window));
        }
    }
    *out = renderer;
    return window;
}

void wn_dev_wait_dialogs(void) {
    while (atomic_load(&dialogs)) {
        if (stopping) {
            exit(0);
        }
        SDL_PumpEvents();
        SDL_Delay(10);
    }
}

struct Dialog {
    SDL_DialogFileCallback callback;
};

static void dialog_done(void *data, const char *const *files, int filter) {
    struct Dialog *dialog = data;
    atomic_fetch_add(&dialog_results, 1);
    dialog->callback(NULL, files, filter);
    free(dialog);
    // The module callback has returned before its code may be unloaded.
    atomic_fetch_sub(&dialogs, 1);
}

void wn_dev_dialogs_consumed(int count) {
    atomic_fetch_sub(&dialog_results, count);
}

void wn_dev_dialog(enum DialogKind kind, SDL_DialogFileCallback callback, const char *name) {
    struct Dialog *dialog = malloc(sizeof(*dialog));
    if (!dialog) {
        atomic_fetch_add(&dialog_results, 1);
        callback(NULL, NULL, -1);
        return;
    }
    dialog->callback = callback;
    atomic_fetch_add(&dialogs, 1);
    if (kind == DIALOG_SAVE) {
        SDL_ShowSaveFileDialog(dialog_done, dialog, window, NULL, 0, name);
    } else {
        SDL_ShowOpenFileDialog(dialog_done, dialog, window, NULL, 0, NULL,
                               kind == DIALOG_OPEN_MANY);
    }
}

// Called on the UI thread, between frames. Link a candidate first, so a
// broken library cannot take down the working session.
enum ReloadAction wn_dev_reload(enum ReloadGate gate) {
    if (stopping) {
        return STOP_APP;
    }
    if (gate == RELOAD_BUSY || atomic_load(&dialogs) || atomic_load(&dialog_results)) {
        return KEEP_RUNNING;
    }
    if (next_module) {
        return RELOAD_APP;
    }
    Uint64 now = SDL_GetTicks();
    if (now < next_poll) {
        return KEEP_RUNNING;
    }
    next_poll = now + 200;
    FILE *file = fopen(manifest, "r");
    if (!file) {
        return KEEP_RUNNING;
    }
    char path[sizeof(loaded)];
    char *line = fgets(path, sizeof(path), file);
    fclose(file);
    if (!line) {
        return KEEP_RUNNING;
    }
    path[strcspn(path, "\r\n")] = 0;
    if (!path[0] || strcmp(path, loaded) == 0) {
        return KEEP_RUNNING;
    }
    snprintf(loaded, sizeof(loaded), "%s", path);
    void *candidate = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!candidate) {
        fprintf(stderr, "dev: load failed: %s\n", dlerror());
        return KEEP_RUNNING;
    }
    AppRun entry = (AppRun)dlsym(candidate, "wn_app_run");
    AppInit init = (AppInit)dlsym(candidate, "_odin_entry_point");
    AppInit fini = (AppInit)dlsym(candidate, "_odin_exit_point");
    if (!entry || !init || !fini) {
        fprintf(stderr, "dev: missing app entry points\n");
        dlclose(candidate);
        return KEEP_RUNNING;
    }
    init();
    next_module = candidate;
    next_run = entry;
    return RELOAD_APP;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        return 1;
    }
    manifest = argv[1];
    signal(SIGINT, stop);
    signal(SIGTERM, stop);
    if (wn_dev_reload(RELOAD_READY) != RELOAD_APP) {
        return 1;
    }
    // Keep argv[0] beside the packaged helpers, as in a normal app launch.
    argv[1] = argv[0];
    int generation = 0;
    for (;;) {
        module = next_module;
        run = next_run;
        next_module = NULL;
        char path[sizeof(loaded)];
        snprintf(path, sizeof(path), "%s", loaded);
        int reload = run(argc - 1, argv + 1, generation++);
        ((AppInit)dlsym(module, "_odin_exit_point"))();
        dlclose(module);
        // Libraries live in just dev's session directory, one per build.
        unlink(path);
        if (!reload || !next_module || stopping) {
            break;
        }
        fprintf(stderr, "dev: reloaded, window=%u\n", SDL_GetWindowID(window));
    }
    if (next_module) {
        ((AppInit)dlsym(next_module, "_odin_exit_point"))();
        dlclose(next_module);
    }
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
