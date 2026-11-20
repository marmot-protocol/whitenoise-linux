package main

import "core:os"
import "core:strings"

@(private)
test_isolated :: proc(name: string) -> bool {
	if len(os.args) == 2 && strings.has_prefix(os.args[1], "-tests:") {
		return os.args[1][len("-tests:"):] == name
	}
	return #config(ODIN_TEST_NAMES, "") == name
}
