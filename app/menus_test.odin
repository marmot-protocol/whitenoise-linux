package main

import "core:testing"

@(test)
test_rune_prefix :: proc(t: ^testing.T) {
	testing.expect_value(t, rune_prefix("abcdef", 3), 3)
	testing.expect_value(t, rune_prefix("abc", 9), 3)
	testing.expect_value(t, rune_prefix("héllo", 2), 3) // é is two bytes
	testing.expect_value(t, rune_prefix("", 4), 0)
}
