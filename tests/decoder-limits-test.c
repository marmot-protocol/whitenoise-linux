#include "../app/decoder_limits.h"
#include <assert.h>
#include <sys/mman.h>
#include <sys/wait.h>

int main(void) {
    const WnDecoderLifetime lifetimes[] = {WN_DECODER_ONESHOT, WN_DECODER_SESSION};
    for (size_t i = 0; i < sizeof(lifetimes) / sizeof(lifetimes[0]); ++i) {
        pid_t child = fork();
        assert(child >= 0);
        if (child == 0) {
            assert(wn_decoder_limits(lifetimes[i]));
            const size_t small = 1024 * 1024;
            void *region = mmap(NULL, small, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
            assert(region != MAP_FAILED);
            assert(munmap(region, small) == 0);

            region = mmap(NULL, (size_t)WN_IMAGE_MEMORY_MAX * 2, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANON, -1, 0);
            assert(region == MAP_FAILED);
            _exit(0);
        }
        int status = 0;
        assert(waitpid(child, &status, 0) == child);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    puts("decoder limits: small allocations succeed; over-budget mappings fail");
    return 0;
}
