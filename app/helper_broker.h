#ifndef WN_HELPER_BROKER_H
#define WN_HELPER_BROKER_H

#include <stddef.h>

/* Start before threads, after main policy preparation. Returns an errno value.
 * An inactive wn_helper_execve returns -1/ENOSYS; the linker wrapper instead
 * preserves ordinary execve behavior when no broker is running.
 * Successful exec calls do not return: the fork child proxies the real helper.
 * stop must run after helper users have joined. */
int wn_helpers_start(const char *const *helpers, size_t count, const char *resources);
void wn_helpers_stop(void);
int wn_helper_execve(const char *path, char *const argv[], char *const envp[]);
int __wrap_execve(const char *path, char *const argv[], char *const envp[]);

#endif
