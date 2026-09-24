// Binary glTF attachments share the STL viewer's normalized triangle soup.
// cgltf owns only parse metadata; no file loader is called, and every channel
// retained by the viewer is an Odin allocation independent of the input bytes.
package main

import "core:encoding/endian"
import "core:math"
import "vendor:cgltf"

@(private)
Glb_Instance :: struct {
	node:   ^cgltf.node,
	world:  [16]f64, // column-major, accumulated without f32 overflow
	active: bool,
}

@(private)
Glb_Primitive_Info :: struct {
	pos, nrm, uv: ^cgltf.accessor,
	ntri:         int,
}

@(private)
Glb_Mesh_Info :: struct {
	primitives: []Glb_Primitive_Info,
	ntri:       int,
	has_uv:     bool,
}

// The vendor's single-element readers do not resolve sparse accessors, and its
// bulk float reader uses the base stride for sparse values. Separate packed
// overlays handle sparse data correctly even when the base is interleaved.
@(private)
Glb_Accessor :: struct {
	base:    cgltf.accessor,
	indices: cgltf.accessor,
	values:  cgltf.accessor,
}

@(private)
glb_finite :: proc(v: f64) -> bool {
	return !math.is_nan(v) && !math.is_inf(v)
}

@(private)
glb_u32 :: proc(data: []u8, at: int) -> u32 {
	v, _ := endian.get_u32(data[at:at + 4], .Little)
	return v
}

// cgltf accepts trailing/truncated container declarations more permissively
// than an attachment should. Check every chunk before exposing any BIN data.
@(private)
glb_container_valid :: proc(data: []u8) -> bool {
	if len(data) < 28 ||
	   u64(len(data)) > u64(max(u32)) ||
	   glb_u32(data, 0) != 0x46546c67 ||
	   glb_u32(data, 4) != 2 ||
	   glb_u32(data, 8) != u32(len(data)) {
		return false
	}
	at, chunk := 12, 0
	has_bin := false
	for at < len(data) {
		if len(data) - at < 8 {return false}
		size, kind := int(glb_u32(data, at)), glb_u32(data, at + 4)
		at += 8
		if size % 4 != 0 || size > len(data) - at {return false}
		if chunk == 0 {
			if kind != 0x4e4f534a || size == 0 {return false}
		} else if kind == 0x4e4f534a {
			return false
		} else if kind == 0x004e4942 {
			if chunk != 1 || has_bin {return false}
			has_bin = true
		}
		at += size
		chunk += 1
	}
	return has_bin
}

@(private)
glb_unsigned :: proc(kind: cgltf.component_type) -> bool {
	return kind == .r_8u || kind == .r_16u || kind == .r_32u
}

// Subtraction/division avoid attacker-controlled offset + count * stride
// arithmetic wrapping before the range check.
@(private)
glb_range_valid :: proc(size, offset, count, stride, element: uint) -> bool {
	return(
		count > 0 &&
		stride >= element &&
		element > 0 &&
		offset <= size &&
		element <= size - offset &&
		count - 1 <= (size - offset - element) / stride \
	)
}

@(private)
glb_accessor :: proc(a: ^cgltf.accessor) -> Glb_Accessor {
	out := Glb_Accessor {
		base = a^,
	}
	out.base.is_sparse = false
	if a.is_sparse {
		s := &a.sparse
		out.indices = cgltf.accessor {
			component_type = s.indices_component_type,
			type           = .scalar,
			buffer_view    = s.indices_buffer_view,
			offset         = s.indices_byte_offset,
			count          = s.count,
			stride         = cgltf.component_size(s.indices_component_type),
		}
		out.values = cgltf.accessor {
			component_type = a.component_type,
			normalized     = a.normalized,
			type           = a.type,
			buffer_view    = s.values_buffer_view,
			offset         = s.values_byte_offset,
			count          = s.count,
			stride         = cgltf.calc_size(a.type, a.component_type),
		}
	}
	return out
}

@(private)
glb_sparse_index :: proc(a: ^Glb_Accessor, index: uint) -> (uint, bool) {
	lo, hi := uint(0), a.indices.count
	for lo < hi {
		mid := lo + (hi - lo) / 2
		value := cgltf.accessor_read_index(&a.indices, mid)
		if value < index {lo = mid + 1} else {hi = mid}
	}
	if lo < a.indices.count && cgltf.accessor_read_index(&a.indices, lo) == index {
		return lo, true
	}
	return 0, false
}

