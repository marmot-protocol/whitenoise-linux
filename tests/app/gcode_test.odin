// Extrusion-segment extraction checks.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:testing"

@(test)
gcode_parse :: proc(t: ^testing.T) {
	src := "; header\nG90\nG1 X10 Y0 Z0.2 ; travel, no E\nG1 X20 Y0 E1\nG1 X20 Y10 E2\nG92 E0\nG1 X0 Y10 E1.5\nM83\nG1 X0 Y0 E0.5\nG1 X5 Y5 E-1 ; retract move, no segment\n"
	segs, ok := parse_gcode(transmute([]u8)src)
	defer delete(segs)
	testing.expect(t, ok)
	testing.expect_value(t, len(segs) / 6, 4) // travel and retract excluded

	// Normalized into the unit sphere.
	for v in segs {
		testing.expect(t, abs(v) <= 1.001)
	}

	// Comment-only input has no extrusion.
	_, bad := parse_gcode(transmute([]u8)string("; nothing\nG1 X5 Y5\n"))
	testing.expect(t, !bad)
}
