package main

import "core:os"
import "core:strings"

// A test that owns a window or other process-wide state opens by calling
// this with its own name as a string literal, and returns when it is false.
// That skips it in the shared run. `tests/odin.sh app --isolated` finds the
// call in the source and runs the test in a process of its own, so the name
// must be a literal and this comment must not spell out a call.
@(private)
test_isolated :: proc(name: string) -> bool {
	if len(os.args) == 2 && strings.has_prefix(os.args[1], "-tests:") {
		return os.args[1][len("-tests:"):] == name
	}
	return #config(ODIN_TEST_NAMES, "") == name
}
