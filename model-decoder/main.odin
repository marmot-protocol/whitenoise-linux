package main

import "core:c"
import "core:encoding/endian"
import "core:mem"

WN_TARGET :: #config(WN_TARGET, "")
WN_BUILD_DIR :: "../build" when WN_TARGET == "" else "../build/cross/" + WN_TARGET
foreign import bootstrap {WN_BUILD_DIR + "/libwnmesh.a"}
@(default_calling_convention = "c")
foreign bootstrap {
	wn_mesh_bootstrap :: proc() -> c.int ---
	wn_mesh_input :: proc(bytes: rawptr, length: c.size_t) -> c.int ---
	wn_mesh_input_end :: proc() -> c.int ---
	wn_mesh_output :: proc(bytes: rawptr, length: c.size_t) -> c.int ---
	wn_mesh_finish :: proc(success: c.int) ---
}

MESH_MAX_OUTPUT :: 512 * 1024 * 1024
mesh_payload :: proc(mesh: ^Mesh) -> []u8 {
	ntri, nmat := len(mesh.tris) / 9, len(mesh.mats) / FBX_MAT_FLOATS
	flags: u32
	if len(mesh.vnrm) > 0 {flags |= 1}
	if len(mesh.uv) > 0 {flags |= 2}
	if len(mesh.mat) > 0 {flags |= 4}
	if len(mesh.segments) > 0 {
		ntri = len(mesh.segments) / 6
		flags = 8
	}
	size :=
		24 +
		(len(mesh.tris) +
				len(mesh.segments) +
				len(mesh.vnrm) +
				len(mesh.uv) +
				len(mesh.mat) +
				len(mesh.mats)) *
			4 +
		nmat * 6 * 64
	for image in mesh.images {
		if len(image) > MESH_MAX_OUTPUT - size - 4 {return nil}
		size += 4 + len(image)
	}
	if size > MESH_MAX_OUTPUT {return nil}
	out := make([]u8, size)
	at := 0
	put :: proc(out: []u8, at: ^int, value: u32) {
		endian.put_u32(out[at^:at^ + 4], .Little, value)
		at^ += 4
	}
	for value in ([6]u32{1, u32(ntri), flags, u32(nmat), u32(len(mesh.images)), 0}) {put(out, &at, value)}
	for channel in ([4][]f32{mesh.tris, mesh.segments, mesh.vnrm, mesh.uv}) {
		for v in channel {
			if !glb_finite(f64(v)) {delete(out); return nil}
			put(out, &at, transmute(u32)v)
		}
	}
	for v in mesh.mat {put(out, &at, transmute(u32)v)}
	for v in mesh.mats {put(out, &at, transmute(u32)v)}
	for material in mesh.textures {
		for texture in material {
			for value in ([5]u32{u32(texture.image), u32(texture.clamp_u), u32(texture.clamp_v), u32(texture.pixels), u32(texture.alpha)}) {put(out, &at, value)}
			for v in texture.uv {put(out, &at, transmute(u32)v)}
			for v in texture.tint {put(out, &at, transmute(u32)v)}
			put(out, &at, transmute(u32)texture.alpha_cutoff)
		}
	}
	for image in mesh.images {
		put(out, &at, u32(len(image)))
		copy(out[at:], image)
		at += len(image)
	}
	return out
}

main :: proc() {
	if wn_mesh_bootstrap() == 0 {wn_mesh_finish(0); return}
	header: [16]u8
	if wn_mesh_input(raw_data(header[:]), 16) == 0 ||
	   string(header[:4]) != "MDI1" {wn_mesh_finish(0); return}
	size, format, reserved := glb_u32(header[:], 4), glb_u32(header[:], 8), glb_u32(header[:], 12)
	if size == 0 ||
	   size > 128 * 1024 * 1024 ||
	   format < 1 ||
	   format > 4 ||
	   reserved != 0 {wn_mesh_finish(0); return}
	input := make([]u8, int(size))
	if wn_mesh_input(raw_data(input), c.size_t(size)) == 0 ||
	   wn_mesh_input_end() == 0 {wn_mesh_finish(0); return}
	mesh: ^Mesh
	ok: bool
	if format == 3 {
		mesh, ok = parse_glb(input)
	} else if format == 4 {
		segments: []f32
		segments, ok = parse_gcode(input)
		if ok {mesh = new(Mesh); mesh.segments = segments}
	} else {
		tris: []f32
		if format == 1 {tris, ok = parse_stl(input)} else {tris, ok = parse_obj(input)}
		if ok {mesh = new(Mesh); mesh.tris = tris}
	}
	delete(input)
	if !ok {wn_mesh_finish(0); return}
	payload := mesh_payload(mesh)
	mesh_free(mesh)
	if len(payload) == 0 {wn_mesh_finish(0); return}
	reply := [4]u32le{0x314f444d, 1, 0, u32le(len(payload))}
	if wn_mesh_output(raw_data(mem.slice_to_bytes(reply[:])), 16) == 0 ||
	   wn_mesh_output(raw_data(payload), c.size_t(len(payload))) == 0 {wn_mesh_finish(0); return}
	delete(payload)
	wn_mesh_finish(1)
}
