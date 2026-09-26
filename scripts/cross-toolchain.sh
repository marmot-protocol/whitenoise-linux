#!/usr/bin/env bash
# Sourced by cross-build.sh. No target executable is run while compiling.
set -euo pipefail
pin() { sed -n "s/^$1-commit = //p" "$HERE/DEPS_PIN"; }
checkout() {
  local name="$1" url="$2" revision="$3" dir="$HERE/vendor/$1"
  if [ ! -d "$dir/.git" ]; then git clone --filter=blob:none "$url" "$dir"; fi
  if [ "$(git -C "$dir" rev-parse HEAD)" != "$revision" ]; then
    git -C "$dir" fetch origin "$revision"
    git -C "$dir" checkout --detach "$revision"
  fi
}
fetch() {
  local url="$1" path="$2" digest="$3"
  if [ -f "$path" ] && printf '%s  %s\n' "$digest" "$path" | sha256sum -c --status; then return; fi
  curl -fL --retry 3 "$url" -o "$path.part"
  printf '%s  %s\n' "$digest" "$path.part" | sha256sum -c
  mv "$path.part" "$path"
}
PREFIX="$OUT/vcpkg-installed/$TARGET"
SYSROOT=
EXE=
case "$TARGET" in
  linux-arm64)
    RUST_TARGET=aarch64-unknown-linux-gnu; ODIN_TARGET=linux_arm64
    CPU=aarch64; SYSTEM=Linux; CC=aarch64-linux-gnu-gcc; CXX=aarch64-linux-gnu-g++
    AR=aarch64-linux-gnu-ar; STRIP=aarch64-linux-gnu-strip; OBJCOPY=aarch64-linux-gnu-objcopy
    SYSROOT="$OUT/sysroot"
    if [ ! -f "$SYSROOT/.complete" ]; then
      # extract mode downloads and unpacks arm64 packages without chrooting or
      # emulating a compiler; GCC above remains an amd64 Linux executable.
      mmdebstrap --mode=root --variant=extract --architectures=arm64 \
        --include=libc6-dev,libstdc++-13-dev,libarchive-dev,libwebp-dev,libmpv-dev,libpoppler-glib-dev,libcairo2-dev,libcurl4-openssl-dev,libssl-dev,libglib2.0-dev,libfreetype-dev,libavformat-dev,libavcodec-dev,libavutil-dev,libswresample-dev,libwebkit2gtk-4.1-dev,libasound2-dev,libpulse-dev,libx11-dev,libxext-dev,libxcursor-dev,libxi-dev,libxfixes-dev,libxrandr-dev,libxss-dev,libxtst-dev,libwayland-dev,libxkbcommon-dev,libegl1-mesa-dev,libgbm-dev,curl,ca-certificates,gstreamer1.0-plugins-good,gstreamer1.0-libav \
        noble "$SYSROOT" 'deb http://ports.ubuntu.com/ubuntu-ports noble main universe' \
        'deb http://ports.ubuntu.com/ubuntu-ports noble-updates main universe' \
        'deb http://ports.ubuntu.com/ubuntu-ports noble-security main universe'
      touch "$SYSROOT/.complete"
    fi
    # extract mode does not run usrmerge's maintainer script. Some packages
    # still unpack under /lib, while glibc's linker script names /lib paths
    # for files shipped under /usr/lib. Merge without executing target code;
    # this also repairs previously extracted sysroots marked complete.
    for directory in bin sbin lib; do
      if [ ! -L "$SYSROOT/$directory" ]; then
        mkdir -p "$SYSROOT/usr/$directory"
        if [ -d "$SYSROOT/$directory" ]; then
          cp -a "$SYSROOT/$directory/." "$SYSROOT/usr/$directory/"
          rm -rf "$SYSROOT/$directory"
        fi
        ln -s "usr/$directory" "$SYSROOT/$directory"
      fi
    done
    # BLAS/LAPACK normally acquire these SONAME paths via update-alternatives.
    # libsphinxbase (through libmpv/FFmpeg) needs them during linking/loading.
    for library in blas lapack; do
      test -f "$SYSROOT/usr/lib/aarch64-linux-gnu/$library/lib$library.so.3"
      ln -sfn "$library/lib$library.so.3" "$SYSROOT/usr/lib/aarch64-linux-gnu/lib$library.so.3"
    done
    PREFIX="$SYSROOT/usr"
    # Match the native build's Clang workaround for SQLCipher TLS relocations.
    CC="$OUT/target-clang"
    cat > "$CC" <<CLANG
