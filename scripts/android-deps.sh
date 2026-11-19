#!/usr/bin/env bash
# All sources and generated files are target-local; vendor/ is read-only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-android-arm64}"
COMPONENT="${2:-all}"
case "$TARGET" in
  android-amd64) ABI=x86_64; ARCH=x64; CPU=x86_64; TRIPLE=x86_64-linux-android ;;
  android-arm64) ABI=arm64-v8a; ARCH=arm64; CPU=aarch64; TRIPLE=aarch64-linux-android ;;
  *) echo 'Usage: android-deps.sh android-amd64|android-arm64 [all|sdl|stb|vcpkg|mpv]' >&2; exit 2 ;;
esac
case "$COMPONENT" in all|sdl|stb|vcpkg|mpv) ;; *) echo "Unknown component: $COMPONENT" >&2; exit 2 ;; esac
OUT="$HERE/build/cross/$TARGET"
PREFIX="$OUT/prefix"
mkdir -p "$OUT" "$PREFIX/lib" "$PREFIX/include" "$PREFIX/bin"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
NDK="${WN_ANDROID_NDK:-$SDK/ndk/30.0.16248370}"
test -f "$NDK/build/cmake/android.toolchain.cmake"
API=29
TOOLBIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
CC="$TOOLBIN/${TRIPLE}${API}-clang"
CXX="$TOOLBIN/${TRIPLE}${API}-clang++"
AR="$TOOLBIN/llvm-ar"
JOBS=6
export ANDROID_NDK_HOME="$NDK" ANDROID_NDK_ROOT="$NDK" VCPKG_MAX_CONCURRENCY="$JOBS"
export CMAKE_BUILD_PARALLEL_LEVEL="$JOBS"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH= PKG_CONFIG_SYSROOT_DIR=
PIN_FILE="$HERE/DEPS_PIN"
MANIFEST="$HERE/packaging/android/deps-manifest.json"
pin() {
  local key equal value
  while read -r key equal value; do
    if [ "$key" = "$1-commit" ]; then printf '%s\n' "$value"; return; fi
  done < "$PIN_FILE"
  echo "Missing dependency pin: $1" >&2; return 1
}
checkout() {
  local name="$1" url="$2" revision="$3" source="$OUT/$1"
  if [ ! -d "$source/.git" ]; then
    if [ -d "$HERE/vendor/$name/.git" ] || [ -f "$HERE/vendor/$name/.git" ]; then
      git clone --no-hardlinks "$HERE/vendor/$name" "$source"
    else
      git clone --filter=blob:none "$url" "$source"
    fi
  fi
  if ! git -C "$source" cat-file -e "$revision^{commit}" 2>/dev/null; then
    git -C "$source" fetch "$url" "$revision"
  fi
  git -C "$source" checkout --detach "$revision"
}
recipe="$(sha256sum < "$HERE/scripts/android-deps.sh")"
ndk_stamp="$(sha256sum < "$NDK/source.properties")"
stamp_key() { printf '%s\n' "$recipe" "$ndk_stamp" "$TARGET" "$@" | sha256sum | cut -d' ' -f1; }
fresh() { [ -f "$OUT/$1.stamp" ] && [ "$(cat "$OUT/$1.stamp")" = "$2" ]; }
stamp() { printf '%s\n' "$2" > "$OUT/$1.stamp"; }
fetch_archive() {
  local archive="$1" sha="$2" url="$3"
  if printf '%s  %s\n' "$sha" "$archive" | sha256sum -c --status 2>/dev/null; then return; fi
  curl -fL --retry 3 --remove-on-error "$url" -o "$archive.part"
  printf '%s  %s\n' "$sha" "$archive.part" | sha256sum -c -
  mv -f "$archive.part" "$archive"
}

if [ "$COMPONENT" = all ] || [ "$COMPONENT" = sdl ]; then
  sdl_pin="$(pin sdl-android)"
  key="$(stamp_key "$sdl_pin")"
  if ! fresh sdl "$key"; then
    checkout SDL https://github.com/libsdl-org/SDL.git "$sdl_pin"
    cmake --fresh -S "$OUT/SDL" -B "$OUT/sdl-build" -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API" -DANDROID_STL=c++_shared \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON \
      '-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384' \
      -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
      -DSDL_INSTALL=ON -DSDL_ANDROID_JAR=OFF
    cmake --build "$OUT/sdl-build" -j "$JOBS"
    cmake --install "$OUT/sdl-build"
    stamp sdl "$key"
  fi
