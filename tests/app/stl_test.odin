// Parser checks for both STL flavors plus the hostile-input guards.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:testing"

@(private = "file")
put_f32 :: proc(buf: ^[dynamic]u8, v: f32) {
	bits := transmute(u32)v
	append(buf, u8(bits), u8(bits >> 8), u8(bits >> 16), u8(bits >> 24))
}

@(test)
stl_binary_parse :: proc(t: ^testing.T) {
	// One triangle: header, count=1, normal, (0,0,0)(2,0,0)(0,2,0), attr.
	bin: [dynamic]u8
	defer delete(bin)
	resize(&bin, 80)
	append(&bin, 1, 0, 0, 0)
	for _ in 0 ..< 3 {
		put_f32(&bin, 0)
	}
	verts := [9]f32{0, 0, 0, 2, 0, 0, 0, 2, 0}
	for v in verts {
		put_f32(&bin, v)
	}
	append(&bin, 0, 0)

	tris, ok := parse_stl(bin[:])
	defer delete(tris)
	testing.expect(t, ok)
	testing.expect_value(t, len(tris), 9)
	// Normalized: every coordinate inside the unit sphere.
	for v in tris {
		testing.expect(t, abs(v) <= 1.001)
	}

	// Hostile count larger than the payload must fail, not allocate.
	bin[80] = 0xff
	bin[81] = 0xff
	bin[82] = 0xff
	bin[83] = 0x7f
	_, bad := parse_stl(bin[:])
	testing.expect(t, !bad)
}

@(test)
stl_ascii_parse :: proc(t: ^testing.T) {
	src := "solid demo\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid demo\n"
	tris, ok := parse_stl(transmute([]u8)src)
	defer delete(tris)
	testing.expect(t, ok)
	testing.expect_value(t, len(tris), 9)

	// Truncated vertex list must fail.
	broken := "solid x\nvertex 1 2\nendsolid x\n"
	_, bad := parse_stl(transmute([]u8)broken)
	testing.expect(t, !bad)
}

@(test)
obj_parse :: proc(t: ^testing.T) {
	src := "# cube corner\nv 0 0 0\nv 1 0 0\nv 0 1 0\nv 0 0 1\nf 1 2 3\nf 1/1 2/2/2 4//3\nf -1 -2 -3\n"
	tris, ok := parse_obj(transmute([]u8)src)
	defer delete(tris)
	testing.expect(t, ok)
	testing.expect_value(t, len(tris), 27) // 3 faces, fan of 1 tri each

	// Out-of-range index must fail.
	_, bad := parse_obj(transmute([]u8)string("v 0 0 0\nf 1 2 3\n"))
	testing.expect(t, !bad)
}
