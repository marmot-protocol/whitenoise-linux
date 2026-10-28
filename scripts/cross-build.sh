#!/usr/bin/env bash
# Release builds for other targets. Linux and Windows packages build on Linux
# (the packaging/cross container); macOS packages build on a Mac, where
# Apple's SDK is licensed (scripts/macos-setup.sh). See README.md.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-${WN_TARGET:-}}"
case "$TARGET" in
linux-arm64 | linux-amd64 | windows-amd64 | darwin-amd64 | darwin-arm64) ;;
*)
  echo 'Usage: scripts/cross-build.sh {linux-arm64|linux-amd64|windows-amd64|darwin-amd64|darwin-arm64}' >&2
  exit 2
  ;;
esac
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo 'Run with bash 4 or newer (on macOS: scripts/macos-setup.sh).' >&2
  exit 2
fi
case "$TARGET" in
darwin-*) HOST=Darwin ;;
*) HOST=Linux ;;
esac
if [ "$(uname -s)" != "$HOST" ]; then
  echo "$TARGET packages build on a $HOST host." >&2
  exit 2
fi
export WN_TARGET="$TARGET"
source "$HERE/scripts/whip-flags.sh"
OUT="$HERE/build/cross/$TARGET"
JOBS="${WN_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
mkdir -p "$OUT" "$HERE/vendor"
# Slow third-party builds write a stamp of their inputs (pins, patches) next
# to their output and are skipped while it matches. CI caches the outputs
# plus stamps; a restore from other inputs just fails the check and rebuilds.
#   stamp_fresh <output> <stamp-file> <stamp>
stamp_fresh() { [ -e "$1" ] && [ "$(cat "$2" 2>/dev/null || true)" = "$3" ]; }
# Target includes come from the selected SDK and explicit pkg-config flags,
# never host search paths inherited from the invoking developer shell.
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH
source "$HERE/scripts/cross-toolchain.sh"
# This mode fetches and patches sources and assets only, never host archives.
bash "$HERE/scripts/build.sh" sources
source "$HERE/scripts/cross-deps.sh"
source "$HERE/scripts/build-cache.sh"
# SDK contents are identified by the existing toolchain/dependency stamps;
# hash local sources and the actual pkg-config headers/libraries separately.
C_ID="$(build_cache_key "$TOOLCHAIN_STAMP ${CFLAGS[*]} $CC $CXX $AR ${SDL_STAMP:-} ${VCPKG_STAMP:-} ${MPV_STAMP:-}" \
  "$HERE/scripts/cross-build.sh" "$HERE/scripts/build-cache.sh" "$AR")"
