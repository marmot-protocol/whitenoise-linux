#ifndef WN_MAIN_SANDBOX_H
#define WN_MAIN_SANDBOX_H

#include <stddef.h>

/* Preparation runs as non-root before brokers, threads or the SDL window.
 * Read-only runtime trees, private SDL and their ancestry must be root-owned
 * without group/other write permission. HOME/XAUTHORITY and XDG runtime state
 * are redirected to private data before broker environments are frozen.
 * All returned strings live until process exit. A failure is fatal. */
int wn_main_sandbox_prepare(const char *data, const char *settings, const char *resources,
                            const char *const *helpers, size_t helper_count);
const char *wn_main_sandbox_data(void);
const char *wn_main_sandbox_settings(void);
const char *wn_main_sandbox_downloads(void);
const char *wn_main_sandbox_error(void);
/* Call after SDL has opened the display, before workers or Marmot start. */
int wn_main_sandbox_enter(void);
/* After display/audio and both brokers have stopped, remove the private runtime
 * home, including credentials and GTK state, without following symlinks.
 * Also safe after a failed preparation. Returns -1 with the usual error string. */
int wn_main_sandbox_cleanup(void);
/* Only the prestarted trusted helper launcher receives reset-on-exec authority. */
int wn_main_sandbox_enter_launcher(void);
/* Optional unsandboxed helpers retain the launcher's frozen policy on exec. */
int wn_main_sandbox_keep_exec(void);
/* Establish pinned filesystem identities in the broker before accepting any
 * request. Descendants can only remove executable grants, never add roots. */
int wn_main_sandbox_prepare_tools(const char *const *executables, size_t count);
/* Only the prestarted broker calls this, with its frozen operation's binary.
 * Main cannot add executables after locking. Tool exec retains this policy. */
int wn_main_sandbox_enter_tool(const char *executable);

#endif
