package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

// Encode bytes, not runes: SOCKS5 credentials are UTF-8 byte strings.
@(private)
proxy_uri_component :: proc(value: string) -> string {
	encoded := make([]u8, len(value) * 3, context.temp_allocator)
	hex := "0123456789ABCDEF"
	for i in 0 ..< len(value) {
		encoded[i * 3] = '%'
		encoded[i * 3 + 1] = hex[value[i] >> 4]
		encoded[i * 3 + 2] = hex[value[i] & 15]
	}
	return string(encoded)
}

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
	desc := desc
	credential_proxy := ""
	if len(desc.command) > 0 && desc.command[0] == curl_path() {
		proxy := os.get_env("WN_SOCKS5_PROXY", context.temp_allocator)
		username := os.get_env("WN_SOCKS5_USERNAME", context.temp_allocator)
		password := os.get_env("WN_SOCKS5_PASSWORD", context.temp_allocator)
		authenticated := username != "" || password != ""
		if (proxy != "" && !socks5_proxy_valid(proxy)) ||
		   (authenticated && (proxy == "" || !socks5_auth_valid(username, password))) {
			return {}, nil, nil, os.General_Error.Invalid_Command
		}
		if proxy != "" {
			args := make([dynamic]string, context.temp_allocator)
			// Ignore curlrc and NO_PROXY so explicit proxy mode cannot bypass it.
			append(&args, desc.command[0], "-q", "--socks5-basic", "--noproxy", "")
			if authenticated {
				credential_proxy = fmt.tprintf(
					"socks5h://%s:%s@%s",
					proxy_uri_component(username),
					proxy_uri_component(password),
					proxy,
				)
				when ODIN_OS != .OpenBSD {
					// A child-only override keeps secrets out of argv and off disk.
					source := desc.env
					if source == nil {
						env_err: os.Error
						source, env_err = os.environ(context.temp_allocator)
						if env_err != nil {return {}, nil, nil, env_err}
					}
					environment := make([dynamic]string, context.temp_allocator)
					for entry in source {
						separator := strings.index_byte(entry, '=')
						if separator < 0 {continue}
						key := entry[:separator]
						if strings.has_suffix(key, "_proxy") || strings.has_suffix(key, "_PROXY") {
							continue
						}
						append(&environment, entry)
					}
					append(&environment, fmt.tprintf("all_proxy=%s", credential_proxy))
					desc.env = environment[:]
				}
			} else {
				append(&args, "--proxy", fmt.tprintf("socks5h://%s", proxy))
			}
			append(&args, ..desc.command[1:])
			desc.command = args[:]
		}
	}
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
		return sandbox_tool_exec(1, desc.command[1:], allocator, credential_proxy)
	} else {
		return os.process_exec(desc, allocator)
	}
}
