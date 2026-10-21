#!/usr/bin/env bash
# Pinned CPU runtime. ONNX runs the multilingual model without Python or a server.
# Every input is a `-file` pin in DEPS_PIN, fetched by scripts/fetch.sh; the
# runtime archive is picked by host architecture (sherpa-onnx-<arch>-file).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TTS="$HERE/vendor/sherpa-onnx"
mkdir -p "$TTS/include/sherpa-onnx/c-api" "$HERE/build/tts-lib"
fetch() { bash "$HERE/scripts/fetch.sh" "$1"; }

RUNTIME="$(fetch "sherpa-onnx-$(uname -m)")"
if [ ! -f "$TTS/lib/libsherpa-onnx-c-api.so" ] || [ ! -f "$TTS/lib/libonnxruntime.so" ] || [ "$RUNTIME" -nt "$TTS/lib/libsherpa-onnx-c-api.so" ]; then
  tar --no-same-owner -xjf "$RUNTIME" --strip-components=1 -C "$TTS"
  touch "$TTS/lib/libsherpa-onnx-c-api.so"
fi
HEADER="$(fetch sherpa-onnx-header)"
LICENSE="$(fetch sherpa-onnx-license)"
ORT_LICENSE="$(fetch onnxruntime-license)"
ORT_NOTICES="$(fetch onnxruntime-notices)"
cp "$HEADER" "$TTS/include/sherpa-onnx/c-api/c-api.h"
cp "$LICENSE" "$TTS/LICENSE"
cp "$ORT_LICENSE" "$TTS/LICENSE-onnxruntime"
cp "$ORT_NOTICES" "$TTS/ThirdPartyNotices-onnxruntime.txt"
cp "$TTS/lib/libsherpa-onnx-c-api.so" "$TTS/lib/libonnxruntime.so" "$HERE/build/tts-lib/"
