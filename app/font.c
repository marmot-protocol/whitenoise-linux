// Decode web fonts in a bounded child process before the UI loads their SFNT data.
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_TRUETYPE_TABLES_H
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        return 1;
    }
    struct rlimit memory = {256 * 1024 * 1024, 256 * 1024 * 1024};
    struct rlimit cpu = {5, 5};
    if (setrlimit(RLIMIT_AS, &memory) || setrlimit(RLIMIT_CPU, &cpu)) {
        return 1;
    }
    FT_Library library;
    FT_Face face;
    if (FT_Init_FreeType(&library)) {
        return 1;
    }
    if (FT_New_Face(library, argv[1], 0, &face)) {
        FT_Done_FreeType(library);
        return 1;
    }
    FT_ULong size = 0;
    int result = 1;
    if (!FT_Load_Sfnt_Table(face, 0, 0, NULL, &size) && size >= 12 && size <= 16 * 1024 * 1024) {
        unsigned char *data = malloc(size);
        if (data && !FT_Load_Sfnt_Table(face, 0, 0, data, &size)) {
            result = fwrite(data, 1, size, stdout) == size && !fflush(stdout) ? 0 : 1;
        }
        free(data);
    }
    FT_Done_Face(face);
    FT_Done_FreeType(library);
    return result;
}
