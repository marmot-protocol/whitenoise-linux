// marmot:// link parsing, mirroring the slint deeplink.rs tests.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:fmt"
import "core:testing"

@(test)
deeplink_link_ref :: proc(t: ^testing.T) {
	testing.expect_value(t, marmot_link_ref("marmot://profile/abc"), "abc")
	testing.expect_value(t, marmot_link_ref("marmot://profile/abc/"), "abc")
	testing.expect_value(t, marmot_link_ref("marmot://profile/abc?from=qr"), "abc")
	testing.expect_value(t, marmot_link_ref("marmot://profile/abc#x"), "abc")
	testing.expect_value(t, marmot_link_ref("MARMOT://profile/abc"), "abc")

	testing.expect_value(t, marmot_link_ref("marmot://profile/"), "")
	testing.expect_value(t, marmot_link_ref("marmot://group/abc"), "")
	testing.expect_value(t, marmot_link_ref("nostr:npub1abc"), "")
	testing.expect_value(t, marmot_link_ref("https://example.com/marmot://profile/a"), "")
}

@(test)
deeplink_chip_at :: proc(t: ^testing.T) {
	// npub for the key 0x00..01; the ?from=qr tail rides on the chip.
	npub := hex_npub("0000000000000000000000000000000000000000000000000000000000000001")
	defer delete(npub)
	body := fmt.tprintf("see marmot://profile/%s?from=qr now", npub)

	end, hx, ok := marmot_link_at(body, 4)
	testing.expect(t, ok)
	testing.expect_value(t, hx, "0000000000000000000000000000000000000000000000000000000000000001")
	testing.expect_value(t, body[end:], " now")

	_, _, bad := marmot_link_at("marmot://profile/notakey", 0)
	testing.expect(t, !bad)
}

@(test)
deeplink_ref_hex :: proc(t: ^testing.T) {
	hex_key := "0000000000000000000000000000000000000000000000000000000000000001"
	npub := hex_npub(hex_key)
	defer delete(npub)

	testing.expect_value(t, deeplink_hex(npub), hex_key)
	testing.expect_value(t, deeplink_hex(hex_key), hex_key)
	testing.expect_value(t, deeplink_hex("notakey"), "")
}
