// Only bounded flat mesh data enters the UI; source parsing lives in wn-mesh.
package main

import "core:c"
import "core:c/libc"
import "core:encoding/endian"
import "core:math"
import "core:strings"
import rl "sdlrl"

foreign import mesh_decoder {WN_BUILD_DIR + "/libwndecoder.a"}
@(private, default_calling_convention = "c")
foreign mesh_decoder {
	wn_mesh_decode :: proc(helper: cstring, data: [^]u8, size: c.int, format: c.uint, length: ^c.uint) -> [^]u8 ---
}

@(private)
Mesh_Reply :: struct {
	ntri, nmat, nimages:                         int,
	tris, vnrm, uv, mat, mats, textures, images: []u8,
}
@(private)
mesh_word :: proc(bytes: []u8, at: int = 0) -> u32 {
	v, _ := endian.get_u32(bytes[at:at + 4], .Little)
	return v
}
@(private)
mesh_float :: proc(bytes: []u8, at: int = 0) -> f32 {
	return transmute(f32)mesh_word(bytes, at)
}

// Validate every count, channel, enum and reference before constructing any view.
// Descriptor slices borrow the transport buffer, and never escape the operation.
@(private)
mesh_validate :: proc(payload: []u8, format: u32) -> (out: Mesh_Reply, ok: bool) {
	if len(payload) < 24 ||
	   len(payload) > 512 * 1024 * 1024 ||
	   mesh_word(payload) != 1 ||
	   mesh_word(payload, 20) != 0 {return {}, false}
	ntri, flags := int(mesh_word(payload, 4)), mesh_word(payload, 8)
	nmat, nimages := int(mesh_word(payload, 12)), int(mesh_word(payload, 16))
	if ntri == 0 ||
	   ntri > STL_MAX_TRIS ||
	   flags & ~u32(15) != 0 ||
	   nmat > 65536 ||
	   nimages > 4096 {return {}, false}
	if format < 1 || format > 4 {return {}, false}
	if format != 3 &&
	   (flags != (format == 4 ? 8 : 0) || nmat != 0 || nimages != 0) {return {}, false}
	if format == 3 && flags & 8 != 0 {return {}, false}
	if format == 3 && flags & 5 != 5 {return {}, false}
	out.ntri, out.nmat, out.nimages = ntri, nmat, nimages
	at := 24
	take :: proc(bytes: []u8, at: ^int, size: int) -> ([]u8, bool) {
		if size > len(bytes) - at^ {return nil, false}
		part := bytes[at^:at^ + size]
		at^ += size
		return part, true
	}
	out.tris, ok = take(payload, &at, ntri * (format == 4 ? 6 : 9) * 4)
	if !ok {return {}, false}
	if flags & 1 != 0 {out.vnrm, ok = take(payload, &at, ntri * 9 * 4); if !ok {return {}, false}}
	if flags & 2 != 0 {out.uv, ok = take(payload, &at, ntri * 6 * 4); if !ok {return {}, false}}
	if flags & 4 != 0 {out.mat, ok = take(payload, &at, ntri * 4); if !ok {return {}, false}}
	out.mats, ok = take(payload, &at, nmat * FBX_MAT_FLOATS * 4)
	if !ok {return {}, false}
	out.textures, ok = take(payload, &at, nmat * 6 * 64)
	if !ok {return {}, false}
	for channel, index in ([4][]u8{out.tris, out.vnrm, out.uv, out.mats}) {
		for offset := 0; offset < len(channel); offset += 4 {
			v := mesh_float(channel, offset)
			if math.is_nan(v) || math.is_inf(v) || (index < 2 && abs(v) > 1.001) {return {}, false}
		}
	}
	for offset := 0; offset < len(out.mat); offset += 4 {
		index := transmute(i32)mesh_word(out.mat, offset)
		if index < -1 || index >= i32(nmat) {return {}, false}
	}
	for offset := 0; offset < len(out.textures); offset += 64 {
		t := out.textures[offset:offset + 64]
		if mesh_word(t) > u32(nimages) ||
		   mesh_word(t, 4) > 2 ||
		   mesh_word(t, 8) > 2 ||
		   mesh_word(t, 12) > 3 ||
		   mesh_word(t, 16) > 2 {return {}, false}
		for k := 20; k < 64; k += 4 {
			v := mesh_float(t, k)
			if math.is_nan(v) || math.is_inf(v) {return {}, false}
		}
	}
	out.images = payload[at:]
	encoded := 0
	for _ in 0 ..< nimages {
		if len(payload) - at < 4 {return {}, false}
		size := int(mesh_word(payload, at))
		at += 4
		if size == 0 ||
		   size > FBX_TEXTURE_BYTES - encoded ||
		   size > len(payload) - at {return {}, false}
		image := payload[at:at + size]
		png := size >= 8 && string(image[:8]) == "\x89PNG\r\n\x1a\n"
		jpeg := size >= 3 && image[0] == 0xff && image[1] == 0xd8 && image[2] == 0xff
		if !png && !jpeg {return {}, false}
		at += size
		encoded += size
	}
	return out, at == len(payload)
}

