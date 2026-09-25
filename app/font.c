// Decode web fonts in a bounded child process before the UI loads their SFNT data.
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_TRUETYPE_TABLES_H
#include <stdio.h>
#include <stdlib.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#else
#include <sys/resource.h>
#endif
#ifdef __APPLE__
#include <mach/mach.h>
#endif

#ifdef _WIN32
static unsigned long font_read(FT_Stream stream, unsigned long offset, unsigned char *buffer,
                               unsigned long count) {
    FILE *file = stream->descriptor.pointer;
    if (_fseeki64(file, offset, SEEK_SET))
        return count ? 0 : 1;
    return count ? (unsigned long)fread(buffer, 1, count, file) : 0;
}
#endif

int main(int argc, char **argv) {
    if (argc != 2) {
        return 1;
    }
#ifdef _WIN32
    HANDLE job = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_PROCESS_TIME;
    limits.ProcessMemoryLimit = 256 * 1024 * 1024;
    limits.BasicLimitInformation.PerProcessUserTimeLimit.QuadPart = 5 * 10000000LL;
    if (!job ||
        !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) ||
        !AssignProcessToJobObject(job, GetCurrentProcess()) ||
        _setmode(_fileno(stdout), _O_BINARY) < 0)
        return 1;
#else
    struct rlimit memory = {256 * 1024 * 1024, 256 * 1024 * 1024};
    struct rlimit cpu = {5, 5};
#ifdef __APPLE__
    // dyld's shared cache already occupies far more than 256 MiB of virtual
    // address space. Bound additional mappings instead of rejecting every font.
    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) !=
        KERN_SUCCESS)
        return 1;
    memory.rlim_cur += info.virtual_size;
    memory.rlim_max = memory.rlim_cur;
#endif
    if (setrlimit(RLIMIT_AS, &memory) || setrlimit(RLIMIT_CPU, &cpu))
        return 1;
#endif
    FT_Library library;
    FT_Face face;
    if (FT_Init_FreeType(&library)) {
        return 1;
    }
#ifdef _WIN32
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[1], -1, NULL, 0);
    wchar_t *path = length ? malloc((size_t)length * sizeof(*path)) : NULL;
    if (!path) {
        FT_Done_FreeType(library);
        return 1;
    }
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[1], -1, path, length);
    FILE *file = _wfopen(path, L"rb");
    free(path);
    if (!file) {
        FT_Done_FreeType(library);
        return 1;
    }
    __int64 input_size = _filelengthi64(_fileno(file));
    if (input_size <= 0 || input_size > 16 * 1024 * 1024) {
        fclose(file);
        FT_Done_FreeType(library);
        return 1;
    }
    FT_StreamRec stream = {0};
    stream.size = (unsigned long)input_size;
    stream.descriptor.pointer = file;
    stream.read = font_read;
    FT_Open_Args args = {0};
    args.flags = FT_OPEN_STREAM;
    args.stream = &stream;
    FT_Error opened = FT_Open_Face(library, &args, 0, &face);
#else
    FT_Error opened = FT_New_Face(library, argv[1], 0, &face);
#endif
    if (opened) {
#ifdef _WIN32
        fclose(file);
#endif
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
#ifdef _WIN32
    fclose(file);
    CloseHandle(job);
#endif
    FT_Done_FreeType(library);
    return result;
}

#include "helper_main.h"
