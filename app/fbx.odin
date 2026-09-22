// FBX models: bindings for app/fbx_shim.c (ufbx behind a flat C API,
// built into build/libwnfbx.a by scripts/build.sh) plus the inspector state a
// mesh view carries.
//
// An FBX file lands in the same Stl_View the STL/OBJ path uses, so
// orbit, painter's sort, and the draw call are shared. What FBX adds
// rides in Inspect: per-vertex normals and UVs, skin weights, material
// channels, and the animation takes the chooser lists. Static formats
// leave those nil and simply show fewer inspector rows.
//
//   parse_fbx  → shim triangulates once → Stl_View + Inspect
//   fbx_pose   → per frame while playing: re-skin into view.tris
//                (the shim writes into our buffers, no allocation)
package main

import "core:c"
import "core:strings"

import rl "sdlrl"

foreign import fbxlib {"../build/libwnfbx.a", "system:m", "system:stdc++"}

// Mirrors `struct fbx_model` in app/fbx_shim.c: four i32, then only
// pointers, then two i32. Every array is owned by the C side and
// lives until fbx_close.
Fbx_Model :: struct {
	num_tris:  i32,
	num_bones: i32,
	num_anims: i32,
	num_mats:  i32,
	pos:       [^]f32, // num_tris*9, rest pose, unit-sphere normalized
	nrm:       [^]f32, // num_tris*9
	uv:        [^]f32, // num_tris*6
	bone:      [^]i32, // num_tris*3, dominant cluster or -1
	weight:    [^]f32, // num_tris*3
	mat:       [^]i32, // num_tris, index into mats or -1
	mats:      [^]f32, // num_mats*FBX_MAT_FLOATS
	has_uv:    i32,
	has_skin:  i32,
}

FBX_MAT_FLOATS :: 12 // base rgb, metal, rough, emission rgb, specular rgb, opacity

@(default_calling_convention = "c")
foreign fbxlib {
	@(private)
	fbx_texture_of :: proc(scene: rawptr, material: i32, channel: Fbx_Channel, out: ^Fbx_Texture_Info) -> i32 ---
	@(private)
	fbx_material_name :: proc(scene: rawptr, material: i32) -> cstring ---
	fbx_open :: proc(data: rawptr, len: c.size_t) -> rawptr ---
	fbx_model_of :: proc(scene: rawptr) -> ^Fbx_Model ---
	fbx_anim_name :: proc(scene: rawptr, index: i32) -> cstring ---
	fbx_anim_begin :: proc(scene: rawptr, index: i32) -> f64 ---
	fbx_anim_end :: proc(scene: rawptr, index: i32) -> f64 ---
	fbx_eval :: proc(scene: rawptr, anim: i32, time: f64, out_pos: [^]f32, out_nrm: [^]f32) -> i32 ---
	fbx_close :: proc(scene: rawptr) ---
}

// What the Model Inspector paints. Every mode works on any mesh; the
// ones that need data the format doesn't carry (skin weights, UVs,
// materials) are listed as unavailable rather than hidden, so the
// panel doesn't reshuffle between files.
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

// Overlay geometry (wireframe, vertex normals) is built as thin quads
// in the same vertex buffer the model uses, so it costs one extra
// draw call and no new renderer path.
// ponytail: 18 verts per triangle for the wireframe; past this many
// triangles the overlay rows go unavailable rather than stalling the
// frame. A real line renderer is the upgrade.
WIRE_MAX_TRIS :: 60_000

// Inspector state carried by every mesh view. The C-owned slices are
// nil for STL/OBJ.
Inspect :: struct {
	mode:         Render_Mode,
	wire:         int, // wireframe overlay color index, -1 = off
	single_sided: bool,

	// FBX side channels, pointing into shim memory.
	scene:        rawptr, // ^fbx_scene, nil for STL/OBJ
	vnrm:         []f32, // ntri*9 per-vertex normals, Odin-owned (posed)
	uv:           []f32, // ntri*6
	bone:         []i32, // ntri*3 dominant cluster
	bwt:          []f32, // ntri*3 its weight
	mat:          []i32, // ntri material index
	mats:         []f32, // nmat*FBX_MAT_FLOATS
	nbones:       int,
	textures:     [][Fbx_Channel]Fbx_Texture,
	images:       [dynamic]rl.Image, // decoded archive textures, owned and shared by materials

	// Animation chooser: -1 is the rest pose, otherwise a take index.
	anim:         int,
	takes:        []string, // owned names, one per take
	t0:           f64,
	t1:           f64,
	time:         f64,
	playing:      bool,
	posed:        bool, // tris hold a posed frame, not the rest pose
}

