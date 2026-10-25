package main

// Keep in sync with translation_models.h. Files are fetched only after opt-in.
@(private)
TRANSLATION_MODEL_DIR :: "translategemma-4b-q4km-v1"
@(private)
TRANSLATION_MODEL_BYTES :: i64(2490847773)
@(private)
TRANSLATION_MODEL_NAME :: "TranslateGemma 4B Q4_K_M"

@(private)
TRANSLATION_AVAILABLE :: ODIN_OS == .Linux && #config(WN_TARGET, "") == ""
