// URL detection in message bodies and the host the guard names.
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:testing"

@(test)
url_at_scan :: proc(t: ^testing.T) {
	// A link mid-sentence stops at whitespace, without the period.
	text := "see https://example.com/docs. ok"
	end, url, ok := url_at(text, 4)
	testing.expect(t, ok)
	testing.expect_value(t, url, "https://example.com/docs")
	testing.expect_value(t, text[end:], ". ok")

	// http too, and the end of the string is a valid end.
	_, plain, ok2 := url_at("http://a.example", 0)
	testing.expect(t, ok2)
	testing.expect_value(t, plain, "http://a.example")

	// Not a URL: another scheme, and a scheme with no host.
	_, _, ok3 := url_at("ftp://example.com", 0)
	testing.expect(t, !ok3)
	_, _, ok4 := url_at("https://", 0)
	testing.expect(t, !ok4)
}

@(test)
url_host_parse :: proc(t: ^testing.T) {
	testing.expect_value(t, url_host("https://example.com/a?b#c"), "example.com")
	testing.expect_value(t, url_host("http://example.com:8080/x"), "example.com:8080")
	testing.expect_value(t, url_host("https://example.com"), "example.com")
	// A lookalike host must not fold into the trusted one.
	testing.expect(t, url_host("https://evil.example.com/x") != url_host("https://example.com/x"))
}
