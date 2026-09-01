// Flat C shim over ufbx, the FBX half of the model viewer.
//
// FBX is a versioned proprietary format (binary node trees with
// deflated arrays, plus an ASCII flavor) carrying skin clusters,
// animation curves, and a transform pyramid with pre/post rotation
// and geometric transforms. ufbx handles all of that; this file
// flattens its scene graph into the triangle-soup arrays the Odin
// viewer already draws, so app/fbx.odin binds six plain procs
// instead of mirroring ufbx's struct layouts.
//
//   fbx_open   → triangulate every mesh instance once, into
//                unit-sphere world-space arrays + the per-vertex
//                skin/material side channels the inspector reads
//   fbx_eval   → pose the skeleton at a time and re-skin into
//                caller-owned buffers (no allocation per frame)
//   fbx_close  → free the scene and every array above
//
// Odin owns nothing here; every pointer handed out lives until
// fbx_close.
#include "ufbx.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// Parse cap, matching STL_MAX_TRIS: a hostile file can't make us
// allocate gigabytes before we notice.
#define FBX_MAX_TRIS 2000000

// The unit-sphere fit covers the animation, not just the rest pose,
// or a model that walks away from the origin drifts out of the tile.
// Sampling costs one full skinning pass per sample at load, so it is
// capped; past that a big model keeps the rest-pose fit.
#define FBX_FIT_SAMPLES 8
#define FBX_FIT_MAX_TRIS 200000

// Per-material channel row handed to the inspector's channel views.
#define FBX_MAT_FLOATS 12

// Layout mirrored by Fbx_Model in app/fbx.odin. Four i32 then only
// pointers, so both sides agree without packing pragmas.
typedef struct fbx_model {
	int32_t num_tris;
	int32_t num_bones;
	int32_t num_anims;
	int32_t num_mats;
	float *pos;    // num_tris*9, rest pose, unit-sphere normalized
	float *nrm;    // num_tris*9, per-vertex normals
	float *uv;     // num_tris*6, zeros when the file carries none
	int32_t *bone; // num_tris*3, dominant cluster, -1 when unskinned
	float *weight; // num_tris*3, that cluster's weight
	int32_t *mat;  // num_tris, index into mats, -1 when unassigned
	float *mats;   // num_mats*FBX_MAT_FLOATS
	int32_t has_uv;
	int32_t has_skin;
} fbx_model;

// One mesh instance: an FBX mesh can hang off several nodes, and each
// placement is its own run of triangles.
typedef struct fbx_part {
	ufbx_node *node;
	ufbx_mesh *mesh;
	ufbx_skin_deformer *skin; // NULL when the instance is static
	int32_t bone_base;        // offset of its clusters in the global table
} fbx_part;

struct fbx_scene {
	ufbx_scene *scene;
	fbx_model model;

	// Skinning inputs, kept in geometry space: eval re-poses these
	// rather than trying to undo the rest-pose world transform.
	float *geo;      // num_tris*9
	float *geo_nrm;  // num_tris*9
	int32_t *vidx;   // num_tris*3, logical vertex index inside the part
	int32_t *tripart; // num_tris, index into parts

	fbx_part *parts;
	int32_t num_parts;

	ufbx_skin_cluster **clusters; // global bone table, parts index into it
	int32_t num_clusters;

	// Per-eval scratch, sized once at open.
	ufbx_matrix *world; // one per scene node
	uint8_t *world_done;
	ufbx_matrix *skin_mat; // one per cluster

	// Unit-sphere fit over the rest pose widened by sampled animation
	// poses (see fit_animation), reused by eval so a take can't make
	// the model jump scale between frames.
	float center[3];
	float radius;
};

typedef struct fbx_scene fbx_scene;

static int32_t eval_raw(fbx_scene *s, int32_t anim_index, double time, float *out_pos, float *out_nrm);
static void fit_animation(fbx_scene *s, float *lo, float *hi);



static float clampf(float v, float lo, float hi)
{
	return v < lo ? lo : (v > hi ? hi : v);
}

// ---------------------------------------------------------------- load

