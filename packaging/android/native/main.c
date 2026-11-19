#define SDL_MAIN_HANDLED
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

/* Odin's generated C main performs runtime initialization before app.main.
 * Rename that symbol with llvm-objcopy; do not call app.main directly. */
extern int wn_odin_main(int argc, char **argv);

SDL_DECLSPEC int SDL_main(int argc, char **argv) {
    return wn_odin_main(argc, argv);
}
