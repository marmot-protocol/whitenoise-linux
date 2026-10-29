#!/usr/bin/env bash
# Native Linux only. `sources` stages pinned runtime source for offline builds;
# neither this nor a normal build downloads the opt-in translation model.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$(uname -s)" != Linux ]; then exit 0; fi
stage() {
  local name="$1" dir="$2" archive digest
  archive="$(bash "$HERE/scripts/fetch.sh" "$name-source")"
  digest="$(sha256sum "$archive" | cut -d' ' -f1)"
  if [ ! -f "$dir/.wn-source" ] || [ "$(cat "$dir/.wn-source")" != "$digest" ]; then
    rm -rf "$dir"
    mkdir -p "$dir"
    tar --no-same-owner -xzf "$archive" -C "$dir" --strip-components=1
    printf '%s\n' "$digest" > "$dir/.wn-source"
  fi
}
stage llama "$HERE/vendor/llama.cpp"
stage fasttext "$HERE/vendor/fasttext"
if [ "${1:-}" = sources ]; then exit 0; fi
cmake -S "$HERE/scripts/translation" -B "$HERE/build/translation" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="${CC:-cc}" \
  -DCMAKE_CXX_COMPILER="${CXX:-c++}"
# The model graph sources can exhaust RAM under an unrestricted -j. Keep this
# independent of the host CPU count; packagers can explicitly lower it to one.
cmake --build "$HERE/build/translation" --target wn-translate --parallel "${WN_TRANSLATION_BUILD_JOBS:-2}"
cp "$HERE/build/translation/bin/wn-translate" "$HERE/build/wn-translate.next"
mv -f "$HERE/build/wn-translate.next" "$HERE/build/wn-translate"
