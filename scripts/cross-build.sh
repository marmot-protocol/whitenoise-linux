#!/usr/bin/env bash
# Release builds for other targets. Linux and Windows packages build on Linux
# (the packaging/cross container); macOS packages build on a Mac, where
# Apple's SDK is licensed (scripts/macos-setup.sh). See README.md.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-${WN_TARGET:-}}"
case "$TARGET" in
  linux-arm64|windows-amd64|darwin-amd64|darwin-arm64) ;;
  *) echo 'Usage: scripts/cross-build.sh {linux-arm64|windows-amd64|darwin-amd64|darwin-arm64}' >&2; exit 2 ;;
esac
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then echo 'Run with bash 4 or newer (on macOS: scripts/macos-setup.sh).' >&2; exit 2; fi
case "$TARGET" in
  darwin-*) HOST=Darwin ;;
  *) HOST=Linux ;;
esac
if [ "$(uname -s)" != "$HOST" ]; then echo "$TARGET packages build on a $HOST host." >&2; exit 2; fi
export WN_TARGET="$TARGET"
OUT="$HERE/build/cross/$TARGET"
JOBS="${WN_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
mkdir -p "$OUT"
source "$HERE/scripts/cross-toolchain.sh"
# This mode fetches and patches sources and assets only, never host archives.
bash "$HERE/scripts/build.sh" sources
source "$HERE/scripts/cross-deps.sh"

# The Rust build is the slowest step (13-15 min on CI runners). Skip it when
# libmarmot_c.a was built from the same MDK commit and patches for this
# target. Toolchain and dependency-prefix edits deliberately do not count:
# the archive is unlinked Rust, and the final link picks up the prefix. CI
# caches the archive plus this stamp under a key over the same inputs.
MARMOT_STAMP="$({
  git -C "$HERE/vendor/mdk" rev-parse HEAD
  echo "$RUST_TARGET"
  cat "$HERE"/patches/mdk-*.patch
} | sha256sum | cut -d' ' -f1)"
if [ ! -f "$OUT/libmarmot_c.a" ] || [ "$(cat "$OUT/libmarmot_c.stamp" 2>/dev/null || true)" != "$MARMOT_STAMP" ]; then
  # Rust host proc macros/build scripts use the host compiler. Only target crates
  # receive the target C compiler, sysroot and link arguments.
  rustup target add "$RUST_TARGET"
  export "CFLAGS_$RUST_KEY=${CFLAGS[*]}" "CXXFLAGS_$RUST_KEY=${CFLAGS[*]}"
  export "PKG_CONFIG_LIBDIR_$RUST_KEY=$PKG_CONFIG_LIBDIR"
  export "PKG_CONFIG_SYSROOT_DIR_$RUST_KEY=${PKG_CONFIG_SYSROOT_DIR:-}"
  RUST_ARGS=(-C "linker=$CC")
  if [ "$TARGET" = linux-arm64 ]; then RUST_ARGS+=(-C "link-arg=--sysroot=$SYSROOT"); fi
  export "CARGO_TARGET_${RUST_UPPER}_RUSTFLAGS=${RUST_ARGS[*]}"
  env -u CC -u CXX -u AR -u PKG_CONFIG_LIBDIR -u PKG_CONFIG_SYSROOT_DIR \
    CARGO_TARGET_DIR="$OUT/cargo" cargo build --manifest-path "$HERE/vendor/mdk/Cargo.toml" \
    --locked --release --target "$RUST_TARGET" -p marmot-c --features otlp-export
  cp "$OUT/cargo/$RUST_TARGET/release/libmarmot_c.a" "$OUT/libmarmot_c.a"
  echo "$MARMOT_STAMP" > "$OUT/libmarmot_c.stamp"
fi

mkdir -p "$OUT/clay" "$OUT/fbx" "$OUT/math" "$OUT/stb"
cp "$HERE/vendor/clay/clay.h" "$OUT/clay/clay.h"
# clay-mingw-enums.patch only affects _WIN32: the Odin binding assumes MSVC's
# 4-byte enums there, while Clang for MinGW would pack them to 1 byte.
for patch in clay-hashmap clay-mingw-enums; do
  git -C "$HERE" apply --directory="build/cross/$TARGET/clay" "$HERE/patches/$patch.patch"