fi

if [ "$COMPONENT" = all ] || [ "$COMPONENT" = stb ]; then
  odin_root="$(env -u ODIN_ROOT odin root)"
  odin_root="${odin_root%/}"
  mkdir -p "$OUT/stb"
  # Preserve Odin's per-module archive names and provide one aggregate archive
  # for callers that link the entire Odin application as a single object.
  for module in image image_write image_resize truetype rect_pack vorbis sprintf; do
    "$CC" -O2 -fPIC -c "$odin_root/vendor/stb/src/stb_$module.c" -o "$OUT/stb/$module.o"
    "$AR" rcs "$OUT/stb/stb_$module.a" "$OUT/stb/$module.o"
    cp "$OUT/stb/stb_$module.a" "$PREFIX/lib/"
  done
  "$AR" rcs "$OUT/stb/stb.a" "$OUT/stb/"*.o
  cp "$OUT/stb/stb.a" "$PREFIX/lib/libstb.a"
fi

if [ "$COMPONENT" = all ] || [ "$COMPONENT" = vcpkg ]; then
  vcpkg_pin="$(pin vcpkg)"
  key="$(stamp_key "$vcpkg_pin" "$(sha256sum < "$MANIFEST")")"
  if ! fresh vcpkg "$key"; then
    checkout vcpkg https://github.com/microsoft/vcpkg.git "$vcpkg_pin"
    VCPKG="$OUT/vcpkg"
    if [ ! -x "$VCPKG/vcpkg" ]; then "$VCPKG/bootstrap-vcpkg.sh" -disableMetrics; fi
    mkdir -p "$OUT/triplets" "$OUT/deps-manifest" "$OUT/downloads" "$OUT/empty-pkgconfig"
    # The host may have autotools without the GNU archive macros. Keep these
    # pinned build-machine inputs local instead of installing system packages.
    archive="$OUT/downloads/autoconf-archive-2024.10.16.tar.xz"
    fetch_archive "$archive" 7bcd5d001916f3a50ed7436f4f700e3d2b1bade3ed803219c592d62502a57363 \
      https://ftpmirror.gnu.org/autoconf-archive/autoconf-archive-2024.10.16.tar.xz
    tar -xJf "$archive" -C "$OUT"
    export ACLOCAL_PATH="$OUT/autoconf-archive-2024.10.16/m4${ACLOCAL_PATH:+:$ACLOCAL_PATH}"
    # dav1d/FFmpeg use NASM on x86; it is a build-machine executable.
    if ! command -v nasm >/dev/null; then
      archive="$OUT/downloads/nasm-3.01.tar.xz"
      fetch_archive "$archive" b7324cbe86e767b65f26f467ed8b12ad80e124e3ccb89076855c98e43a9eddd4 \
        https://www.nasm.us/pub/nasm/releasebuilds/3.01/nasm-3.01.tar.xz
      if [ ! -x "$OUT/host/bin/nasm" ]; then
        tar -xJf "$archive" -C "$OUT"
        (cd "$OUT/nasm-3.01" && env -u CC -u CXX -u AR ./configure --prefix="$OUT/host" && make -j "$JOBS" && make install)
      fi
      export PATH="$OUT/host/bin:$PATH"
    fi
    cp "$MANIFEST" "$OUT/deps-manifest/vcpkg.json"
    cat > "$OUT/triplets/$TARGET.cmake" <<CMAKE
