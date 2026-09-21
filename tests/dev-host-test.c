#define main dev_host_main
#include "../scripts/dev-host.c"
#undef main
#include <assert.h>

static int callbacks;

static void result(void *data, const char *const *files, int filter) {
    (void)data;
    (void)files;
    (void)filter;
    assert(atomic_load(&dialogs) > 0);
    assert(atomic_load(&dialog_results) > 0);
    assert(wn_dev_reload(RELOAD_READY) == KEEP_RUNNING);
    callbacks++;
}

int main(void) {
    atomic_store(&dialogs, 2);
    for (int i = 0; i < 2; i++) {
        struct Dialog *dialog = malloc(sizeof(*dialog));
        assert(dialog);
        dialog->callback = result;
        dialog_done(dialog, NULL, -1);
    }
    assert(callbacks == 2);
    assert(atomic_load(&dialogs) == 0);
    assert(wn_dev_reload(RELOAD_READY) == KEEP_RUNNING);
    wn_dev_dialogs_consumed(1);
    assert(wn_dev_reload(RELOAD_READY) == KEEP_RUNNING);
    wn_dev_dialogs_consumed(1);
    assert(atomic_load(&dialog_results) == 0);
    assert(wn_dev_reload(RELOAD_BUSY) == KEEP_RUNNING);
    stopping = 1;
    assert(wn_dev_reload(RELOAD_BUSY) == STOP_APP);
    return 0;
}
