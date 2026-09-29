package main

import "core:testing"

@(test)
test_check_path_geometry :: proc(t: ^testing.T) {
	verts: [dynamic]rl.Vertex
	defer delete(verts)
	check_path(&verts, 0, 0, 0, {})
	testing.expect(t, len(verts) == 0, "zero progress must not draw")
	for progress in ([]f32{0.00001, 0.001, 1}) {
		clear(&verts)
		check_path(&verts, 0, 0, progress, {})
		testing.expect(t, len(verts) == (progress == 1 ? 12 : 6))
		for v in verts {
			for coordinate in v.position {
				testing.expect(t, !math.is_nan(coordinate) && !math.is_inf(coordinate))
			}
		}
		for i := 0; i < len(verts); i += 6 {
			a, b := verts[i].position, verts[i + 1].position
			c, d := verts[i + 2].position, verts[i + 4].position
			dx := (c.x + d.x - a.x - b.x) / 2
			dy := (c.y + d.y - a.y - b.y) / 2
			length := math.sqrt(dx * dx + dy * dy)
			width := math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))
			expected := 1.8 * min(length / 0.001, 1)
			testing.expect(
				t,
				abs(width - expected) < 0.001,
				"stroke must retain its guarded thickness",
			)
		}
	}
	end := (verts[8].position + verts[10].position) / 2
	testing.expect(t, abs(end.x - CHECK_W) < 0.0001 && abs(end.y - CHECK_H * 0.1) < 0.0001)
	clear(&verts)
	stroke(&verts, 0, 0, 0, 0, 1.8, {})
	for v in verts {
		testing.expect(
			t,
			v.position.x == 0 && v.position.y == 0,
			"zero-length stroke must stay finite and collapsed",
		)
	}
}
