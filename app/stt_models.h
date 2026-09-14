// Pinned multilingual Whisper tiny int8 export, verified before loading.
#include <stddef.h>
#define MODEL_REV "65176e2deb88badc814a94058666cadccc29b61c"
#define MODEL_URL "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny/resolve/" MODEL_REV
typedef struct { const char *name; size_t size; const char *sha256; } ModelFile;
static const ModelFile models[] = {
    {"tiny-encoder.int8.onnx", 12937772, "d24fb083ae3b1041fc24e97971d60e280c9342201fbb67b0ab428a8b4a51a434"},
    {"tiny-decoder.int8.onnx", 89855401, "d2fece8dd42771f1df975c6c0445770d0c292bf7547c2cae04a6c0cc57540925"},
    {"tiny-tokens.txt", 816730, "b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126"},
};
