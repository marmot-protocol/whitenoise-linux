/* Persistent FBX decoder: only flat little-endian messages leave this process.
 * OPEN payload: FBM1,u32 triangles,bones,takes,materials,flags,reserved=0,0;
 * f32 positions[9T],normals[9T], UV[6T] if flags&1;
 * i32 bones[3T],f32 weights[3T] if flags&2;
 * i32 materials[T] (if M>0), f32 material_channels[12M];
 * takes: f64 begin,end,string name; materials: string name, six textures.
 * Texture: i32 reference(-1/0/1),u32 clamp_u,clamp_v,f32 uv[6],tint[4],string path.
 * String: u32 byte count followed by UTF-8, no terminator, at most 4096 bytes.
 * POSE request: i32 take (-1=rest),f64 time. Reply: FBP1,u32 T,pos[9T],nrm[9T].
 * Counts <=65536 (triangles <=2000000), flags use only bits 0..1.
 * Envelope: FBI1,u32 operation,size,sequence (starts at 1, no wrap);
 * FBO1,u32 operation,sequence,size. Source <=128MiB, payload <=512MiB.
 * Link: cc -O2 -Ivendor/ufbx app/fbx_helper.c app/fbx_shim.c build/fbx/ufbx.o -lm -o build/wn-fbx
 */