@(private)
glb_read_float :: proc(a: ^Glb_Accessor, index: uint, out: []f32) -> bool {
	if index >= a.base.count {return false}
	source, at := &a.base, index
	if a.indices.count > 0 {
		if sparse, found := glb_sparse_index(a, index); found {
			source, at = &a.values, sparse
		}
	}
	if !cgltf.accessor_read_float(source, at, raw_data(out), uint(len(out))) {return false}
	for value in out {if !glb_finite(f64(value)) {return false}}
	return true
}

@(private)
glb_read_index :: proc(a: ^Glb_Accessor, index: uint) -> uint {
	if a.indices.count > 0 {
		if sparse, found := glb_sparse_index(a, index); found {
			return cgltf.accessor_read_index(&a.values, sparse)
		}
	}
	return cgltf.accessor_read_index(&a.base, index)
}

@(private)
glb_buffers_valid :: proc(data: ^cgltf.data) -> bool {
	// A GLB's sole embedded buffer is the BIN chunk, with up to three
	// padding bytes. In particular, never pass a URI to load_buffers.
	if len(data.buffers) != 1 || len(data.bin) == 0 {return false}
	buffer := &data.buffers[0]
	if buffer.uri != nil ||
	   buffer.size == 0 ||
	   buffer.size > uint(len(data.bin)) ||
	   uint(len(data.bin)) - buffer.size > 3 {
		return false
	}
	buffer.data = raw_data(data.bin)
	buffer.data_free_method = .none
	for &view in data.buffer_views {
		if view.buffer != buffer ||
		   view.data != nil ||
		   view.has_meshopt_compression ||
		   view.offset > buffer.size ||
		   view.size == 0 ||
		   view.size > buffer.size - view.offset ||
		   (view.stride != 0 && (view.stride < 4 || view.stride > 252 || view.stride % 4 != 0)) {
			return false
		}
	}
	sparse_work: uint
	for &a in data.accessors {
		if a.type == .invalid ||
		   a.component_type == .invalid ||
		   a.count == 0 ||
		   a.count > STL_MAX_TRIS * 3 ||
		   (a.normalized && (a.component_type == .r_32f || a.component_type == .r_32u)) {
			return false
		}
		component := cgltf.component_size(a.component_type)
		element := cgltf.calc_size(a.type, a.component_type)
		if component == 0 || element == 0 || a.stride < element || a.stride % component != 0 {
			return false
		}
		if view := a.buffer_view; view != nil {
			if !glb_range_valid(view.size, a.offset, a.count, a.stride, element) ||
			   (view.offset + a.offset) % component != 0 {
				return false
			}
		} else if a.offset != 0 {
			return false
		}
		if a.has_min {
			for value in a.min {if !glb_finite(f64(value)) {return false}}
		}
		if a.has_max {
			for value in a.max {if !glb_finite(f64(value)) {return false}}
		}
		if !a.is_sparse {continue}
		s := &a.sparse
		if !glb_unsigned(s.indices_component_type) ||
		   s.count == 0 ||
		   s.count > a.count ||
		   s.indices_buffer_view == nil ||
		   s.values_buffer_view == nil {
			return false
		}
		ic := cgltf.component_size(s.indices_component_type)
		iv, vv := s.indices_buffer_view, s.values_buffer_view
		if iv.stride != 0 ||
		   vv.stride != 0 ||
		   !glb_range_valid(iv.size, s.indices_byte_offset, s.count, ic, ic) ||
		   !glb_range_valid(vv.size, s.values_byte_offset, s.count, element, element) ||
		   (iv.offset + s.indices_byte_offset) % ic != 0 ||
		   (vv.offset + s.values_byte_offset) % component != 0 {
			return false
		}
		// Aliased sparse views must not turn tiny metadata into unbounded
		// repeated scans. Allow a full output's position/normal/UV/index data.
		if s.count > STL_MAX_TRIS * 12 - sparse_work {return false}
		sparse_work += s.count
		reader := glb_accessor(&a)
		previous: uint
		for i in 0 ..< s.count {
			index := cgltf.accessor_read_index(&reader.indices, i)
			if index >= a.count || (i > 0 && index <= previous) {return false}
			previous = index
		}
	}
	return true
}

