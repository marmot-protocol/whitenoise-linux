#!/usr/bin/env bash
# Sourced after cross-toolchain.sh; every compiler invocation targets TARGET.
set -euo pipefail
if [ "$TARGET" = linux-arm64 ]; then
  SDL_VERSION=3.4.14
  if [ ! -d "$OUT/SDL" ]; then
    git clone --depth 1 -b "release-$SDL_VERSION" https://github.com/libsdl-org/SDL.git "$OUT/SDL"
  fi
  if ! WAYLAND_SCANNER="$(command -v wayland-scanner)"; then
    echo 'Install host libwayland-bin: ARM64 SDL requires a Linux-hosted wayland-scanner.' >&2
    exit 1
  fi
  cmake -S "$OUT/SDL" -B "$OUT/sdl-build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$OUT/toolchain.cmake" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF \
    -DSDL_WAYLAND=ON -DSDL_X11=ON -DSDL_WAYLAND_SHARED=OFF -DWAYLAND_SCANNER="$WAYLAND_SCANNER"
  # SDL's options express intent, not successful detection. Its normal check
  # accepts either desktop backend; our Linux packages require both.
  for backend in WAYLAND X11; do
    if ! grep -q "^#define SDL_VIDEO_DRIVER_$backend 1$" "$OUT/sdl-build/include-config-release/build_config/SDL_build_config.h"; then
      echo "SDL configuration is missing required $backend support." >&2
      exit 1
    fi
  done
  cmake --build "$OUT/sdl-build" -j"$JOBS"
  DESTDIR="$SYSROOT" cmake --install "$OUT/sdl-build"
else
  checkout vcpkg https://github.com/microsoft/vcpkg.git "$(pin vcpkg)"
  VCPKG="$HERE/vendor/vcpkg"
  "$VCPKG/bootstrap-vcpkg.sh" -disableMetrics
  VCPKG_ARCH=x64; [ "$CPU" != aarch64 ] || VCPKG_ARCH=arm64
  VCPKG_SYSTEM="$SYSTEM"; [ "$SYSTEM" != Windows ] || VCPKG_SYSTEM=MinGW
  VCPKG_TRIPLET="$TARGET"
  if [ "$SYSTEM" = Windows ]; then VCPKG_TRIPLET="$TARGET-llvm-ucrt"; fi
  cat > "$OUT/triplets/$VCPKG_TRIPLET.cmake" <<CMAKE
set(VCPKG_TARGET_ARCHITECTURE $VCPKG_ARCH)
set(VCPKG_CMAKE_SYSTEM_NAME $VCPKG_SYSTEM)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)
set(VCPKG_BUILD_TYPE release)
set(VCPKG_CHAINLOAD_TOOLCHAIN_FILE "$OUT/toolchain.cmake")
CMAKE
  # vcpkg treats an arm64 Mac building darwin-arm64 as native and puts the
  # prefix include/link flags in its --native file; an extra --cross file
  # then compiles the host side without them (glib: no libintl.h). vcpkg
  # describes Darwin hosts itself, so only non-Apple targets need ours.
  if [ "$SYSTEM" != Darwin ]; then
    echo "set(VCPKG_MESON_CROSS_FILE \"$OUT/meson.ini\")" >> "$OUT/triplets/$VCPKG_TRIPLET.cmake"
  fi
  if [ "$SYSTEM" = Windows ]; then
    cat >> "$OUT/triplets/$VCPKG_TRIPLET.cmake" <<'CMAKE'
# PE has no ELF symbol versioning; libffi otherwise assumes GNU-style ld
# implies ELF even when LLVM's linker is correctly configured for Windows.
if(PORT STREQUAL "libffi")
  set(VCPKG_MAKE_CONFIGURE_OPTIONS --disable-symvers)
