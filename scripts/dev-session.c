#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

// The watcher retains this anonymous file across app restarts. Nothing
// secret goes into an environment variable or a named file.
int main(int argc, char **argv) {
    if (argc < 2) {
        return 1;
    }
    int fd = memfd_create("wn-dev-vault", 0);
    if (fd < 0) {
        perror("memfd_create");
        return 1;
    }
    char value[32];
    snprintf(value, sizeof(value), "%d", fd);
    if (setenv("WN_DEV_VAULT_FD", value, 1) != 0) {
        perror("setenv");
        return 1;
    }
    execvp(argv[1], argv + 1);
    perror("execvp");
    return 1;
}
