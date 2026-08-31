// Starter identity: deterministic name and guaranteed face art.
// Run: ODIN_ROOT=build/odin-root odin test app
package main

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
starter_identity_deterministic :: proc(t: ^testing.T) {
	a, cp_a := starter_identity("npub1testkey")
	b, cp_b := starter_identity("npub1testkey")
	testing.expect_value(t, a, b)
	testing.expect_value(t, cp_a, cp_b)

	other, _ := starter_identity("npub1otherkey")
	testing.expect(t, a != other, "different keys should differ (hash collision otherwise)")
}

@(test)
starter_animals_have_tiles :: proc(t: ^testing.T) {
	for animal in ANIMALS {
		path := fmt.tprintf("%s/%x.png", twemoji_dir(), i32(animal.cp))
		testing.expect(t, os.exists(path), fmt.tprintf("%s: missing tile %s", animal.name, path))
	}
}
