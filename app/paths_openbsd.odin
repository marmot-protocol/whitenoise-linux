package main

import "base:runtime"
import "core:strings"
import "core:sys/posix"

// OpenBSD has no API for the running executable's path. Odin guesses from
// argv[0], but resolves only "./x" and "/x" and searches PATH for anything
// else, so a relative "build/app" fails. Any argv[0] with a slash is a path
// from the startup directory, which the app never leaves; "" defers to Odin.
@(private)
argv0_path :: proc(allocator := context.temp_allocator) -> string {
	if len(runtime.args__) == 0 || !strings.contains(string(runtime.args__[0]), "/") {
		return ""
	}
	real := posix.realpath(runtime.args__[0])
	if real == nil {return ""}
	defer posix.free(real)
	return strings.clone(string(real), allocator)
}