// Dominant influence of a logical vertex: ufbx sorts each vertex's
// weights by decreasing weight, so the first entry is the answer.
static void dominant_weight(const ufbx_skin_deformer *skin, int32_t bone_base,
	size_t vertex, int32_t *out_bone, float *out_weight)
{
	*out_bone = -1;
	*out_weight = 0.0f;
	if (!skin || vertex >= skin->vertices.count) {
		return;
	}
	ufbx_skin_vertex sv = skin->vertices.data[vertex];
	if (sv.num_weights == 0) {
		return;
	}
	ufbx_skin_weight sw = skin->weights.data[sv.weight_begin];
	*out_bone = bone_base + (int32_t)sw.cluster_index;
	*out_weight = (float)sw.weight;
}

// Channel row per material: what the inspector's MATERIAL CHANNELS
// section paints. ufbx normalizes Phong/Lambert/Stingray/glTF
// materials into the same pbr map set, so classic FBX materials
// still answer for metalness and roughness.
static void fill_material(float *row, const ufbx_material *mat)
{
	const ufbx_material_pbr_maps *p = &mat->pbr;
	const ufbx_material_fbx_maps *f = &mat->fbx;

	// Some exports (Maya's aiStandardSurface, notably) leave the pbr
	// base black or zero-weighted while the classic lambert half still
	// carries the real color. A dead pbr base falls back to it.
	ufbx_vec3 base = p->base_color.value_vec3;
	double base_w = p->base_factor.has_value ? p->base_factor.value_real : 1.0;
	int base_dead = base_w == 0.0 || (base.x == 0 && base.y == 0 && base.z == 0);
	if (base_dead && f->diffuse_color.has_value) {
		base = f->diffuse_color.value_vec3;
		double dw = f->diffuse_factor.has_value ? f->diffuse_factor.value_real : 1.0;
		if (dw > 0) {
			base.x *= dw;
			base.y *= dw;
			base.z *= dw;
		}
	}
	row[0] = (float)base.x;
	row[1] = (float)base.y;
	row[2] = (float)base.z;
	row[3] = (float)p->metalness.value_real;
	row[4] = (float)p->roughness.value_real;
	// The emission color means nothing without its weight: Arnold
	// defaults the color to white with the weight at zero.
	double em_w = p->emission_factor.has_value ? p->emission_factor.value_real : 1.0;
	row[5] = (float)(p->emission_color.value_vec3.x * em_w);
	row[6] = (float)(p->emission_color.value_vec3.y * em_w);
	row[7] = (float)(p->emission_color.value_vec3.z * em_w);
	row[8] = (float)p->specular_color.value_vec3.x;
	row[9] = (float)p->specular_color.value_vec3.y;
	row[10] = (float)p->specular_color.value_vec3.z;
	row[11] = (float)p->opacity.value_real;
	for (int i = 0; i < FBX_MAT_FLOATS; i++) {
		row[i] = clampf(row[i], 0.0f, 1.0f);
	}
}

static void fbx_free_arrays(fbx_scene *s)
{
	free(s->model.pos);
	free(s->model.nrm);
	free(s->model.uv);
	free(s->model.bone);
	free(s->model.weight);
	free(s->model.mat);
	free(s->model.mats);
	free(s->geo);
	free(s->geo_nrm);
	free(s->vidx);
	free(s->tripart);
	free(s->parts);
	free(s->clusters);
	free(s->world);
	free(s->world_done);
	free(s->skin_mat);
}

// ------------------------------------------------------- subdivision
//
// The viewer's painter's sort orders whole triangles, so one face
// spanning the model (a display quad, a bezel plate) is either
// entirely in front of or entirely behind everything it overlaps; at
// oblique angles the wrong half wins and a wedge of the far surface
// pokes through. Splitting big triangles at load caps how much area
// one sort decision covers. Skinned parts stay whole: their corners
// carry per-vertex weights a synthesized midpoint doesn't have.
//
// ponytail: still painter's, so truly coplanar sheets and edge-on
// interpenetration can misorder within one piece; the upgrade path
// is a depth buffer.

#define FBX_SPLIT_EDGE2 (0.20f * 0.20f) // max edge^2, unit-sphere space
#define FBX_SPLIT_DEPTH 6               // <= 64 pieces per triangle
#define FBX_SPLIT_GROW 300000           // added-triangle budget

// One triangle with every per-corner side channel the arrays carry.
typedef struct tri_rec {
	float pos[9], nrm[9], uv[6], geo[9], geon[9], weight[3];
	int32_t bone[3], vidx[3];
} tri_rec;

