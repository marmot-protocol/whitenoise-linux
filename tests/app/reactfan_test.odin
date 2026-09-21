package main

import "core:math"
import "core:testing"

// A corner press still has to leave room for the whole ring.
@(test)
fan_center_stays_on_screen :: proc(t: ^testing.T) {
	count := 8
	w, h := f32(1024), f32(700)
	m := fan_radius(count) + FAN_CELL * FAN_PICK / 2

	c := fan_center({0, 0}, count, w, h)
	testing.expect(t, c.x >= m && c.y >= m, "top-left press pulled inside")

	c = fan_center({w, h}, count, w, h)
	testing.expect(t, c.x <= w - m && c.y <= h - m, "bottom-right press pulled inside")

	c = fan_center({500, 350}, count, w, h)
	testing.expect(t, c == {500, 350}, "a press with room to spare does not move")

	// Narrower than the ring: centred rather than clamped to nonsense.
	c = fan_center({0, 0}, count, m, m)
	testing.expect(t, c.x == m && c.y == m, "no room means no crossed bounds")
}

// The ring is wide enough that its cells never overlap.
@(test)
fan_radius_fits_cells :: proc(t: ^testing.T) {
	for count in 4 ..= 16 {
		gap := 2 * math.PI * fan_radius(count) / f32(count)
		testing.expect(t, gap >= FAN_CELL, "cells sit side by side without touching")
	}
}
