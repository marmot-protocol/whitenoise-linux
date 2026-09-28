package main

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sysinfo "core:sys/info"
import rl "sdlrl"

foreign import main_sandbox {WN_BUILD_DIR + "/libwnsandbox.a"}

@(private = "file", default_calling_convention = "c")
foreign main_sandbox {
	wn_main_sandbox_prepare :: proc(data, settings, resources: cstring, helpers: [^]cstring, count: c.size_t) -> c.int ---
	wn_main_sandbox_data :: proc() -> cstring ---
	wn_main_sandbox_settings :: proc() -> cstring ---
	wn_main_sandbox_error :: proc() -> cstring ---
	wn_main_sandbox_enter :: proc() -> c.int ---
	wn_main_sandbox_cleanup :: proc() -> c.int ---
	wn_helpers_start :: proc(helpers: [^]cstring, count: c.size_t, resources: cstring) -> c.int ---
	wn_helpers_stop :: proc() ---
	wn_tools_start :: proc() -> c.int ---
	wn_tools_stop :: proc() ---
	wn_tools_run :: proc(operation: c.int, arguments: [^]cstring, count: c.size_t, output: ^[^]u8, output_size: ^c.size_t, errors: ^[^]u8, errors_size: ^c.size_t, exit_code: ^c.int) -> c.int ---
	wn_tools_submit_notification :: proc(arguments: [^]cstring, count: c.size_t) -> c.int ---
}

@(private)
sandbox_settings_dir: string

@(private)
sandbox_os_version: string

@(private)
sandbox_helpers: map[string]string

// Resolve everything before unveil hides argv[0], PATH and XDG configuration.
// Optional helpers stay optional, but an installed helper must be executable.
@(private)
sandbox_prepare :: proc(home: string) -> string {
	// KERN_OSREVISION is forbidden under pledge. Kernel identity is immutable
	// for this process, so collect it before entering the policy.
	if version, ok := sysinfo.os_version(context.temp_allocator); ok {
		sandbox_os_version = strings.clone(version.full)
	}

	helpers := make([dynamic]cstring, context.temp_allocator)
	sandbox_helpers = make(map[string]string)
	for name in ([]string{"wn-image", "wn-archive", "wn-pdf", "wn-mesh", "wn-fbx", "wn-math", "wn-font", "wn-stt", "wn-tts", "wn-webview"}) {
		path := helper_path(name)
		if path == "" || !os.is_file(path) {
			if name == "wn-stt" || name == "wn-tts" || name == "wn-webview" {continue}
			fmt.eprintfln("OpenBSD sandbox: missing required helper %s", name)
			os.exit(1)
		}
		sandbox_helpers[name] = strings.clone(path)
		append(&helpers, strings.clone_to_cstring(path, context.temp_allocator))
	}
	settings := settings_path()
	if settings == "" {
		fmt.eprintln("OpenBSD sandbox: cannot locate settings directory")
		os.exit(1)
	}
	if wn_main_sandbox_prepare(
		   strings.clone_to_cstring(home, context.temp_allocator),
		   strings.clone_to_cstring(filepath.dir(settings), context.temp_allocator),
		   strings.clone_to_cstring(res_dir(), context.temp_allocator),
		   raw_data(helpers),
		   c.size_t(len(helpers)),
	   ) !=
	   0 {
		fmt.eprintfln("OpenBSD sandbox: %s", wn_main_sandbox_error())
		sandbox_stop()
		os.exit(1)
	}
	sandbox_settings_dir = strings.clone(string(wn_main_sandbox_settings()))
	if error := wn_helpers_start(
		raw_data(helpers),
		c.size_t(len(helpers)),
		strings.clone_to_cstring(res_dir(), context.temp_allocator),
	); error != 0 {
		fmt.eprintfln("OpenBSD sandbox: cannot start trusted helper launcher: %d", error)
		sandbox_stop()
		os.exit(1)
	}
	if error := wn_tools_start(); error != 0 {
		fmt.eprintfln("OpenBSD sandbox: cannot start confined tools: %d", error)
		sandbox_stop()
		os.exit(1)
	}
	return strings.clone(string(wn_main_sandbox_data()))
}

@(private)
sandbox_enter :: proc() {
	if wn_main_sandbox_enter() != 0 {
		fmt.eprintfln("OpenBSD sandbox: %s", wn_main_sandbox_error())
		rl.CloseWindow()
		sandbox_stop()
		os.exit(1)
	}
}

@(private)
sandbox_stop :: proc() {
	wn_tools_stop()
	wn_helpers_stop()
	delete(sandbox_os_version)
	sandbox_os_version = ""
	if wn_main_sandbox_cleanup() != 0 {
		fmt.eprintfln("OpenBSD sandbox cleanup: %s", wn_main_sandbox_error())
		os.exit(1)
	}
}

@(private)
sandbox_tool_exec :: proc(
	operation: c.int,
	args: []string,
	allocator: runtime.Allocator,
) -> (
	state: os.Process_State,
	stdout: []u8,
	stderr: []u8,
	err: os.Error,
) {
	arguments := make([]cstring, len(args), context.temp_allocator)
	for arg, i in args {
		arguments[i] = strings.clone_to_cstring(arg, context.temp_allocator)
	}
	output, errors: [^]u8
	output_size, errors_size: c.size_t
	exit_code: c.int
	error := wn_tools_run(
		operation,
		raw_data(arguments),
		c.size_t(len(args)),
		&output,
		&output_size,
		&errors,
		&errors_size,
		&exit_code,
	)
	defer libc.free(output)
	defer libc.free(errors)
	if error != 0 {return {}, nil, nil, os.Platform_Error(error)}
	stdout = make([]u8, int(output_size), allocator)
	stderr = make([]u8, int(errors_size), allocator)
	copy(stdout, output[:int(output_size)])
	copy(stderr, errors[:int(errors_size)])
	state = {
		exited    = true,
		exit_code = int(exit_code),
		success   = exit_code == 0,
	}
	return state, stdout, stderr, nil
}

@(private)
sandbox_notify :: proc(args: []string) -> c.int {
	arguments := make([]cstring, len(args), context.temp_allocator)
	for arg, i in args {
		arguments[i] = strings.clone_to_cstring(arg, context.temp_allocator)
	}
	return wn_tools_submit_notification(raw_data(arguments), c.size_t(len(args)))
}
