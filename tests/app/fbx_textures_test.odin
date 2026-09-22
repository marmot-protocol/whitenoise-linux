package main

import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import rl "sdlrl"
import stbi "vendor:stb/image"

@(test)
fbx_archive_textures :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	// Handwritten triangle FBX, Windows relative texture path, 2x2 RGBA TGA.
	data := #load("fbx_textures.zip", []u8)
	owned := make([]u8, len(data))
	copy(owned, data)
	archive := arc_view_make(owned)
	testing.expect(t, archive != nil)
	if archive == nil {delete(owned); return}
	defer arc_view_free(archive)
	bytes, ok := arc_entry_bytes(archive, archive.entries[0].index)
	testing.expect(t, ok)
	if !ok {return}
	preview_show(archive.entries[0].name, bytes, archive)
	defer preview_close()
	testing.expect_value(t, preview.kind, Preview_Kind.Mesh)
	if preview.mesh == nil {return}
	insp := &preview.mesh.insp
	testing.expect_value(t, len(insp.images), 1) // two channels share one decode
	testing.expect_value(t, len(insp.textures), 1)
	if len(insp.images) == 0 {return}
	texture := &insp.textures[0][.Base_Color]
	testing.expect(t, texture.image.data == insp.textures[0][.Specular].image.data)
	testing.expect_value(t, fbx_sample_texture(texture, {0.25, 0.75}), [4]f32{1, 0, 0, 1})
	testing.expect_value(t, fbx_sample_texture(texture, {0.25, 0.25}), [4]f32{0, 0, 1, 1})
	testing.expect_value(t, fbx_sample_texture(texture, {1.25, -0.25}), [4]f32{1, 0, 0, 1})
	testing.expect_value(t, fbx_sample_texture(texture, {0.75, 0.25}), [4]f32{1, 1, 1, 0})

	// Missing references keep the model preview, without attempting local files.
	delete(archive.entries[1].name)
	archive.entries[1].name = strings.clone("elsewhere/unrelated.tga")
	missing, _ := arc_entry_bytes(archive, archive.entries[0].index)
	preview_show(archive.entries[0].name, missing, archive)
	testing.expect_value(t, preview.kind, Preview_Kind.Mesh)
	testing.expect_value(t, len(preview.mesh.insp.images), 0)

	// An exporter that omitted texture links can still identify a material
	// with a unique Material_Channel filename, as in the house ZIP.
	no_links, _ := strings.replace_all(string(preview.bytes), `C: "OP",4,3,"DiffuseColor"`, "")
	defer delete(no_links)
	no_links2, _ := strings.replace_all(no_links, `C: "OP",4,3,"SpecularColor"`, "")
	delete(archive.entries[1].name)
	archive.entries[1].name = strings.clone("Texture/House_Default_AlbedoTransparency.tga")
	preview_show(archive.entries[0].name, transmute([]u8)no_links2, archive)
	testing.expect_value(t, len(preview.mesh.insp.images), 1)

	// Two files matching the same material/channel must leave it untextured.
	delete(archive.entries[0].name)
	archive.entries[0].name = strings.clone("Texture/Other_Default_Albedo.tga")
	copy_fbx := strings.clone(string(preview.bytes))
	preview_show("Models/Triangle.fbx", transmute([]u8)copy_fbx, archive)
	testing.expect_value(t, len(preview.mesh.insp.images), 0)
}

@(test)
fbx_texture_paths :: proc(t: ^testing.T) {
	paths := make(map[string]int)
	paths["models/tex/color.png"], paths["tex/color.png"] = 1, 2
	defer delete(paths)
	basenames := make(map[string]int)
	basenames["color.png"], basenames["unique.png"] = -1, 3
	defer delete(basenames)
	cases := []struct {
		model, reference: string,
		want:             int,
	} {
		{"Models/House.FBX", ".\\tex\\COLOR.png", 1},
		{"Models/House.FBX", "../tex/color.png", 2},
		{"Models/House.FBX", "C:\\author\\unique.png", 3},
		{"Models/House.FBX", "/author/color.png", -1},
		{"House.fbx", "../../missing.png", -1},
	}
	for tc in cases {
		testing.expect_value(
			t,
			fbx_find_texture(paths, basenames, tc.model, tc.reference),
			tc.want,
		)
	}
}

