#ifndef WN_DECODER_LIMITS_H
#define WN_DECODER_LIMITS_H

#include "decoder_ipc.h"
#include <stdio.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#include <string.h>
#else
#include <sys/resource.h>
#include <unistd.h>
#endif
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_vm.h>
#endif

typedef enum {
    WN_DECODER_ONESHOT,
    WN_DECODER_SESSION,
} WnDecoderLifetime;

/* Set before parsing; each decoder installs its own filesystem capability policy.
 * Sessions use the parent's per-transaction deadline, not a cumulative CPU quota
 * that would eventually terminate a healthy looping animation. */
static inline int wn_decoder_limits(WnDecoderLifetime lifetime) {
#ifdef _WIN32
    HANDLE job = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    memset(&limits, 0, sizeof limits);
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_PROCESS_MEMORY;
    limits.ProcessMemoryLimit = WN_IMAGE_MEMORY_MAX;
    if (lifetime == WN_DECODER_ONESHOT) {
        limits.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_PROCESS_TIME;
        limits.BasicLimitInformation.PerProcessUserTimeLimit.QuadPart = 5 * 10000000LL;
    }
    if (!job ||
        !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) ||
        !AssignProcessToJobObject(job, GetCurrentProcess()) ||
        _setmode(_fileno(stdin), _O_BINARY) < 0 || _setmode(_fileno(stdout), _O_BINARY) < 0) {
        if (job) {
            CloseHandle(job);
        }
        return 0;
    }
    /* Keep the job alive until process exit. */
#else
    struct rlimit memory = {WN_IMAGE_MEMORY_MAX, WN_IMAGE_MEMORY_MAX};
    struct rlimit cpu = {5, 5};
    struct rlimit core = {0, 0};
#ifdef __APPLE__
    /* Count top-level mappings: task_info omits Rosetta's reserved regions,
     * but RLIMIT_AS includes them when validating the limit. */
    mach_vm_address_t address = 0;
    for (;;) {
        mach_vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t result = mach_vm_region_recurse(mach_task_self(), &address, &size, &depth,
                                                      (vm_region_recurse_info_t)&info, &count);
        if (result == KERN_INVALID_ADDRESS) {
            break;
        }
        if (result != KERN_SUCCESS || size > RLIM_INFINITY - memory.rlim_cur ||
            address > UINT64_MAX - size) {
            return 0;
        }
        memory.rlim_cur += size;
        address += size;
    }
    memory.rlim_max = memory.rlim_cur;
#endif
#ifdef RLIMIT_AS
    if (setrlimit(RLIMIT_AS, &memory)) {
        return 0;
    }
#else
    if (setrlimit(RLIMIT_DATA, &memory)) {
        return 0;
    }
#endif
    if ((lifetime == WN_DECODER_ONESHOT && setrlimit(RLIMIT_CPU, &cpu)) ||
        setrlimit(RLIMIT_CORE, &core)) {
        return 0;
    }
#endif
    return 1;
}

#endif
