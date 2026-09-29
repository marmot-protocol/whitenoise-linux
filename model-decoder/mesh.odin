package main

// Parser-owned data only: no UI, image decoder, or rendering dependencies.
Mesh :: struct {
	tris, vnrm, uv: []f32,
	segments:       []f32,
	mat:            []i32,
	mats:           []f32,
	textures:       [][Mesh_Channel]Mesh_Texture,
	images:         [dynamic][]u8,
}
Mesh_Channel :: enum {
	Base_Color,
	Metalness,
	Roughness,
	Emission,
	Specular,
	Normal,
}
Mesh_Texture :: struct {
	image:            i32, // one-based encoded image index; zero means unavailable
	uv:               [6]f32,
	tint:             [4]f32,
	clamp_u, clamp_v: i32,
	pixels:           enum {
		Color,
		Smoothness,
		Green,
		Blue,
	},
	alpha:            enum {
		From_Image,
		Opaque,
		Mask,
	},
	alpha_cutoff:     f32,
}
FBX_MAT_FLOATS :: 12
FBX_TEXTURE_BYTES :: 256 * 1024 * 1024
MESH_MAX_MATERIALS :: 65536
MESH_MAX_IMAGES :: 4096
mesh_free :: proc(mesh: ^Mesh) {
	if mesh == nil {return}
	delete(mesh.tris)
	delete(mesh.segments)
	delete(mesh.vnrm)
	delete(mesh.uv)
	delete(mesh.mat)
	delete(mesh.mats)
	delete(mesh.textures)
	for bytes in mesh.images {delete(bytes)}
	delete(mesh.images)
	free(mesh)
}