// Longest edge by rendered position, or -1 when every edge fits.
static int longest_edge(const tri_rec *t)
{
	int best = -1;
	float most = FBX_SPLIT_EDGE2;
	for (int e = 0; e < 3; e++) {
		const float *a = &t->pos[e * 3], *b = &t->pos[((e + 1) % 3) * 3];
		float d0 = a[0] - b[0], d1 = a[1] - b[1], d2 = a[2] - b[2];
		float l2 = d0 * d0 + d1 * d1 + d2 * d2;
		if (l2 > most) {
			most = l2;
			best = e;
		}
	}
	return best;
}

static void corner_mid(const tri_rec *t, int i, int j, tri_rec *out, int k)
{
	for (int a = 0; a < 3; a++) {
		out->pos[k * 3 + a] = (t->pos[i * 3 + a] + t->pos[j * 3 + a]) * 0.5f;
		out->geo[k * 3 + a] = (t->geo[i * 3 + a] + t->geo[j * 3 + a]) * 0.5f;
		out->nrm[k * 3 + a] = (t->nrm[i * 3 + a] + t->nrm[j * 3 + a]) * 0.5f;
		out->geon[k * 3 + a] = (t->geon[i * 3 + a] + t->geon[j * 3 + a]) * 0.5f;
	}
	for (int a = 0; a < 2; a++) {
		out->uv[k * 2 + a] = (t->uv[i * 2 + a] + t->uv[j * 2 + a]) * 0.5f;
	}
	out->bone[k] = t->bone[i];
	out->weight[k] = (t->weight[i] + t->weight[j]) * 0.5f;
	out->vidx[k] = t->vidx[i];
}

static void corner_copy(const tri_rec *t, int i, tri_rec *out, int k)
{
	memcpy(&out->pos[k * 3], &t->pos[i * 3], 3 * sizeof(float));
	memcpy(&out->geo[k * 3], &t->geo[i * 3], 3 * sizeof(float));
	memcpy(&out->nrm[k * 3], &t->nrm[i * 3], 3 * sizeof(float));
	memcpy(&out->geon[k * 3], &t->geon[i * 3], 3 * sizeof(float));
	memcpy(&out->uv[k * 2], &t->uv[i * 2], 2 * sizeof(float));
	out->bone[k] = t->bone[i];
	out->weight[k] = t->weight[i];
	out->vidx[k] = t->vidx[i];
}

// Walk one triangle, splitting its longest edge until every piece
// fits, and either count the leaves or emit them through `sink`.
struct split_sink {
	fbx_model *m;
	fbx_scene *s;
	size_t at;
	int32_t part, mat;
};

static void emit_leaf(struct split_sink *k, const tri_rec *t)
{
	size_t at = k->at++;
	memcpy(&k->m->pos[at * 9], t->pos, 9 * sizeof(float));
	memcpy(&k->m->nrm[at * 9], t->nrm, 9 * sizeof(float));
	memcpy(&k->m->uv[at * 6], t->uv, 6 * sizeof(float));
	memcpy(&k->m->bone[at * 3], t->bone, 3 * sizeof(int32_t));
	memcpy(&k->m->weight[at * 3], t->weight, 3 * sizeof(float));
	k->m->mat[at] = k->mat;
	memcpy(&k->s->geo[at * 9], t->geo, 9 * sizeof(float));
	memcpy(&k->s->geo_nrm[at * 9], t->geon, 9 * sizeof(float));
	memcpy(&k->s->vidx[at * 3], t->vidx, 3 * sizeof(int32_t));
	k->s->tripart[at] = k->part;
}

static size_t split_walk(const tri_rec *t, int depth, struct split_sink *sink)
{
	int e = depth < FBX_SPLIT_DEPTH ? longest_edge(t) : -1;
	if (e < 0) {
		if (sink) {
			emit_leaf(sink, t);
		}
		return 1;
	}
	int i = e, j = (e + 1) % 3, o = (e + 2) % 3;
	tri_rec a, b;
	// (i, mid, o) and (mid, j, o) keep the winding.
	corner_copy(t, i, &a, 0);
	corner_mid(t, i, j, &a, 1);
	corner_copy(t, o, &a, 2);
	corner_mid(t, i, j, &b, 0);
	corner_copy(t, j, &b, 1);
	corner_copy(t, o, &b, 2);
	return split_walk(&a, depth + 1, sink) + split_walk(&b, depth + 1, sink);
}