#!/usr/bin/env bash
exec clang --target=aarch64-linux-gnu --sysroot="$SYSROOT" "\$@"
CLANG
    chmod +x "$CC"
    export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
    export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/aarch64-linux-gnu/pkgconfig:$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
    ;;
  windows-amd64)
    # LLVM-MinGW supplies the recent WinRT headers required by current GLib.
    # Its UCRT and libc++ ABI must match Rust's gnullvm target, not windows-gnu.
    LLVM_MINGW="$HERE/vendor/llvm-mingw-20260922"
    mkdir -p "$LLVM_MINGW"
    fetch https://github.com/mstorsjo/llvm-mingw/releases/download/20260922/llvm-mingw-20260922-ucrt-ubuntu-22.04-x86_64.tar.xz \
      "$HERE/vendor/llvm-mingw-20260922.tar.xz" bb7bb7654b33d5aa8712acb837c963b2e0c56352560c76105270a3268c665c21
    if [ ! -x "$LLVM_MINGW/bin/x86_64-w64-mingw32-clang" ]; then
      tar -xJf "$HERE/vendor/llvm-mingw-20260922.tar.xz" --strip-components=1 -C "$LLVM_MINGW"
    fi
    RUST_TARGET=x86_64-pc-windows-gnullvm; ODIN_TARGET=windows_amd64
    CPU=x86_64; SYSTEM=Windows; EXE=.exe
    CC="$LLVM_MINGW/bin/x86_64-w64-mingw32-clang"
    CXX="$LLVM_MINGW/bin/x86_64-w64-mingw32-clang++"
    AR="$LLVM_MINGW/bin/llvm-ar"; STRIP="$LLVM_MINGW/bin/llvm-strip"; OBJCOPY="$LLVM_MINGW/bin/llvm-objcopy"
    DLLTOOL="$LLVM_MINGW/bin/llvm-dlltool"
    # One version for the in-app C library and the vpk packer.
    export VELOPACK_VERSION=1.2.158
    # FFmpeg invokes unprefixed dlltool with Clang, ignoring CMAKE_DLLTOOL.
    # Expose only that LLVM tool, not cross clang as a host compiler.
    mkdir -p "$OUT/tool-bin"
    ln -sfn "$DLLTOOL" "$OUT/tool-bin/dlltool"
    export PATH="$OUT/tool-bin:$PATH"
    # A separate vcpkg triplet/prefix cannot reuse pre-cutover GCC/MSVCRT libs.
    PREFIX="$OUT/vcpkg-installed/$TARGET-llvm-ucrt"
    ;;
  darwin-amd64|darwin-arm64)
    # Apple's SDK is licensed for Apple hardware only, so macOS packages build
    # on a Mac with Xcode or its Command Line Tools. Either architecture builds
    # on either Mac: the wrappers pin clang's -arch, the SDK and the minimum
    # macOS version for every compiler, linker and build-system invocation.
    SYSROOT="$(xcrun --sdk macosx --show-sdk-path)"
    export MACOSX_DEPLOYMENT_TARGET=13.0 SDKROOT="$SYSROOT"
    if [ "$TARGET" = darwin-arm64 ]; then
      CPU=aarch64; APPLE_CPU=arm64; RUST_TARGET=aarch64-apple-darwin; ODIN_TARGET=darwin_arm64
    else
      CPU=x86_64; APPLE_CPU=x86_64; RUST_TARGET=x86_64-apple-darwin; ODIN_TARGET=darwin_amd64
    fi
    mkdir -p "$OUT/tool-bin"
    for tool in clang clang++; do
      printf '#!/bin/sh\nexec "%s" -arch %s -isysroot "%s" -mmacosx-version-min=%s "$@"\n' \
        "$(xcrun -f "$tool")" "$APPLE_CPU" "$SYSROOT" "$MACOSX_DEPLOYMENT_TARGET" > "$OUT/tool-bin/$APPLE_CPU-apple-$tool"
      chmod +x "$OUT/tool-bin/$APPLE_CPU-apple-$tool"
    done
    CC="$OUT/tool-bin/$APPLE_CPU-apple-clang"; CXX="$OUT/tool-bin/$APPLE_CPU-apple-clang++"
    SYSTEM=Darwin; AR="$(xcrun -f ar)"; STRIP="$(xcrun -f strip)"
    # Mach-O inspection and rpath rewriting in cross-bundle.js.
    export WN_OBJDUMP="$(xcrun -f objdump)" WN_INSTALL_NAME_TOOL="$(xcrun -f install_name_tool)"
    ;;
