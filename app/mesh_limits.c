#include "decoder_limits.h"
#include <stdlib.h>

/* Shared by the Odin helpers: wn-mesh is one-shot, wn-nes a session. */
int wn_mesh_bootstrap(WnDecoderLifetime lifetime) {
    if (!wn_decoder_limits(lifetime)) {
        return 0;
    }
#ifdef __OpenBSD__
    if (unveil(NULL, NULL) || pledge("stdio", NULL)) {
        return 0;
    }
#endif
    return 1;
}
int wn_mesh_input(void *bytes, size_t length) {
    return fread(bytes, 1, length, stdin) == length;
}
int wn_mesh_input_end(void) {
    return fgetc(stdin) == EOF && !ferror(stdin);
}
int wn_mesh_output(const void *bytes, size_t length) {
    return fwrite(bytes, 1, length, stdout) == length;
}
int wn_mesh_flush(void) {
    return !fflush(stdout);
}
void wn_mesh_finish(int success) {
    if (fflush(stdout)) {
        success = 0;
    }
    exit(success ? 0 : 1);
}
