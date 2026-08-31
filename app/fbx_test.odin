// FBX checks across the C boundary: the shim's arrays have to line up
// with what the viewer indexes, and posing has to actually move
// vertices. Run: ODIN_ROOT=build/odin-root odin test app
//
// The fixtures are ufbx's own test data, which build.sh clones (and
// .gitignore keeps out of the tree), so each test skips when the
// vendor dir isn't there rather than failing a fresh checkout.
package main

import "core:fmt"
import "core:os"
import "core:testing"

// Run from the repo root or from app/, so try both.
@(private = "file")
FIXTURE_DIRS := []string{"vendor/ufbx/data/", "../vendor/ufbx/data/"}

@(private = "file")
load_fixture :: proc(t: ^testing.T, name: string) -> ([]u8, bool) {
	for dir in FIXTURE_DIRS {
		path := fmt.tprintf("%s%s", dir, name)
		if data, err := os.read_entire_file(path, context.allocator); err == nil {
			return data, true
		}
	}
	fmt.eprintfln("skipped %s: vendor/ufbx not cloned", name)
	return nil, false
}

@(test)
fbx_parse_binary :: proc(t: ^testing.T) {
	data, ok := load_fixture(t, "blender_279_default_7400_binary.fbx")
	if !ok {
		return
	}
	defer delete(data)

	view, parsed := parse_fbx(data)
	testing.expect(t, parsed)
	if !parsed {
		return
	}
	defer stl_view_free(view)

	testing.expect(t, len(view.tris) >= 9)
	testing.expect(t, len(view.tris) % 9 == 0)
	// Normalized into the unit sphere, like every other mesh format.
	for v in view.tris {
		testing.expect(t, abs(v) <= 1.001)
	}
	// Per-vertex normals ride along, one per triangle corner.
	testing.expect_value(t, len(view.insp.vnrm), len(view.tris))
}

// The 6100 ASCII flavor takes a different path through ufbx; a viewer
// that only opened binary files would miss half the exports in the
// wild.
@(test)
fbx_parse_ascii :: proc(t: ^testing.T) {
	data, ok := load_fixture(t, "blender_279_default_6100_ascii.fbx")
	if !ok {
		return
	}
	defer delete(data)

	view, parsed := parse_fbx(data)
	testing.expect(t, parsed)
	if !parsed {
		return
	}
	defer stl_view_free(view)
	testing.expect(t, len(view.tris) >= 9)
}

// Skin weights index the global cluster table; an off-by-one here
// would paint the Bones view from out-of-bounds memory.
@(test)
fbx_skin_channels :: proc(t: ^testing.T) {
	data, ok := load_fixture(t, "blender_293_half_skinned_7400_binary.fbx")
	if !ok {
		return
	}
	defer delete(data)

	view, parsed := parse_fbx(data)
	testing.expect(t, parsed)
	if !parsed {
		return
	}
	defer stl_view_free(view)

	insp := &view.insp
	testing.expect(t, insp.bone != nil)
	testing.expect(t, insp.nbones > 0)
	testing.expect_value(t, len(insp.bone), len(view.tris) / 3)
	for bone, i in insp.bone {
		testing.expect(t, int(bone) < insp.nbones)
		testing.expect(t, insp.bwt[i] >= 0 && insp.bwt[i] <= 1.001)
	}
	testing.expect(t, mode_ready(view, .Bones))
}

// Posing has to reach the vertices: same take, two times, different
// geometry, and nothing non-finite from the matrix blend.
@(test)
fbx_animation_moves :: proc(t: ^testing.T) {
	data, ok := load_fixture(t, "max2009_cube_anim_6100_binary.fbx")
	if !ok {
		return
	}
	defer delete(data)

	view, parsed := parse_fbx(data)
	testing.expect(t, parsed)
	if !parsed {
		return
	}
	defer stl_view_free(view)

	insp := &view.insp
	testing.expect(t, len(insp.takes) > 0)
	if len(insp.takes) == 0 {
		return
	}
	testing.expect(t, insp.anim == 0) // opens on the first take
	testing.expect(t, insp.t1 > insp.t0)

	fbx_pose(view, insp.t0)
	start := make([]f32, len(view.tris))
	defer delete(start)
	copy(start, view.tris)

	fbx_pose(view, (insp.t0 + insp.t1) / 2)
	moved := false
	for v, i in view.tris {
		testing.expect(t, v == v) // NaN would poison the bucket sort
		testing.expect(t, abs(v) < 1000)
		if abs(v - start[i]) > 0.0001 {
			moved = true
		}
	}
	testing.expect(t, moved)
}

// Hostile input must fail, not crash or allocate: the shim owns a lot
// of memory behind one pointer.
@(test)
fbx_rejects_garbage :: proc(t: ^testing.T) {
	junk := make([]u8, 4096)
	defer delete(junk)
	for i in 0 ..< len(junk) {
		junk[i] = u8(i * 7)
	}
	_, ok := parse_fbx(junk)
	testing.expect(t, !ok)

	_, empty := parse_fbx(nil)
	testing.expect(t, !empty)
}

// An STL view has no inspector channels, so every FBX-only mode must
// report unavailable instead of indexing a nil slice.
@(test)
fbx_modes_gated :: proc(t: ^testing.T) {
	tris := make([]f32, 9)
	tris[3], tris[7] = 1, 1
	view := stl_view_make(tris)
	defer stl_view_free(view)

	testing.expect(t, mode_ready(view, .Final))
	testing.expect(t, mode_ready(view, .Matcap))
	testing.expect(t, !mode_ready(view, .Bones))
	testing.expect(t, !mode_ready(view, .Uv_Checker))
	testing.expect(t, !mode_ready(view, .Base_Color))

	// The color path still has to answer for a static mesh.
	view.insp.mode = .Matcap
	colors := model_vert_colors(view, 0)
	for c in colors {
		testing.expect(t, c.a == 1)
	}
}
