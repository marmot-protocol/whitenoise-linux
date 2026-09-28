#ifndef WN_FBX_SHIM_H
#define WN_FBX_SHIM_H
#include <stdint.h>
#include <stddef.h>
#define FBX_MAX_TRIS 2000000
#define FBX_MAT_FLOATS 12
#define FBX_MAX_ITEMS 65536
#define FBX_MAX_STRING 4096
enum fbx_channel {
    FBX_BASE_COLOR,
    FBX_METALNESS,
    FBX_ROUGHNESS,
    FBX_EMISSION,
    FBX_SPECULAR,
    FBX_NORMAL,
    FBX_CHANNEL_COUNT,
};

typedef struct fbx_scene fbx_scene;
typedef struct fbx_model {
    int32_t num_tris, num_bones, num_anims, num_mats;
    float *pos, *nrm, *uv;
    int32_t *bone;
    float *weight;
    int32_t *mat;
    float *mats;
    int32_t has_uv, has_skin;
} fbx_model;
typedef struct fbx_texture_info {
    const char *path;
    float uv[6], tint[4];
    int32_t clamp_u, clamp_v;
} fbx_texture_info;
fbx_scene *fbx_open(const void *data, size_t len);
const fbx_model *fbx_model_of(fbx_scene *s);
const char *fbx_material_name(fbx_scene *s, int32_t material);
int32_t fbx_texture_of(fbx_scene *s, int32_t material, int32_t channel, fbx_texture_info *out);
const char *fbx_anim_name(fbx_scene *s, int32_t index);
double fbx_anim_begin(fbx_scene *s, int32_t index);
double fbx_anim_end(fbx_scene *s, int32_t index);
int32_t fbx_eval(fbx_scene *s, int32_t anim, double time, float *pos, float *nrm);
void fbx_close(fbx_scene *s);
#endif