static void gather_tri(const fbx_scene *s, size_t tri, tri_rec *t)
{
	const fbx_model *m = &s->model;
	memcpy(t->pos, &m->pos[tri * 9], 9 * sizeof(float));
	memcpy(t->nrm, &m->nrm[tri * 9], 9 * sizeof(float));
	memcpy(t->uv, &m->uv[tri * 6], 6 * sizeof(float));
	memcpy(t->bone, &m->bone[tri * 3], 3 * sizeof(int32_t));
	memcpy(t->weight, &m->weight[tri * 3], 3 * sizeof(float));
	memcpy(t->geo, &s->geo[tri * 9], 9 * sizeof(float));
	memcpy(t->geon, &s->geo_nrm[tri * 9], 9 * sizeof(float));
	memcpy(t->vidx, &s->vidx[tri * 3], 3 * sizeof(int32_t));
}

static void subdivide_big_tris(fbx_scene *s)
{
	fbx_model *m = &s->model;
	size_t ntri = (size_t)m->num_tris;

	size_t total = 0;
	for (size_t i = 0; i < ntri; i++) {
		tri_rec t;
		if (s->parts[s->tripart[i]].skin) {
			total += 1;
			continue;
		}
		gather_tri(s, i, &t);
		total += split_walk(&t, 0, NULL);
	}
	if (total == ntri || total > (size_t)FBX_MAX_TRIS || total > ntri + FBX_SPLIT_GROW) {
		return;
	}

	fbx_model nm = *m;
	fbx_scene ns = *s;
	nm.pos = (float *)calloc(total * 9, sizeof(float));
	nm.nrm = (float *)calloc(total * 9, sizeof(float));
	nm.uv = (float *)calloc(total * 6, sizeof(float));
	nm.bone = (int32_t *)calloc(total * 3, sizeof(int32_t));
	nm.weight = (float *)calloc(total * 3, sizeof(float));
	nm.mat = (int32_t *)calloc(total, sizeof(int32_t));
	ns.geo = (float *)calloc(total * 9, sizeof(float));
	ns.geo_nrm = (float *)calloc(total * 9, sizeof(float));
	ns.vidx = (int32_t *)calloc(total * 3, sizeof(int32_t));
	ns.tripart = (int32_t *)calloc(total, sizeof(int32_t));
	if (!nm.pos || !nm.nrm || !nm.uv || !nm.bone || !nm.weight || !nm.mat ||
		!ns.geo || !ns.geo_nrm || !ns.vidx || !ns.tripart) {
		free(nm.pos); free(nm.nrm); free(nm.uv); free(nm.bone);
		free(nm.weight); free(nm.mat);
		free(ns.geo); free(ns.geo_nrm); free(ns.vidx); free(ns.tripart);
		return; // out of memory: keep the unsplit model
	}

	struct split_sink sink = {&nm, &ns, 0, 0, 0};
	for (size_t i = 0; i < ntri; i++) {
		tri_rec t;
		gather_tri(s, i, &t);
		sink.part = s->tripart[i];
		sink.mat = m->mat[i];
		if (s->parts[sink.part].skin) {
			emit_leaf(&sink, &t);
			continue;
		}
		split_walk(&t, 0, &sink);
	}

	free(m->pos); free(m->nrm); free(m->uv); free(m->bone);
	free(m->weight); free(m->mat);
	free(s->geo); free(s->geo_nrm); free(s->vidx); free(s->tripart);
	m->pos = nm.pos; m->nrm = nm.nrm; m->uv = nm.uv; m->bone = nm.bone;
	m->weight = nm.weight; m->mat = nm.mat;
	s->geo = ns.geo; s->geo_nrm = ns.geo_nrm; s->vidx = ns.vidx; s->tripart = ns.tripart;
	m->num_tris = (int32_t)sink.at;
}

