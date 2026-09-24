package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"

import rl "sdlrl"
import stbi "vendor:stb/image"

@(private)
Fbx_Channel :: enum i32 {
	Base_Color,
	Metalness,
	Roughness,
	Emission,
	Specular,
	Normal,
}

@(private)
Fbx_Texture_Info :: struct {
	path:             cstring, // borrowed from ufbx
	uv:               [6]f32,
	tint:             [4]f32,
	clamp_u, clamp_v: i32,
}

@(private)
Fbx_Texture :: struct {
	info:         Fbx_Texture_Info,
	image:        rl.Image, // borrowed from Inspect.images
	pixels:       enum {
		Color,
		Smoothness,
		Green,
		Blue,
	},
	alpha:        enum {
		From_Image,
		Opaque,
		Mask,
	},
	alpha_cutoff: f32,
}

@(private)
FBX_TEXTURE_BYTES :: 256 * 1024 * 1024 // total decoded RGBA per preview

// Paths remain virtual: even an absolute exporter path can only match ZIP entries.
@(private)
fbx_texture_path :: proc(path: string) -> string {
	slashes, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	lower := strings.to_lower(slashes, context.temp_allocator)
	clean, _ := filepath.clean(lower, context.temp_allocator)
	return clean
}

@(private)
fbx_find_texture :: proc(paths, basenames: map[string]int, model_name, reference: string) -> int {
	path := fbx_texture_path(reference)
	dir := filepath.dir(fbx_texture_path(model_name))
	relative := fbx_texture_path(fmt.tprintf("%s/%s", dir, path))
	if index, ok := paths[relative]; ok {return index}
	if index, ok := paths[path]; ok {return index}
	// Exporters often retain an author-machine path. Accept a basename only
	// when it identifies exactly one archive entry.
	if index, ok := basenames[filepath.base(path)]; ok {return index}
	return -1
}

@(private)
fbx_load_textures :: proc(insp: ^Inspect, archive: ^Arc_View, model_name: string) {
	if insp.scene == nil || insp.uv == nil || archive == nil {return}
	paths := make(map[string]int, context.temp_allocator)
	basenames := make(map[string]int, context.temp_allocator)
	named := make(map[string]int, context.temp_allocator)
	packed := make(map[int]bool, context.temp_allocator)
	for entry in archive.entries {
		path := fbx_texture_path(entry.name)
		base := filepath.base(path)
		_, duplicate_path := paths[path]
		_, duplicate_base := basenames[base]
		paths[path] = duplicate_path ? -1 : entry.index
		basenames[base] = duplicate_base ? -1 : entry.index
		stem := strings.trim_suffix(base, filepath.ext(base))
		sep := strings.last_index_byte(stem, '_')
		if sep < 0 {continue}
		channels: []Fbx_Channel
		switch stem[sep + 1:] {
		case "albedotransparency", "albedo", "basecolor", "diffuse":
			channels = {.Base_Color}
		case "metallic", "metalness":
			channels = {.Metalness}
		case "roughness":
			channels = {.Roughness}
		case "emission", "emissive":
			channels = {.Emission}
		case "specular":
			channels = {.Specular}
		case "normal":
			channels = {.Normal}
		case "metallicsmoothness":
			channels = {.Metalness, .Roughness}
			packed[entry.index] = true
		}
		// ponytail: exported Material_Channel filenames only. Other naming
		// conventions need explicit FBX references, not a guessed texture.
		for start := 0; start <= sep; start += 1 {
			if start != 0 && stem[start - 1] != '_' {continue}
			for channel in channels {
				key := fmt.tprintf("%s/%d", stem[start:sep], channel)
				_, duplicate := named[key]
				named[key] = duplicate ? -1 : entry.index
			}
		}
	}

	loaded := make(map[int]rl.Image, context.temp_allocator)
	insp.textures = make([][Fbx_Channel]Fbx_Texture, len(insp.mats) / FBX_MAT_FLOATS)
	decoded, extracted := 0, 0
	for &material, i in insp.textures {
		name := strings.to_lower(
			string(fbx_material_name(insp.scene, i32(i))),
			context.temp_allocator,
		)
		for &texture, channel in material {
			index := -1
			reference := fbx_texture_of(insp.scene, i32(i), channel, &texture.info)
			if reference < 0 {continue}
			if reference > 0 {
				index = fbx_find_texture(paths, basenames, model_name, string(texture.info.path))
			} else if match, ok := named[fmt.tprintf("%s/%d", name, channel)]; ok && name != "" {
				index = match
				texture.info = {
					uv   = {1, 0, 0, 0, 1, 0},
					tint = {1, 1, 1, 1},
				}
				if channel == .Roughness && packed[index] {texture.pixels = .Smoothness}
			}
			if index < 0 {continue}
			if image, ok := loaded[index]; ok {
				texture.image = image
				continue
			}
			loaded[index] = {} // failed decodes are not retried for each material
			if extracted >= FBX_TEXTURE_BYTES {continue}
			bytes, ok := arc_entry_bytes(archive, index)
			if !ok {continue}
			extracted += len(bytes)
			w, h, components: c.int
			valid :=
				stbi.info_from_memory(raw_data(bytes), c.int(len(bytes)), &w, &h, &components) != 0
			size := i64(w) * i64(h) * 4
			if valid && w > 0 && h > 0 && size <= i64(FBX_TEXTURE_BYTES - decoded) {
				image := rl.LoadImageFromMemory("", raw_data(bytes), i32(len(bytes)))
				if image.data != nil {
					decoded += int(size)
					append(&insp.images, image)
					loaded[index] = image
					texture.image = image
				}
			}
			delete(bytes)
		}
	}
}

