// Pinned multilingual speech models, verified before loading.
#include <stddef.h>
typedef struct {
    const char *name;
    size_t size;
    const char *sha256;
} ModelFile;
typedef enum { WHISPER, PARAKEET, SENSEVOICE } ModelKind;
typedef struct {
    const char *name, *url;
    int feature_dim;
    ModelKind kind;
    size_t file_count;
    ModelFile files[4];
} SttModel;
static const SttModel stt_models[] = {
    {"tiny",
     "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny/resolve/"
     "65176e2deb88badc814a94058666cadccc29b61c",
     80,
     WHISPER,
     3,
     {
         {"tiny-encoder.int8.onnx", 12937772,
          "d24fb083ae3b1041fc24e97971d60e280c9342201fbb67b0ab428a8b4a51a434"},
         {"tiny-decoder.int8.onnx", 89855401,
          "d2fece8dd42771f1df975c6c0445770d0c292bf7547c2cae04a6c0cc57540925"},
         {"tiny-tokens.txt", 816730,
          "b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126"},
     }},
    {"base",
     "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base/resolve/"
     "bb53ee204431c90d314c1cc08d28d23e5b7927cc",
     80,
     WHISPER,
     3,
     {
         {"base-encoder.int8.onnx", 29120534,
          "0b8fb1304b6109976038efff5ace81720e00386f3ff6b54ee8c75291ca0a1e11"},
         {"base-decoder.int8.onnx", 130672026,
          "9759d217388a01b3a4c7c15533201067b48ae819c4daafc8624e64b9409dc02d"},
         {"base-tokens.txt", 816730,
          "b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126"},
     }},
    {"small",
     "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/"
     "8f3c18b358db4d1f2fc1eae49d75cd20989e4309",
     80,
     WHISPER,
     3,
     {
         {"small-encoder.int8.onnx", 112442483,
          "4cbe7b22fa9026b843b60a68640c747de05bafb1a11b57edc0e66c232d9f33a9"},
         {"small-decoder.int8.onnx", 262226114,
          "acad50b5c782696e91b55914cc5ab4f756f1532f76e22aa6fc615f39fb69a8ee"},
         {"small-tokens.txt", 816730,
          "b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126"},
     }},
    {"medium",
     "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-medium/resolve/"
     "8c31d28503847560985df21f90e14f0c736e075e",
     80,
     WHISPER,
     3,
     {
         {"medium-encoder.int8.onnx", 374196283,
          "1c54582b4d829de0089f6cb63bbbdb3bf7555398bacaf855fbecf1a84dfd193e"},
         {"medium-decoder.int8.onnx", 571059257,
          "595d00a338a365a7bfa0ca7f296cabc639583bef770ab6130df90f49a6412747"},
         {"medium-tokens.txt", 816730,
          "b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126"},
     }},
    {"large-v3",
     "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-large-v3/resolve/"
     "2a6507094dd6020d939d78e3f1834a1d06267fca",
     128,
     WHISPER,
     3,
     {
         {"large-v3-encoder.int8.onnx", 766671985,
          "d531cf17248acc43e8c09b472a0877055e770877857a5332fc1304b36534ec85"},
         {"large-v3-decoder.int8.onnx", 1008265203,
          "ebc6bfd88e162a46cb3edee8a7e727e1dcbc65cabecb19e2573695e4d495e1af"},
         {"large-v3-tokens.txt", 816730,
          "b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126"},
     }},
    {"turbo",
     "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-turbo/resolve/"
     "2ca6ff69fc878651b770880507669577ac41c2ff",
     128,
     WHISPER,
     3,
     {
         {"turbo-encoder.int8.onnx", 674716297,
          "b02dcdf54f348741e93fe732b67d933c8dcb6735655f710640143081db38878b"},
         {"turbo-decoder.int8.onnx", 361080764,
          "20accd02388482eb3a46bd615631adfdc85e1eb2c7db9ea3f02a40ffe6b81547"},
         {"turbo-tokens.txt", 816730,
          "b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126"},
     }},
    {"parakeet-v3",
     "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/"
     "2bda32ec70b097a55adaa07d9a7173915b43cc78",
     80,
     PARAKEET,
     4,
     {
         {"encoder.int8.onnx", 652184281,
          "acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247"},
         {"decoder.int8.onnx", 11845275,
          "179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e"},
         {"joiner.int8.onnx", 6355277,
          "3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3"},
         {"tokens.txt", 93939, "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"},
     }},
    {"sensevoice",
     "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/"
     "2365baeacb507f821a0c8120fcee3d484dba7a07",
     80,
     SENSEVOICE,
     2,
     {
         {"model.int8.onnx", 239233841,
          "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"},
         {"tokens.txt", 315894, "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"},
     }},
};
static const SttModel *stt_model = &stt_models[0];
#define models (stt_model->files)
#define MODEL_URL (stt_model->url)
