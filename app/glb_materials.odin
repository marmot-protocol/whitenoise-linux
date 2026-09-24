package main

import "core:c"
import "core:encoding/base64"
import "core:math"
import "core:strings"

import rl "sdlrl"
import cgltf "vendor:cgltf"
import stbi "vendor:stb/image"

// Material factors and decoded images outlive cgltf.data. Texture views borrow
// only the images recorded in insp.images, never the GLB's encoded bytes.
@(private)
glb_load_materials :: proc(data: ^cgltf.data, insp: ^Inspect) -> bool {
	if data == nil || insp == nil {return false}
	if len(data.materials) == 0 {return true}
	insp.mats = make([]f32, len(data.materials) * FBX_MAT_FLOATS)
	insp.textures = make([][Fbx_Channel]Fbx_Texture, len(data.materials))
	loaded := make(map[^cgltf.image]rl.Image)
	defer delete(loaded)
	decoded, encoded := 0, 0
	for &material, i in data.materials {
		pbr := &material.pbr_metallic_roughness
		base := pbr.base_color_factor
		emission := material.emissive_factor
		if material.has_emissive_strength {
			emission *= material.emissive_strength.emissive_strength
		}
		mat := insp.mats[i * FBX_MAT_FLOATS:(i + 1) * FBX_MAT_FLOATS]
		copy(
			mat,
			[]f32 {
				base[0],
				base[1],
				base[2],
				pbr.metallic_factor,
				pbr.roughness_factor,
				emission[0],
				emission[1],
				emission[2],
				0.04,
				0.04,
				0.04,
				base[3],
			},
		)
		for value in mat {
			if math.is_nan(value) || math.is_inf(value) {return false}
		}
		if math.is_nan(material.alpha_cutoff) || math.is_inf(material.alpha_cutoff) {
			return false
		}
		if material.alpha_mode == .opaque {
			mat[11] = 1
		} else if material.alpha_mode == .mask {
			mat[11] = base[3] >= material.alpha_cutoff ? 1 : 0
		}

		views := [3]^cgltf.texture_view {
			&pbr.base_color_texture,
			&pbr.metallic_roughness_texture,
			&material.emissive_texture,
		}
		for view in views {
			if view.texture == nil || !view.has_transform {continue}
			t := &view.transform
			for value in ([5]f32{t.offset[0], t.offset[1], t.rotation, t.scale[0], t.scale[1]}) {
				if math.is_nan(value) || math.is_inf(value) {return false}
			}
		}
		if insp.uv == nil {continue}
		textures := &insp.textures[i]
		textures[.Base_Color] = glb_material_texture(
			&pbr.base_color_texture,
			base,
			insp,
			&loaded,
			&decoded,
			&encoded,
		)
		switch material.alpha_mode {
		case .opaque:
			textures[.Base_Color].alpha = .Opaque
		case .mask:
			textures[.Base_Color].alpha = .Mask
			textures[.Base_Color].alpha_cutoff = material.alpha_cutoff
		case .blend:
		}
		textures[.Metalness] = glb_material_texture(
			&pbr.metallic_roughness_texture,
			{pbr.metallic_factor, pbr.metallic_factor, pbr.metallic_factor, 1},
			insp,
			&loaded,
			&decoded,
			&encoded,
		)
		textures[.Metalness].pixels = .Blue
		textures[.Roughness] = textures[.Metalness]
		textures[.Roughness].pixels = .Green
		textures[.Roughness].info.tint = {
			pbr.roughness_factor,
			pbr.roughness_factor,
			pbr.roughness_factor,
			1,
		}
		textures[.Emission] = glb_material_texture(
			&material.emissive_texture,
			{emission[0], emission[1], emission[2], 1},
			insp,
			&loaded,
			&decoded,
			&encoded,
		)
	}
	return true
}