done
"$CC" "${CFLAGS[@]}" -x c -c -DCLAY_IMPLEMENTATION "$OUT/clay/clay.h" -o "$OUT/clay/clay.o"
"$AR" rcs "$OUT/clay/clay.a" "$OUT/clay/clay.o"
"$CC" "${CFLAGS[@]}" -c "$HERE/vendor/ufbx/ufbx.c" -o "$OUT/fbx/ufbx.o"
"$CC" "${CFLAGS[@]}" -I"$HERE/vendor/ufbx" -c "$HERE/app/fbx_shim.c" -o "$OUT/fbx/shim.o"
"$AR" rcs "$OUT/libwnfbx.a" "$OUT/fbx/ufbx.o" "$OUT/fbx/shim.o"
"$CC" "${CFLAGS[@]}" $(pkg-config --cflags libcurl) -c "$HERE/app/ws_shim.c" -o "$OUT/ws.o"
"$AR" rcs "$OUT/libwnws.a" "$OUT/ws.o"
"$CC" "${CFLAGS[@]}" -c "$HERE/app/helper_ipc.c" -o "$OUT/ipc.o"
"$AR" rcs "$OUT/libwnipc.a" "$OUT/ipc.o"
cmake -S "$HERE/vendor/microtex" -B "$OUT/microtex" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$OUT/toolchain.cmake" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_STATIC=ON -DHAVE_CWRAPPER=ON \
  -DHAVE_LOG=OFF -DGRAPHICS_DEBUG=OFF -DHAVE_AUTO_FONT_FIND=OFF
cmake --build "$OUT/microtex" --target microtex -j"$JOBS"
"$CXX" "${CFLAGS[@]}" -std=c++17 -DHAVE_CWRAPPER \
  -isystem "$HERE/vendor/microtex/lib" -isystem "$OUT/microtex/lib" \
  $(pkg-config --cflags cairo) -c "$HERE/app/math_shim.cpp" -o "$OUT/math/shim.o"
"$AR" rcs "$OUT/libwnmath.a" "$OUT/math/shim.o"

SYSTEM_LIBS=()
RPATH=()
case "$SYSTEM" in
  Linux) SYSTEM_LIBS=(-pthread -ldl -lm); RPATH=(-Wl,-rpath,'$ORIGIN/../lib:$ORIGIN/../share/whitenoise-linux/tts-lib') ;;
  Windows) SYSTEM_LIBS=(-lws2_32 -luserenv -lbcrypt -lntdll -ladvapi32 -lcrypt32 -liphlpapi -lsecur32 -lshell32 -lole32 -luuid -luser32 -lgdi32) ;;
  Darwin) SYSTEM_LIBS=(-framework Security -framework CoreFoundation -framework SystemConfiguration -framework Cocoa -liconv -lresolv); RPATH=(-Wl,-rpath,@executable_path/../Frameworks) ;;
esac
HELPER_ENTRY=()
if [ "$SYSTEM" = Windows ]; then HELPER_ENTRY=(-municode); fi
"$CC" "${CFLAGS[@]}" "$HERE/app/font.c" $(pkg-config --cflags --libs freetype2) \
  "${HELPER_ENTRY[@]}" "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/wn-font$EXE"
for speech in tts stt; do
  "$CC" "${CFLAGS[@]}" -I"$TTS/include" "$HERE/app/$speech.c" "$OUT/libwnipc.a" \
    -L"$TTS/lib" -lsherpa-onnx-c-api \
    $(pkg-config --cflags --libs sdl3 libcurl glib-2.0 libcrypto libavformat libavcodec libavutil libswresample) \
    "${HELPER_ENTRY[@]}" "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/wn-$speech$EXE"
done
if [ "$SYSTEM" = Linux ]; then
  "$CC" "${CFLAGS[@]}" "$HERE/app/webview.c" "$OUT/libwnipc.a" \
    $(pkg-config --cflags --libs webkit2gtk-4.1) "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/wn-webview"