endif()
CMAKE
  fi
  # Build-machine tools (code generators) are built for the host itself.
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) HOST_TRIPLET=arm64-osx ;;
    Darwin-x86_64) HOST_TRIPLET=x64-osx ;;
    *) HOST_TRIPLET=x64-linux ;;
  esac
  # Do not expose target CC/pkg-config to build-machine code generators.
  env -u CC -u CXX -u AR -u PKG_CONFIG_SYSROOT_DIR -u PKG_CONFIG_LIBDIR \
    "$VCPKG/vcpkg" install --triplet "$VCPKG_TRIPLET" --host-triplet "$HOST_TRIPLET" \
    --overlay-triplets="$OUT/triplets" --x-manifest-root="$HERE/packaging/cross" \
    --x-install-root="$OUT/vcpkg-installed"
  PREFIX="$OUT/vcpkg-installed/$VCPKG_TRIPLET"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
  export PKG_CONFIG_SYSROOT_DIR=
  # libmpv is not a vcpkg port. It uses software RGBA rendering in this app;
  # its CLI, Swift/Cocoa window backend and GPU backends are not app features.
  checkout libplacebo https://github.com/haasn/libplacebo.git "$(pin libplacebo)"
  git -C "$HERE/vendor/libplacebo" submodule update --init --recursive
  meson setup "$OUT/libplacebo" "$HERE/vendor/libplacebo" --reconfigure \
    --cross-file "$OUT/meson.ini" --prefix "$PREFIX" --libdir lib --buildtype release \
    -Ddefault_library=shared -Ddemos=false -Dtests=false -Dvulkan=disabled \
    -Dopengl=disabled -Dd3d11=disabled -Dshaderc=disabled -Dglslang=disabled
  meson compile -C "$OUT/libplacebo" -j "$JOBS"
  meson install -C "$OUT/libplacebo"
  checkout mpv https://github.com/mpv-player/mpv.git "$(pin mpv)"
  # The app renders through the software API into an RGBA buffer and never
  # enables hwdec, so mpv's GPU outputs and D3D decoders are unused.
  meson setup "$OUT/mpv" "$HERE/vendor/mpv" --reconfigure \
    --cross-file "$OUT/meson.ini" --prefix "$PREFIX" --libdir lib --buildtype release \
    -Dlibmpv=true -Dcplayer=false -Dtests=false -Dmanpage-build=disabled \
    -Dswift-build=disabled -Dcocoa=disabled -Dgl=disabled -Dvulkan=disabled \
    -Dd3d11=disabled -Ddirect3d=disabled -Dd3d-hwaccel=disabled -Dd3d9-hwaccel=disabled
  meson compile -C "$OUT/mpv" -j "$JOBS"
  meson install -C "$OUT/mpv"
fi

# Use upstream's pinned CPU C runtime, as the native build does. Target-specific
# caches prevent a host sherpa .so from being mistaken for a target dependency.
TTS="$OUT/sherpa-onnx"
mkdir -p "$TTS/include/sherpa-onnx/c-api" "$OUT/tts-lib"
case "$TARGET" in
  linux-arm64)
    archive=sherpa-onnx-v1.13.7-linux-aarch64-shared-cpu-lib.tar.bz2
    digest=306001f71409c73e8c4bfe117f410daab7e551a5dc4e1f22d75738b2ce0c8051 ;;
  windows-amd64)
    archive=sherpa-onnx-v1.13.7-win-x64-shared-MT-Release-lib.tar.bz2
    digest=7a362a9f339a2937e7f8806e904f3e8a031a7774982eea08bca8336b2c257529 ;;
  darwin-amd64)
    archive=sherpa-onnx-v1.13.7-osx-x64-shared-lib.tar.bz2
    digest=24182aef70b889868dbfd943a7f2246383dd1cd196b9b86c20b9642e7b2c396f ;;
  darwin-arm64)
    archive=sherpa-onnx-v1.13.7-osx-arm64-shared-lib.tar.bz2
    digest=c51e220217f2ce5d3de211887dc13ad49bf22346a2025a4159591d892008242d ;;
