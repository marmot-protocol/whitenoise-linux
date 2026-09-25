// Include after main: the MinGW Unicode entry point keeps model/font paths UTF-8.
// Build Windows helpers with -municode; this does not change the Unix entry point.
#if defined(_WIN32) && !defined(main)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
int wmain(int argc, wchar_t **wide) {
    char **args = calloc((size_t)argc + 1, sizeof(*args));
    if (!args)
        return 1;
    int result = 1;
    for (int i = 0; i < argc; ++i) {
        int size =
            WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide[i], -1, NULL, 0, NULL, NULL);
        if (!size || !(args[i] = malloc((size_t)size)) ||
            !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide[i], -1, args[i], size, NULL,
                                 NULL))
            goto done;
    }
    result = main(argc, args);
done:
    for (int i = 0; i < argc; ++i)
        free(args[i]);
    free(args);
    return result;
}
#endif
