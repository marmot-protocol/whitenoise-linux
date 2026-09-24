package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"

@(private)
GLB_TEST_JSON :: `{
  "asset":{"version":"2.0"},
  "buffers":[{"byteLength":60}],
  "bufferViews":[{"buffer":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":12}],
  "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},{"bufferView":1,"componentType":5123,"count":6,"type":"SCALAR"}],
  "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
  "nodes":[{"children":[1],"translation":[10,0,0]},{"mesh":0,"scale":[-2,1,1]},{"mesh":0,"translation":[100,0,0]}],
  "scenes":[{"nodes":[0]},{"nodes":[2]}],"scene":0
}`

@(private)
glb_test_bytes :: proc(doc: string, bin: []u8) -> []u8 {
	json_size := (len(doc) + 3) & ~int(3)
	bin_size := (len(bin) + 3) & ~int(3)
	bytes := make([]u8, 28 + json_size + bin_size)
	header := [5]u32le{0x46546c67, 2, u32le(len(bytes)), u32le(json_size), 0x4e4f534a}
	copy(bytes, mem.slice_to_bytes(header[:]))
	for &b in bytes[20:20 + json_size] {b = ' '}
	copy(bytes[20:], transmute([]u8)doc)
	chunk := [2]u32le{u32le(bin_size), 0x004e4942}
	copy(bytes[20 + json_size:], mem.slice_to_bytes(chunk[:]))
	copy(bytes[28 + json_size:], bin)
	return bytes
}

@(private)
glb_test_quad :: proc(doc: string = GLB_TEST_JSON) -> []u8 {
	positions := [12]f32le{0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0}
	indices := [6]u16le{0, 1, 2, 2, 1, 3}
	bin: [60]u8
	copy(bin[:], mem.slice_to_bytes(positions[:]))
	copy(bin[48:], mem.slice_to_bytes(indices[:]))
	return glb_test_bytes(doc, bin[:])
}

@(test)
glb_scene_instances :: proc(t: ^testing.T) {
	bytes := glb_test_quad()
	defer delete(bytes)
	view := model_view_make("scene.glb", bytes)
	testing.expect(t, view != nil)
	if view == nil {return}
	defer stl_view_free(view)
	// Only the selected scene contributes geometry. Mirrored scale preserves
	// front-face winding, and normalization keeps the 2:1 aspect ratio.
	testing.expect_value(t, len(view.tris), 18)
	x, y := f32(2 / math.sqrt(5.0)), f32(1 / math.sqrt(5.0))
	expected := [18]f32{x, -y, 0, x, y, 0, -x, -y, 0, x, y, 0, -x, y, 0, -x, -y, 0}
	for value, i in view.tris {testing.expect(t, abs(value - expected[i]) < 0.00001)}
	for i in 0 ..< 2 {testing.expect(t, view.norms[i * 3 + 2] > 0.999)}
}

@(test)
glb_triangle_modes :: proc(t: ^testing.T) {
	positions := [12]f32le{0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0}
	for mode in ([]int{5, 6}) {
		doc, _ := strings.replace_all(
			`{"asset":{"version":"2.0"},"buffers":[{"byteLength":48}],"bufferViews":[{"buffer":0,"byteLength":48}],"accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"}],"meshes":[{"primitives":[{"attributes":{"POSITION":0},"mode":%d}]}],"nodes":[{"mesh":0}],"scenes":[{"nodes":[0]}]}`,
			"%d",
			fmt.tprintf("%d", mode),
			context.temp_allocator,
		)
		bytes := glb_test_bytes(doc, mem.slice_to_bytes(positions[:]))
		view := model_view_make("quad.glb", bytes)
		delete(bytes)
		testing.expect(t, view != nil)
		if view == nil {continue}
		testing.expect_value(t, len(view.tris), 18)
		// A strip reverses alternate triangle indices; a fan shares vertex 0.
		if mode == 5 {
			testing.expect(t, view.norms[2] > 0.999 && view.norms[5] > 0.999)
		} else {
			for k in 0 ..< 3 {testing.expect_value(t, view.tris[k], view.tris[9 + k])}
		}
		stl_view_free(view)
	}
}

@(test)
glb_rejects_invalid :: proc(t: ^testing.T) {
	bytes := glb_test_quad()
	defer delete(bytes)
	for length in ([]int{0, 11, 20, len(bytes) - 1}) {
		view := model_view_make("bad.glb", bytes[:length])
		testing.expect(t, view == nil)
		if view != nil {stl_view_free(view)}
	}
	for change in ([][2]string{{`"byteLength":60`, `"byteLength":600`}, {`"byteOffset":48`, `"byteOffset":18446744073709551612`}, {`"count":4`, `"count":4294967295`}, {`"byteLength":60`, `"byteLength":60,"uri":"file:///etc/passwd"`}, {`"children":[1]`, `"children":[1,0]`}}) {
		doc, _ := strings.replace_all(GLB_TEST_JSON, change[0], change[1], context.temp_allocator)
		bad := glb_test_quad(doc)
		view := model_view_make("bad.glb", bad)
		delete(bad)
		testing.expect(t, view == nil, change[1])
		if view != nil {stl_view_free(view)}
	}
	// The index buffer is the final 12 bytes, with four addressable vertices.
	bytes[len(bytes) - 12] = 4
	view := model_view_make("bad.glb", bytes)
	testing.expect(t, view == nil)
	if view != nil {stl_view_free(view)}
}

