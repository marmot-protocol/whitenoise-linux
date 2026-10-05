// FBX parsing and evaluation live in the persistent wn-fbx helper. The UI
// owns every published channel and validates each complete reply before use.
package main

import "core:c/libc"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import rl "sdlrl"

foreign import fbx_decoder {WN_BUILD_DIR + "/libwndecoder.a"}
@(private, default_calling_convention = "c")
foreign fbx_decoder {
	wn_model_start :: proc(helper: cstring) -> rawptr ---
	wn_model_exchange :: proc(session: rawptr, operation: u32, data: [^]u8, size: u32, output: [^]u8, capacity: u32, length: ^u32) -> [^]u8 ---
	wn_model_close :: proc(session: rawptr) ---
}

FBX_MAT_FLOATS :: 12
@(private)
FBX_MAX_ITEMS :: 65536
@(private)
FBX_MAX_PAYLOAD :: 512 * 1024 * 1024

Render_Mode :: enum u8 {
	Final,
	Bones,
	Bone_Influence,
	Base_Color,
	Metalness,
	Roughness,
	Emission,
	Specular,
	Matcap,
	Wireframe,
	Vertex_Normals,
	Uv_Checker,
}

WIRE_MAX_TRIS :: 60_000

Inspect :: struct {
	mode:           Render_Mode,
	wire:           int,
	single_sided:   bool,
	// Opaque transport handle, never a parser or scene pointer.
	session:        rawptr,
	vnrm:           []f32,
	uv:             []f32,
	bone:           []i32,
	bwt:            []f32,
	mat:            []i32,
	mats:           []f32,
	nbones:         int,
	textures:       [][Fbx_Channel]Fbx_Texture,
	images:         [dynamic]rl.Image,
	material_names: []string,
	pose_scratch:   []u8,
	anim:           int,
	takes:          []string,
	take_times:     [][2]f64,
	t0, t1, time:   f64,
	playing, posed: bool,
}

@(private)
Fbx_Wire :: struct {
	data: []u8,
	at:   int,
	ok:   bool,
}