@(private)
mesh_request :: proc(data: []u8, format: u32) -> []u8 {
	if len(data) == 0 || len(data) > 128 * 1024 * 1024 {return nil}
	helper := strings.clone_to_cstring(helper_path("wn-mesh"))
	defer delete(helper)
	length: c.uint
	bytes := wn_mesh_decode(helper, raw_data(data), c.int(len(data)), c.uint(format), &length)
	if bytes == nil {return nil}
	return bytes[:int(length)]
}
@(private)
mesh_copy_floats :: proc(bytes: []u8) -> []f32 {
	if len(bytes) == 0 {return nil}
	out := make([]f32, len(bytes) / 4)
	for &value, i in out {value = mesh_float(bytes, i * 4)}
	return out
}
@(private)
mesh_parse_points :: proc(data: []u8, format: u32) -> ([]f32, bool) {
	payload := mesh_request(data, format)
	if payload == nil {return nil, false}
	defer libc.free(raw_data(payload))
	reply, ok := mesh_validate(payload, format)
	if !ok {return nil, false}
	return mesh_copy_floats(reply.tris), true
}
parse_stl :: proc(data: []u8) -> ([]f32, bool) {return mesh_parse_points(data, 1)}
parse_obj :: proc(data: []u8) -> ([]f32, bool) {return mesh_parse_points(data, 2)}

parse_glb :: proc(data: []u8) -> (^Stl_View, bool) {
	payload := mesh_request(data, 3)
	if payload == nil {return nil, false}
	defer libc.free(raw_data(payload))
	reply, ok := mesh_validate(payload, 3)
	if !ok {return nil, false}
	view := stl_view_make(mesh_copy_floats(reply.tris))
	insp := &view.insp
	insp.vnrm, insp.uv, insp.mats =
		mesh_copy_floats(reply.vnrm), mesh_copy_floats(reply.uv), mesh_copy_floats(reply.mats)
	insp.mat = make([]i32, reply.ntri)
	for &index, i in insp.mat {index = transmute(i32)mesh_word(reply.mat, i * 4)}
	// Missing glTF normals use the same normalized face normals as before.
	for i in 0 ..< reply.ntri {
		for k in 0 ..< 3 {
			at := i * 9 + k * 3
			if insp.vnrm[at] == 0 && insp.vnrm[at + 1] == 0 && insp.vnrm[at + 2] == 0 {
				copy(insp.vnrm[at:at + 3], view.norms[i * 3:i * 3 + 3])
			}
		}
	}
	images := make([]rl.Image, reply.nimages)
	defer delete(images)
	at, decoded := 0, 0
	for &image in images {
		size := int(mesh_word(reply.images, at))
		at += 4
		if decoded < FBX_TEXTURE_BYTES {
			image = rl.LoadImageFromMemory(
				"",
				raw_data(reply.images[at:at + size]),
				i32(size),
				max_bytes = u32(FBX_TEXTURE_BYTES - decoded),
			)
			if image.data != nil {
				decoded += int(image.width) * int(image.height) * 4
				append(&insp.images, image)
			}
		}
		at += size
	}
	insp.textures = make([][Fbx_Channel]Fbx_Texture, reply.nmat)
	at = 0
	for &material in insp.textures {
		for &texture in material {
			record := reply.textures[at:at + 64]
			index := int(mesh_word(record))
			if index > 0 {texture.image = images[index - 1]; texture.reference = 1}
			texture.info.clamp_u, texture.info.clamp_v =
				i32(mesh_word(record, 4)), i32(mesh_word(record, 8))
			texture.pixels = type_of(texture.pixels)(mesh_word(record, 12))
			texture.alpha = type_of(texture.alpha)(mesh_word(record, 16))
			for &value, i in texture.info.uv {value = mesh_float(record, 20 + i * 4)}
			for &value, i in texture.info.tint {value = mesh_float(record, 44 + i * 4)}
			texture.alpha_cutoff = mesh_float(record, 60)
			at += 64
		}
	}
	return view, true
}
