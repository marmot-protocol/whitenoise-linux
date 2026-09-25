// Private helper transport: memory-backed mappings only, never plaintext disk files.
#ifndef WN_HELPER_IPC_H
#define WN_HELPER_IPC_H
#include <stddef.h>
#include <stdint.h>

typedef struct WnIpc WnIpc;
WnIpc *wn_ipc_create(size_t size);
WnIpc *wn_ipc_open(const char *name, size_t size);
void wn_ipc_close(WnIpc *ipc);
void *wn_ipc_data(WnIpc *ipc);
const char *wn_ipc_name(WnIpc *ipc);
size_t wn_ipc_size(WnIpc *ipc);
intptr_t wn_ipc_read(WnIpc *ipc, void *data, size_t size, size_t offset);
intptr_t wn_ipc_write(WnIpc *ipc, const void *data, size_t size, size_t offset);
int wn_helper_guard(unsigned long parent);
int wn_helper_silence(void);
void *wn_model_lock(const char *directory);
void wn_model_unlock(void *lock);
#endif
