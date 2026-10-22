#pragma once
#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

/* A 0700 workspace is not enough if another UID can rename its directory
 * entry. Check every ancestor before staging executables or replacing source.
 * Sticky root/user-owned shared ancestors (e.g. /tmp) protect our owned child.
 * Symlinked paths and directories owned by other users are ineligible. */
static int wn_appimage_private_directory(const char *path) {
    char canonical[PATH_MAX];
    if (!path || path[0] != '/' || !realpath(path, canonical) || strcmp(path, canonical)) {
        return 0;
    }
    size_t length = strlen(canonical);
    for (size_t end = 1; end <= length; ++end) {
        if (canonical[end] && canonical[end] != '/') {
            continue;
        }
        char saved = canonical[end];
        canonical[end] = 0;
        struct stat directory;
        int ok = lstat(canonical, &directory) == 0 && S_ISDIR(directory.st_mode) &&
                 (directory.st_uid == 0 || directory.st_uid == getuid()) &&
                 (!(directory.st_mode & 0022) || (directory.st_mode & 01000));
        canonical[end] = saved;
        if (!ok) {
            return 0;
        }
    }
    return 1;
}
