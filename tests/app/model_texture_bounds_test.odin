package main

import "core:slice"
import "core:sync"
import "core:testing"

// Exercise the renderer's textured dispatch, not just the color helper.
@(test)
model_texture_missing_material_raster :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	old_scale, old_zoom := UI_SCALE, UI_ZOOM
	UI_SCALE, UI_ZOOM = 1, 1
	defer {UI_SCALE, UI_ZOOM = old_scale, old_zoom}

	positions := [18]f32{-0.8, -0.8, 0, 0, -0.8, 0, -0.4, 0.8, 0, 0, -0.8, 0, 0.8, -0.8, 0, 0.4, 0.8, 0}
	rotated: [18]f32
	normals := [6]f32{0, 0, 1, 0, 0, 1}
	uvs: [12]f32
	materials := [2]i32{-1, -1}
	view := Stl_View{tris = positions[:], rot = rotated[:], norms = normals[:], orbit = {zoom = 1}}
	view.insp.uv = uvs[:]
	// The presence of an image routes every visible triangle through
	// model_texture_color even when its material assignment is missing.
	resize(&view.insp.images, 1)
	defer delete(view.insp.images)
	defer delete(view.pix)
	defer delete(view.zbuf)

	// First capture the ordinary no-texture fallback for both triangles.
	resize(&view.insp.images, 0)
	stl_draw(&view, {0, 0, 64, 64})
	expected := slice.clone(view.pix)
	defer delete(expected)
	drawn := 0
	for i := 3; i < len(expected); i += 4 {
		if expected[i] != 0 {drawn += 1}
	}
	testing.expect(t, drawn > 100)

	resize(&view.insp.images, 1)
	for count in 0 ..= 2 {
		view.insp.mat = count == 0 ? nil : materials[:count]
		view.built = {}
		stl_draw(&view, {0, 0, 64, 64})
		testing.expect(t, view.refined)
		testing.expect(t, slice.equal(view.pix, expected))
	}
}
