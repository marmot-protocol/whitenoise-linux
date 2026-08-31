// NIP-49 conformance: the spec's test vector must decrypt, and an
// encrypt → decrypt round trip must return the same key.
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:testing"

@(test)
nip49_vector :: proc(t: ^testing.T) {
	// The test vector from nips/49.md (log_n 16, password "nostr").
	vector := "ncryptsec1qgg9947rlpvqu76pj5ecreduf9jxhselq2nae2kghhvd5g7dgjtcxfqtd67p9m0w57lspw8gsq6yphnm8623nsl8xn9j4jdzz84zm3frztj3z7s35vpzmqf6ksu8r89qk5z2zxfmu5gv8th8wclt0h4p"
	testing.expect_value(t, nip49_decrypt(vector, "nostr"), "3501454135014541350145413501453fefb02227e449e57cf4d3a3ce05378683")

	// Wrong password fails the tag.
	testing.expect_value(t, nip49_decrypt(vector, "wrong"), "")
}

@(test)
nip49_round_trip :: proc(t: ^testing.T) {
	// nsec for the key 0x00..01.
	nsec := "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsmhltgl"
	hrp, key, ok := bech32_decode(nsec)
	testing.expect(t, ok)
	testing.expect_value(t, hrp, "nsec")
	testing.expect_value(t, len(key), 32)

	sealed := nip49_encrypt(nsec, "hunter2")
	testing.expect(t, len(sealed) > 0)
	testing.expect_value(t, nip49_decrypt(sealed, "hunter2"), "0000000000000000000000000000000000000000000000000000000000000001")
}