@(private)
glb_material_texture :: proc(
	view: ^cgltf.texture_view,
	tint: [4]f32,
	insp: ^Inspect,
	loaded: ^map[^cgltf.image]rl.Image,
	decoded, encoded: ^int,
) -> Fbx_Texture {
	out: Fbx_Texture
	texture := view.texture
	if texture == nil || texture.image_ == nil {return out}
	texcoord := view.texcoord
	if view.has_transform && view.transform.has_texcoord {
		texcoord = view.transform.texcoord
	}
	// Geometry carries UV0 only. Do not silently sample UV1 textures with UV0.
	if texcoord != 0 {return out}
	out.info.uv = {1, 0, 0, 0, 1, 0}
	out.info.tint = tint
	if view.has_transform {
		t := &view.transform
		co, si := math.cos(t.rotation), math.sin(t.rotation)
		a, b := co * t.scale[0], -si * t.scale[1]
		c, d := si * t.scale[0], co * t.scale[1]
		// Both Inspect UVs and the sampler use V up. Conjugate glTF's
		// top-origin transform by (u, v) -> (u, 1-v).
		out.info.uv = {a, -b, b + t.offset[0], -c, d, 1 - d - t.offset[1]}
		for value in out.info.uv {
			if math.is_nan(value) || math.is_inf(value) {return {}}
		}
	}
	if texture.sampler != nil {
		out.info.clamp_u = glb_texture_wrap(texture.sampler.wrap_s)
		out.info.clamp_v = glb_texture_wrap(texture.sampler.wrap_t)
	}
	if image, ok := loaded[texture.image_]; ok {
		out.image = image
		return out
	}
	out.image = glb_material_image(texture.image_, decoded, encoded)
	loaded[texture.image_] = out.image // Failed decodes are not retried.
	if out.image.data != nil {append(&insp.images, out.image)}
	return out
}

@(private)
glb_texture_wrap :: proc(wrap: cgltf.wrap_mode) -> i32 {
	switch wrap {
	case .clamp_to_edge:
		return 1
	case .mirrored_repeat:
		return 2
	case .repeat:
		return 0
	}
	return 0
}

@(private)
glb_material_image :: proc(source: ^cgltf.image, decoded, encoded: ^int) -> rl.Image {
	if decoded^ >= FBX_TEXTURE_BYTES || encoded^ >= FBX_TEXTURE_BYTES {return {}}
	bytes: []u8
	owned: []u8
	defer delete(owned)
	if source.buffer_view != nil {
		view := source.buffer_view
		if view.has_meshopt_compression || view.buffer == nil || view.buffer.data == nil {
			return {}
		}
		if view.offset > view.buffer.size ||
		   view.size > view.buffer.size - view.offset ||
		   view.size > uint(FBX_TEXTURE_BYTES - encoded^) {return {}}
		bytes = (cast([^]u8)view.buffer.data)[view.offset:view.offset + view.size]
	} else {
		// Only standard embedded PNG/JPEG data URIs. Never resolve a filename,
		// network URL, or a URI referring to the enclosing archive.
		uri := string(source.uri)
		payload: string
		if strings.has_prefix(uri, "data:image/png;base64,") {
			payload = uri[len("data:image/png;base64,"):]
		} else if strings.has_prefix(uri, "data:image/jpeg;base64,") {
			payload = uri[len("data:image/jpeg;base64,"):]
		} else {
			return {}
		}
		if len(payload) == 0 ||
		   len(payload) % 4 != 0 ||
		   len(payload) > ((FBX_TEXTURE_BYTES - encoded^ + 2) / 3) * 4 {return {}}
		if base64.decoded_len(payload) > FBX_TEXTURE_BYTES - encoded^ {return {}}
		result, err := base64.decode(payload)
		if err != nil {return {}}
		owned, bytes = result, result
	}
	encoded^ += len(bytes)
	png := len(bytes) >= 8 && string(bytes[:8]) == "\x89PNG\r\n\x1a\n"
	jpeg := len(bytes) >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff
	if !png && !jpeg {return {}}
	w, h, components: c.int
	if stbi.info_from_memory(raw_data(bytes), c.int(len(bytes)), &w, &h, &components) == 0 {
		return {}
	}
	if w <= 0 || h <= 0 || i64(w) * i64(h) > i64(FBX_TEXTURE_BYTES - decoded^) / 4 {
		return {}
	}
	size := int(w) * int(h) * 4
	image := rl.LoadImageFromMemory("", raw_data(bytes), i32(len(bytes)))
	if image.data != nil {decoded^ += size}
	return image
}
