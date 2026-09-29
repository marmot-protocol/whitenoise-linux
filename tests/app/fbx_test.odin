// FBX behavior across the persistent helper boundary: channels are parent-owned
// and posing must actually move vertices. Run: tests/odin.sh app
//
// The fixtures are ufbx's own test data, which scripts/build.sh clones (and
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

// Hostile source data must fail without publishing a view.
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

// A complete skin/material record exercises offsets even after variable strings.
@(private = "file")
fbx_test_metadata :: proc() -> []u8 {
	data := make([]u8, 554)
	copy(data[:4], "FBM1")
	fbx_put_u32(data[4:], 1) // triangle
	fbx_put_u32(data[8:], 1) // bone
	fbx_put_u32(data[16:], 1) // material
	fbx_put_u32(data[20:], 3) // UV and skin
	fbx_put_u32(data[44:], transmute(u32)f32(1))
	fbx_put_u32(data[60:], transmute(u32)f32(1))
	fbx_put_u32(data[204:], 3)
	copy(data[208:211], "mat")
	fbx_put_u32(data[211:], 1) // explicit first texture
	fbx_put_u32(data[263:], 7)
	copy(data[267:274], "tex.png")
	return data
}

@(test)
fbx_metadata_ownership :: proc(t: ^testing.T) {
	data := fbx_test_metadata()
	defer delete(data)
	view, ok := fbx_decode_metadata(data)
	testing.expect(t, ok)
	if !ok {return}
	defer stl_view_free(view)
	for &byte in data {byte = 0}
	testing.expect_value(t, view.tris[3], f32(1))
	testing.expect_value(t, view.insp.material_names[0], "mat")
	testing.expect_value(t, view.insp.textures[0][.Base_Color].info.path, "tex.png")
	testing.expect_value(t, view.insp.bone[0], i32(0))
	testing.expect_value(t, view.insp.mat[0], i32(0))
}

@(test)
fbx_rejects_hostile_metadata :: proc(t: ^testing.T) {
	for mutation in ([]struct {
			offset: int,
			bits:   u32,
		} {
			{4, 2_000_001}, // allocation bound
			{20, 4}, // unknown flags
			{24, 1}, // reserved field
			{32, 0x7f800000}, // nonfinite position
			{104, 0x7fc00000}, // nonfinite UV
			{128, 1}, // bone outside table
			{140, 0x7fc00000}, // nonfinite skin weight
			{152, 1}, // material outside table
			{156, 0xff800000}, // nonfinite material channel
			{204, 4097}, // oversized name
			{211, 2}, // unsupported texture reference enum
			{215, 2}, // unsupported FBX wrapping
			{223, 0x7fc00000}, // nonfinite texture transform
			{263, 0}, // explicit reference cannot be empty
		}) {
		data := fbx_test_metadata()
		fbx_put_u32(data[mutation.offset:], mutation.bits)
		view, ok := fbx_decode_metadata(data)
		testing.expect(t, !ok)
		if ok {stl_view_free(view)}
		delete(data)
	}
	data := fbx_test_metadata()
	defer delete(data)
	for size in 0 ..< len(data) {
		view, ok := fbx_decode_metadata(data[:size])
		testing.expect(t, !ok)
		if ok {stl_view_free(view)}
	}
	data[208] = 0xff
	_, invalid_utf8 := fbx_decode_metadata(data)
	testing.expect(t, !invalid_utf8)
	data[208] = 0
	_, embedded_nul := fbx_decode_metadata(data)
	testing.expect(t, !embedded_nul)
}

@(test)
fbx_pose_atomic_publication :: proc(t: ^testing.T) {
	data := fbx_test_metadata()
	defer delete(data)
	view, ok := fbx_decode_metadata(data)
	testing.expect(t, ok)
	if !ok {return}
	defer stl_view_free(view)
	pose: [80]u8
	copy(pose[:4], "FBP1")
	fbx_put_u32(pose[4:], 1)
	fbx_put_u32(pose[8:], transmute(u32)f32(0.5))
	fbx_put_u32(pose[76:], 0x7fc00000)
	testing.expect(t, !fbx_apply_pose(view, pose[:]))
	testing.expect_value(t, view.tris[0], f32(0))
	testing.expect_value(t, view.tris[3], f32(1))
	testing.expect_value(t, view.insp.vnrm[8], f32(0))
	fbx_put_u32(pose[76:], transmute(u32)f32(1))
	testing.expect(t, fbx_apply_pose(view, pose[:]))
	testing.expect_value(t, view.tris[0], f32(0.5))
	testing.expect_value(t, view.insp.vnrm[8], f32(1))
	testing.expect(t, !fbx_apply_pose(view, pose[:79]))
	fbx_put_u32(pose[4:], 2)
	testing.expect(t, !fbx_apply_pose(view, pose[:]))
}
