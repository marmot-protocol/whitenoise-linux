package main

import "base:runtime"
import "core:os"

// HTTP workers use the same process result contract on every platform. On
// OpenBSD only the prestarted broker, never the UI process, may execute curl.
@(private)
tool_exec :: proc(
	desc: os.Process_Desc,
	allocator: runtime.Allocator,
) -> (
	state: os.Process_State,
	stdout: []u8,
	stderr: []u8,
	err: os.Error,
) {
	when ODIN_OS == .OpenBSD {
		if len(desc.command) == 0 ||
		   desc.command[0] != curl_path() ||
		   desc.working_dir != "" ||
		   desc.env != nil ||
		   desc.stdin != nil ||
		   desc.stdout != nil ||
		   desc.stderr != nil {
			return {}, nil, nil, os.General_Error.Invalid_Command
		}
		return sandbox_tool_exec(1, desc.command[1:], allocator)
	} else {
		return os.process_exec(desc, allocator)
	}
}