@(private)
fbx_wire_u32 :: proc(r: ^Fbx_Wire) -> u32 {
	if !r.ok || len(r.data) - r.at < 4 {r.ok = false; return 0}
	b := r.data[r.at:r.at + 4]
	r.at += 4
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private)
fbx_put_u32 :: proc(b: []u8, v: u32) {
	b[0], b[1], b[2], b[3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
}

@(private)
fbx_wire_f32 :: proc(r: ^Fbx_Wire) -> f32 {
	v := transmute(f32)fbx_wire_u32(r)
	if math.is_nan(v) || math.is_inf(v) {r.ok = false}
	return v
}

@(private)
fbx_wire_f64 :: proc(r: ^Fbx_Wire) -> f64 {
	lo := fbx_wire_u32(r)
	hi := fbx_wire_u32(r)
	v := transmute(f64)(u64(lo) | u64(hi) << 32)
	if math.is_nan(v) || math.is_inf(v) {r.ok = false}
	return v
}

@(private)
fbx_wire_string :: proc(r: ^Fbx_Wire) -> string {
	n := int(fbx_wire_u32(r))
	if !r.ok || n > 4096 || n > len(r.data) - r.at {r.ok = false; return ""}
	s := string(r.data[r.at:r.at + n])
	r.at += n
	if !utf8.valid_string(s) || strings.contains(s, "\x00") {r.ok = false; return ""}
	return strings.clone(s)
}

@(private)
fbx_wire_floats :: proc(r: ^Fbx_Wire, n: int) -> []f32 {
	if !r.ok || n > (len(r.data) - r.at) / 4 {r.ok = false; return nil}
	values := make([]f32, n)
	for &v in values {v = fbx_wire_f32(r)}
	return values
}

@(private)
fbx_wire_indices :: proc(r: ^Fbx_Wire, n, count: int) -> []i32 {
	if !r.ok || n > (len(r.data) - r.at) / 4 {r.ok = false; return nil}
	values := make([]i32, n)
	for &v in values {
		v = transmute(i32)fbx_wire_u32(r)
		if v < -1 || int(v) >= count {r.ok = false}
	}
	return values
}

// FBM1 schema is documented next to the helper writer. No scene is published
// until all counts, numeric channels, indices, names and references validate.
@(private)
fbx_decode_metadata :: proc(payload: []u8) -> (^Stl_View, bool) {
	if len(payload) < 32 ||
	   len(payload) > FBX_MAX_PAYLOAD ||
	   string(payload[:4]) != "FBM1" {return nil, false}
	r := Fbx_Wire {
		data = payload,
		at   = 4,
		ok   = true,
	}
	ntri := int(fbx_wire_u32(&r))
	nbones := int(fbx_wire_u32(&r))
	ntakes := int(fbx_wire_u32(&r))
	nmats := int(fbx_wire_u32(&r))
	flags := fbx_wire_u32(&r)
	reserved0, reserved1 := fbx_wire_u32(&r), fbx_wire_u32(&r)
	if ntri < 1 ||
	   ntri > STL_MAX_TRIS ||
	   nbones > FBX_MAX_ITEMS ||
	   ntakes > FBX_MAX_ITEMS ||
	   nmats > FBX_MAX_ITEMS ||
	   flags & ~u32(3) != 0 ||
	   reserved0 != 0 ||
	   reserved1 != 0 {return nil, false}
	// Check the complete fixed-size portion before allocating any channels.
	fixed := ntri * 18 * 4 + nmats * FBX_MAT_FLOATS * 4
	if flags & 1 != 0 {fixed += ntri * 6 * 4}
	if flags & 2 != 0 {fixed += ntri * 6 * 4}
	if nmats > 0 {fixed += ntri * 4}
	if fixed > len(payload) - r.at {return nil, false}
	insp := Inspect {
		wire   = -1,
		anim   = -1,
		nbones = nbones,
	}
	tris := fbx_wire_floats(&r, ntri * 9)
	complete := false
	defer {
		if !complete {delete(tris); fbx_free(&insp)}
	}
	insp.vnrm = fbx_wire_floats(&r, ntri * 9)
	if flags & 1 != 0 {insp.uv = fbx_wire_floats(&r, ntri * 6)}
	if flags & 2 != 0 {
		if nbones == 0 {return nil, false}
		insp.bone = fbx_wire_indices(&r, ntri * 3, nbones)
		insp.bwt = fbx_wire_floats(&r, ntri * 3)
	}
	if nmats > 0 {
		insp.mat = fbx_wire_indices(&r, ntri, nmats)
		insp.mats = fbx_wire_floats(&r, nmats * FBX_MAT_FLOATS)
	}
	if !r.ok || ntakes * 20 + nmats * (4 + 6 * 56) > len(payload) - r.at {return nil, false}
	insp.takes = make([]string, ntakes)
	insp.take_times = make([][2]f64, ntakes)
	for &name, i in insp.takes {
		begin, end := fbx_wire_f64(&r), fbx_wire_f64(&r)
		if !r.ok || end < begin {return nil, false}
		insp.take_times[i] = {begin, end}
		name = fbx_wire_string(&r)
		if !r.ok {return nil, false}
	}
	insp.material_names = make([]string, nmats)
	insp.textures = make([][Fbx_Channel]Fbx_Texture, nmats)
	for &name, i in insp.material_names {
		name = fbx_wire_string(&r)
		for &texture in insp.textures[i] {
			texture.reference = transmute(i32)fbx_wire_u32(&r)
			texture.info.clamp_u = transmute(i32)fbx_wire_u32(&r)
			texture.info.clamp_v = transmute(i32)fbx_wire_u32(&r)
			for &v in texture.info.uv {v = fbx_wire_f32(&r)}
			for &v in texture.info.tint {v = fbx_wire_f32(&r)}
			texture.info.path = fbx_wire_string(&r)
			if !r.ok ||
			   texture.reference < -1 ||
			   texture.reference > 1 ||
			   texture.info.clamp_u < 0 ||
			   texture.info.clamp_u > 1 ||
			   texture.info.clamp_v < 0 ||
			   texture.info.clamp_v > 1 ||
			   (texture.reference == 1 && texture.info.path == "") {return nil, false}
		}
	}
	if !r.ok || r.at != len(payload) {return nil, false}
	if ntakes > 0 {insp.pose_scratch = make([]u8, 8 + ntri * 18 * 4)}
	view := stl_view_make(tris)
	view.insp = insp
	complete = true
	return view, true
}

parse_fbx :: proc(data: []u8) -> (^Stl_View, bool) {
	if len(data) == 0 || len(data) > 128 * 1024 * 1024 {return nil, false}
	helper := strings.clone_to_cstring(helper_path("wn-fbx"), context.temp_allocator)
	session := wn_model_start(helper)
	if session == nil {return nil, false}
	complete := false
	defer {if !complete {wn_model_close(session)}}
	length: u32
	payload := wn_model_exchange(session, 0, raw_data(data), u32(len(data)), nil, 0, &length)
	if payload == nil {return nil, false}
	defer libc.free(payload)
	view, ok := fbx_decode_metadata(payload[:int(length)])
	if !ok {return nil, false}
	if len(view.insp.takes) > 0 {
		view.insp.session = session
		complete = true
		fbx_select_take(view, 0)
		view.insp.playing = view.insp.session != nil
	} else {
		wn_model_close(session)
		complete = true
	}
	return view, true
}

fbx_select_take :: proc(view: ^Stl_View, take: int) {
	insp := &view.insp
	insp.anim = take
	if take < 0 || take >= len(insp.takes) {
		insp.anim = -1
		insp.t0, insp.t1, insp.time = 0, 0, 0
		insp.playing = false
		fbx_pose(view, 0)
		return
	}
	insp.t0, insp.t1 = insp.take_times[take][0], insp.take_times[take][1]
	if insp.t1 <= insp.t0 {insp.t1 = insp.t0 + 1}
	insp.time = insp.t0
	fbx_pose(view, insp.t0)
}

// Validation is a separate pass: a malformed final normal must not publish
// even the first position. Transport writes only into reusable scratch.
@(private)
fbx_apply_pose :: proc(view: ^Stl_View, payload: []u8) -> bool {
	if len(payload) != 8 + len(view.tris) * 8 ||
	   len(view.insp.vnrm) != len(view.tris) ||
	   string(payload[:4]) != "FBP1" {return false}
	r := Fbx_Wire {
		data = payload,
		at   = 4,
		ok   = true,
	}
	if int(fbx_wire_u32(&r)) != len(view.tris) / 9 {return false}
	for i in 0 ..< len(view.tris) * 2 {fbx_wire_f32(&r)}
	if !r.ok || r.at != len(payload) {return false}
	r.at = 8
	for &v in view.tris {v = transmute(f32)fbx_wire_u32(&r)}
	for &v in view.insp.vnrm {v = transmute(f32)fbx_wire_u32(&r)}
	view.insp.posed = view.insp.anim >= 0
	stl_face_normals(view)
	view.built = {}
	return true
}

fbx_pose :: proc(view: ^Stl_View, time: f64) {
	insp := &view.insp
	if insp.session == nil {return}
	request: [12]u8
	fbx_put_u32(request[:4], transmute(u32)i32(insp.anim))
	bits := transmute(u64)time
	fbx_put_u32(request[4:8], u32(bits))
	fbx_put_u32(request[8:], u32(bits >> 32))
	length: u32
	payload := wn_model_exchange(
		insp.session,
		1,
		raw_data(request[:]),
		12,
		raw_data(insp.pose_scratch),
		u32(len(insp.pose_scratch)),
		&length,
	)
	if payload == nil || !fbx_apply_pose(view, insp.pose_scratch[:int(length)]) {
		wn_model_close(insp.session)
		insp.session = nil
		insp.playing = false
	}
}

advance_models :: proc(dt: f32) {
	for view in playing_models {
		insp := &view.insp
		if !insp.playing || insp.anim < 0 {continue}
		anim_moving += 1
		insp.time += f64(dt)
		if insp.time > insp.t1 {insp.time = insp.t0 + (insp.time - insp.t1)}
		fbx_pose(view, insp.time)
	}
	clear(&playing_models)
}

playing_models: [dynamic]^Stl_View

fbx_free :: proc(insp: ^Inspect) {
	if insp.session != nil {wn_model_close(insp.session)}
	delete(insp.uv)
	delete(insp.bone)
	delete(insp.bwt)
	delete(insp.mat)
	delete(insp.mats)
	for image in insp.images {rl.UnloadImage(image)}
	delete(insp.images)
	for material in insp.textures {for texture in material {delete(texture.info.path)}}
	delete(insp.textures)
	delete(insp.vnrm)
	for name in insp.takes {delete(name)}
	delete(insp.takes)
	delete(insp.take_times)
	for name in insp.material_names {delete(name)}
	delete(insp.material_names)
	delete(insp.pose_scratch)
	insp^ = {}
}
