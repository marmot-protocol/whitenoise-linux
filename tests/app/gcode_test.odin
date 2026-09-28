// Extrusion-segment extraction checks.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:math"
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

@(test)
gcode_relative_axes :: proc(t: ^testing.T) {
	source := "G90\nM82\nG1 X2 E1\nG91\nG1 Y2 E1\nG92 E0\nG1 Z2 E1\n"
	segments, ok := parse_gcode(transmute([]u8)source)
	defer delete(segments)
	testing.expect(t, ok)
	expected := [18]f32{-1, -1, -1, 1, -1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1, 1, 1}
	testing.expect_value(t, len(segments), len(expected))
	if len(segments) != len(expected) {return}
	scale := math.sqrt(f32(3))
	for value, i in segments {
		testing.expect(t, abs(value - expected[i] / scale) < 0.00001)
	}
}