@(private)
glb_primitive :: proc(
	p: ^cgltf.primitive,
) -> (
	pos, nrm, uv: ^cgltf.accessor,
	ntri: int,
	ok: bool,
) {
	if p.type == .invalid || p.has_draco_mesh_compression || len(p.attributes) == 0 {
		return nil, nil, nil, 0, false
	}
	count := p.attributes[0].data.count
	for attr in p.attributes {
		if attr.data.count != count {return nil, nil, nil, 0, false}
		if attr.index != 0 {continue}
		#partial switch attr.type {
		case .position:
			if pos != nil {return nil, nil, nil, 0, false}
			pos = attr.data
		case .normal:
			if nrm != nil {return nil, nil, nil, 0, false}
			nrm = attr.data
		case .texcoord:
			if uv != nil {return nil, nil, nil, 0, false}
			uv = attr.data
		}
	}
	if pos == nil ||
	   pos.type != .vec3 ||
	   pos.component_type == .r_32u ||
	   (nrm != nil && (nrm.type != .vec3 || nrm.component_type == .r_32u)) ||
	   (uv != nil && (uv.type != .vec2 || uv.component_type == .r_32u)) {
		return nil, nil, nil, 0, false
	}
	for target in p.targets {
		for attr in target.attributes {
			if attr.data.count != count {return nil, nil, nil, 0, false}
		}
	}
	if indices := p.indices; indices != nil {
		if indices.type != .scalar ||
		   !glb_unsigned(indices.component_type) ||
		   indices.normalized ||
		   indices.stride != cgltf.component_size(indices.component_type) {
			return nil, nil, nil, 0, false
		}
		count = indices.count
	}
	#partial switch p.type {
	case .triangles:
		if count % 3 != 0 {return nil, nil, nil, 0, false}
		ntri = int(count / 3)
	case .triangle_strip, .triangle_fan:
		if count < 3 {return nil, nil, nil, 0, false}
		ntri = int(count - 2)
	case .points, .lines, .line_loop, .line_strip:
		// The shared viewer has only a triangle surface, not line/point draws.
		ntri = 0
	case:
		return nil, nil, nil, 0, false
	}
	return pos, nrm, uv, ntri, ntri <= STL_MAX_TRIS
}

@(private)
glb_local_transform :: proc(node: ^cgltf.node) -> ([16]f64, bool) {
	if node.has_mesh_gpu_instancing {return {}, false}
	for v in node.translation {if !glb_finite(f64(v)) {return {}, false}}
	for v in node.rotation {if !glb_finite(f64(v)) {return {}, false}}
	for v in node.scale {if !glb_finite(f64(v)) {return {}, false}}
	if node.has_matrix {
		if node.has_translation || node.has_rotation || node.has_scale {return {}, false}
		for v in node.matrix_ {if !glb_finite(f64(v)) {return {}, false}}
		if node.matrix_[3] != 0 ||
		   node.matrix_[7] != 0 ||
		   node.matrix_[11] != 0 ||
		   node.matrix_[15] != 1 {
			return {}, false
		}
	} else {
		q := node.rotation
		norm :=
			f64(q[0]) * f64(q[0]) +
			f64(q[1]) * f64(q[1]) +
			f64(q[2]) * f64(q[2]) +
			f64(q[3]) * f64(q[3])
		if abs(norm - 1) > 0.001 {return {}, false}
	}
	local: [16]f32
	cgltf.node_transform_local(node, raw_data(local[:]))
	out: [16]f64
	for v, i in local {
		if !glb_finite(f64(v)) {return {}, false}
		out[i] = f64(v)
	}
	return out, true
}

