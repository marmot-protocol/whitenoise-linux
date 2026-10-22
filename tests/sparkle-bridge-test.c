// Run on macOS against the actual bridge, outside an .app bundle. Developer
// executables must never initialize Sparkle or contact its production feed.
#include <assert.h>
#include <stdbool.h>
#include <string.h>

extern void wn_sparkle_start(const char *home);
extern void wn_sparkle_stop(void);
extern bool wn_sparkle_available(void);
extern bool wn_sparkle_can_check(void);
extern bool wn_sparkle_auto(void);
extern void wn_sparkle_set_auto(bool enabled);
extern bool wn_sparkle_take_quit(void);
extern const char *wn_sparkle_status(void);

int main(void) {
    wn_sparkle_start("/tmp/whitenoise-nonbundle-test");
    assert(!wn_sparkle_available());
    assert(!wn_sparkle_can_check());
    assert(!wn_sparkle_auto());
    wn_sparkle_set_auto(true);
    assert(!wn_sparkle_auto());
    assert(!wn_sparkle_take_quit());
    assert(strlen(wn_sparkle_status()) != 0);
    wn_sparkle_stop();
    return 0;
}