APP_HEADERS=("$HERE"/app/*.h)
cross_key() { build_cache_key "$C_ID $1" "${@:2}"; }
cross_fresh() {
  local name="$1" key="$2"
  shift 2
  if build_cache_fresh "$key" "$OUT/$name.cache" "$@"; then
    echo "==> cross cache hit: $name"
    return 0
  fi
  # A failed rebuild must not leave a previously valid publication behind.
  rm -f "$OUT/$name.cache"
  return 1
}
cross_store() { build_cache_store "$2" "$OUT/$1.cache" "${@:3}"; }
# Resolve libraries from the same -L search paths as the target driver. This
# catches a replaced dependency archive even when its installer stamp matches.
cross_pkg_key() {
  local flags token dir name path found module header
  local -a inputs=() dirs=() libs=() roots=("$PREFIX/include")
  if [ "$SYSTEM" = Linux ]; then roots+=("$PREFIX/include/$TRIPLE"); fi
  flags="$(pkg-config --cflags --libs "$@")" || return
  for module in "$@"; do
    dir="$(pkg-config --variable=pcfiledir "$module")" || return
    inputs+=("$dir/$module.pc")
    case "$module" in
    libcurl) header=curl ;;
    libcrypto | openssl) header=openssl ;;
    libwebp) header=webp ;;
    libarchive) header=archive.h ;;
    mpv) header=mpv ;;
    libavformat | libavcodec | libavutil | libswresample | fontconfig) header="$module" ;;
    *) header= ;;
    esac
    if [ -n "$header" ]; then
      found=
      for dir in "${roots[@]}"; do
        if [ -e "$dir/$header" ]; then
          inputs+=("$dir/$header")
          found=1
        fi
        if [ "$module" = libarchive ] && [ -e "$dir/archive_entry.h" ]; then inputs+=("$dir/archive_entry.h"); fi
      done
      if [ -z "$found" ]; then
        echo "Cannot locate target headers: $module" >&2
        return 1
      fi
    fi
  done
  for token in $flags; do
    case "$token" in
    -I*)
      path="${token#-I}"
      # Do not recursively hash an entire SDK for a generic include flag.
      # Its immutable package set is already in TOOLCHAIN_STAMP.
      if [ "$path" != "$PREFIX/include" ] && [ "$path" != "$PREFIX/include/${TRIPLE:-}" ] && [ "$path" != "$SYSROOT/usr/include" ] && [ "$path" != /usr/include ]; then
        inputs+=("$path")
      fi
      ;;
    -L*) dirs+=("${token#-L}") ;;
    -l*) libs+=("${token#-l}") ;;
    esac
  done
  for name in "${libs[@]}"; do
    found=
    for dir in "${dirs[@]}"; do
      for path in "$dir/lib$name.so" "$dir/lib$name.dylib" "$dir/lib$name.dll.a" "$dir/lib$name.a"; do
        if [ -f "$path" ]; then
          found="$path"
          break 2
        fi
      done
    done
    if [ -z "$found" ]; then
      for token in "lib$name.so" "lib$name.dylib" "lib$name.dll.a" "lib$name.a"; do
        path="$("$CC" "${CFLAGS[@]}" -print-file-name="$token")" || return
        if [ -f "$path" ]; then
          found="$path"
          break
        fi
      done
    fi
    # SDK framework/stub libraries on macOS have no ordinary archive path;
    # Xcode's SDK build identity remains part of the toolchain key.
    if [ -n "$found" ]; then
      inputs+=("$found")
    elif [ "$SYSTEM" != Darwin ]; then
      echo "Cannot locate target library: $name" >&2
      return 1
    fi
  done
  cross_key "pkg $* $flags" "${inputs[@]}"
}
CURL_KEY="$(cross_pkg_key libcurl)"
CAIRO_KEY="$(cross_pkg_key cairo)"

# Sparkle's signed universal framework is kept out of dependency relocation.
# The bridge loads it only from an installed app bundle after SDL starts.
SPARKLE=
if [ "$SYSTEM" = Darwin ]; then
  SPARKLE="$(bash "$HERE/scripts/build-sparkle-updater.sh" "$OUT")"
  KEY="$(cross_key 'sparkle -fobjc-arc -fblocks' "$HERE/app/updater_sparkle.m" "$SPARKLE")"
  if ! cross_fresh sparkle "$KEY" "$OUT/updater_sparkle.o" "$OUT/libwnsparkle.a"; then
    "$CC" "${CFLAGS[@]}" -fobjc-arc -fblocks -F"$SPARKLE" \
      -c "$HERE/app/updater_sparkle.m" -o "$OUT/updater_sparkle.o"
    "$AR" rcs "$OUT/libwnsparkle.a" "$OUT/updater_sparkle.o"
    cross_store sparkle "$KEY" "$OUT/updater_sparkle.o" "$OUT/libwnsparkle.a"
  fi
elif [ "$SYSTEM" = Linux ]; then
  KEY="$(cross_key appimage "$HERE/scripts/build-appimage-updater.sh" "$HERE/app/appimage_update_client.c" "${APP_HEADERS[@]}")"
  if ! cross_fresh appimage "$KEY" "$OUT/appimage_update_client.o" "$OUT/libwnappimage.a"; then
    CC="$CC" AR="$AR" CFLAGS="${CFLAGS[*]}" \
      bash "$HERE/scripts/build-appimage-updater.sh" bridge "$OUT"
    cross_store appimage "$KEY" "$OUT/appimage_update_client.o" "$OUT/libwnappimage.a"
  fi
fi

# Always let Cargo check source/configuration changes, never trust a final
# archive stamp. MDK pin/patch changes retain unchanged crates; compiler/SDK
# changes use a separate tree because C build scripts may not detect them.
RUST_ARGS=(-C "linker=$CC")
if [ "$SYSTEM" = Linux ]; then RUST_ARGS+=(-C "link-arg=--sysroot=$SYSROOT"); fi
export "CFLAGS_$RUST_KEY=${CFLAGS[*]}" "CXXFLAGS_$RUST_KEY=${CFLAGS[*]}"
export "PKG_CONFIG_LIBDIR_$RUST_KEY=$PKG_CONFIG_LIBDIR"
export "PKG_CONFIG_SYSROOT_DIR_$RUST_KEY=${PKG_CONFIG_SYSROOT_DIR:-}"
export "CARGO_TARGET_${RUST_UPPER}_RUSTFLAGS=${RUST_ARGS[*]}"
MARMOT_STAMP="$({
  printf '%s\n' "$TOOLCHAIN_STAMP" "${RUST_ARGS[*]}" "${RUSTFLAGS:-}" "${CARGO_ENCODED_RUSTFLAGS:-}" \
    "${RUSTC:-}" "${RUSTC_WRAPPER:-}" "${RUSTC_WORKSPACE_WRAPPER:-}"
  rustc -vV
  cargo -V
} | sha256sum | cut -d' ' -f1)"
if ! rustup target list --installed | grep -qx "$RUST_TARGET"; then
  rustup target add "$RUST_TARGET"
fi
# Rust host proc macros/build scripts use the host compiler, not target CC.
env -u CC -u CXX -u AR -u PKG_CONFIG_LIBDIR -u PKG_CONFIG_SYSROOT_DIR \
  CARGO_TARGET_DIR="$OUT/cargo/$MARMOT_STAMP" cargo build --manifest-path "$HERE/vendor/mdk/Cargo.toml" \
  --locked --release --target "$RUST_TARGET" -p marmot-c --features otlp-export
MARMOT_ARCHIVE="$OUT/cargo/$MARMOT_STAMP/$RUST_TARGET/release/libmarmot_c.a"
if ! cmp -s "$MARMOT_ARCHIVE" "$OUT/libmarmot_c.a"; then cp "$MARMOT_ARCHIVE" "$OUT/libmarmot_c.a"; fi

mkdir -p "$OUT/clay" "$OUT/fbx" "$OUT/math" "$OUT/stb"
CLAY_PATCHES=()
for patch in clay-hashmap clay-scroll-target clay-scroll-reflow clay-float-layer clay-nested-clip clay-cjk-wrap clay-mingw-enums; do
  CLAY_PATCHES+=("$HERE/patches/$patch.patch")
done
KEY="$(cross_key 'clay -x c -DCLAY_IMPLEMENTATION' "$HERE/vendor/clay/clay.h" "${CLAY_PATCHES[@]}")"
if ! cross_fresh clay "$KEY" "$OUT/clay/clay.h" "$OUT/clay/clay.o" "$OUT/clay/clay.a"; then
  cp "$HERE/vendor/clay/clay.h" "$OUT/clay/clay.h"
  # Cached output may live behind a symlink. Apply directly in its physical
  # directory without discovering the source repository above it.
  CLAY_DIR="$(cd "$OUT/clay" && pwd -P)"
  # clay-mingw-enums.patch only affects _WIN32: the Odin binding assumes MSVC's
  # 4-byte enums there, while Clang for MinGW would pack them to 1 byte.
  for patch in clay-hashmap clay-scroll-target clay-scroll-reflow clay-float-layer clay-nested-clip clay-cjk-wrap clay-mingw-enums; do
    GIT_CEILING_DIRECTORIES="${CLAY_DIR%/*}" git -C "$CLAY_DIR" apply "$HERE/patches/$patch.patch"
  done
  "$CC" "${CFLAGS[@]}" -x c -c -DCLAY_IMPLEMENTATION "$OUT/clay/clay.h" -o "$OUT/clay/clay.o"
  "$AR" rcs "$OUT/clay/clay.a" "$OUT/clay/clay.o"
  cross_store clay "$KEY" "$OUT/clay/clay.h" "$OUT/clay/clay.o" "$OUT/clay/clay.a"
fi
KEY="$(cross_key ufbx "$HERE/vendor/ufbx/ufbx.c" "$HERE/vendor/ufbx/ufbx.h")"
if ! cross_fresh ufbx "$KEY" "$OUT/fbx/ufbx.o"; then
  "$CC" "${CFLAGS[@]}" -c "$HERE/vendor/ufbx/ufbx.c" -o "$OUT/fbx/ufbx.o"
  cross_store ufbx "$KEY" "$OUT/fbx/ufbx.o"
fi
KEY="$(cross_key "ws $CURL_KEY" "$HERE/app/ws_shim.c" "$HERE/app/nc_shim.c" "${APP_HEADERS[@]}")"
if ! cross_fresh ws "$KEY" "$OUT/ws.o" "$OUT/nc.o" "$OUT/libwnws.a"; then
  "$CC" "${CFLAGS[@]}" $(pkg-config --cflags libcurl) -c "$HERE/app/ws_shim.c" -o "$OUT/ws.o"
  "$CC" "${CFLAGS[@]}" $(pkg-config --cflags libcurl) -c "$HERE/app/nc_shim.c" -o "$OUT/nc.o"
  "$AR" rcs "$OUT/libwnws.a" "$OUT/ws.o" "$OUT/nc.o"
  cross_store ws "$KEY" "$OUT/ws.o" "$OUT/nc.o" "$OUT/libwnws.a"
fi
for stage in ipc decoder_ipc timestamp mesh_limits; do
  case "$stage" in
  ipc)
    source=helper_ipc
    archive=wnipc
    ;;
  decoder_ipc)
    source=decoder_ipc
    archive=wndecoder
    ;;
  timestamp)
    source=timestamp
    archive=wntimestamp
    ;;
  mesh_limits)
    source=mesh_limits
    archive=wnmesh
    ;;
  esac
  KEY="$(cross_key "$stage" "$HERE/app/$source.c" "${APP_HEADERS[@]}")"
  if ! cross_fresh "$stage" "$KEY" "$OUT/$stage.o" "$OUT/lib$archive.a"; then
    "$CC" "${CFLAGS[@]}" -c "$HERE/app/$source.c" -o "$OUT/$stage.o"
    "$AR" rcs "$OUT/lib$archive.a" "$OUT/$stage.o"
    cross_store "$stage" "$KEY" "$OUT/$stage.o" "$OUT/lib$archive.a"
  fi
done
KEY="$(cross_key "math-shim $CAIRO_KEY -std=c++17 Bragi" "$HERE/app/math_shim.cpp" "${APP_HEADERS[@]}" "$HERE/vendor/bragi/capi/include")"
if ! cross_fresh math-shim "$KEY" "$OUT/math/shim.o" "$OUT/libwnmath.a"; then
  "$CXX" "${CFLAGS[@]}" -std=c++17 \
    -isystem "$HERE/vendor/bragi/capi/include" \
    $(pkg-config --cflags cairo) -c "$HERE/app/math_shim.cpp" -o "$OUT/math/shim.o"
  "$AR" rcs "$OUT/libwnmath.a" "$OUT/math/shim.o"
  cross_store math-shim "$KEY" "$OUT/math/shim.o" "$OUT/libwnmath.a"
fi

SYSTEM_LIBS=()
RPATH=()
# Linux needs no link-time rpath: cross-bundle.js replaces the RUNPATH of every
# packaged ELF with one relative to its own place in the package.
case "$SYSTEM" in
Linux) SYSTEM_LIBS=(-pthread -ldl -lm) ;;
Windows) SYSTEM_LIBS=(-lws2_32 -luserenv -lbcrypt -lntdll -ladvapi32 -lcrypt32 -liphlpapi -lsecur32 -lshell32 -lole32 -luuid -luser32 -lgdi32) ;;
Darwin)
  SYSTEM_LIBS=(-framework Security -framework CoreFoundation -framework SystemConfiguration -framework Cocoa -lobjc -liconv -lresolv)
  RPATH=(-Wl,-rpath,@executable_path/../Frameworks)
  ;;
esac
HELPER_ENTRY=()
if [ "$SYSTEM" = Windows ]; then HELPER_ENTRY=(-municode); fi
LINK_ID="$C_ID ${SYSTEM_LIBS[*]} ${RPATH[*]} ${HELPER_ENTRY[*]}"
FONT_KEY="$(cross_pkg_key freetype2)"
KEY="$(cross_key "$LINK_ID font $FONT_KEY" "$HERE/app/font.c" "${APP_HEADERS[@]}")"
if ! cross_fresh font "$KEY" "$OUT/wn-font$EXE"; then
  "$CC" "${CFLAGS[@]}" "$HERE/app/font.c" $(pkg-config --cflags --libs freetype2) \
    "${HELPER_ENTRY[@]}" "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/wn-font$EXE"
  cross_store font "$KEY" "$OUT/wn-font$EXE"
fi
ODIN_ROOT="$(env -u ODIN_ROOT odin root)"
ODIN_ROOT="${ODIN_ROOT%/}"
IMAGE_KEY="$(cross_pkg_key libwebp)"
STB_ID="$(cross_key stb-sources "$ODIN_ROOT/vendor/stb/src")"
KEY="$(cross_key "$LINK_ID image $IMAGE_KEY $STB_ID" "$HERE/app/image.c" "${APP_HEADERS[@]}")"
if ! cross_fresh image "$KEY" "$OUT/wn-image$EXE"; then
  "$CC" "${CFLAGS[@]}" -I"${ODIN_ROOT%/}/vendor/stb/src" "$HERE/app/image.c" \
    $(pkg-config --cflags --libs libwebp) -lm \
    "${HELPER_ENTRY[@]}" "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/wn-image$EXE"
  cross_store image "$KEY" "$OUT/wn-image$EXE"
fi
ARCHIVE_KEY="$(cross_pkg_key libarchive)"
KEY="$(cross_key "$LINK_ID archive $ARCHIVE_KEY" "$HERE/app/archive.c" "${APP_HEADERS[@]}")"
if ! cross_fresh archive "$KEY" "$OUT/wn-archive$EXE"; then
  "$CC" "${CFLAGS[@]}" "$HERE/app/archive.c" $(pkg-config --cflags --libs libarchive) \
    "${HELPER_ENTRY[@]}" "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/wn-archive$EXE"
  cross_store archive "$KEY" "$OUT/wn-archive$EXE"
fi
PDF_KEY="$(cross_pkg_key poppler-glib cairo fontconfig)"
KEY="$(cross_key "$LINK_ID pdf $PDF_KEY" "$HERE/app/pdf.c" "${APP_HEADERS[@]}")"
if ! cross_fresh pdf "$KEY" "$OUT/wn-pdf$EXE"; then
  "$CC" "${CFLAGS[@]}" "$HERE/app/pdf.c" $(pkg-config --cflags --libs poppler-glib cairo fontconfig) -lm \
    "${HELPER_ENTRY[@]}" "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/wn-pdf$EXE"
  cross_store pdf "$KEY" "$OUT/wn-pdf$EXE"
fi
KEY="$(cross_key "$LINK_ID fbx" "$HERE/app/fbx_helper.c" "$HERE/app/fbx_shim.c" "${APP_HEADERS[@]}" "$HERE/vendor/ufbx/ufbx.h" "$OUT/fbx/ufbx.o")"
if ! cross_fresh fbx "$KEY" "$OUT/wn-fbx$EXE"; then
  "$CC" "${CFLAGS[@]}" -I"$HERE/vendor/ufbx" "$HERE/app/fbx_helper.c" "$HERE/app/fbx_shim.c" \
    "$OUT/fbx/ufbx.o" -lm "${HELPER_ENTRY[@]}" "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/wn-fbx$EXE"
  cross_store fbx "$KEY" "$OUT/wn-fbx$EXE"
fi
SPEECH_KEY="$(cross_pkg_key sdl3 libcurl glib-2.0 libcrypto libavformat libavcodec libavutil libswresample)"
TTS_LIBRARY="$TTS/lib/libsherpa-onnx-c-api.so"
if [ "$SYSTEM" = Darwin ]; then
  TTS_LIBRARY="$TTS/lib/libsherpa-onnx-c-api.dylib"
elif [ "$SYSTEM" = Windows ]; then TTS_LIBRARY="$TTS/lib/libsherpa-onnx-c-api.dll.a"; fi
for speech in tts stt; do
  KEY="$(cross_key "$LINK_ID $speech $SPEECH_KEY" "$HERE/app/$speech.c" "${APP_HEADERS[@]}" "$TTS/include" "$TTS_LIBRARY" "$OUT/libwnipc.a")"
  if ! cross_fresh "$speech" "$KEY" "$OUT/wn-$speech$EXE"; then
    "$CC" "${CFLAGS[@]}" -I"$TTS/include" "$HERE/app/$speech.c" "$OUT/libwnipc.a" \
      -L"$TTS/lib" -lsherpa-onnx-c-api \
      $(pkg-config --cflags --libs sdl3 libcurl glib-2.0 libcrypto libavformat libavcodec libavutil libswresample) \
      "${HELPER_ENTRY[@]}" "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/wn-$speech$EXE"
    cross_store "$speech" "$KEY" "$OUT/wn-$speech$EXE"
  fi
done
if [ "$SYSTEM" = Linux ]; then
  LOCATION_KEY="$(cross_pkg_key gio-2.0)"
  KEY="$(cross_key "$LINK_ID location $LOCATION_KEY" "$HERE/app/location.c" "${APP_HEADERS[@]}")"
  if ! cross_fresh location "$KEY" "$OUT/wn-location"; then
    "$CC" "${CFLAGS[@]}" "$HERE/app/location.c" \
      $(pkg-config --cflags --libs gio-2.0) "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/wn-location"
    cross_store location "$KEY" "$OUT/wn-location"
  fi
  WEBVIEW_KEY="$(cross_pkg_key webkit2gtk-4.1)"
  KEY="$(cross_key "$LINK_ID webview $WEBVIEW_KEY" "$HERE/app/webview.c" "${APP_HEADERS[@]}" "$OUT/libwnipc.a")"
  if ! cross_fresh webview "$KEY" "$OUT/wn-webview"; then
    "$CC" "${CFLAGS[@]}" "$HERE/app/webview.c" "$OUT/libwnipc.a" \
      $(pkg-config --cflags --libs webkit2gtk-4.1) "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/wn-webview"
    cross_store webview "$KEY" "$OUT/wn-webview"
  fi
fi

STB_OUTPUTS=()
for stb in image image_write image_resize truetype rect_pack vorbis sprintf; do
  STB_OUTPUTS+=("$OUT/stb/$stb.o")
  KEY="$(cross_key "stb-$stb $STB_ID")"
  if ! cross_fresh "stb-$stb" "$KEY" "$OUT/stb/$stb.o"; then
    "$CC" "${CFLAGS[@]}" -c "$ODIN_ROOT/vendor/stb/src/stb_$stb.c" -o "$OUT/stb/$stb.o"
    cross_store "stb-$stb" "$KEY" "$OUT/stb/$stb.o"
  fi
done
KEY="$(cross_key stb-archive "${STB_OUTPUTS[@]}")"
if ! cross_fresh stb-archive "$KEY" "$OUT/stb/stb.a"; then
  rm -f "$OUT/stb/stb.a"
  "$AR" rcs "$OUT/stb/stb.a" "${STB_OUTPUTS[@]}"
  cross_store stb-archive "$KEY" "$OUT/stb/stb.a"
fi
KEY="$(cross_key cgltf "$ODIN_ROOT/vendor/cgltf/src")"
if ! cross_fresh cgltf "$KEY" "$OUT/cgltf.o" "$OUT/cgltf.a"; then
  "$CC" "${CFLAGS[@]}" -c "$ODIN_ROOT/vendor/cgltf/src/cgltf.c" -o "$OUT/cgltf.o"
  "$AR" rcs "$OUT/cgltf.a" "$OUT/cgltf.o"
  cross_store cgltf "$KEY" "$OUT/cgltf.o" "$OUT/cgltf.a"
fi
# Vendor bindings check archive existence while type-checking, even for
# object-only builds. Keep target archives in a private compiler-root overlay.
ODIN_INPUTS=("$(command -v odin)" "$ODIN_ROOT/base" "$ODIN_ROOT/core" "$ODIN_ROOT/shared")
# Hash binding sources, not the SDK's unused prebuilt archives. The compiler
# root path and source filenames are included, so upgrades/additions invalidate.
ODIN_LIST="$(mktemp)"
find -L "$ODIN_ROOT/vendor" \( -name .git -o -name .hg -o -name .svn -o -name .env -o -name '*.env' \) -prune -o -name '*.odin' -print0 >"$ODIN_LIST"
while IFS= read -r -d '' entry; do ODIN_INPUTS+=("$entry"); done <"$ODIN_LIST"
CLAY_BINDINGS=()
find -L "$HERE/vendor/clay/bindings/odin/clay-odin" \( -name .git -o -name .hg -o -name .svn -o -name .env -o -name '*.env' \) -prune -o -name '*.odin' -print0 >"$ODIN_LIST"
while IFS= read -r -d '' entry; do CLAY_BINDINGS+=("$entry"); done <"$ODIN_LIST"
rm -f "$ODIN_LIST"
ODIN_ID="$(build_cache_key "odin $ODIN_ROOT $ODIN_TARGET $TARGET -o:speed -build-mode:obj" "${ODIN_INPUTS[@]}")"
OVERLAY="$OUT/odin-root"
KEY="$(cross_key "overlay $ODIN_ID" "$ODIN_ROOT/vendor/stb/src" "$ODIN_ROOT/vendor/cgltf/src" "${STB_OUTPUTS[@]}" "$OUT/cgltf.a")"
OVERLAY_LINKS=1
for entry in "$ODIN_ROOT/base" "$ODIN_ROOT/core" "$ODIN_ROOT/shared" "$ODIN_ROOT/vendor/"*; do
  name="$(basename "$entry")"
  case "$entry" in
  "$ODIN_ROOT/vendor/stb" | "$ODIN_ROOT/vendor/cgltf") continue ;;
  "$ODIN_ROOT/vendor/"*) path="$OVERLAY/vendor/$name" ;;
  *) path="$OVERLAY/$name" ;;
  esac
  if [ ! -L "$path" ] || [ "$(readlink "$path")" != "$entry" ]; then OVERLAY_LINKS=0; fi
done
if ! cross_fresh odin-overlay "$KEY" "$OVERLAY/vendor/stb" "$OVERLAY/vendor/cgltf" || [ "$OVERLAY_LINKS" != 1 ]; then
  rm -f "$OUT/odin-overlay.cache"
  rm -rf "$OVERLAY"
  mkdir -p "$OVERLAY/vendor"
  ln -sfn "$ODIN_ROOT/base" "$ODIN_ROOT/core" "$ODIN_ROOT/shared" "$OVERLAY/"
  for entry in "$ODIN_ROOT/vendor/"*; do
    case "$(basename "$entry")" in
    stb | cgltf) cp -a "$entry" "$OVERLAY/vendor/" ;;
    *) ln -sfn "$entry" "$OVERLAY/vendor/" ;;
    esac
  done
  SUFFIX=a
  SUBDIR=
  if [ "$SYSTEM" = Windows ]; then SUFFIX=lib; fi
  if [ "$SYSTEM" = Darwin ]; then SUBDIR=/darwin; fi
  rm -rf "$OVERLAY/vendor/stb/lib" "$OVERLAY/vendor/cgltf/lib"
  mkdir -p "$OVERLAY/vendor/stb/lib$SUBDIR" "$OVERLAY/vendor/cgltf/lib$SUBDIR"
  # Replace, never update: `ar rcs` edits an existing archive in place, and the
  # copied Odin tree ships prebuilt ones (universal on macOS, which ar rejects).
  for stb in image image_write image_resize truetype rect_pack vorbis sprintf; do
    rm -f "$OVERLAY/vendor/stb/lib$SUBDIR/stb_$stb.$SUFFIX"
    "$AR" rcs "$OVERLAY/vendor/stb/lib$SUBDIR/stb_$stb.$SUFFIX" "$OUT/stb/$stb.o"
  done
  cp "$OUT/cgltf.a" "$OVERLAY/vendor/cgltf/lib$SUBDIR/cgltf.$SUFFIX"
  cross_store odin-overlay "$KEY" "$OVERLAY/vendor/stb" "$OVERLAY/vendor/cgltf"
fi
export ODIN_ROOT="$OVERLAY"
WINDOWS_RUNTIME=()
if [ "$SYSTEM" = Windows ]; then
  KEY="$(cross_key mingw-runtime "$HERE/app/mingw_shim.c" "${APP_HEADERS[@]}")"
  if ! cross_fresh mingw-runtime "$KEY" "$OUT/mingw_shim.o"; then
    "$CC" "${CFLAGS[@]}" -c "$HERE/app/mingw_shim.c" -o "$OUT/mingw_shim.o"
    cross_store mingw-runtime "$KEY" "$OUT/mingw_shim.o"
  fi
  WINDOWS_RUNTIME=("$OUT/mingw_shim.o")
fi
KEY="$(cross_key "mesh-object $ODIN_ID" "$HERE/model-decoder")"
if ! cross_fresh mesh-object "$KEY" "$OUT/mesh.o"; then
  odin build "$HERE/model-decoder" -target:"$ODIN_TARGET" -define:WN_TARGET="$TARGET" \
    -o:speed -build-mode:obj -out:"$OUT/mesh.o"
  cross_store mesh-object "$KEY" "$OUT/mesh.o"
fi
KEY="$(cross_key "$LINK_ID mesh-link" "$OUT/mesh.o" "${WINDOWS_RUNTIME[@]}" "$OUT/libwnmesh.a" "$OUT/cgltf.a")"
if ! cross_fresh mesh-link "$KEY" "$OUT/wn-mesh$EXE"; then
  "$CC" "${CFLAGS[@]}" "$OUT/mesh.o" "${WINDOWS_RUNTIME[@]}" "$OUT/libwnmesh.a" "$OUT/cgltf.a" \
    -lm "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/wn-mesh$EXE"
  cross_store mesh-link "$KEY" "$OUT/wn-mesh$EXE"
fi
KEY="$(cross_key "math-object $ODIN_ID" "$HERE/math-decoder" "$HERE/vendor/bragi")"
if ! cross_fresh math-object "$KEY" "$OUT/math.o"; then
  odin build "$HERE/math-decoder" -target:"$ODIN_TARGET" -define:WN_TARGET="$TARGET" \
    -o:speed -build-mode:obj -out:"$OUT/math.o"
  cross_store math-object "$KEY" "$OUT/math.o"
fi
KEY="$(cross_key "$LINK_ID math-link $CAIRO_KEY" "$OUT/math.o" "${WINDOWS_RUNTIME[@]}" "$OUT/libwnmath.a")"
if ! cross_fresh math-link "$KEY" "$OUT/wn-math$EXE"; then
  "$CXX" "${CFLAGS[@]}" "$OUT/math.o" "${WINDOWS_RUNTIME[@]}" "$OUT/libwnmath.a" \
    $(pkg-config --libs cairo) \
    "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/wn-math$EXE"
  cross_store math-link "$KEY" "$OUT/wn-math$EXE"
fi
KEY="$(cross_key "nes-object $ODIN_ID" "$HERE/nes-decoder")"
if ! cross_fresh nes-object "$KEY" "$OUT/nes.o"; then
  odin build "$HERE/nes-decoder" -target:"$ODIN_TARGET" -define:WN_TARGET="$TARGET" \
    -o:speed -build-mode:obj -out:"$OUT/nes.o"
  cross_store nes-object "$KEY" "$OUT/nes.o"
fi
KEY="$(cross_key "$LINK_ID nes-link" "$OUT/nes.o" "${WINDOWS_RUNTIME[@]}" "$OUT/libwnmesh.a")"
if ! cross_fresh nes-link "$KEY" "$OUT/wn-nes$EXE"; then
  "$CC" "${CFLAGS[@]}" "$OUT/nes.o" "${WINDOWS_RUNTIME[@]}" "$OUT/libwnmesh.a" \
    -lm "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/wn-nes$EXE"
  cross_store nes-link "$KEY" "$OUT/wn-nes$EXE"
fi
# Odin does not cross-link different OSes. Link its native object with the
# target driver; Bragi and Cairo belong only to the math helper.
# Archive existence is checked by Odin, but archive bytes do not affect an
# object-only compile. In particular MDK edits must change only the final link.
KEY="$(cross_key "app-object $ODIN_ID" "$HERE/app" "$HERE/marmot" \
  "${CLAY_BINDINGS[@]}" "$HERE/vendor/crop-circles" "$HERE/lang" "$HERE/themes" \
  "$HERE/vendor/common-passwords.txt" "$HERE/build/observability-tokens.toml")"
if ! cross_fresh app-object "$KEY" "$OUT/app.o"; then
  odin build "$HERE/app" -target:"$ODIN_TARGET" -define:WN_TARGET="$TARGET" \
    -o:speed -build-mode:obj -out:"$OUT/app.o"
  cross_store app-object "$KEY" "$OUT/app.o"
fi
APP_LINK_ARGS=()
if [ "$SYSTEM" = Windows ]; then
  APP_LINK_ARGS=("${WINDOWS_RUNTIME[@]}" "$OUT/velopack/libvelopack_libc.dll.a")
elif [ "$SYSTEM" = Linux ]; then
  # System libssl must not resolve crypto calls to Marmot's bundled OpenSSL.
  APP_LINK_ARGS=(-Wl,--exclude-libs=libmarmot_c.a "$OUT/libwnappimage.a")
elif [ "$SYSTEM" = Darwin ]; then
  APP_LINK_ARGS=("$OUT/libwnsparkle.a")
fi
APP_LINK_INPUTS=("$OUT/app.o" "$OUT/libwnws.a" "$OUT/libwnipc.a" "$OUT/libwndecoder.a" "$OUT/libwntimestamp.a"
  "$OUT/clay/clay.a" "$OUT/stb/stb.a" "$OUT/libmarmot_c.a")
case "$SYSTEM" in
Windows) APP_LINK_INPUTS+=("${WINDOWS_RUNTIME[@]}" "$OUT/velopack/libvelopack_libc.dll.a") ;;
Linux) APP_LINK_INPUTS+=("$OUT/libwnappimage.a") ;;
Darwin) APP_LINK_INPUTS+=("$OUT/libwnsparkle.a") ;;
esac
APP_PKG_KEY="$(cross_pkg_key sdl3 mpv libcurl openssl)"
KEY="$(cross_key "$LINK_ID app-link $APP_PKG_KEY ${APP_LINK_ARGS[*]}" "${APP_LINK_INPUTS[@]}")"
if ! cross_fresh app-link "$KEY" "$OUT/whitenoise$EXE"; then
  "$CC" "${CFLAGS[@]}" "$OUT/app.o" "${APP_LINK_ARGS[@]}" \
    "$OUT/libwnws.a" "$OUT/libwnipc.a" "$OUT/libwndecoder.a" "$OUT/libwntimestamp.a" \
    "$OUT/clay/clay.a" "$OUT/stb/stb.a" "$OUT/libmarmot_c.a" \
    $(pkg-config --libs sdl3 mpv libcurl openssl) \
    "${SYSTEM_LIBS[@]}" "${RPATH[@]}" -o "$OUT/whitenoise$EXE"
  cross_store app-link "$KEY" "$OUT/whitenoise$EXE"
fi
# Export only paths consumed by packaging; do not serialize credentials/SDKs.
export WN_CROSS_PREFIX="$PREFIX" WN_CROSS_SYSROOT="$SYSROOT" WN_CROSS_TTS="$TTS"
export WN_CROSS_WINDOWS_RUNTIME="${LLVM_MINGW:-}" WN_CROSS_VELOPACK="${VELOPACK:-}"
export WN_CROSS_SPARKLE="$SPARKLE"
bash "$HERE/scripts/cross-package.sh" "$TARGET"
