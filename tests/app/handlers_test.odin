package main

import "core:testing"

@(test)
test_uri_unescape :: proc(t: ^testing.T) {
	testing.expect_value(t, uri_unescape("/home/me/a%20b.png"), "/home/me/a b.png")
	testing.expect_value(t, uri_unescape("/tmp/100%"), "/tmp/100%")
	testing.expect_value(t, uri_unescape("/tmp/%zz"), "/tmp/%zz")
}