#include "decoder_limits.h"
#include "fbx_shim.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    unsigned char *data;
    size_t size, capacity;
    int ok;
} Writer;
static void bytes(Writer *w, const void *p, size_t n) {
    if (!w->ok || n > WN_MODEL_OUTPUT_MAX - w->size || (w->data && n > w->capacity - w->size)) {
        w->ok = 0;
        return;
    }
    if (w->data) {
        memcpy(w->data + w->size, p, n);
    }
    w->size += n;
}
static void u32(Writer *w, uint32_t v) {
    unsigned char b[4];
    wn_image_put(b, v);
    bytes(w, b, 4);
}
static void f32(Writer *w, float v) {
    uint32_t bits;
    memcpy(&bits, &v, 4);
    if (!isfinite(v)) {
        w->ok = 0;
        return;
    }
    u32(w, bits);
}
static void f64(Writer *w, double v) {
    uint64_t bits;
    memcpy(&bits, &v, 8);
    if (!isfinite(v)) {
        w->ok = 0;
        return;
    }
    u32(w, (uint32_t)bits);
    u32(w, (uint32_t)(bits >> 32));
}
static void floats(Writer *w, const float *v, size_t n) {
    if (!w->data) {
        bytes(w, NULL, n * 4);
        return;
    }
    for (size_t i = 0; i < n && w->ok; i++) {
        f32(w, v[i]);
    }
}
static void string(Writer *w, const char *s) {
    size_t n = 0;
    if (s) {
        while (n <= FBX_MAX_STRING && s[n]) {
            n++;
        }
    }
    if (n > FBX_MAX_STRING) {
        w->ok = 0;
        return;
    }
    u32(w, (uint32_t)n);
    if (n) {
        bytes(w, s, n);
    }
}
static void metadata(Writer *w, fbx_scene *scene) {
    const fbx_model *m = fbx_model_of(scene);
    size_t t = (size_t)m->num_tris;
    if (!t || t > FBX_MAX_TRIS || m->num_bones < 0 || m->num_bones > FBX_MAX_ITEMS ||
        m->num_anims < 0 || m->num_anims > FBX_MAX_ITEMS || m->num_mats < 0 ||
        m->num_mats > FBX_MAX_ITEMS) {
        w->ok = 0;
        return;
    }
    bytes(w, "FBM1", 4);
    u32(w, (uint32_t)t);
    u32(w, m->num_bones);
    u32(w, m->num_anims);
    u32(w, m->num_mats);
    u32(w, (m->has_uv ? 1u : 0u) | (m->has_skin ? 2u : 0u));
    u32(w, 0);
    u32(w, 0);
    floats(w, m->pos, t * 9);
    floats(w, m->nrm, t * 9);
    if (m->has_uv) {
        floats(w, m->uv, t * 6);
    }
    if (m->has_skin) {
        for (size_t i = 0; i < t * 3; i++) {
            u32(w, (uint32_t)m->bone[i]);
        }
        floats(w, m->weight, t * 3);
    }
    if (m->num_mats) {
        for (size_t i = 0; i < t; i++) {
            u32(w, (uint32_t)m->mat[i]);
        }
        floats(w, m->mats, (size_t)m->num_mats * FBX_MAT_FLOATS);
    }
    for (int i = 0; i < m->num_anims && w->ok; i++) {
        f64(w, fbx_anim_begin(scene, i));
        f64(w, fbx_anim_end(scene, i));
        string(w, fbx_anim_name(scene, i));
    }
    for (int i = 0; i < m->num_mats && w->ok; i++) {
        string(w, fbx_material_name(scene, i));
        for (int ch = 0; ch < FBX_CHANNEL_COUNT; ch++) {
            fbx_texture_info info = {0};
            int ref = fbx_texture_of(scene, i, ch, &info);
            u32(w, (uint32_t)ref);
            u32(w, info.clamp_u);
            u32(w, info.clamp_v);
            floats(w, info.uv, 6);
            floats(w, info.tint, 4);
            string(w, info.path);
        }
    }
}
static int reply(uint32_t operation, uint32_t sequence, const void *payload, size_t size) {
    unsigned char header[16];
    memcpy(header, "FBO1", 4);
    wn_image_put(header + 4, operation);
    wn_image_put(header + 8, sequence);
    wn_image_put(header + 12, (uint32_t)size);
    return fwrite(header, 1, 16, stdout) == 16 && fwrite(payload, 1, size, stdout) == size &&
           !fflush(stdout);
}
int main(int argc, char **argv) {
    (void)argv;
    if (argc != 1 || !wn_decoder_limits(WN_DECODER_SESSION)) {
        return 1;
    }
#ifdef __OpenBSD__
    if (unveil(NULL, NULL) || pledge("stdio", NULL)) {
        return 1;
    }
#endif
    fbx_scene *scene = NULL;
    unsigned char *wire = NULL;
    size_t pose_count = 0, wire_size = 0;
    int result = 1;
    uint32_t sequence = 0;
    for (;;) {
        unsigned char header[16];
        size_t got = fread(header, 1, 16, stdin);
        if (!got && feof(stdin) && !ferror(stdin)) {
            result = 0;
            break;
        }
        if (got != 16 || memcmp(header, "FBI1", 4) || sequence == UINT32_MAX ||
            wn_image_u32(header + 12) != sequence + 1) {
            break;
        }
        sequence++;
        uint32_t op = wn_image_u32(header + 4), size = wn_image_u32(header + 8);
        if (op == 0 && !scene && size && size <= WN_MODEL_INPUT_MAX) {
            unsigned char *input = malloc(size);
            if (!input) {
                break;
            }
            if (fread(input, 1, size, stdin) != size) {
                free(input);
                break;
            }
            scene = fbx_open(input, size);
            free(input);
            if (!scene) {
                break;
            }
            Writer measure = {NULL, 0, 0, 1};
            metadata(&measure, scene);
            if (!measure.ok) {
                break;
            }
            unsigned char *initial = malloc(measure.size);
            if (!initial) {
                break;
            }
            Writer output = {initial, 0, measure.size, 1};
            metadata(&output, scene);
            int sent = output.ok && reply(op, sequence, initial, output.size);
            free(initial);
            if (!sent) {
                break;
            }
            pose_count = (size_t)fbx_model_of(scene)->num_tris * 9;
            wire_size = 8 + pose_count * 8;
        } else if (op == 1 && scene && size == 12) {
            unsigned char request[12];
            if (fread(request, 1, 12, stdin) != 12) {
                break;
            }
            uint32_t index_bits = wn_image_u32(request);
            int32_t index;
            memcpy(&index, &index_bits, 4);
            uint64_t bits =
                (uint64_t)wn_image_u32(request + 4) | (uint64_t)wn_image_u32(request + 8) << 32;
            double time;
            memcpy(&time, &bits, 8);
            if (index < -1 || index >= fbx_model_of(scene)->num_anims || !isfinite(time)) {
                break;
            }
            if (!wire) {
                wire = malloc(wire_size);
                if (!wire) {
                    break;
                }
            }
            float *pose = (float *)(wire + 8);
            if (!fbx_eval(scene, index, time, pose, pose + pose_count)) {
                break;
            }
            int valid = 1;
            const uint32_t endian = 1;
            for (size_t i = 0; i < pose_count * 2; i++) {
                if (!isfinite(pose[i])) {
                    valid = 0;
                    break;
                }
                if (*(const unsigned char *)&endian != 1) {
                    uint32_t value;
                    memcpy(&value, pose + i, 4);
                    wn_image_put(wire + 8 + i * 4, value);
                }
            }
            memcpy(wire, "FBP1", 4);
            wn_image_put(wire + 4, (uint32_t)(pose_count / 9));
            if (!valid || !reply(op, sequence, wire, wire_size)) {
                break;
            }
        } else {
            break;
        }
    }
    free(wire);
    fbx_close(scene);
    return result;
}
#include "helper_main.h"