esac
fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.7/$archive" "$TTS/runtime.tar.bz2" "$digest"
tar --no-same-owner -xjf "$TTS/runtime.tar.bz2" --strip-components=1 -C "$TTS"
fetch "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$(pin sherpa-onnx)/sherpa-onnx/c-api/c-api.h" \
  "$TTS/include/sherpa-onnx/c-api/c-api.h" 426db2c6acfb51e02143aece67c45779fae699d961c7c26ccf6f1388fdeaa2df
fetch "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$(pin sherpa-onnx)/LICENSE" \
  "$TTS/LICENSE" cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
fetch https://raw.githubusercontent.com/microsoft/onnxruntime/v1.27.1/LICENSE \
  "$TTS/LICENSE-onnxruntime" 2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c
fetch https://raw.githubusercontent.com/microsoft/onnxruntime/v1.27.1/ThirdPartyNotices.txt \
  "$TTS/ThirdPartyNotices-onnxruntime.txt" 0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2
if [ "$SYSTEM" = Windows ]; then
  # GNU ld accepts PE import libraries, but using gendef/dlltool makes the ABI
  # explicit and avoids depending on Microsoft's import-library format.
  SHERPA_DLL="$(find "$TTS" -name sherpa-onnx-c-api.dll -print -quit)"
  test -n "$SHERPA_DLL"
  (cd "$OUT" && gendef "$SHERPA_DLL")
  "$DLLTOOL" -m i386:x86-64 -d "$OUT/sherpa-onnx-c-api.def" \
    -l "$TTS/lib/libsherpa-onnx-c-api.dll.a" -D sherpa-onnx-c-api.dll
fi

# Velopack's C library: the in-app half of Windows self-updates. packaging
# installs the vpk CLI at this same version, which the library expects.
if [ "$SYSTEM" = Windows ]; then
  VELOPACK="$OUT/velopack"
  mkdir -p "$VELOPACK"
  fetch "https://github.com/velopack/velopack/releases/download/$VELOPACK_VERSION/velopack_libc_$VELOPACK_VERSION.zip" \
    "$VELOPACK/libc.zip" 63438c5d87b01d93853d0259a0d86eefccea8347914bd84fb58edbb5a71e05da
  fetch "https://raw.githubusercontent.com/velopack/velopack/$VELOPACK_VERSION/LICENSE" \
    "$VELOPACK/LICENSE" 91845db83551c877ebbb1118e0fb92e4e527290d23b995c55dcd438b3293943f
  unzip -o -q -j "$VELOPACK/libc.zip" lib/velopack_libc_win_x64_msvc.dll -d "$VELOPACK/lib"
  # The DLL links its CRT statically and imports only OS DLLs, so the
  # MSVC build loads beside the UCRT app; only the import library is ours.
  (cd "$OUT" && gendef "$VELOPACK/lib/velopack_libc_win_x64_msvc.dll")
  "$DLLTOOL" -m i386:x86-64 -d "$OUT/velopack_libc_win_x64_msvc.def" \
    -l "$VELOPACK/libvelopack_libc.dll.a" -D velopack_libc_win_x64_msvc.dll
  # vpk from a verified local nupkg only: the temporary NuGet config clears
  # every remote source, so the digest above is what gets installed.
  if [ ! -x "$VELOPACK/vpk/vpk" ]; then
    feed="$VELOPACK/feed"
    mkdir -p "$feed"
    fetch "https://www.nuget.org/api/v2/package/vpk/$VELOPACK_VERSION" "$feed/vpk.$VELOPACK_VERSION.nupkg" \
      acbd53884f96d1b0c08f68117620cd9d5bf1e8b9cb6b6bd253a7fd36dfe01ee7
    printf '<configuration><packageSources><clear /><add key="local" value="%s" /></packageSources></configuration>\n' \
      "$feed" > "$feed/nuget.config"
    dotnet tool install vpk --version "$VELOPACK_VERSION" --tool-path "$VELOPACK/vpk" --configfile "$feed/nuget.config"
  fi
fi
