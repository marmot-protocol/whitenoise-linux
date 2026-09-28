#!/usr/bin/env bash
# OpenBSD amd64 build: the standalone binary plus its data tree, packed as
# dist/WhiteNoise-<version>-openbsd-amd64.tar.gz. Runs on OpenBSD itself; CI
# boots one under QEMU with cross-platform-actions (.github/workflows/cross.yml).
#
# Build dependencies (the workflow installs them):
#   pkg_add bash git cmake ninja gmake coreutils llvm%21 rust unzip-- \
#     sdl3 libarchive libwebp mpv poppler cairo curl glib2 ffmpeg
# The binary links the last line's libraries dynamically, so a machine that
# runs it needs those installed. Speech (reading aloud, dictation) is not
# built: sherpa-onnx publishes no OpenBSD runtime.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/build/openbsd"
ODIN_VERSION=dev-2026-09
ODIN_COMMIT=a2fb372b76e81ef31fbbc8a2cf2b4fdf5ac6c924

# Odin has no OpenBSD package: build the pinned release from source (~1 min).
ODIN="$OUT/odin"
if [ ! -x "$ODIN/odin" ] || [ "$(git -C "$ODIN" rev-parse HEAD 2>/dev/null || true)" != "$ODIN_COMMIT" ]; then
  rm -rf "$ODIN"
  git clone -q --depth 1 --branch "$ODIN_VERSION" https://github.com/odin-lang/Odin.git "$ODIN"
  if [ "$(git -C "$ODIN" rev-parse HEAD)" != "$ODIN_COMMIT" ]; then
    echo "Odin tag $ODIN_VERSION no longer points at $ODIN_COMMIT." >&2
    exit 1
  fi
  (cd "$ODIN" && LLVM_CONFIG=/usr/local/llvm21/bin/llvm-config ./build_odin.sh release)
fi
export PATH="$ODIN:$PATH"

bash "$HERE/scripts/build.sh"
cc -O2 -Wall -Wextra -I"$ODIN/vendor/stb/src" "$HERE/tests/image-test.c" \
  "$HERE/build/libwndecoder.a" $(pkg-config --cflags --libs libwebp) -lm -o "$HERE/build/image-test"
"$HERE/build/image-test" "$HERE/build/wn-image"
cc -O2 -Wall -Wextra "$HERE/tests/archive-helper-test.c" "$HERE/build/libwndecoder.a" \
  $(pkg-config --cflags --libs libarchive) -o "$HERE/build/archive-helper-test"
"$HERE/build/archive-helper-test" "$HERE/build/wn-archive"
cc -O2 -Wall -Wextra "$HERE/tests/pdf-helper-test.c" "$HERE/build/libwndecoder.a" \
  -o "$HERE/build/pdf-helper-test"
"$HERE/build/pdf-helper-test" "$HERE/build/wn-pdf" "$HERE/vendor/fonts"
cc -O2 -Wall -Wextra "$HERE/tests/model-transport-test.c" "$HERE/build/libwndecoder.a" \
  -o "$HERE/build/model-transport-test"
"$HERE/build/model-transport-test" --test

VERSION="${WN_RELEASE_VERSION:-$(bash "$HERE/scripts/version.sh")}"
NAME="WhiteNoise-$VERSION-openbsd-amd64"
STAGE="$OUT/package/$NAME"
rm -rf "$STAGE"
bash "$HERE/scripts/install-tree.sh" "$STAGE" whitenoise
mkdir -p "$HERE/dist"
tar -czf "$HERE/dist/$NAME.tar.gz" -C "$OUT/package" "$NAME"

# Boot the packaged binary headless: SDL's dummy driver, and WN_SHOT exits
# after a few frames. Catches a missing library or a res_dir that no longer
# finds the packaged data. The screenshot stays in $OUT as CI evidence.
DATA="$(mktemp -d)"
(cd "$OUT" && SDL_VIDEODRIVER=dummy WN_SHOT=1 WN_VAULT_PW=ci-smoke "$STAGE/bin/whitenoise" "$DATA")
rm -rf "$DATA"
printf 'Packaged %s\n' "$NAME"
