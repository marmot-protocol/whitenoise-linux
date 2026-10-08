package main

import "core:strings"
import "core:testing"

@(test)
socks5_numeric_endpoints :: proc(t: ^testing.T) {
	for endpoint in ([]string{"127.0.0.1:9050", "0.0.0.0:1", "255.255.255.255:65535", "[::1]:9050", "[::]:1", "[2001:db8::abcd]:65535", "[::ffff:192.0.2.1]:1080", "[1:2:3:4:5:6:7:8]:1080"}) {
		testing.expect(t, socks5_proxy_valid(endpoint), endpoint)
	}
}

@(test)
socks5_credential_limits :: proc(t: ^testing.T) {
	limit := strings.repeat("a", 255, context.temp_allocator)
	too_long := strings.repeat("a", 256, context.temp_allocator)
	unicode_limit := strings.repeat("é", 127, context.temp_allocator)
	unicode_too_long := strings.repeat("é", 128, context.temp_allocator)
	for pair in ([][2]string{{"user:@/%", "päss:@/%"}, {limit, limit}, {unicode_limit, unicode_limit}}) {
		testing.expect(t, socks5_auth_valid(pair[0], pair[1]))
	}
	for pair in ([][2]string{{"", ""}, {"user", ""}, {"", "pass"}, {too_long, "pass"}, {"user", too_long}, {unicode_too_long, "pass"}, {"user", unicode_too_long}, {"user\x00name", "pass"}, {"user", "pass\x00word"}, {"\xff", "pass"}, {"user", "\xff"}}) {
		testing.expect(t, !socks5_auth_valid(pair[0], pair[1]))
	}
}

@(test)
socks5_invalid_endpoints :: proc(t: ^testing.T) {
	for endpoint in ([]string{"", "127.0.0.1", "127.0.0.1:0", "127.0.0.1:65536", "127.0.0.1:-1", "127.0.0.1:+9050", "127.0.0.1:", "127.0.0.1:9050/path", " 127.0.0.1:9050", "127.0.0.1:9050 ", "localhost:9050", "socks5://127.0.0.1:9050", "user:pass@127.0.0.1:9050", "256.0.0.1:9050", "127.1:9050", "127.0.00.1:9050", "[127.0.0.1]:9050", "::1:9050", "[::1]", "[::1]:0", "[::1]:65536", "[::1]:-1", "[fe80::1%eth0]:9050", "[1:2:3:4:5:6:7:8:9]:9050", "[2001:db8::g]:9050", "[::ffff:192.00.2.1]:9050", "[::ffff:256.0.0.1]:9050"}) {
		testing.expect(t, !socks5_proxy_valid(endpoint), endpoint)
	}
}