@(test)
glb_sparse_interleaved :: proc(t: ^testing.T) {
	// Interleaved positions have padding; the sparse replacement is tightly packed.
	base := [12]f32le{0, 0, 0, 99, 1, 0, 0, 99, 0, 0, 0, 99}
	replacement := [3]f32le{0, 1, 0}
	bin: [64]u8
	copy(bin[:], mem.slice_to_bytes(base[:]))
	bin[48] = 2
	copy(bin[52:], mem.slice_to_bytes(replacement[:]))
	doc := `{"asset":{"version":"2.0"},"buffers":[{"byteLength":64}],"bufferViews":[{"buffer":0,"byteLength":48,"byteStride":16},{"buffer":0,"byteOffset":48,"byteLength":1},{"buffer":0,"byteOffset":52,"byteLength":12}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","sparse":{"count":1,"indices":{"bufferView":1,"componentType":5121},"values":{"bufferView":2}}}],"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],"nodes":[{"mesh":0}],"scenes":[{"nodes":[0]}]}`
	bytes := glb_test_bytes(doc, bin[:])
	defer delete(bytes)
	view := model_view_make("sparse.glb", bytes)
	testing.expect(t, view != nil)
	if view == nil {return}
	defer stl_view_free(view)
	testing.expect_value(t, len(view.tris), 9)
	testing.expect(t, view.norms[2] > 0.999)
	testing.expect(t, view.tris[7] > 0.7 && view.tris[1] < -0.7)
}

@(test)
glb_embedded_materials :: proc(t: ^testing.T) {
	bytes := #load("glb_textures.glb", []u8)
	view := model_view_make("textured.glb", bytes)
	testing.expect(t, view != nil)
	if view == nil {return}
	defer stl_view_free(view)
	insp := &view.insp
	testing.expect_value(t, len(insp.images), 1)
	testing.expect_value(t, len(insp.textures), 1)
	if len(insp.images) != 1 || len(insp.textures) != 1 {return}
	// glTF's top-origin UVs and normalized u16 components must survive
	// expansion. OPAQUE ignores the PNG's transparent red texel.
	testing.expect_value(t, insp.uv[0], f32(0))
	testing.expect_value(t, insp.uv[1], f32(0))
	base := &insp.textures[0][.Base_Color]
	testing.expect_value(t, fbx_sample_texture(base, {0.25, 0.75}), [4]f32{0.5, 0, 0, 1})
	testing.expect_value(t, fbx_sample_texture(base, {0.25, 0.25}), [4]f32{0, 0, 1, 1})
	testing.expect_value(t, fbx_sample_texture(base, {1.25, 0.75}), [4]f32{0, 1, 0, 1})
	testing.expect_value(
		t,
		fbx_sample_texture(&insp.textures[0][.Roughness], {0.75, 0.75}),
		[4]f32{0.75, 0.75, 0.75, 1},
	)
	testing.expect_value(
		t,
		fbx_sample_texture(&insp.textures[0][.Metalness], {0.25, 0.25}),
		[4]f32{0.25, 0.25, 0.25, 1},
	)
}

@(test)
glb_parent_transforms :: proc(t: ^testing.T) {
	doc, _ := strings.replace_all(
		GLB_TEST_JSON,
		`"nodes":[0]`,
		`"nodes":[0,2]`,
		context.temp_allocator,
	)
	bytes := glb_test_quad(doc)
	defer delete(bytes)
	view := model_view_make("instances.glb", bytes)
	testing.expect(t, view != nil)
	if view == nil {return}
	defer stl_view_free(view)
	testing.expect_value(t, len(view.tris), 36)
	// World bounds are x=[8,101], y=[0,1]. Parent translation must apply
	// before both instances are normalized into the same view.
	radius := f32(math.sqrt(93.0 * 93.0 + 1) / 2)
	found_parent, found_root := false, false
	for i in 0 ..< len(view.tris) / 3 {
		found_parent = found_parent || abs(view.tris[i * 3] - (10 - 54.5) / radius) < 0.00001
		found_root = found_root || abs(view.tris[i * 3] - (100 - 54.5) / radius) < 0.00001
	}
	testing.expect(t, found_parent && found_root)
}

@(test)
glb_material_opacity :: proc(t: ^testing.T) {
	for mode in ([]string{"OPAQUE", "MASK", "BLEND"}) {
		doc, _ := strings.replace_all(
			GLB_TEST_JSON,
			`"indices":1`,
			`"indices":1,"material":0`,
			context.temp_allocator,
		)
		doc, _ = strings.replace_all(
			doc,
			`"scene":0`,
			fmt.tprintf(
				"%s%s%s",
				`"scene":0,"materials":[{"alphaMode":"`,
				mode,
				`","pbrMetallicRoughness":{"baseColorFactor":[1,0,0,0.25]}}]`,
			),
			context.temp_allocator,
		)
		bytes := glb_test_quad(doc)
		view := model_view_make("opacity.glb", bytes)
		delete(bytes)
		testing.expect(t, view != nil)
		if view == nil {continue}
		color := model_vert_colors(view, 0)[0]
		want := mode == "OPAQUE" ? f32(1) : (mode == "MASK" ? f32(0) : f32(0.25))
		testing.expect_value(t, color.a, want)
		stl_view_free(view)
	}
}