@(private)
glb_instances :: proc(data: ^cgltf.data) -> ([]Glb_Instance, bool) {
	if len(data.nodes) == 0 || len(data.nodes) > STL_MAX_TRIS {return nil, false}
	active := make([]bool, len(data.nodes))
	defer delete(active)
	selected := data.scene
	if selected == nil && len(data.scenes) > 0 {selected = &data.scenes[0]}
	if selected != nil {
		for root in selected.nodes {
			index := int(cgltf.node_index(data, root))
			if root.parent != nil || active[index] {return nil, false}
			active[index] = true
		}
	}
	// Traverse every root once, including inactive trees: an unvisited node
	// at the end identifies a disconnected cycle without recursion or an
	// O(depth) parent-chain walk per node.
	stack := make([dynamic]Glb_Instance)
	defer delete(stack)
	instances := make([dynamic]Glb_Instance)
	success := false
	defer if !success {delete(instances)}
	identity := [16]f64{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
	for &node, i in data.nodes {
		if node.parent == nil {
			append(&stack, Glb_Instance{&node, identity, selected == nil || active[i]})
		}
	}
	visited := 0
	for len(stack) > 0 {
		item := pop(&stack)
		local, ok := glb_local_transform(item.node)
		if !ok {return nil, false}
		world: [16]f64
		for col in 0 ..< 4 {
			for row in 0 ..< 4 {
				for k in 0 ..< 4 {world[col * 4 + row] += item.world[k * 4 + row] * local[col * 4 + k]}
				if !glb_finite(world[col * 4 + row]) {return nil, false}
			}
		}
		item.world = world
		visited += 1
		if visited > len(data.nodes) {return nil, false}
		if item.active && item.node.mesh != nil {append(&instances, item)}
		for child in item.node.children {
			if child.parent != item.node {return nil, false}
			append(&stack, Glb_Instance{child, world, item.active})
		}
	}
	if visited != len(data.nodes) {return nil, false}
	success = true
	return instances[:], true
}

// Cofactors give inverse-transpose normals up to the determinant. Keeping
// only its sign avoids dividing by a tiny determinant before normalization.
@(private)
glb_normal_transform :: proc(m: [16]f64) -> ([9]f64, f64, bool) {
	out := [9]f64 { 	// row-major cofactor matrix
		m[5] * m[10] - m[9] * m[6],
		m[9] * m[2] - m[1] * m[10],
		m[1] * m[6] - m[5] * m[2],
		m[8] * m[6] - m[4] * m[10],
		m[0] * m[10] - m[8] * m[2],
		m[4] * m[2] - m[0] * m[6],
		m[4] * m[9] - m[8] * m[5],
		m[8] * m[1] - m[0] * m[9],
		m[0] * m[5] - m[4] * m[1],
	}
	det := m[0] * out[0] + m[1] * out[3] + m[2] * out[6]
	for v in out {if !glb_finite(v) {return {}, 0, false}}
	return out, det, glb_finite(det)
}

@(private)
glb_unit_normal :: proc(v: [3]f64) -> [3]f32 {
	scale := max(abs(v[0]), abs(v[1]), abs(v[2]))
	if scale == 0 {return {}}
	x, y, z := v[0] / scale, v[1] / scale, v[2] / scale
	length := math.sqrt(x * x + y * y + z * z)
	return {f32(x / length), f32(y / length), f32(z / length)}
}

// Same bbox-centered unit sphere as normalize_tris, using f64 intermediate
// sums and squares so finite, very large/small glTF coordinates remain safe.
@(private)
glb_normalize :: proc(tris: []f32) {
	lo, hi := [3]f64{max(f64), max(f64), max(f64)}, [3]f64{min(f64), min(f64), min(f64)}
	for i in 0 ..< len(tris) / 3 {
		for a in 0 ..< 3 {
			v := f64(tris[i * 3 + a])
			lo[a], hi[a] = min(lo[a], v), max(hi[a], v)
		}
	}
	center, delta: [3]f64
	for a in 0 ..< 3 {center[a], delta[a] = (lo[a] + hi[a]) / 2, hi[a] - lo[a]}
	radius := math.sqrt(delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2]) / 2
	if radius == 0 {radius = 1}
	for i in 0 ..< len(tris) / 3 {
		for a in 0 ..< 3 {tris[i * 3 + a] = f32((f64(tris[i * 3 + a]) - center[a]) / radius)}
	}
}

