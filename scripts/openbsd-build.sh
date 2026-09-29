#!/usr/bin/env bash
# OpenBSD amd64 build: the standalone binary plus its data tree, packed as
# dist/WhiteNoise-<version>-openbsd-amd64.tar.gz. Runs on OpenBSD itself; CI
# boots one under QEMU with cross-platform-actions (.github/workflows/cross.yml).
#
# Build dependencies (the workflow installs them):
#   pkg_add bash git cmake ninja gmake coreutils llvm%21 rust unzip-- \
#     sdl3 libarchive libwebp mpv poppler cairo curl glib2 ffmpeg zenity libnotify
# Media libraries and desktop tools remain system packages; SDL is linked
# statically below. Speech (reading aloud, dictation) is not built:
# sherpa-onnx publishes no OpenBSD runtime.
set -euo pipefail
if [ "$(id -u)" -eq 0 ]; then
  echo "Run as a normal user; only package staging uses root privileges." >&2
  exit 1
fi
ROOT=doas
if command -v sudo >/dev/null 2>&1; then ROOT=sudo; fi
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
cargo test --manifest-path "$HERE/vendor/mdk/Cargo.toml" -p fs-private --lib
cc -O2 -Wall -Wextra "$HERE/tests/ws-frame-test.c" \
  $(pkg-config --cflags --libs libcurl) -o "$HERE/build/ws-frame-test"
"$HERE/build/ws-frame-test"
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
cc -O2 -Wall -Wextra "$HERE/tests/math-helper-test.c" "$HERE/build/libwndecoder.a" \
  -o "$HERE/build/math-helper-test"
"$HERE/build/math-helper-test" "$HERE/build/wn-math"
cc -O2 -Wall -Wextra "$HERE/tests/main-sandbox-test.c" \
  -Wl,--wrap=execve -o "$HERE/build/main-sandbox-test"
cc -O2 -Wall -Wextra -pthread "$HERE/tests/tool-broker-test.c" \
  "$HERE/app/main_sandbox.c" "$HERE/app/tool_broker.c" \
  -Wl,--wrap=execve -o "$HERE/build/tool-broker-test"
cc -O2 -Wall -Wextra "$HERE/tests/helper-broker-test.c" \
  "$HERE/app/helper_broker.c" "$HERE/app/main_sandbox.c" \
  -Wl,--wrap=execve -o "$HERE/build/helper-broker-test"
cc -shared -fPIC -O2 "$HERE/tests/helper-broker-preload.c" -o "$HERE/build/broker-preload.so"

VERSION="${WN_RELEASE_VERSION:-$(bash "$HERE/scripts/version.sh")}"
NAME="WhiteNoise-$VERSION-openbsd-amd64"
# Trusted runtime files need protected ownership and ancestry. Only staging
# uses elevation; the application and capability tests run as the invoking user.
"$ROOT" install -d -m 0755 /usr/local/libexec
PROTECTED="$("$ROOT" mktemp -d /usr/local/libexec/wn-build.XXXXXXXX)"
"$ROOT" chmod 0755 "$PROTECTED"
DATA=""
XVFB=""
cleanup() {
  if [ -n "$XVFB" ]; then kill "$XVFB" 2>/dev/null || true; wait "$XVFB" 2>/dev/null || true; fi
  "$ROOT" rm -rf "$PROTECTED"
  if [ -n "$DATA" ]; then rm -rf "$DATA"; fi
}
trap cleanup EXIT
STAGE="$PROTECTED/$NAME"
"$ROOT" bash "$HERE/scripts/install-tree.sh" "$STAGE" whitenoise

POLICY="$PROTECTED/policy/share/whitenoise-linux"
"$ROOT" install -d -m 0755 "$POLICY/fonts"
"$ROOT" install -m 0755 "$HERE/build/main-sandbox-test" "$POLICY/wn-helper"
printf font | "$ROOT" tee "$POLICY/font" >/dev/null
"$ROOT" chmod 0644 "$POLICY/font"
"$ROOT" install -m 0664 /dev/null "$POLICY/../../bad-mode"
"$ROOT" ln -s /dev/null "$POLICY/../../bad-link"
"$ROOT" install -d -o "$(id -un)" -g wheel -m 0755 "$POLICY/../../mutable"
ln -s ../share/whitenoise-linux "$POLICY/../../mutable/redirect"
"$ROOT" ln -s mutable/redirect/font "$POLICY/../../bad-chain"
WN_SANDBOX_TEST_RESOURCES="$POLICY" "$HERE/build/main-sandbox-test"
WN_SANDBOX_TEST_RESOURCES="$POLICY" "$HERE/build/tool-broker-test"

HELPERS="$PROTECTED/helpers/share/whitenoise-linux"
"$ROOT" install -d -m 0755 "$HELPERS/fonts"
for helper in wn-image wn-fbx wn-pdf wn-font wn-stt wn-math; do
  "$ROOT" install -m 0755 "$HERE/build/helper-broker-test" "$HELPERS/$helper"
done
printf 'Invalid ELF\n' | "$ROOT" tee "$HELPERS/wn-archive" >/dev/null
"$ROOT" chmod 0755 "$HELPERS/wn-archive"
"$ROOT" install -m 0644 "$HERE/build/broker-preload.so" "$HELPERS/broker-preload.so"
WN_HELPER_TEST_RESOURCES="$HELPERS" "$HERE/build/helper-broker-test"

# Boot the packaged binary headless: SDL's dummy driver, and WN_SHOT exits
# after a few frames. Catches a missing library or a res_dir that no longer
# finds the packaged data. The screenshot stays in $OUT as CI evidence.
DATA="$(mktemp -d)"
(cd "$DATA" && XDG_CONFIG_HOME="$DATA/config" SDL_VIDEODRIVER=dummy WN_SHOT=1 WN_VAULT_PW=ci-smoke "$STAGE/bin/whitenoise" "$DATA")
cp "$DATA/wn-odin-shot.png" "$OUT/wn-odin-shot.png"
# The dummy driver cannot catch X11 shared-memory calls forbidden by pledge.
# Let Xvfb choose a free display; the FIFO reports readiness without polling.
mkfifo "$DATA/display"
/usr/X11R6/bin/Xvfb -displayfd 3 -screen 0 1024x768x24 -nolisten tcp -ac 3>"$DATA/display" &
XVFB=$!
if ! IFS= read -r -t 30 DISPLAY_NUMBER < "$DATA/display"; then
  echo "Xvfb did not provide a display" >&2
  exit 1
fi
(cd "$DATA" && DISPLAY=":$DISPLAY_NUMBER" XDG_CONFIG_HOME="$DATA/config" \
  WN_TEST_RESIZE=1000x700@15~10 WN_SHOT=1 WN_SHOT_FRAME=45 WN_VAULT_PW=ci-smoke \
  "$STAGE/bin/whitenoise" "$DATA")
cp "$DATA/wn-odin-shot.png" "$OUT/wn-odin-shot-x11.png"
mkdir -p "$HERE/dist"
"$ROOT" tar -czf "$HERE/dist/$NAME.tar.gz" -C "$PROTECTED" "$NAME"
printf 'Packaged %s\n' "$NAME"