set(VCPKG_TARGET_ARCHITECTURE $ARCH)
set(VCPKG_CMAKE_SYSTEM_NAME Android)
set(VCPKG_CMAKE_SYSTEM_VERSION $API)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)
set(VCPKG_BUILD_TYPE release)
set(VCPKG_MAKE_BUILD_TRIPLET "--host=$TRIPLE")
set(VCPKG_CMAKE_CONFIGURE_OPTIONS -DANDROID_ABI=$ABI -DANDROID_PLATFORM=android-$API -DANDROID_STL=c++_shared -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON)
set(VCPKG_C_FLAGS "-fPIC")
set(VCPKG_CXX_FLAGS "-fPIC")
set(VCPKG_LINKER_FLAGS "-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384")
CMAKE
    # vcpkg supplies each package's search path. Do not fall back to /usr's
    # host .pc files for optional target dependencies (e.g. libunibreak).
    env -u CC -u CXX -u AR -u PKG_CONFIG_PATH -u PKG_CONFIG_SYSROOT_DIR \
      PKG_CONFIG_LIBDIR="$OUT/empty-pkgconfig" VCPKG_DOWNLOADS="$OUT/downloads" "$VCPKG/vcpkg" install \
      --triplet "$TARGET" --host-triplet x64-linux --overlay-triplets="$OUT/triplets" \
      --x-manifest-root="$OUT/deps-manifest" --x-install-root="$OUT/vcpkg-installed" \
      --x-buildtrees-root="$OUT/buildtrees" --x-packages-root="$OUT/packages"
    cp -a "$OUT/vcpkg-installed/$TARGET/." "$PREFIX/"
    # vcpkg installs executable tools below tools/<port>, not bin/.
    install -m755 "$PREFIX/tools/curl/curl" "$PREFIX/bin/curl"
    stamp vcpkg "$key"
  fi
fi

if [ "$COMPONENT" = all ] || [ "$COMPONENT" = mpv ]; then
  placebo_pin="$(pin libplacebo)"
  mpv_pin="$(pin mpv)"
  key="$(stamp_key "$placebo_pin" "$mpv_pin" "$(pin vcpkg)" "$(sha256sum < "$MANIFEST")")"
  if ! fresh mpv "$key"; then
    checkout libplacebo https://github.com/haasn/libplacebo.git "$placebo_pin"
    checkout mpv https://github.com/mpv-player/mpv.git "$mpv_pin"
    cat > "$OUT/meson-android.ini" <<MESON
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$TOOLBIN/llvm-strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'android'
cpu_family = '$CPU'
cpu = '$CPU'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = ['-fPIC', '-D_FILE_OFFSET_BITS=64']
cpp_args = ['-fPIC', '-D_FILE_OFFSET_BITS=64']
c_link_args = ['-Wl,-z,max-page-size=16384', '-Wl,-z,common-page-size=16384']
cpp_link_args = ['-Wl,-z,max-page-size=16384', '-Wl,-z,common-page-size=16384']
MESON
    git -C "$OUT/libplacebo" submodule update --init --recursive
    meson setup "$OUT/libplacebo-build" "$OUT/libplacebo" --wipe \
      --cross-file "$OUT/meson-android.ini" --prefix "$PREFIX" --libdir lib --buildtype release \
      -Ddefault_library=shared -Ddemos=false -Dtests=false -Dvulkan=disabled \
      -Dopengl=disabled -Dd3d11=disabled -Dshaderc=disabled -Dglslang=disabled
    meson compile -C "$OUT/libplacebo-build" -j "$JOBS"
    meson install -C "$OUT/libplacebo-build"
    meson setup "$OUT/mpv-build" "$OUT/mpv" --wipe \
      --cross-file "$OUT/meson-android.ini" --prefix "$PREFIX" --libdir lib --buildtype release \
      -Dlibmpv=true -Dcplayer=false -Dtests=false -Dmanpage-build=disabled \
      -Dswift-build=disabled -Dcocoa=disabled -Dgl=disabled -Dvulkan=disabled \
      -Dd3d11=disabled -Ddirect3d=disabled -Dd3d-hwaccel=disabled -Dd3d9-hwaccel=disabled \
      -Degl=disabled -Degl-android=disabled -Dandroid-media-ndk=disabled
    meson compile -C "$OUT/mpv-build" -j "$JOBS"
    meson install -C "$OUT/mpv-build"
    stamp mpv "$key"
  fi
fi
cp "$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/$TRIPLE/libc++_shared.so" "$PREFIX/lib/"
printf 'Android dependencies: %s\nSDL Java sources: %s\n' "$PREFIX" "$OUT/SDL/android-project/app/src/main/java"