@(test)
fbx_texture_render :: proc(t: ^testing.T) {
	if #config(ODIN_TEST_NAMES, "") != "fbx_texture_render" {return}
	rl.InitWindow(512, 512, "FBX texture regression")
	defer rl.CloseWindow()
	UI_SCALE, UI_ZOOM = 1, 1
	data := #load("fbx_textures.zip", []u8)
	owned := make([]u8, len(data))
	copy(owned, data)
	path := os.get_env("WN_FBX_ZIP", context.temp_allocator)
	if path != "" {
		delete(owned)
		err: os.Error
		owned, err = os.read_entire_file(path, context.allocator)
		testing.expect(t, err == nil)
		if err != nil {return}
	}
	archive := arc_view_make(owned)
	testing.expect(t, archive != nil)
	if archive == nil {delete(owned); return}
	defer arc_view_free(archive)
	entry := -1
	for e, i in archive.entries {
		if strings.has_suffix(
			strings.to_lower(e.name, context.temp_allocator),
			".fbx",
		) {entry = i; break}
	}
	testing.expect(t, entry >= 0)
	if entry < 0 {return}
	bytes, ok := arc_entry_bytes(archive, archive.entries[entry].index)
	testing.expect(t, ok)
	if !ok {return}
	preview_show(archive.entries[entry].name, bytes, archive)
	defer preview_close()
	view := preview.mesh
	testing.expect(t, view != nil)
	if view == nil {return}
	testing.expect(t, len(view.insp.images) > 0)
	view.yaw, view.pitch, view.dirty = 0, 0, true
	stl_draw(view, {0, 0, 512, 512})
	colored := 0
	primaries: [3]int
	for i := 0; i < len(view.pix); i += 4 {
		if view.pix[i + 3] > 0 && view.pix[i] != view.pix[i + 2] {colored += 1}
		for k in 0 ..< 3 {
			if view.pix[i + k] > 200 &&
			   view.pix[i + (k + 1) % 3] == 0 &&
			   view.pix[i + (k + 2) % 3] == 0 {
				primaries[k] += 1
			}
		}
	}
	testing.expect(t, colored > 100)
	if path == "" {
		for count in primaries {testing.expect(t, count > 100)}
	}
	stbi.write_png("/tmp/wn-fbx-textures.png", 512, 512, 4, raw_data(view.pix), 512 * 4)
	full := hash.crc32(view.pix)
	orbit_drag, orbit_moved = &view.orbit, true
	defer {orbit_drag, orbit_moved = nil, false}
	stl_draw(view, {0, 0, 512, 512})
	testing.expect_value(t, view.rw, i32(ORBIT_RASTER_SIZE))
	orbit_drag = nil
	stl_draw(view, {0, 0, 512, 512})
	testing.expect_value(t, view.rw, i32(512))
	testing.expect_value(t, hash.crc32(view.pix), full)
	if path != "" {
		for pass in 0 ..< 2 {
			orbit_drag = pass == 0 ? nil : &view.orbit
			view.yaw = 0
			samples: [21]f64
			for &sample in samples {
				view.yaw += 0.03
				view.dirty = true
				start := time.tick_now()
				stl_draw(view, {0, 0, 512, 512})
				sample = time.duration_milliseconds(time.tick_since(start))
			}
			slice.sort(samples[:])
			fmt.printfln(
				"FBX orbit: %d triangles, %d images, %dpx, median %.2f ms",
				len(view.tris) / 9,
				len(view.insp.images),
				view.rw,
				samples[len(samples) / 2],
			)
		}
	}
}
