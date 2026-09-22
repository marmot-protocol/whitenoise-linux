#include <assert.h>
#include <stdlib.h>
#define CLAY_IMPLEMENTATION
#include "clay.h"

static void fail_on_error(Clay_ErrorData error) {
    (void)error;
    assert(!"Clay layout error");
}

int main(void) {
    Clay_SetMaxElementCount(64);
    uint32_t size = Clay_MinMemorySize();
    void *memory = malloc(size);
    assert(memory);
    Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(size, memory),
                    (Clay_Dimensions){800, 600},
                    (Clay_ErrorHandler){.errorHandlerFunction = fail_on_error});
    // Two generations fill the map. Later frames must reuse freed slots.
    for (int frame = 0; frame < 20; frame++) {
        Clay_BeginLayout();
        for (int i = 0; i < (frame < 2 ? 31 : 30); i++) {
            CLAY(CLAY_IDI("Row", frame * 31 + i), {}) {
            }
        }
        if (frame >= 2) {
            CLAY(CLAY_ID("Floating"), {.floating = {
                                           .parentId = CLAY_IDI("Row", frame * 31).id,
                                           .attachTo = CLAY_ATTACH_TO_ELEMENT_WITH_ID,
                                       }}) {
            }
        }
        Clay_EndLayout(0);
    }
    free(memory);
}
