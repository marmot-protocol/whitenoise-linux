// Pinned Supertonic 3 int8 files. SHA-256 is checked before loading.
#include <stddef.h>
#define MODEL_REV "cca5a0e6c96e1d2c720986bf7e75fcc81dee3ae4"
#define MODEL_URL                                                                                  \
    "https://huggingface.co/csukuangfj2/sherpa-onnx-supertonic-3-tts-int8-2026-05-11/"             \
    "resolve/" MODEL_REV
typedef struct {
    const char *name;
    size_t size;
    const char *sha256;
} ModelFile;
static const char *const voices[] = {"F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"};
static const char *const languages[] = {
    "en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es", "et", "fi", "fr", "hi", "hr", "hu",
    "id", "it", "lt", "lv", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi"};
static const ModelFile models[] = {
    {"duration_predictor.int8.onnx", 3700147,
     "c3eb91414d5ff8a7a239b7fe9e34e7e2bf8a8140d8375ffb14718b1c639325db"},
    {"text_encoder.int8.onnx", 36416150,
     "c7befd5ea8c3119769e8a6c1486c4edc6a3bc8365c67621c881bbb774b9902ff"},
    {"vector_estimator.int8.onnx", 78400833,
     "20cd86fa5c6effedfda0e7cffe5b0569ca401c440a0c3a1d72bf39286c0db3fd"},
    {"vocoder.int8.onnx", 25991073,
     "e923d60f53f95eb1ce235f1dc33ec56d9c057823c96fa6f8acf98f32b0da6152"},
    {"tts.json", 8253, "42078d3aef1cd43ab43021f3c54f47d2d75ceb4e75f627f118890128b06a0d09"},
    {"unicode_indexer.bin", 262144,
     "8402ca48e5189a8950138580b0fff64db6f072f24ac07cd54ba8b2fbb9883b30"},
    {"voice.bin", 517168, "67d5209b0ee8ce6c74105ffbe12fe6a7628aea3b4ba2fcb308a4a67938a93ce8"},
    {"LICENSE", 1070, "0dfe0d0ba84416fe3879d9a34f4909d8d0137c78d1e95834177b0414ac096fa2"},
};
