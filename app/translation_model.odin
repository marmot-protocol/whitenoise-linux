package main

@(private)
TRANSLATION_MODEL_DIR :: "translategemma-4b-q4km-v1"
@(private)
TRANSLATION_MODEL_NAME :: "TranslateGemma 4B"

@(private)
TRANSLATION_AVAILABLE :: ODIN_OS == .Linux && #config(WN_TARGET, "") == ""
