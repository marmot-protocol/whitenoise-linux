#include <unistd.h>

/* A loaded attacker DSO runs before the helper can install its own policy. */
__attribute__((constructor)) static void expose_loader_escape(void) {
    static const char marker[] = "loader-escape\n";
    (void)write(STDOUT_FILENO, marker, sizeof marker - 1);
    _exit(91);
}
