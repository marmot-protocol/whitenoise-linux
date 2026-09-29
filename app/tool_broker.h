#ifndef WN_TOOL_BROKER_H
#define WN_TOOL_BROKER_H
#include <stddef.h>

enum wn_tool_operation {
    WN_TOOL_CURL = 1,
    WN_TOOL_NOTIFY,
    WN_TOOL_OPEN_DIALOG,
    WN_TOOL_SAVE_DIALOG
};
/* Fork once, before threads and before the main process enters confinement. */
int wn_tools_start(void);
void wn_tools_stop(void);
/* Arguments do not include argv[0]. Operations select frozen executable paths;
 * the protocol never accepts executable names, environment or policy roots.
 * Returned buffers are malloc-owned, and bounded to 128 MiB each. */
int wn_tools_run(int operation, const char *const *arguments, size_t count, unsigned char **output,
                 size_t *output_size, unsigned char **errors, size_t *errors_size, int *exit_code);
int wn_tools_submit_notification(const char *const *arguments, size_t count);
typedef void (*wn_tool_dialog_callback)(void *, const char *const *, int);
int wn_tools_dialog(int save, int multiple, const char *name, wn_tool_dialog_callback callback,
                    void *userdata);
#endif