fbx_scene *fbx_open(const void *data, size_t len)
{
	ufbx_load_opts opts = {0};
	// Y-up right-handed metres, matching the viewer's own axes, and
	// no external or embedded content: an attachment must never make
	// the app touch the filesystem or decode a texture.
	opts.target_axes = ufbx_axes_right_handed_y_up;
	opts.target_unit_meters = 1.0f;
	opts.generate_missing_normals = true;
	opts.load_external_files = false;
	opts.ignore_embedded = true;

	ufbx_error error;
	ufbx_scene *scene = ufbx_load_memory(data, len, &opts, &error);
	if (!scene) {
		return NULL;
	}

	fbx_scene *s = (fbx_scene *)calloc(1, sizeof(fbx_scene));
	if (!s) {
		ufbx_free_scene(scene);
		return NULL;
	}
	s->scene = scene;

	// Pass 1: collect mesh instances, count triangles and clusters.
	size_t ntri = 0;
	int32_t nclusters = 0;
	for (size_t i = 0; i < scene->nodes.count; i++) {
		ufbx_node *node = scene->nodes.data[i];
		if (node->is_root || !node->mesh) {
			continue;
		}
		ntri += node->mesh->num_triangles;
	}
	if (ntri == 0 || ntri > FBX_MAX_TRIS) {
		ufbx_free_scene(scene);
		free(s);
		return NULL;
	}

	s->parts = (fbx_part *)calloc(scene->nodes.count, sizeof(fbx_part));
	s->clusters = (ufbx_skin_cluster **)calloc(scene->skin_clusters.count + 1, sizeof(ufbx_skin_cluster *));
	if (!s->parts || !s->clusters) {
		fbx_free_arrays(s);
		ufbx_free_scene(scene);
		free(s);
		return NULL;
	}

	for (size_t i = 0; i < scene->nodes.count; i++) {
		ufbx_node *node = scene->nodes.data[i];
		if (node->is_root || !node->mesh) {
			continue;
		}
		fbx_part *part = &s->parts[s->num_parts++];
		part->node = node;
		part->mesh = node->mesh;
		part->bone_base = nclusters;
		if (node->mesh->skin_deformers.count > 0) {
			part->skin = node->mesh->skin_deformers.data[0];
			for (size_t c = 0; c < part->skin->clusters.count; c++) {
				s->clusters[nclusters++] = part->skin->clusters.data[c];
			}
		}
	}
	s->num_clusters = nclusters;

	// Pass 2: triangulate into the flat arrays.
	fbx_model *m = &s->model;
	m->num_tris = (int32_t)ntri;
	m->num_bones = nclusters;
	m->num_anims = (int32_t)scene->anim_stacks.count;
	m->num_mats = (int32_t)scene->materials.count;
	m->pos = (float *)calloc(ntri * 9, sizeof(float));
	m->nrm = (float *)calloc(ntri * 9, sizeof(float));
	m->uv = (float *)calloc(ntri * 6, sizeof(float));
	m->bone = (int32_t *)calloc(ntri * 3, sizeof(int32_t));
	m->weight = (float *)calloc(ntri * 3, sizeof(float));
	m->mat = (int32_t *)calloc(ntri, sizeof(int32_t));
	m->mats = (float *)calloc((size_t)(m->num_mats + 1) * FBX_MAT_FLOATS, sizeof(float));
	s->geo = (float *)calloc(ntri * 9, sizeof(float));
	s->geo_nrm = (float *)calloc(ntri * 9, sizeof(float));
	s->vidx = (int32_t *)calloc(ntri * 3, sizeof(int32_t));
	s->tripart = (int32_t *)calloc(ntri, sizeof(int32_t));
	s->world = (ufbx_matrix *)calloc(scene->nodes.count + 1, sizeof(ufbx_matrix));
	s->world_done = (uint8_t *)calloc(scene->nodes.count + 1, 1);
	s->skin_mat = (ufbx_matrix *)calloc((size_t)nclusters + 1, sizeof(ufbx_matrix));
	if (!m->pos || !m->nrm || !m->uv || !m->bone || !m->weight || !m->mat || !m->mats ||
		!s->geo || !s->geo_nrm || !s->vidx || !s->tripart || !s->world || !s->world_done || !s->skin_mat) {
		fbx_free_arrays(s);
		ufbx_free_scene(scene);
		free(s);
		return NULL;
	}

	for (int32_t i = 0; i < m->num_mats; i++) {
		fill_material(&m->mats[(size_t)i * FBX_MAT_FLOATS], scene->materials.data[i]);
	}

	size_t tri = 0;
	for (int32_t pi = 0; pi < s->num_parts; pi++) {
		fbx_part *part = &s->parts[pi];
		ufbx_mesh *mesh = part->mesh;
		ufbx_matrix geo_to_world = part->node->geometry_to_world;
		ufbx_matrix nrm_matrix = ufbx_get_compatible_matrix_for_normals(part->node);

		uint32_t *corners = (uint32_t *)malloc(mesh->max_face_triangles * 3 * sizeof(uint32_t));
		if (!corners) {
			continue;
		}
		for (size_t f = 0; f < mesh->faces.count; f++) {
			ufbx_face face = mesh->faces.data[f];
			uint32_t tris = ufbx_triangulate_face(corners, mesh->max_face_triangles * 3, mesh, face);
			int32_t material = -1;
			if (f < mesh->face_material.count) {
				uint32_t local = mesh->face_material.data[f];
				if (local < mesh->materials.count && mesh->materials.data[local]) {
					material = (int32_t)mesh->materials.data[local]->typed_id;
				}
			}

			for (uint32_t t = 0; t < tris; t++) {
				if (tri >= ntri) {
					break; // num_triangles is a promise; don't trust it blindly
				}
				s->tripart[tri] = pi;
				m->mat[tri] = material;

				for (int k = 0; k < 3; k++) {
					uint32_t ix = corners[t * 3 + k];
					size_t at = tri * 9 + (size_t)k * 3;

					ufbx_vec3 p = ufbx_get_vertex_vec3(&mesh->vertex_position, ix);
					s->geo[at] = (float)p.x;
					s->geo[at + 1] = (float)p.y;
					s->geo[at + 2] = (float)p.z;
					ufbx_vec3 wp = ufbx_transform_position(&geo_to_world, p);
					m->pos[at] = (float)wp.x;
					m->pos[at + 1] = (float)wp.y;
					m->pos[at + 2] = (float)wp.z;

					ufbx_vec3 n = {0, 0, 1};
					if (mesh->vertex_normal.exists) {
						n = ufbx_get_vertex_vec3(&mesh->vertex_normal, ix);
					}
					s->geo_nrm[at] = (float)n.x;
					s->geo_nrm[at + 1] = (float)n.y;
					s->geo_nrm[at + 2] = (float)n.z;
					ufbx_vec3 wn = ufbx_transform_direction(&nrm_matrix, n);
					m->nrm[at] = (float)wn.x;
					m->nrm[at + 1] = (float)wn.y;
					m->nrm[at + 2] = (float)wn.z;

					size_t corner = tri * 3 + (size_t)k;
					if (mesh->vertex_uv.exists) {
						ufbx_vec2 uv = ufbx_get_vertex_vec2(&mesh->vertex_uv, ix);
						m->uv[corner * 2] = (float)uv.x;
						m->uv[corner * 2 + 1] = (float)uv.y;
						m->has_uv = 1;
					}

					uint32_t vertex = mesh->vertex_indices.data[ix];
					s->vidx[corner] = (int32_t)vertex;
					dominant_weight(part->skin, part->bone_base, vertex, &m->bone[corner], &m->weight[corner]);
					if (part->skin) {
						m->has_skin = 1;
					}
				}
				tri++;
			}
		}
		free(corners);
	}
	m->num_tris = (int32_t)tri;

	// Unit-sphere fit over the rest pose, the same normalization the
	// STL/OBJ path applies in Odin, widened to hold every sampled
	// animation pose so playback stays inside the tile.
	float lo[3] = {INFINITY, INFINITY, INFINITY};
	float hi[3] = {-INFINITY, -INFINITY, -INFINITY};
	for (size_t i = 0; i < (size_t)m->num_tris * 3; i++) {
		for (int a = 0; a < 3; a++) {
			float v = m->pos[i * 3 + a];
			lo[a] = v < lo[a] ? v : lo[a];
			hi[a] = v > hi[a] ? v : hi[a];
		}
	}
	fit_animation(s, lo, hi);
	for (size_t i = 0; i < (size_t)m->num_tris * 3; i++) {
		for (int a = 0; a < 3; a++) {
			m->pos[i * 3 + a] = (m->pos[i * 3 + a] - s->center[a]) / s->radius;
		}
	}

	return s;
}