@(private)
parse_glb :: proc(bytes: []u8) -> (^Stl_View, bool) {
	if !glb_container_valid(bytes) {return nil, false}
	data, result := cgltf.parse(cgltf.options{type = .glb}, raw_data(bytes), uint(len(bytes)))
	if result != .success {return nil, false}
	defer cgltf.free(data)
	if string(data.asset.version) != "2.0" ||
	   (data.asset.min_version != nil && string(data.asset.min_version) != "2.0") {
		return nil, false
	}
	for required in data.extensions_required {
		switch string(required) {
		case "KHR_mesh_quantization", "KHR_texture_transform", "KHR_materials_emissive_strength":
		case:
			return nil, false
		}
	}
	// parse performs checked reference-index fixups. Buffer/accessor ranges
	// must additionally be validated before any reader touches their data.
	if !glb_buffers_valid(data) {return nil, false}
	meshes := make([]Glb_Mesh_Info, len(data.meshes))
	defer {
		for mesh in meshes {delete(mesh.primitives)}
		delete(meshes)
	}
	for &mesh, mi in data.meshes {
		info := &meshes[mi]
		info.primitives = make([]Glb_Primitive_Info, len(mesh.primitives))
		for &primitive, pi in mesh.primitives {
			pos, nrm, uv, count, ok := glb_primitive(&primitive)
			if !ok || count > STL_MAX_TRIS - info.ntri {return nil, false}
			info.primitives[pi] = {pos, nrm, uv, count}
			info.ntri += count
			info.has_uv = info.has_uv || (count > 0 && uv != nil)
		}
	}
	instances, ok := glb_instances(data)
	if !ok {return nil, false}
	defer delete(instances)
	ntri := 0
	primitive_visits := 0
	has_uv := false
	for instance in instances {
		// Non-surface primitives produce no triangles, but their repeated
		// instancing still needs a bound before iterating a shared mesh.
		if len(instance.node.mesh.primitives) > STL_MAX_TRIS - primitive_visits {return nil, false}
		primitive_visits += len(instance.node.mesh.primitives)
		info := &meshes[cgltf.mesh_index(data, instance.node.mesh)]
		if info.ntri > STL_MAX_TRIS - ntri {return nil, false}
		ntri += info.ntri
		has_uv = has_uv || info.has_uv
	}
	if ntri == 0 {return nil, false}
	tris := make([]f32, ntri * 9)
	vnrm := make([]f32, ntri * 9)
	uvs: []f32
	if has_uv {uvs = make([]f32, ntri * 6)}
	mats := make([]i32, ntri)
	owned := true
	defer if owned {delete(tris); delete(vnrm); delete(uvs); delete(mats)}
	tri := 0
	for instance in instances {
		world := instance.world
		normal, det, normal_ok := glb_normal_transform(world)
		if !normal_ok {return nil, false}
		mesh := &meshes[cgltf.mesh_index(data, instance.node.mesh)]
		for &primitive, pi in instance.node.mesh.primitives {
			info := &mesh.primitives[pi]
			pos, nrm, uv, count := info.pos, info.nrm, info.uv, info.ntri
			if count == 0 {continue}
			positions := glb_accessor(pos)
			normals, texcoords, indices: Glb_Accessor
			if nrm != nil {normals = glb_accessor(nrm)}
			if uv != nil {texcoords = glb_accessor(uv)}
			if primitive.indices != nil {indices = glb_accessor(primitive.indices)}
			material := i32(-1)
			if primitive.material !=
			   nil {material = i32(cgltf.material_index(data, primitive.material))}
			for face in 0 ..< count {
				corners: [3]uint
				#partial switch primitive.type {
				case .triangles:
					corners = {uint(face * 3), uint(face * 3 + 1), uint(face * 3 + 2)}
				case .triangle_strip:
					corners = {uint(face), uint(face + 1), uint(face + 2)}
					if face % 2 != 0 {corners[0], corners[1] = corners[1], corners[0]}
				case .triangle_fan:
					corners = {0, uint(face + 1), uint(face + 2)}
				case:
					return nil, false
				}
				if det < 0 {corners[1], corners[2] = corners[2], corners[1]}
				for corner, k in corners {
					index := corner
					if primitive.indices != nil {index = glb_read_index(&indices, corner)}
					if index >= pos.count {return nil, false}
					p: [3]f32
					if !glb_read_float(&positions, index, p[:]) {return nil, false}
					at := tri * 9 + k * 3
					for a in 0 ..< 3 {
						value :=
							world[a] * f64(p[0]) +
							world[4 + a] * f64(p[1]) +
							world[8 + a] * f64(p[2]) +
							world[12 + a]
						if !glb_finite(value) || abs(value) > f64(max(f32)) {return nil, false}
						tris[at + a] = f32(value)
					}
					if nrm != nil {
						n: [3]f32
						if !glb_read_float(&normals, index, n[:]) {return nil, false}
						if det != 0 {
							transformed: [3]f64
							for a in 0 ..< 3 {
								transformed[a] =
									normal[a * 3] * f64(n[0]) +
									normal[a * 3 + 1] * f64(n[1]) +
									normal[a * 3 + 2] * f64(n[2])
								if det < 0 {transformed[a] = -transformed[a]}
								if !glb_finite(transformed[a]) {return nil, false}
							}
							n = glb_unit_normal(transformed)
							copy(vnrm[at:at + 3], n[:])
						}
					}
					if uv != nil {
						t: [2]f32
						if !glb_read_float(&texcoords, index, t[:]) {return nil, false}
						uv_at := tri * 6 + k * 2
						uvs[uv_at], uvs[uv_at + 1] = t[0], 1 - t[1]
					}
				}
				mats[tri] = material
				tri += 1
			}
		}
	}
	glb_normalize(tris)
	view := stl_view_make(tris)
	view.insp.vnrm, view.insp.uv, view.insp.mat = vnrm, uvs, mats
	owned = false
	for i in 0 ..< ntri {
		for k in 0 ..< 3 {
			at := i * 9 + k * 3
			if vnrm[at] == 0 && vnrm[at + 1] == 0 && vnrm[at + 2] == 0 {
				copy(vnrm[at:at + 3], view.norms[i * 3:i * 3 + 3])
			}
		}
	}
	if !glb_load_materials(data, &view.insp) {
		stl_view_free(view)
		return nil, false
	}
	return view, true
}