// Parse an FBX file into the shared mesh view. The triangle buffer is
// copied out of the shim so posing can write into it; the read-only
// side channels stay borrowed.
parse_fbx :: proc(data: []u8) -> (^Stl_View, bool) {
	scene := fbx_open(raw_data(data), c.size_t(len(data)))
	if scene == nil {
		return nil, false
	}
	model := fbx_model_of(scene)
	ntri := int(model.num_tris)
	if ntri <= 0 {
		fbx_close(scene)
		return nil, false
	}

	tris := make([]f32, ntri * 9)
	copy(tris, model.pos[:ntri * 9])
	view := stl_view_make(tris)

	vnrm := make([]f32, ntri * 9)
	copy(vnrm, model.nrm[:ntri * 9])

	takes := make([]string, int(model.num_anims))
	for i in 0 ..< len(takes) {
		takes[i] = strings.clone_from_cstring(fbx_anim_name(scene, i32(i)))
	}

	view.insp = Inspect {
		wire   = -1,
		scene  = scene,
		vnrm   = vnrm,
		uv     = model.has_uv != 0 ? model.uv[:ntri * 6] : nil,
		bone   = model.has_skin != 0 ? model.bone[:ntri * 3] : nil,
		bwt    = model.has_skin != 0 ? model.weight[:ntri * 3] : nil,
		mat    = model.num_mats > 0 ? model.mat[:ntri] : nil,
		mats   = model.num_mats > 0 ? model.mats[:int(model.num_mats) * FBX_MAT_FLOATS] : nil,
		nbones = int(model.num_bones),
		takes  = takes,
		anim   = -1,
	}
	// Open on the first take so a rigged model moves without hunting
	// through the panel first.
	if len(takes) > 0 {
		fbx_select_take(view, 0)
		view.insp.playing = true
	}
	return view, true
}

// Point the chooser at a take (or -1 for the rest pose) and rewind to
// its start.
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
	insp.t0 = fbx_anim_begin(insp.scene, i32(take))
	insp.t1 = fbx_anim_end(insp.scene, i32(take))
	if insp.t1 <= insp.t0 {
		insp.t1 = insp.t0 + 1
	}
	insp.time = insp.t0
	fbx_pose(view, insp.t0)
}

// Skin the mesh at `time` straight into the view's own buffers, then
// invalidate the rotation caches so the next frame redraws it.
fbx_pose :: proc(view: ^Stl_View, time: f64) {
	insp := &view.insp
	if insp.scene == nil {
		return
	}
	if fbx_eval(insp.scene, i32(insp.anim), time, raw_data(view.tris), raw_data(insp.vnrm)) == 0 {
		return
	}
	insp.posed = insp.anim >= 0
	stl_face_normals(view)
	view.dirty = true
	view.built = {} // force the vertex buffer to rebuild
}

// Advance every playing model view by the frame delta, looping inside
// the take's own time range. Called once per frame from the app loop.
advance_models :: proc(dt: f32) {
	for view in playing_models {
		insp := &view.insp
		if !insp.playing || insp.anim < 0 {
			continue
		}
		anim_moving += 1
		insp.time += f64(dt)
		if insp.time > insp.t1 {
			insp.time = insp.t0 + (insp.time - insp.t1)
		}
		fbx_pose(view, insp.time)
	}
	clear(&playing_models)
}

// Views that asked to animate this frame, refilled during the layout
// build (only mounted tiles animate; a scrolled-away model costs
// nothing).
playing_models: [dynamic]^Stl_View

fbx_free :: proc(insp: ^Inspect) {
	if insp.scene == nil {
		return
	}
	// uv/bone/bwt/mat/mats are shim memory, released by fbx_close.
	fbx_close(insp.scene)
	for image in insp.images {
		rl.UnloadImage(image)
	}
	delete(insp.images)
	delete(insp.textures)
	delete(insp.vnrm)
	for name in insp.takes {
		delete(name)
	}
	delete(insp.takes)
	insp^ = {}
}
