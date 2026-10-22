#define _GNU_SOURCE
#include <assert.h>
#include <stdio.h>
#include "../app/appimage_update_policy.h"
#include "../app/appimage_update_directory.h"

int main(void) {
    assert(wn_appimage_newer("2026.9.30+9", "2026.10.1+1"));
    assert(wn_appimage_newer("2026.10.2+9", "2026.10.2+10"));
    assert(wn_appimage_newer("2026.10.2-build.9", "2026.10.2+10"));
    assert(wn_appimage_newer("2026.10.2", "2026.10.2-build.1"));
    assert(!wn_appimage_newer("2026.10.2+10", "2026.10.2-build.9"));
    assert(!wn_appimage_newer("2026.10.2+10", "2026.10.2-build.10"));
    assert(!wn_appimage_newer("2026.10.2+10", "2026.9.30+99"));
    assert(!wn_appimage_newer("2026.10.2+10", "2026.10.2+18446744073709551616"));
    assert(!wn_appimage_newer("2026.10.2+10", "2026.10.2+11garbage"));
    assert(!wn_appimage_newer("not-a-version", "2026.10.2+11"));
    assert(!wn_appimage_newer("2026.10.2+10", "2026.13.2+11"));
    assert(wn_appimage_test_feed("http://127.0.0.1:8123/update.AppImage.zsync"));
    assert(wn_appimage_test_feed("http://[::1]:8123/update.AppImage.zsync"));
    assert(wn_appimage_test_feed("file:///tmp/update.AppImage.zsync"));
    assert(!wn_appimage_test_feed("http://127.0.0.1.attacker.test:8123/x"));
    assert(!wn_appimage_test_feed("http://127.0.0.1:8123@attacker.test/x"));
    assert(!wn_appimage_test_feed("http://127.0.0.1:0/x"));
    assert(!wn_appimage_test_feed("http://127.0.0.1:65536/x"));
    assert(!wn_appimage_test_feed("http://localhost:8123/x"));
    assert(!wn_appimage_test_feed("https://attacker.test/x"));
    assert(!wn_appimage_test_feed("zsync|http://127.0.0.1:8123/x"));
    assert(!wn_appimage_test_feed("http://127.0.0.1:8123/x\nInjected"));
    assert(!wn_appimage_test_feed("file://attacker.test/tmp/x"));
    char directory[] = "/tmp/wn-updater-policy-XXXXXX";
    assert(mkdtemp(directory));
    assert(wn_appimage_private_directory(directory));
    char shared[sizeof directory + 16], nested[sizeof directory + 32], alias[sizeof directory + 16];
    snprintf(shared, sizeof shared, "%s/shared", directory);
    snprintf(nested, sizeof nested, "%s/shared/private", directory);
    snprintf(alias, sizeof alias, "%s/alias", directory);
    assert(mkdir(shared, 0700) == 0 && mkdir(nested, 0700) == 0);
    assert(wn_appimage_private_directory(nested));
    assert(chmod(shared, 0777) == 0);
    assert(!wn_appimage_private_directory(nested));
    assert(chmod(shared, 01777) == 0);
    assert(wn_appimage_private_directory(nested));
    assert(symlink(nested, alias) == 0);
    assert(!wn_appimage_private_directory(alias));
    assert(unlink(alias) == 0 && rmdir(nested) == 0 && rmdir(shared) == 0 && rmdir(directory) == 0);
    return 0;
}
