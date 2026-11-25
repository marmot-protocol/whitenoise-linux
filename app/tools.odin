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

when ODIN_OS == .Linux && ODIN_PLATFORM_SUBTARGET != .Android {
	@(private)
	strip_appimage_env :: proc(entries: []string) -> []string {
		rules := #load("appimage-host-env.txt", string)
		for rule in strings.split_lines_iterator(&rules) {
			line := rule
			op, _ := strings.fields_iterator(&line)
			name, _ := strings.fields_iterator(&line)
			marker, _ := strings.fields_iterator(&line)
			suffix, _ := strings.fields_iterator(&line)
			owner := ""
			if marker != "" {
				for entry in entries {
					key, _, value := strings.partition(entry, "=")
					if key == marker {
						owner = value
						break
					}
				}
				if owner == "" {continue}
			}
			for &entry in entries {
				key, _, value := strings.partition(entry, "=")
				if key != name {continue}
				if op == "unset" {
					entry = ""
					continue
				}
				if !strings.has_prefix(value, owner) {continue}
				value = value[len(owner):]
				if !strings.has_prefix(value, suffix) {continue}
				value = value[len(suffix):]
				if op == "trim" {
					entry = fmt.tprintf("%s=%s", name, value)
				} else if op == "drop" && value == "" {
					entry = ""
				}
			}
		}
		n := 0
		for entry in entries {
			if entry == "" {continue}
			entries[n] = entry
			n += 1
		}
		return entries[:n]
	}
}

@(private)
host_process_exec :: proc(
	desc: os.Process_Desc,
	allocator: runtime.Allocator,
) -> (
	state: os.Process_State,
	stdout: []u8,
	stderr: []u8,
	err: os.Error,
) {
	desc := desc
	when ODIN_OS == .Linux && ODIN_PLATFORM_SUBTARGET != .Android {
		if os.get_env("WN_APPIMAGE_AUDIO_ROOT", context.temp_allocator) != "" {
			entries := desc.env
			if entries == nil {
				entries = os.environ(context.temp_allocator) or_return
			} else {
				entries = make([]string, len(desc.env), context.temp_allocator)
				copy(entries, desc.env)
			}
			desc.env = strip_appimage_env(entries)
		}
	}
	return os.process_exec(desc, allocator)
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
					env_err: os.Error
					desc.env, env_err = proxy_child_env(desc.env, credential_proxy)
					if env_err != nil {return {}, nil, nil, env_err}
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
		return host_process_exec(desc, allocator)
	}
}
