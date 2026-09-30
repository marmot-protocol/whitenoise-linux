#include <assert.h>
#include <stdlib.h>
#define CLAY_IMPLEMENTATION
#include "clay.h"

static Clay_Dimensions measure(Clay_StringSlice text, Clay_TextElementConfig *config, void *user) {
    (void)config;
    (void)user;
    return (Clay_Dimensions){(float)text.length * 10, 16};
}

static void fail_on_error(Clay_ErrorData error) {
    (void)error;
    assert(!"Clay layout error");
}

// A vertical list whose rows hold a clipped, overflowing one-line label,
// like a chat row with a long preview. The label can only scroll sideways.
static void layout(void) {
    Clay_BeginLayout();
    CLAY(CLAY_ID("List"), {.layout = {.sizing = {CLAY_SIZING_FIXED(200), CLAY_SIZING_FIXED(100)},
                                      .layoutDirection = CLAY_TOP_TO_BOTTOM},
                           .clip = {.vertical = true, .childOffset = Clay_GetScrollOffset()}}) {
        for (int i = 0; i < 10; i++) {
            CLAY(CLAY_IDI("Label", i),
                 {.layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_FIXED(40)}},
                  .clip = {.horizontal = true}}) {
                CLAY_TEXT(CLAY_STRING("a preview far too long for the row it sits in"),
                          CLAY_TEXT_CONFIG({.fontSize = 16, .wrapMode = CLAY_TEXT_WRAP_NONE}));
            }
        }
    }
    Clay_EndLayout(0);
}

int main(void) {
    uint32_t size = Clay_MinMemorySize();
    void *memory = malloc(size);
    assert(memory);
    Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(size, memory),
                    (Clay_Dimensions){800, 600},
                    (Clay_ErrorHandler){.errorHandlerFunction = fail_on_error});
    Clay_SetMeasureTextFunction(measure, NULL);

    // Two frames settle content sizes; the pointer rests on the first label.
    for (int frame = 0; frame < 2; frame++) {
        Clay_SetPointerState((Clay_Vector2){20, 20}, false);
        Clay_UpdateScrollContainers(false, (Clay_Vector2){0, 0}, 0.016f);
        layout();
    }

    // A vertical wheel over the label must scroll the list, not vanish into
    // the label's horizontal-only clip.
    Clay_SetPointerState((Clay_Vector2){20, 20}, false);
    Clay_UpdateScrollContainers(false, (Clay_Vector2){0, -3}, 0.016f);
    layout();
    Clay_ScrollContainerData list = Clay_GetScrollContainerData(CLAY_ID("List"));
    assert(list.found);
    assert(list.scrollPosition->y == -30);

    // A sideways wheel still reaches the innermost label that can take it.
    // The list sits 30px down, so the pointer now rests on the second label.
    Clay_SetPointerState((Clay_Vector2){20, 20}, false);
    Clay_UpdateScrollContainers(false, (Clay_Vector2){-2, 0}, 0.016f);
    layout();
    Clay_ScrollContainerData label = Clay_GetScrollContainerData(CLAY_IDI("Label", 1));
    assert(label.found);
    assert(label.scrollPosition->x == -20);
    assert(list.scrollPosition->y == -30);

    free(memory);
}