const fbx_model *fbx_model_of(fbx_scene *s)
{
	return s ? &s->model : NULL;
}

// ------------------------------------------------------------ animation

const char *fbx_anim_name(fbx_scene *s, int32_t index)
{
	if (!s || index < 0 || (size_t)index >= s->scene->anim_stacks.count) {
		return "";
	}
	return s->scene->anim_stacks.data[index]->name.data;
}

double fbx_anim_begin(fbx_scene *s, int32_t index)
{
	if (!s || index < 0 || (size_t)index >= s->scene->anim_stacks.count) {
		return 0.0;
	}
	return s->scene->anim_stacks.data[index]->time_begin;
}

double fbx_anim_end(fbx_scene *s, int32_t index)
{
	if (!s || index < 0 || (size_t)index >= s->scene->anim_stacks.count) {
		return 0.0;
	}
	return s->scene->anim_stacks.data[index]->time_end;
}

// Node-to-world at `time`, memoized per eval. Recursive rather than a
// single ordered pass so nothing depends on scene->nodes ordering;
// bone chains are shallow, so the depth is a non-issue.
static ufbx_matrix node_world(fbx_scene *s, const ufbx_anim *anim, ufbx_node *node, double time)
{
	uint32_t id = node->typed_id;
	if (s->world_done[id]) {
		return s->world[id];
	}
	// Mark before recursing: a malformed file with a parent cycle
	// then resolves to identity instead of blowing the stack.
	s->world_done[id] = 1;
	s->world[id] = ufbx_identity_matrix;

	ufbx_transform local = ufbx_evaluate_transform(anim, node, time);
	ufbx_matrix m = ufbx_transform_to_matrix(&local);
	if (node->parent) {
		ufbx_matrix parent = node_world(s, anim, node->parent, time);
		m = ufbx_matrix_mul(&parent, &m);
	}
	s->world[id] = m;
	return m;
}

