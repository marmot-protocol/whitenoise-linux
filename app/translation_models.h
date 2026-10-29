// Runtime downloads only: never fetched by build/stage or bundled in packages.
// TranslateGemma (Google, Gemma terms); Q4_K_M conversion by mradermacher.
// Original: google/translategemma-4b-it@10042cb0e6e7fdce748996a71dc3dc432a4e0c89.
// Template: that revision's chat_template.jinja; text-only Gemma 3 needs no mmproj.
// Detector: Facebook fastText lid.176.ftz, CC-BY-SA-3.0, unmodified.
#ifndef WN_TRANSLATION_MODELS_H
#define WN_TRANSLATION_MODELS_H
#include <stddef.h>
typedef struct {
    const char *name, *sha256;
    size_t size;
    const char *url;
} ModelFile;
static const ModelFile models[] = {
    {"translategemma-4b-it.Q4_K_M.gguf",
     "81200d03e843d2ec1ece6eeafe7d13cb6e5211e1fcd336ade55790b683a08330", 2489909760ULL,
     "https://huggingface.co/mradermacher/translategemma-4b-it-GGUF/resolve/"
     "d37868f759d2f817a43d28dd80cf9f982ffa62fd/translategemma-4b-it.Q4_K_M.gguf"},
    {"lid.176.ftz", "8f3472cfe8738a7b6099e8e999c3cbfae0dcd15696aac7d7738a8039db603e83", 938013,
     "https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.ftz"},
};
#define WN_MODEL_URL(model) g_strdup((model)->url)
#endif
