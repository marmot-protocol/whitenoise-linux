#!/usr/bin/env bash
# Pinned CPU runtime. ONNX runs the multilingual model without Python or a server.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TTS="$HERE/vendor/sherpa-onnx"
REV="$(sed -n 's/^sherpa-onnx-commit = //p' "$HERE/DEPS_PIN")"
mkdir -p "$TTS/include/sherpa-onnx/c-api" "$HERE/build/tts-lib"

fetch() {
  local url="$1" path="$2" digest="$3"
  if [ -f "$path" ] && printf '%s  %s\n' "$digest" "$path" | sha256sum -c --status; then
    return
  fi
  curl -fL --retry 3 "$url" -o "$path.part"
  printf '%s  %s\n' "$digest" "$path.part" | sha256sum -c
  mv "$path.part" "$path"
}

case "$(uname -m)" in
  x86_64)
    archive=sherpa-onnx-v1.13.7-linux-x64-shared-lib.tar.bz2
    digest=29a775ce0936ba9d6d3432769d01731048728dd8851b202e638aa6d4bf77722f ;;
  aarch64)
    archive=sherpa-onnx-v1.13.7-linux-aarch64-shared-cpu-lib.tar.bz2
    digest=306001f71409c73e8c4bfe117f410daab7e551a5dc4e1f22d75738b2ce0c8051 ;;
  *) echo "No pinned speech runtime for this architecture." >&2; exit 1 ;;
esac
fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.7/$archive" "$TTS/runtime.tar.bz2" "$digest"
if [ ! -f "$TTS/lib/libsherpa-onnx-c-api.so" ] || [ ! -f "$TTS/lib/libonnxruntime.so" ] || [ "$TTS/runtime.tar.bz2" -nt "$TTS/lib/libsherpa-onnx-c-api.so" ]; then
  tar -xjf "$TTS/runtime.tar.bz2" --strip-components=1 -C "$TTS"
  touch "$TTS/lib/libsherpa-onnx-c-api.so"
fi
fetch "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$REV/sherpa-onnx/c-api/c-api.h" \
  "$TTS/include/sherpa-onnx/c-api/c-api.h" 426db2c6acfb51e02143aece67c45779fae699d961c7c26ccf6f1388fdeaa2df
fetch "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$REV/LICENSE" \
  "$TTS/LICENSE" cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
fetch "https://raw.githubusercontent.com/microsoft/onnxruntime/v1.27.1/LICENSE" \
  "$TTS/LICENSE-onnxruntime" 2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c
fetch "https://raw.githubusercontent.com/microsoft/onnxruntime/v1.27.1/ThirdPartyNotices.txt" \
  "$TTS/ThirdPartyNotices-onnxruntime.txt" 0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2
cp "$TTS/lib/libsherpa-onnx-c-api.so" "$TTS/lib/libonnxruntime.so" "$HERE/build/tts-lib/"
