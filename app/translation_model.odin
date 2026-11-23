package main

// Keep in sync with translation_models.h. Files are fetched only after opt-in.
@(private)
TRANSLATION_MODEL_DIR :: "translategemma-4b-q4km-v1"
@(private)
TRANSLATION_MODEL_FILES := [?]struct {
	name: string,
	size: i64,
}{{"translategemma-4b-it.Q4_K_M.gguf", 2489909760}, {"lid.176.ftz", 938013}}
@(private)
TRANSLATION_MODEL_NAME :: "TranslateGemma 4B"

@(private)
TRANSLATION_AVAILABLE :: ODIN_OS == .Linux && #config(WN_TARGET, "") == ""