// Pose the skeleton at `time` and skin into caller-owned buffers,
// each num_tris*9 floats. Returns 0 when the arguments don't fit.
//
// ponytail: linear blend skinning only, and normals ride the same
// matrix (correct for rigid bones, off under non-uniform scale).
// Dual-quaternion blending is the upgrade if a file needs it.
int32_t fbx_eval(fbx_scene *s, int32_t anim_index, double time, float *out_pos, float *out_nrm)
{
	if (!s || !out_pos || !out_nrm) {
		return 0;
	}
	if (anim_index < 0 || (size_t)anim_index >= s->scene->anim_stacks.count) {
		memcpy(out_pos, s->model.pos, (size_t)s->model.num_tris * 9 * sizeof(float));
		memcpy(out_nrm, s->model.nrm, (size_t)s->model.num_tris * 9 * sizeof(float));
		return 1;
	}
	if (!eval_raw(s, anim_index, time, out_pos, out_nrm)) {
		return 0;
	}
	// Same fit the rest pose went through, so a take can't change scale.
	for (size_t i = 0; i < (size_t)s->model.num_tris * 3; i++) {
		for (int a = 0; a < 3; a++) {
			out_pos[i * 3 + a] = (out_pos[i * 3 + a] - s->center[a]) / s->radius;
		}
	}
	return 1;
}

