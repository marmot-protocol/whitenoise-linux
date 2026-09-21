// The transport line and the shape the shim polls: everything else in
// the runner is socket plumbing.
package main

import "core:strings"
import "core:testing"

@(test)
xdc_line_roundtrip :: proc(t: ^testing.T) {
	line := xdc_encode("abc123", transmute([]u8)string(`{"move":"e2e4"}`))
	defer delete(line)

	session, payload, ok := xdc_decode(line)
	testing.expect(t, ok)
	testing.expect_value(t, session, "abc123")
	testing.expect_value(t, string(payload), `{"move":"e2e4"}`)
	delete(payload)

	// Ordinary messages are not updates, whatever they contain.
	_, _, plain := xdc_decode("let's play chess")
	testing.expect(t, !plain)
	_, _, half := xdc_decode("wnxdc1:abc123")
	testing.expect(t, !half)
	_, _, empty := xdc_decode("wnxdc1::")
	testing.expect(t, !empty)
}

@(test)
xdc_updates_shape :: proc(t: ^testing.T) {
	clear(&xdc.updates)
	append(&xdc.updates, `{"a":1}`, `{"b":2}`)
	defer {
		delete(xdc.updates)
		xdc.updates = {}
	}

	all := xdc_updates_json("serial=0")
	defer delete(all)
	testing.expect_value(
		t,
		all,
		`[{"payload":{"a":1},"serial":1,"max_serial":2},{"payload":{"b":2},"serial":2,"max_serial":2}]`,
	)

	// A listener that has seen serial 1 gets only what follows it.
	tail := xdc_updates_json("serial=1")
	defer delete(tail)
	testing.expect(t, strings.contains(tail, `"serial":2`))
	testing.expect(t, !strings.contains(tail, `"serial":1,`))
}