fi

ODIN_ROOT="$(odin root)"
for stb in image image_write image_resize truetype rect_pack vorbis sprintf; do
  "$CC" "${CFLAGS[@]}" -c "$ODIN_ROOT/vendor/stb/src/stb_$stb.c" -o "$OUT/stb/$stb.o"
done
"$AR" rcs "$OUT/stb/stb.a" "$OUT/stb/"*.o
"$CC" "${CFLAGS[@]}" -c "$ODIN_ROOT/vendor/cgltf/src/cgltf.c" -o "$OUT/cgltf.o"
"$AR" rcs "$OUT/cgltf.a" "$OUT/cgltf.o"
# Vendor bindings check archive existence while type-checking, even for
# object-only builds. Keep target archives in a private compiler-root overlay.
OVERLAY="$OUT/odin-root"
mkdir -p "$OVERLAY/vendor"
ln -sfn "$ODIN_ROOT/base" "$ODIN_ROOT/core" "$ODIN_ROOT/shared" "$OVERLAY/"
for entry in "$ODIN_ROOT/vendor/"*; do
  case "$(basename "$entry")" in
    stb|cgltf) cp -a "$entry" "$OVERLAY/vendor/" ;;
    *) ln -sfn "$entry" "$OVERLAY/vendor/" ;;
  esac
done
SUFFIX=a; SUBDIR=
if [ "$SYSTEM" = Windows ]; then SUFFIX=lib; fi
if [ "$SYSTEM" = Darwin ]; then SUBDIR=/darwin; fi
mkdir -p "$OVERLAY/vendor/stb/lib$SUBDIR" "$OVERLAY/vendor/cgltf/lib$SUBDIR"
for stb in image image_write image_resize truetype rect_pack vorbis sprintf; do
  "$AR" rcs "$OVERLAY/vendor/stb/lib$SUBDIR/stb_$stb.$SUFFIX" "$OUT/stb/$stb.o"
done
cp "$OUT/cgltf.a" "$OVERLAY/vendor/cgltf/lib$SUBDIR/cgltf.$SUFFIX"
export ODIN_ROOT="$OVERLAY"
# Odin does not cross-link different OSes. Generate a single native object and
# pass all foreign dependencies to the target C++ driver (MicroTeX uses C++).
odin build "$HERE/app" -target:"$ODIN_TARGET" -define:WN_TARGET="$TARGET" \
  -o:speed -build-mode:obj -out:"$OUT/app.o"
WINDOWS_LINK=()
if [ "$SYSTEM" = Windows ]; then
  "$CC" "${CFLAGS[@]}" -c "$HERE/app/mingw_shim.c" -o "$OUT/mingw_shim.o"
  WINDOWS_LINK=("$OUT/mingw_shim.o" "$OUT/velopack/libvelopack_libc.dll.a")
fi
"$CXX" "${CFLAGS[@]}" "$OUT/app.o" "${WINDOWS_LINK[@]}" \
  "$OUT/libwnfbx.a" "$OUT/libwnws.a" "$OUT/libwnmath.a" "$OUT/libwnipc.a" \
  "$OUT/microtex/lib/libmicrotex.a" "$OUT/clay/clay.a" "$OUT/stb/stb.a" "$OUT/cgltf.a" "$OUT/libmarmot_c.a" \
  $(pkg-config --libs sdl3 libarchive libwebp mpv poppler-glib gobject-2.0 glib-2.0 cairo libcurl openssl) \
  "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/whitenoise$EXE"
# Export only paths consumed by packaging; do not serialize credentials/SDKs.
export WN_CROSS_PREFIX="$PREFIX" WN_CROSS_SYSROOT="$SYSROOT" WN_CROSS_TTS="$TTS"
export WN_CROSS_WINDOWS_RUNTIME="${LLVM_MINGW:-}" WN_CROSS_VELOPACK="${VELOPACK:-}"
bash "$HERE/scripts/cross-package.sh" "$TARGET"