// Skinned world-space positions, before the unit-sphere fit; the fit
// itself is derived from these at load.
static int32_t eval_raw(fbx_scene *s, int32_t anim_index, double time, float *out_pos, float *out_nrm)
{

	const ufbx_anim *anim = s->scene->anim_stacks.data[anim_index]->anim;
	memset(s->world_done, 0, s->scene->nodes.count + 1);

	for (int32_t c = 0; c < s->num_clusters; c++) {
		ufbx_skin_cluster *cluster = s->clusters[c];
		if (!cluster->bone_node) {
			s->skin_mat[c] = ufbx_identity_matrix;
			continue;
		}
		ufbx_matrix bone = node_world(s, anim, cluster->bone_node, time);
		s->skin_mat[c] = ufbx_matrix_mul(&bone, &cluster->geometry_to_bone);
	}

	for (int32_t tri = 0; tri < s->model.num_tris; tri++) {
		fbx_part *part = &s->parts[s->tripart[tri]];
		ufbx_matrix node_matrix = node_world(s, anim, part->node, time);
		ufbx_matrix static_matrix = ufbx_matrix_mul(&node_matrix, &part->node->geometry_to_node);

		for (int k = 0; k < 3; k++) {
			size_t at = (size_t)tri * 9 + (size_t)k * 3;
			ufbx_matrix m = static_matrix;

			// Weighted blend of the influencing clusters; an
			// unweighted vertex rides the mesh node itself.
			const ufbx_skin_deformer *skin = part->skin;
			size_t vertex = (size_t)s->vidx[(size_t)tri * 3 + (size_t)k];
			if (skin && vertex < skin->vertices.count && skin->vertices.data[vertex].num_weights > 0) {
				ufbx_skin_vertex sv = skin->vertices.data[vertex];
				ufbx_matrix acc = {0};
				double total = 0.0;
				for (uint32_t w = 0; w < sv.num_weights; w++) {
					ufbx_skin_weight sw = skin->weights.data[sv.weight_begin + w];
					const ufbx_matrix *cm = &s->skin_mat[part->bone_base + (int32_t)sw.cluster_index];
					for (int col = 0; col < 4; col++) {
						for (int row = 0; row < 3; row++) {
							acc.v[col * 3 + row] += cm->v[col * 3 + row] * sw.weight;
						}
					}
					total += sw.weight;
				}
				if (total > 0.0) {
					for (int e = 0; e < 12; e++) {
						acc.v[e] /= total;
					}
					m = acc;
				}
			}

			ufbx_vec3 p = {s->geo[at], s->geo[at + 1], s->geo[at + 2]};
			ufbx_vec3 wp = ufbx_transform_position(&m, p);
			out_pos[at] = (float)wp.x;
			out_pos[at + 1] = (float)wp.y;
			out_pos[at + 2] = (float)wp.z;

			ufbx_vec3 n = {s->geo_nrm[at], s->geo_nrm[at + 1], s->geo_nrm[at + 2]};
			ufbx_vec3 wn = ufbx_transform_direction(&m, n);
			float length = sqrtf((float)(wn.x * wn.x + wn.y * wn.y + wn.z * wn.z));
			if (!(length > 0.0f)) {
				length = 1.0f;
			}
			out_nrm[at] = (float)wn.x / length;
			out_nrm[at + 1] = (float)wn.y / length;
			out_nrm[at + 2] = (float)wn.z / length;
		}
	}
	return 1;
}

// Widen (lo, hi) to cover the first take, sampled evenly across its
// time range, then store the final center/radius. Skipped for scenes
// with no animation or too many triangles to sample cheaply.
static void fit_animation(fbx_scene *s, float *lo, float *hi)
{
	fbx_model *m = &s->model;
	if (s->scene->anim_stacks.count > 0 && m->num_tris <= FBX_FIT_MAX_TRIS) {
		float *scratch_pos = (float *)malloc((size_t)m->num_tris * 9 * sizeof(float));
		float *scratch_nrm = (float *)malloc((size_t)m->num_tris * 9 * sizeof(float));
		if (scratch_pos && scratch_nrm) {
			ufbx_anim_stack *stack = s->scene->anim_stacks.data[0];
			for (int sample = 0; sample < FBX_FIT_SAMPLES; sample++) {
				double t = stack->time_begin +
					(stack->time_end - stack->time_begin) * ((double)sample / (FBX_FIT_SAMPLES - 1));
				if (!eval_raw(s, 0, t, scratch_pos, scratch_nrm)) {
					break;
				}
				for (size_t i = 0; i < (size_t)m->num_tris * 3; i++) {
					for (int a = 0; a < 3; a++) {
						float v = scratch_pos[i * 3 + a];
						lo[a] = v < lo[a] ? v : lo[a];
						hi[a] = v > hi[a] ? v : hi[a];
					}
				}
			}
		}
		free(scratch_pos);
		free(scratch_nrm);
	}

	float d[3];
	for (int a = 0; a < 3; a++) {
		s->center[a] = (lo[a] + hi[a]) * 0.5f;
		d[a] = hi[a] - lo[a];
	}
	s->radius = sqrtf(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]) * 0.5f;
	if (!(s->radius > 0.0f)) {
		s->radius = 1.0f;
	}
}

void fbx_close(fbx_scene *s)
{
	if (!s) {
		return;
	}
	fbx_free_arrays(s);
	ufbx_free_scene(s->scene);
	free(s);
}
