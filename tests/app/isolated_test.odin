package main

import "core:os"
import "core:strings"

// A test that owns a window or other process-wide state opens with
// `if !test_isolated("its_name") {return}`. That skips it in the shared run,
// and `tests/odin.sh app --isolated` finds the call in the source and runs the
// test in a process of its own. Pass the name as a literal for that reason.
@(private)
test_isolated :: proc(name: string) -> bool {
	if len(os.args) == 2 && strings.has_prefix(os.args[1], "-tests:") {
		return os.args[1][len("-tests:"):] == name
	}
	return #config(ODIN_TEST_NAMES, "") == name
}