esac
CC="$(command -v "$CC")"; CXX="$(command -v "$CXX")"; AR="$(command -v "$AR")"
export CC CXX AR STRIP
# Cargo's build dependencies execute on the build machine, so target variables
# must not accidentally replace their compiler or pkg-config environment.
RUST_KEY="${RUST_TARGET//-/_}"; RUST_UPPER="${RUST_KEY^^}"
export "CC_$RUST_KEY=$CC" "CXX_$RUST_KEY=$CXX" "AR_$RUST_KEY=$AR"
export "CARGO_TARGET_${RUST_UPPER}_LINKER=$CC"
export PKG_CONFIG_PATH= PKG_CONFIG_ALLOW_CROSS=1
CFLAGS=(-O2 -fPIC)
if [ "$TARGET" = linux-arm64 ]; then CFLAGS+=("--sysroot=$SYSROOT"); fi
mkdir -p "$OUT" "$PREFIX" "$OUT/triplets"
cat > "$OUT/toolchain.cmake" <<CMAKE
set(CMAKE_SYSTEM_NAME $SYSTEM)
set(CMAKE_SYSTEM_PROCESSOR $CPU)
set(CMAKE_C_COMPILER "$CC")
set(CMAKE_CXX_COMPILER "$CXX")
set(CMAKE_OBJC_COMPILER "$CC")
set(CMAKE_OBJCXX_COMPILER "$CXX")
set(CMAKE_AR "$AR")
set(CMAKE_FIND_ROOT_PATH "$PREFIX")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
CMAKE
if [ "$TARGET" = linux-arm64 ]; then
  printf 'set(CMAKE_SYSROOT "%s")\n' "$SYSROOT" >> "$OUT/toolchain.cmake"
elif [ "$SYSTEM" = Darwin ]; then
  cat >> "$OUT/toolchain.cmake" <<CMAKE
set(CMAKE_OSX_SYSROOT "$SYSROOT")
set(CMAKE_OSX_ARCHITECTURES "$APPLE_CPU")
set(CMAKE_OSX_DEPLOYMENT_TARGET 13.0)
# The ONLY find modes above re-root every search under the vcpkg prefix,
# which hides the SDK's frameworks (curl needs SystemConfiguration).
# Paths already inside a root are searched as-is.
list(APPEND CMAKE_FIND_ROOT_PATH "$SYSROOT")
set(CMAKE_INSTALL_NAME_TOOL "$WN_INSTALL_NAME_TOOL")
CMAKE
elif [ "$SYSTEM" = Windows ]; then
  cat >> "$OUT/toolchain.cmake" <<CMAKE
# Target wrapper selects PE mode even for libtool's direct --help probes.
set(CMAKE_LINKER "$LLVM_MINGW/bin/x86_64-w64-mingw32-ld")
set(CMAKE_RANLIB "$LLVM_MINGW/bin/llvm-ranlib")
set(CMAKE_NM "$LLVM_MINGW/bin/llvm-nm")
set(CMAKE_RC_COMPILER "$LLVM_MINGW/bin/x86_64-w64-mingw32-windres")
set(CMAKE_DLLTOOL "$DLLTOOL")
CMAKE
fi
MESON_WINDRES=
if [ "$SYSTEM" = Windows ]; then MESON_WINDRES="windres = '$LLVM_MINGW/bin/x86_64-w64-mingw32-windres'"; fi
cat > "$OUT/meson.ini" <<MESON
[binaries]
c = '$CC'
cpp = '$CXX'
objc = '$CC'
objcpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = 'pkg-config'
$MESON_WINDRES
[host_machine]
system = '${SYSTEM,,}'
cpu_family = '$CPU'
cpu = '$CPU'
endian = 'little'
[properties]
needs_exe_wrapper = true
MESON
