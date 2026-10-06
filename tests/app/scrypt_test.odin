// scrypt known answer: backups sealed by one build must open in the
// next, so the KDF output is pinned against an independent
// implementation (OpenSSL via node:crypto scryptSync, N=1024 r=8 p=1).
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:encoding/hex"
import "core:testing"

@(test)
scrypt_known_answer :: proc(t: ^testing.T) {
	key: [32]u8
	scrypt_r8p1(
		transmute([]u8)string("pleaseletmein"),
		transmute([]u8)string("SodiumChloride"),
		10,
		key[:],
	)
	testing.expect_value(
		t,
		string(hex.encode(key[:], context.temp_allocator)),
		"54173687d265e43226bd914b015267e2fdd4108aa05937fb549eceb0c276a285",
	)
}