// UVs are in FBX space (V up); wrapping happens before the image-row flip.
@(private)
fbx_sample_texture :: proc(texture: ^Fbx_Texture, uv: [2]f32) -> [4]f32 {
	m := texture.info.uv
	u := m[0] * uv[0] + m[1] * uv[1] + m[2]
	v := m[3] * uv[0] + m[4] * uv[1] + m[5]
	if math.is_nan(u) || math.is_inf(u) || math.is_nan(v) || math.is_inf(v) {return {1, 1, 1, 1}}
	if texture.info.clamp_u == 2 {
		u = 1 - abs(1 - (u - 2 * math.floor(u / 2)))
	} else {
		u = texture.info.clamp_u == 1 ? clamp(u, 0, 1) : u - math.floor(u)
	}
	if texture.info.clamp_v == 2 {
		v = 1 - abs(1 - (v - 2 * math.floor(v / 2)))
	} else {
		v = texture.info.clamp_v == 1 ? clamp(v, 0, 1) : v - math.floor(v)
	}
	image := texture.image
	x := min(int(u * f32(image.width)), int(image.width) - 1)
	y := min(int((1 - v) * f32(image.height)), int(image.height) - 1)
	pixels := cast([^]u8)image.data
	at := (y * int(image.width) + x) * 4
	if texture.pixels == .Smoothness {
		rough := 1 - f32(pixels[at + 3]) / 255
		return {rough, rough, rough, 1}
	}
	color := [4]f32 {
		f32(pixels[at]) / 255,
		f32(pixels[at + 1]) / 255,
		f32(pixels[at + 2]) / 255,
		f32(pixels[at + 3]) / 255,
	}
	if texture.pixels == .Green {
		color = {color[1], color[1], color[1], 1}
	} else if texture.pixels == .Blue {
		color = {color[2], color[2], color[2], 1}
	}
	color *= texture.info.tint
	switch texture.alpha {
	case .Opaque:
		color[3] = 1
	case .Mask:
		color[3] = color[3] >= texture.alpha_cutoff ? 1 : 0
	case .From_Image:
	}
	return color
}
