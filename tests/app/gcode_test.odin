// Extrusion-segment extraction checks.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:math"
import "core:slice"
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

@(test)
gcode_depth_order :: proc(t: ^testing.T) {
	view := Gcode_View {
		rw   = 32,
		rh   = 32,
		pix  = make([]u8, 32 * 32 * 4),
		zbuf = make([]f32, 32 * 32),
	}
	defer delete(view.pix)
	defer delete(view.zbuf)
	front := [6]f32{-1, 0, 0.5, 1, 0, 0.5}
	back := [6]f32{0, -1, -0.5, 0, 1, -0.5}
	slice.fill(view.zbuf, math.NEG_INF_F32)
	gcode_raster_seg(&view, front, 10, 2)
	want := [4]u8{}
	copy(want[:], view.pix[(16 * 32 + 16) * 4:][:4])
	depth := view.zbuf[16 * 32 + 16]
	gcode_raster_seg(&view, back, 10, 2)
	for value, i in want {testing.expect_value(t, view.pix[(16 * 32 + 16) * 4 + i], value)}
	testing.expect_value(t, view.zbuf[16 * 32 + 16], depth)
	slice.fill(view.zbuf, math.NEG_INF_F32)
	gcode_raster_seg(&view, back, 10, 2)
	gcode_raster_seg(&view, front, 10, 2)
	for value, i in want {testing.expect_value(t, view.pix[(16 * 32 + 16) * 4 + i], value)}
	testing.expect_value(t, view.zbuf[16 * 32 + 16], depth)
}

@(test)
gcode_capsule_edges :: proc(t: ^testing.T) {
	view := Gcode_View {
		rw   = 16,
		rh   = 16,
		pix  = make([]u8, 16 * 16 * 4),
		zbuf = make([]f32, 16 * 16),
	}
	defer delete(view.pix)
	defer delete(view.zbuf)
	slice.fill(view.zbuf, math.NEG_INF_F32)
	// Horizontal stroke crossing the viewport.
	gcode_raster_seg(&view, {-2, 0, 0, 2, 0, 0}, 10, 1)
	testing.expect_value(t, view.pix[(8 * 16) * 4 + 3], u8(255))
	testing.expect_value(t, view.pix[(10 * 16) * 4 + 3], u8(0))
	slice.fill(view.zbuf, math.NEG_INF_F32)
	slice.fill(view.pix, 0)
	// A segment viewed end-on still has a round cap at its nearer endpoint.
	gcode_raster_seg(&view, {0, 0, -1, 0, 0, 1}, 10, 2)
	testing.expect(t, view.zbuf[8 * 16 + 8] > 1)
	testing.expect_value(t, view.pix[(8 * 16 + 8) * 4 + 3], u8(255))
	// A nearer cap's edge must not reveal geometry behind it.
	testing.expect_value(t, view.pix[(8 * 16 + 9) * 4 + 3], u8(255))
	testing.expect_value(t, view.pix[(8 * 16 + 10) * 4 + 3], u8(0))
	// A fully offscreen segment leaves every pixel unchanged.
	want := make([]u8, len(view.pix))
	defer delete(want)
	copy(want, view.pix)
	gcode_raster_seg(&view, {4, 4, 2, 5, 5, 2}, 10, 2)
	for value, i in want {testing.expect_value(t, view.pix[i], value)}
}
