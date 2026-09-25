package main

@(private)
WN_IPC_ARCHIVE :: WN_BUILD_DIR + "/libwnipc.a"
when ODIN_OS == .Windows {
	foreign import ipc_lib {WN_IPC_ARCHIVE, "system:bcrypt"}
} else {
	foreign import ipc_lib {WN_IPC_ARCHIVE}
}

@(private)
Helper_Ipc :: struct {}

@(private, default_calling_convention = "c")
foreign ipc_lib {
	wn_ipc_create :: proc(size: uint) -> ^Helper_Ipc ---
	wn_ipc_close :: proc(ipc: ^Helper_Ipc) ---
	wn_ipc_data :: proc(ipc: ^Helper_Ipc) -> rawptr ---
	wn_ipc_name :: proc(ipc: ^Helper_Ipc) -> cstring ---
	wn_ipc_size :: proc(ipc: ^Helper_Ipc) -> uint ---
	wn_ipc_read :: proc(ipc: ^Helper_Ipc, data: rawptr, size, offset: uint) -> int ---
	wn_ipc_write :: proc(ipc: ^Helper_Ipc, data: rawptr, size, offset: uint) -> int ---
}

@(private)
helper_read_at :: proc(ipc: ^Helper_Ipc, data: []u8, offset: uint) -> int {
	return wn_ipc_read(ipc, raw_data(data), uint(len(data)), offset)
}

@(private)
helper_write_at :: proc(ipc: ^Helper_Ipc, data: []u8, offset: uint = 0) -> int {
	return wn_ipc_write(ipc, raw_data(data), uint(len(data)), offset)
}

@(private)
helper_write_string :: proc(ipc: ^Helper_Ipc, text: string) -> int {
	return wn_ipc_write(ipc, raw_data(text), uint(len(text)), 0)
}
