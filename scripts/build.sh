#!/usr/bin/env bash
# Build White Noise Linux against marmot-c from the pinned mdk revision.
# `just test` builds, then runs the app package's tests.
#
# Every third-party revision this build pins lives in DEPS_PIN, one
# `<name>-commit = <sha>` line per git checkout and one
# `<name>-file = <sha256> <url>` line per download (scripts/fetch.sh).
# vendor/mdk is cloned at mdk-commit and its C bundle staged by upstream's
# own c-bindings.sh. Cargo reuses unchanged crates in build/cargo/native;
# then the Odin packages build against the staticlib.
#
# Offline builds: run `scripts/build.sh fetch` (below) with network, or
# place each `-commit` checkout at vendor/<name> and each `-file` download
# at vendor/downloads/<name> and make marmot-c's crates available to cargo
# (scripts/aur-source.sh). Either way the build then fetches nothing.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/scripts/build-cache.sh"
# Keep native dependency identity separate from app sources: an app or MDK
# edit must not rebuild independent C helpers. System headers are read once,
# not once per helper; only resolved link libraries are read, never lib dirs.
native_key() {
  build_cache_key "$NATIVE_ENV $1" "$HERE/scripts/build.sh" "$HERE"/app/*.h "${@:2}"
}
native_compile_key() {
  # Static vendor archives do not link shared libraries. OpenBSD reorders
  # libc and libcrypto at boot, without changing compilation inputs.
  build_cache_key "$NATIVE_COMPILE_ENV $1" "$HERE/scripts/build.sh" "${@:2}"
}
native_odin_build() {
  local name="$1" package="$2" root="$3" mode="$4" object_key="$5" link_key="$6"
  shift 6
  local binary="$HERE/build/$name" command signature arg
  local -a options=() args=() libraries=()
  case "$mode" in
  speed) options=(-o:speed) ;;
  default) ;;
  *)
    echo "Unknown Odin optimization mode: $mode" >&2
    return 2
    ;;
  esac
  printf -v signature '%q ' "$root" "$mode" "$@"
  object_key="$(build_cache_key "Odin object $object_key $signature single-module")"
  # Leave macOS's compiler-managed framework linking unchanged.
  if [ "$(uname -s)" = Darwin ]; then
    link_key="$(build_cache_key "$object_key $link_key")"
    if ! build_cache_fresh "$link_key" "$binary.link.stamp" "$binary"; then
      rm -f "$binary.link.stamp" "$binary"
      env ODIN_ROOT="$root" odin build "$package" "${options[@]}" "$@" -out:"$binary"
      build_cache_store "$link_key" "$binary.link.stamp" "$binary"
    fi
    return
  fi
  if build_cache_fresh "$object_key" "$binary.object.stamp" "$binary.o" "$binary.link.args"; then
    echo "==> native cache hit: $name object"
  else
    echo "==> Compiling native $name"
    rm -f "$binary.object.stamp" "$binary.o" "$binary.link.args"
    # This compiles without linking and retains Odin's native entry point and
    # linker hardening. Decode arguments as data, never as a shell command.
    command="$(env ODIN_ROOT="$root" odin build "$package" "${options[@]}" "$@" \
      -use-single-module -keep-temp-files -print-linker-flags -out:"$binary")"
    case "$command" in
    *$'\n'* | clang)
      echo 'Unexpected multiline or empty Odin linker recipe.' >&2
      return 1
      ;;
    clang\ *) ;;
    *)
      echo "Unsupported Odin linker recipe: $command" >&2
      return 1
      ;;
    esac
    printf '%s\n' "${command#clang }" | xargs printf '%s\0' >"$binary.link.args"
    build_cache_store "$object_key" "$binary.object.stamp" "$binary.o" "$binary.link.args"
  fi
  while IFS= read -r -d '' arg; do
    args+=("$arg")
    case "$arg" in
    -l:/*) libraries+=("${arg#-l:}") ;;
    /*.a | /*.o | /*.so | /*.so.* | /*.dylib) libraries+=("$arg") ;;
    esac
  done <"$binary.link.args"
  link_key="$(build_cache_key "$link_key" "$(command -v clang)" "$binary.o" "$binary.link.args" "${libraries[@]}")"
  if build_cache_fresh "$link_key" "$binary.link.stamp" "$binary"; then
    echo "==> native cache hit: $name link"
  else
    echo "==> Linking native $name"
    rm -f "$binary.link.stamp" "$binary"
    clang "${args[@]}"
    build_cache_store "$link_key" "$binary.link.stamp" "$binary"
  fi
}
native_env() {
  local tool module word file dir
  local -a tool_command include_dirs link_dirs module_dirs module_libs
  local inputs=() link_inputs=() flags=()
  for tool in cc c++ ar odin cmake; do
    inputs+=("$(command -v "$tool")")
  done
  for tool in "${CC:-cc}" "${CXX:-c++}" "${AR:-ar}"; do
    read -r -a tool_command <<<"$tool"
    inputs+=("$(command -v "${tool_command[0]}")")
  done
  IFS=: read -r -a include_dirs <<<"${CPATH:-}:${C_INCLUDE_PATH:-}:${CPLUS_INCLUDE_PATH:-}"
  IFS=: read -r -a link_dirs <<<"${LIBRARY_PATH:-}"
  for dir in "${include_dirs[@]}"; do
    if [ -n "$dir" ]; then inputs+=("$dir"); fi
  done
  for dir in /usr/include /usr/local/include; do
    if [ -d "$dir" ]; then inputs+=("$dir"); fi
  done
  if [ "$(uname -s)" = Darwin ]; then
    # macos-setup.sh provides GNU tools; Xcode's selected SDK is outside
    # /usr/include. Hash used SDK headers/stubs, not the entire SDK tree.
    dir="${SDKROOT:-$(xcrun --show-sdk-path)}"
    inputs+=("$dir/usr/include" "$dir/SDKSettings.json")
    for module in Cocoa AppKit Foundation Security CoreFoundation SystemConfiguration; do
      inputs+=("$dir/System/Library/Frameworks/$module.framework")
    done
    for file in libSystem libc++ libc++abi libobjc; do
      inputs+=("$dir/usr/lib/$file.tbd")
    done
  fi
  for module in libcurl cairo libwebp libarchive poppler-glib fontconfig freetype2 sdl3 glib-2.0 libavformat libavcodec libavutil libswresample libcrypto webkit2gtk-4.1 mpv; do
    if pkg-config --exists "$module"; then
      flags+=("$module $(pkg-config --modversion "$module"): $(pkg-config --cflags --libs "$module")")
      dir="$(pkg-config --variable=includedir "$module")"
      if [ -d "$dir" ] && [ "$dir" != /usr/include ] && [ "$dir" != /usr/local/include ]; then inputs+=("$dir"); fi
      read -r -a module_dirs <<<"$(pkg-config --libs-only-L "$module")"
      read -r -a module_libs <<<"$(pkg-config --libs-only-l "$module")"
      for word in "${module_libs[@]}"; do
        for dir in "${module_dirs[@]}" "${link_dirs[@]}"; do
          [ -n "$dir" ] || continue
          dir="${dir#-L}"
          for file in "$dir/lib${word#-l}.so"* "$dir/lib${word#-l}.dylib" "$dir/lib${word#-l}.a"; do
            if [ -f "$file" ]; then link_inputs+=("$file"); fi
          done
        done
        for file in "$(cc -print-file-name="lib${word#-l}.so")" "$(cc -print-file-name="lib${word#-l}.a")" "$(cc -print-file-name="lib${word#-l}.dylib")"; do
          if [ -f "$file" ]; then link_inputs+=("$file"); fi
        done
      done
    fi
  done
  for file in "$(cc -print-file-name=include)" "$(c++ -print-file-name=include)" "$(cc -print-prog-name=ld)"; do
    if [ -e "$file" ]; then
      inputs+=("$file")
    elif command -v "$file" >/dev/null 2>&1; then
      inputs+=("$(command -v "$file")")
    fi
  done
  dir="$(cc -print-resource-dir 2>/dev/null || true)"
  if [ -n "$dir" ] && [ -d "$dir/include" ]; then inputs+=("$dir/include"); fi
  for word in libc.so libc.so.6 libm.so libm.so.6 libpthread.so libdl.so libc++.so libc++abi.so libstdc++.so libstdc++.so.6 libgcc.a libgcc_s.so; do
    file="$(c++ -print-file-name="$word")"
    if [ -f "$file" ]; then link_inputs+=("$file"); fi
    for dir in "${link_dirs[@]}"; do
      if [ -n "$dir" ] && [ -f "$dir/$word" ]; then link_inputs+=("$dir/$word"); fi
    done
  done
  NATIVE_COMPILE_ENV="$(build_cache_key "$(uname -sm); $(cc --version); $(c++ --version); $(odin version); ${flags[*]}; ${link_inputs[*]}; ${CC:-}; ${CXX:-}; ${AR:-}; ${CFLAGS:-}; ${CXXFLAGS:-}; ${CPPFLAGS:-}; ${LDFLAGS:-}; ${LIBRARY_PATH:-}; ${CPATH:-}; ${C_INCLUDE_PATH:-}; ${CPLUS_INCLUDE_PATH:-}; ${SDKROOT:-}; ${MACOSX_DEPLOYMENT_TARGET:-}" "${inputs[@]}")"
  NATIVE_ENV="$(build_cache_key "$NATIVE_COMPILE_ENV" "${link_inputs[@]}")"
}
# Regenerate before cross dispatch and sources/stage exits as well.
bash "$HERE/scripts/observability.sh"
# OpenBSD's coreutils package installs GNU sha256sum as gsha256sum; its own
# sha256 -c reads a different line format.
if ! command -v sha256sum >/dev/null && command -v gsha256sum >/dev/null; then
  sha256sum() { gsha256sum "$@"; }
fi
# GNU tar restores ownership as root, which fails in Flatpak's UID namespace.
# OpenBSD tar already leaves ownership unchanged unless -p is requested.
TAR_OWNER=()
if [ "$(uname -s)" = Linux ]; then
  TAR_OWNER=(--no-same-owner)
fi
# OpenBSD's login classes cap a process's data size (1.5 GB soft for staff);
# rustc on marmot-app and `odin build -o:speed` on the app need more
# ("memory allocation failed", "Out of Virtual memory"). Raise the soft
# limit to the hard one for the whole build.
if [ "$(uname -s)" = OpenBSD ]; then
  ulimit -d "$(ulimit -Hd)"
fi
# `fetch` downloads everything a later plain build would: the sources and
# assets (`sources`), the speech runtime, and the Rust crates. A packager
# can then compile with the network off, as the Arch packages do:
#
#   scripts/build.sh fetch                          network
#   CARGO_NET_OFFLINE=true scripts/build.sh         no network
if [ "${1:-}" = fetch ]; then
  bash "$HERE/scripts/build.sh" sources
  if [ "$(uname -s)" = Linux ]; then
    bash "$HERE/scripts/build-tts.sh"
  elif [ "$(uname -s)" = Darwin ]; then
    bash "$HERE/scripts/fetch.sh" sparkle >/dev/null
  fi
  # Inside vendor/mdk so rustup, when present, installs the pinned toolchain.
  (cd "$HERE/vendor/mdk" && cargo fetch --locked --target "$(rustc -vV | sed -n 's/^host: //p')")
  exit 0
fi
# Cross builds share source pins and assets, but never stage host objects.
if [ -n "${WN_TARGET:-}" ] && [ "${1:-}" != sources ]; then
  exec bash "$HERE/scripts/cross-build.sh" "$WN_TARGET"
fi
bash "$HERE/scripts/version.sh" >/dev/null
# One pinned revision out of DEPS_PIN, by name.
pin() { sed -n "s/^$1-commit = //p" "$HERE/DEPS_PIN"; }
# One pinned download, by name; prints its path under vendor/downloads.
fetch() { bash "$HERE/scripts/fetch.sh" "$1" </dev/null; }
# git apply inside build/<dir>. A source tarball unpacked inside some other
# repository (an AUR helper's clone of the PKGBUILD) is not a repository of
# its own, so git would use the outer one and silently skip every path
# outside the current directory. Stopping discovery at build/ applies the
# patch as a plain one in every layout, or fails loudly.
apply_in_build() {
  local dir="$1"
  shift
  GIT_CEILING_DIRECTORIES="$HERE/build" git -C "$HERE/build/$dir" apply "$@"
}

MDK_REPO="https://github.com/marmot-protocol/mdk.git"
MDK_PIN="$(pin mdk)"
MDK="$HERE/vendor/mdk"
BUNDLE="$MDK/crates/marmot-c/output"
MDK_PATCHES=("$HERE/patches/mdk-message-authority.patch" "$HERE/patches/mdk-poll-context.patch" "$HERE/patches/mdk-advanced-search.patch" "$HERE/patches/mdk-thread-media-retention.patch")

if [ ! -d "$MDK" ]; then
  git clone --filter=blob:none "$MDK_REPO" "$MDK"
fi

if [ "$(git -C "$MDK" rev-parse HEAD)" != "$MDK_PIN" ]; then
  # Drop applied patches wholesale. Reverse-applying them one by one also
  # "unapplies" hunks upstream's default branch already carries, which
  # dirties a fresh clone and blocks the checkout below.
  git -C "$MDK" reset --hard -q
  git -C "$MDK" clean -fdq
  git -C "$MDK" fetch origin "$MDK_PIN"
  git -C "$MDK" checkout --detach "$MDK_PIN"
  rm -rf "$BUNDLE"
fi

# Apply Linux integration changes to a fresh or partially patched checkout.
bash "$HERE/scripts/apply-mdk-patches.sh" "$MDK" "${MDK_PATCHES[@]}"
PATCHES_HASH="$(sha256sum "${MDK_PATCHES[@]}")"
if [ "${1:-}" != sources ]; then
  RUST_ENV=()
  if [ "$(uname -s)" = OpenBSD ]; then
    # ponytail: OpenBSD has no rustup, and its rust package (1.94) predates
    # MDK's pinned toolchain; libsqlite3-sys's build script uses cfg_select!,
    # still unstable there. Unlock that one feature on the stable compiler.
    # Drop this once the package reaches vendor/mdk/rust-toolchain.toml.
    RUST_ENV=(RUSTC_BOOTSTRAP=1 RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-Zcrate-attr=feature(cfg_select)")
  fi
  # Keep artifacts outside vendor/mdk: changing its pin cleans that checkout.
  # cc-rs does not fingerprint compiler upgrades at the same path, so isolate
  # compiler/flags environments, but NOT MDK pins/patches. Cargo checks source
  # changes on every invocation; a final-bundle stamp must never bypass it.
  MDK_BUILD_ENV="$({
    (cd "$MDK" && export PATH="$HOME/.cargo/bin:$PATH" && env "${RUST_ENV[@]}" rustc -vV && cargo -vV)
    for tool in "${CC:-clang}" "${CXX:-c++}" "${AR:-ar}"; do
      read -r -a tool_command <<<"$tool"
      printf '%s\n' "$tool"
      if ! "${tool_command[@]}" --version 2>&1; then
        sha256sum "$(command -v "${tool_command[0]}")"
      fi
    done
    printf '%s\n' "${RUST_ENV[@]}" 'OTLP_EXPORT=1'
    env | LC_ALL=C sort | while IFS= read -r setting; do
      case "$setting" in
      CC=* | CC_*=* | CXX=* | CXX_*=* | AR=* | AR_*=* | CFLAGS*=* | CXXFLAGS*=* | CPPFLAGS*=* | LDFLAGS*=* | RUSTFLAGS=* | CARGO_ENCODED_RUSTFLAGS=* | RUSTC*=* | RUSTUP_TOOLCHAIN=* | CARGO_BUILD_*=* | CARGO_TARGET_*=* | CARGO_PROFILE_*=* | PKG_CONFIG*=* | OPENSSL*=* | LIBSQLITE3*=* | SQLITE3*=* | SDKROOT=* | MACOSX_DEPLOYMENT_TARGET=* | PRODUCT_ANALYTICS_EXPORT=*)
        printf '%s\n' "$setting"
        ;;
      esac
    done
  } | sha256sum | cut -d' ' -f1)"
  # An explicit CARGO_TARGET_DIR supplies the root, with the same isolation.
  MDK_CARGO_TARGET="${CARGO_TARGET_DIR:-$HERE/build/cargo/native}/$MDK_BUILD_ENV"
  case "$MDK_CARGO_TARGET" in
  /*) ;;
  *) MDK_CARGO_TARGET="$PWD/$MDK_CARGO_TARGET" ;;
  esac
  # GCC folds SQLCipher's TLS seed into overflowing relocations (sqlcipher#600).
  env "${RUST_ENV[@]}" CC="${CC:-clang}" OTLP_EXPORT=1 CARGO_TARGET_DIR="$MDK_CARGO_TARGET" \
    "$MDK/crates/marmot-c/c-bindings.sh"
  printf '%s\n' "$PATCHES_HASH" >"$BUNDLE/.mdk-patches"
  native_env
fi

# OpenBSD pledge cannot permit SysV shared memory. Link the XPutImage-capable
# SDL statically: OpenBSD's loader does not expand $ORIGIN library paths.
# Disable dlopen metadata: OpenBSD skips PT_NOTE segments over 1024 bytes,
# losing the required OpenBSD note when SDL's dependency notes share it.
if [ "$(uname -s)" = OpenBSD ] && [ "${1:-}" != sources ]; then
  SDL="$HERE/vendor/sdl"
  SDL_PIN="$(pin sdl)"
  if [ ! -d "$SDL" ]; then
    git clone --filter=blob:none https://github.com/libsdl-org/SDL.git "$SDL"
  fi
  if [ "$(git -C "$SDL" rev-parse HEAD)" != "$SDL_PIN" ]; then
    git -C "$SDL" fetch origin "$SDL_PIN"
    git -C "$SDL" checkout --detach "$SDL_PIN"
  fi
  SDL_STAMP="$(native_compile_key 'SDL Release PIC NO_SHARED_MEMORY static no-dlopen-notes' "$SDL")"
  if ! build_cache_fresh "$SDL_STAMP" "$HERE/build/sdl/stamp" "$HERE/build/sdl/lib/libSDL3.a" "$HERE/build/sdl/include"; then
    rm -f "$HERE/build/sdl/stamp"
    rm -rf "$HERE/build/sdl-cmake"
    cmake -S "$SDL" -B "$HERE/build/sdl-cmake" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$HERE/build/sdl" \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_C_FLAGS="${CFLAGS:-} -DNO_SHARED_MEMORY" \
      -DSDL_DLOPEN_NOTES=OFF \
      -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF
    cmake --build "$HERE/build/sdl-cmake" -j"$(getconf NPROCESSORS_ONLN)"
    cmake --install "$HERE/build/sdl-cmake"
    build_cache_store "$SDL_STAMP" "$HERE/build/sdl/stamp" "$HERE/build/sdl/lib/libSDL3.a" "$HERE/build/sdl/include"
  fi
  SANDBOX_KEY="$(native_key 'sandbox O2 PIC pthread' "$HERE/app/main_sandbox.c" "$HERE/app/tool_broker.c" "$HERE/app/helper_broker.c")"
  if ! build_cache_fresh "$SANDBOX_KEY" "$HERE/build/sandbox.stamp" "$HERE/build/libwnsandbox.a"; then
    rm -f "$HERE/build/sandbox.stamp" "$HERE/build/libwnsandbox.a"
    cc -O2 -fPIC -pthread -c "$HERE/app/main_sandbox.c" -o "$HERE/build/main_sandbox.o"
    cc -O2 -fPIC -pthread -c "$HERE/app/tool_broker.c" -o "$HERE/build/tool_broker.o"
    cc -O2 -fPIC -c "$HERE/app/helper_broker.c" -o "$HERE/build/helper_broker.o"
    ar rcs "$HERE/build/libwnsandbox.a" "$HERE/build/main_sandbox.o" "$HERE/build/tool_broker.o" "$HERE/build/helper_broker.o"
    build_cache_store "$SANDBOX_KEY" "$HERE/build/sandbox.stamp" "$HERE/build/libwnsandbox.a"
  fi
fi

CLAY="$HERE/vendor/clay"
CLAY_PIN="$(pin clay)"
if [ ! -d "$CLAY" ]; then
  git clone --filter=blob:none https://github.com/nicbarker/clay.git "$CLAY"
  git -C "$CLAY" checkout --detach "$CLAY_PIN"
fi
# The Odin binding links linux/clay.a on Linux only; OpenBSD uses the same
# ELF archive (patches/clay-openbsd.patch). Applied once, in place.
if git -C "$CLAY" apply --check "$HERE/patches/clay-openbsd.patch" 2>/dev/null; then
  git -C "$CLAY" apply "$HERE/patches/clay-openbsd.patch"
fi

if [ "${1:-}" != sources ]; then
  # Rebuild Clay: the upstream prebuilt archive has the slot-reuse bug too.
  # clay-scroll-target.patch keeps a clipped label from swallowing the wheel.
  # clay-float-layer.patch keeps a z-less float (the text caret) above the
  # floating panel it sits in.
  CLAY_LIB="$CLAY/bindings/odin/clay-odin/linux/clay.a"
  CLAY_PATCHES=("$HERE/patches/clay-hashmap.patch" "$HERE/patches/clay-scroll-target.patch" "$HERE/patches/clay-float-layer.patch")
  CLAY_KEY="$(native_key 'clay C PIC O2 CLAY_IMPLEMENTATION' "$CLAY/clay.h" "${CLAY_PATCHES[@]}")"
  if ! build_cache_fresh "$CLAY_KEY" "$HERE/build/clay/stamp" "$HERE/build/clay/clay.a" "$HERE/build/clay/clay.h"; then
    rm -f "$HERE/build/clay/stamp" "$HERE/build/clay/clay.a"
    mkdir -p "$HERE/build/clay"
    cp "$CLAY/clay.h" "$HERE/build/clay/clay.h"
    for patch in "${CLAY_PATCHES[@]}"; do
      apply_in_build clay "$patch"
    done
    cc -x c -c -DCLAY_IMPLEMENTATION -fPIC -O2 "$HERE/build/clay/clay.h" -o "$HERE/build/clay/clay.o"
    ar rcs "$HERE/build/clay/clay.a" "$HERE/build/clay/clay.o"
    build_cache_store "$CLAY_KEY" "$HERE/build/clay/stamp" "$HERE/build/clay/clay.a" "$HERE/build/clay/clay.h"
  fi
  cp "$HERE/build/clay/clay.a" "$CLAY_LIB"
fi

# Local LifeHash avatars. The relay's Git server does not support shallow clones.
CROP="$HERE/vendor/crop-circles"
CROP_PIN="$(pin crop-circles)"
if [ ! -d "$CROP" ]; then
  git clone https://relay.cyberguy.fyi/npub1ven4zk8xxw873876gx8y9g9l9fazkye9qnwnglcptgvfwxmygscqsxddfh/crop-circles.git "$CROP"
fi
if [ "$(git -C "$CROP" rev-parse HEAD)" != "$CROP_PIN" ]; then
  git -C "$CROP" fetch origin "$CROP_PIN"
  git -C "$CROP" checkout --detach "$CROP_PIN"
fi

# ufbx is linked only into the FBX helper. Cache the pinned reader object;
# compile the shim with the helper so header edits cannot leave a stale ABI.
UFBX="$HERE/vendor/ufbx"
UFBX_PIN="$(pin ufbx)"
if [ ! -d "$UFBX" ]; then
  git clone --filter=blob:none https://github.com/ufbx/ufbx.git "$UFBX"
fi
if [ "$(git -C "$UFBX" rev-parse HEAD)" != "$UFBX_PIN" ]; then
  git -C "$UFBX" fetch origin "$UFBX_PIN"
  git -C "$UFBX" checkout --detach "$UFBX_PIN"
  rm -rf "$HERE/build/fbx"
fi

if [ "${1:-}" != sources ]; then
  mkdir -p "$HERE/build/fbx"
  UFBX_KEY="$(native_key 'ufbx O2 PIC' "$UFBX/ufbx.c" "$UFBX/ufbx.h")"
  if ! build_cache_fresh "$UFBX_KEY" "$HERE/build/fbx/ufbx.stamp" "$HERE/build/fbx/ufbx.o"; then
    rm -f "$HERE/build/fbx/ufbx.stamp"
    cc -c -O2 -fPIC "$UFBX/ufbx.c" -o "$HERE/build/fbx/ufbx.o"
    build_cache_store "$UFBX_KEY" "$HERE/build/fbx/ufbx.stamp" "$HERE/build/fbx/ufbx.o"
  fi

  # Nostr event fetch (nevent cards) and Namecoin `.bit` NIP-05 resolution:
  # both use one-shot websocket clients over libcurl's raw socket, framed
  # in app/ws_shim.c (Nostr REQ) and app/nc_shim.c (ElectrumX JSON-RPC).
  mkdir -p "$HERE/build/ws"
  WS_KEY="$(native_key 'websocket O2 PIC curl' "$HERE/app/ws_shim.c" "$HERE/app/nc_shim.c")"
  if ! build_cache_fresh "$WS_KEY" "$HERE/build/ws/stamp" "$HERE/build/libwnws.a"; then
    rm -f "$HERE/build/ws/stamp"
    cc -c -O2 -fPIC $(pkg-config --cflags libcurl) "$HERE/app/ws_shim.c" -o "$HERE/build/ws/ws_shim.o"
    cc -c -O2 -fPIC $(pkg-config --cflags libcurl) "$HERE/app/nc_shim.c" -o "$HERE/build/ws/nc_shim.o"
    rm -f "$HERE/build/libwnws.a"
    ar rcs "$HERE/build/libwnws.a" "$HERE/build/ws/ws_shim.o" "$HERE/build/ws/nc_shim.o"
    build_cache_store "$WS_KEY" "$HERE/build/ws/stamp" "$HERE/build/libwnws.a"
  fi
fi

# Math blocks: MicroTeX (MIT) typesets TeX into a draw-command stream and
# app/math_shim.cpp replays it onto a cairo surface. Pinned to the
# openmath branch: its core is dependency-free C++17, and its C wrapper
# emits glyphs as paths, so no font rasterizer or GTK stack is involved.
# The checkout also carries TeX Gyre DejaVu Math pre-converted to MicroTeX's .clm2
# format, which app/math.odin #loads.
#
# patches/microtex-isolation.patch keeps one formula from changing the
# next: MicroTeX holds \newcommand definitions and \definecolor colors in
# process-wide maps. The patch bounds macro expansion, refuses to replace
# built-ins, and adds the resets the shim calls after every render.
# patches/microtex-libcxx-includes.patch adds headers libstdc++ pulls in
# transitively but LLVM's libc++ (the Windows and macOS toolchains) does not.
# patches/microtex-locale-fallback.patch falls back to C.UTF-8 when the host
# has no en_US.UTF-8, which otherwise fails most renders with an exception.
MICROTEX="$HERE/vendor/microtex"
MICROTEX_PIN="$(pin microtex)"
MICROTEX_PATCHES=("$HERE/patches/microtex-isolation.patch" "$HERE/patches/microtex-libcxx-includes.patch" "$HERE/patches/microtex-locale-fallback.patch")
if [ ! -d "$MICROTEX" ]; then
  git clone --filter=blob:none https://github.com/NanoMichael/MicroTeX.git "$MICROTEX"
fi
if [ "$(git -C "$MICROTEX" rev-parse HEAD)" != "$MICROTEX_PIN" ]; then
  git -C "$MICROTEX" checkout -- .
  git -C "$MICROTEX" fetch origin "$MICROTEX_PIN"
  git -C "$MICROTEX" checkout --detach "$MICROTEX_PIN"
  rm -rf "$HERE/build/microtex"
fi
for patch in "${MICROTEX_PATCHES[@]}"; do
  if git -C "$MICROTEX" apply --check "$patch" 2>/dev/null; then
    git -C "$MICROTEX" apply "$patch"
  elif ! git -C "$MICROTEX" apply --reverse --check "$patch" 2>/dev/null; then
    echo "==> MicroTeX patch conflicts with vendor/microtex: $patch" >&2
    exit 1
  fi
done
if [ "${1:-}" != sources ]; then
  MICROTEX_STAMP="$(native_compile_key 'MicroTeX Release PIC STATIC CWRAPPER no-log no-debug no-font-find' "$MICROTEX" "${MICROTEX_PATCHES[@]}")"
  if ! build_cache_fresh "$MICROTEX_STAMP" "$HERE/build/microtex/stamp" "$HERE/build/microtex/lib/libmicrotex.a" "$HERE/build/microtex/lib/microtexconfig.h"; then
    rm -rf "$HERE/build/microtex"
    cmake -S "$MICROTEX" -B "$HERE/build/microtex" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_STATIC=ON -DHAVE_CWRAPPER=ON \
      -DHAVE_LOG=OFF -DGRAPHICS_DEBUG=OFF -DHAVE_AUTO_FONT_FIND=OFF
    cmake --build "$HERE/build/microtex" --target microtex -j"$(getconf NPROCESSORS_ONLN)"
    build_cache_store "$MICROTEX_STAMP" "$HERE/build/microtex/stamp" "$HERE/build/microtex/lib/libmicrotex.a" "$HERE/build/microtex/lib/microtexconfig.h"
    rm -f "$HERE/build/libwnmath.a"
  fi
  mkdir -p "$HERE/build/math"
  MATH_KEY="$(native_key 'math C++17 O2 PIC Wall Wextra HAVE_CWRAPPER cairo' "$HERE/app/math_shim.cpp" "$MICROTEX/lib" "$HERE/build/microtex/lib/microtexconfig.h")"
  if ! build_cache_fresh "$MATH_KEY" "$HERE/build/math/stamp" "$HERE/build/libwnmath.a"; then
    rm -f "$HERE/build/math/stamp"
    c++ -std=c++17 -c -O2 -fPIC -Wall -Wextra -DHAVE_CWRAPPER -isystem "$MICROTEX/lib" -isystem "$HERE/build/microtex/lib" \
      $(pkg-config --cflags cairo) "$HERE/app/math_shim.cpp" -o "$HERE/build/math/math_shim.o"
    rm -f "$HERE/build/libwnmath.a"
    ar rcs "$HERE/build/libwnmath.a" "$HERE/build/math/math_shim.o"
    build_cache_store "$MATH_KEY" "$HERE/build/math/stamp" "$HERE/build/libwnmath.a"
  fi

  # Parent/child IPC is shared by speech and the webxdc host.
  IPC_KEY="$(native_key 'IPC O2 PIC pthread' "$HERE/app/helper_ipc.c")"
  if ! build_cache_fresh "$IPC_KEY" "$HERE/build/ipc.stamp" "$HERE/build/libwnipc.a"; then
    rm -f "$HERE/build/ipc.stamp" "$HERE/build/libwnipc.a"
    cc -c -O2 -fPIC -pthread "$HERE/app/helper_ipc.c" -o "$HERE/build/helper_ipc.o"
    ar rcs "$HERE/build/libwnipc.a" "$HERE/build/helper_ipc.o"
    build_cache_store "$IPC_KEY" "$HERE/build/ipc.stamp" "$HERE/build/libwnipc.a"
  fi

  # Attachment parsers run in helpers sharing one bounded pipe client.
  DECODER_KEY="$(native_key 'decoder IPC O2 PIC pthread' "$HERE/app/decoder_ipc.c")"
  if ! build_cache_fresh "$DECODER_KEY" "$HERE/build/decoder.stamp" "$HERE/build/libwndecoder.a"; then
    rm -f "$HERE/build/decoder.stamp" "$HERE/build/libwndecoder.a"
    cc -c -O2 -fPIC -pthread "$HERE/app/decoder_ipc.c" -o "$HERE/build/decoder_ipc.o"
    ar rcs "$HERE/build/libwndecoder.a" "$HERE/build/decoder_ipc.o"
    build_cache_store "$DECODER_KEY" "$HERE/build/decoder.stamp" "$HERE/build/libwndecoder.a"
  fi
  TIMESTAMP_KEY="$(native_key 'timestamp O2 PIC Wall Wextra' "$HERE/app/timestamp.c")"
  if ! build_cache_fresh "$TIMESTAMP_KEY" "$HERE/build/timestamp.stamp" "$HERE/build/libwntimestamp.a"; then
    rm -f "$HERE/build/timestamp.stamp" "$HERE/build/libwntimestamp.a"
    cc -c -O2 -fPIC -Wall -Wextra "$HERE/app/timestamp.c" -o "$HERE/build/timestamp.o"
    ar rcs "$HERE/build/libwntimestamp.a" "$HERE/build/timestamp.o"
    build_cache_store "$TIMESTAMP_KEY" "$HERE/build/timestamp.stamp" "$HERE/build/libwntimestamp.a"
  fi
  IMAGE_ODIN="$(env -u ODIN_ROOT odin root)"
  IMAGE_KEY="$(native_key 'image O2 Wall Wextra webp m' "$HERE/app/image.c" "${IMAGE_ODIN%/}/vendor/stb/src")"
  if ! build_cache_fresh "$IMAGE_KEY" "$HERE/build/image.stamp" "$HERE/build/wn-image"; then
    rm -f "$HERE/build/image.stamp" "$HERE/build/wn-image"
    cc -O2 -Wall -Wextra -I"${IMAGE_ODIN%/}/vendor/stb/src" "$HERE/app/image.c" \
      $(pkg-config --cflags --libs libwebp) -lm -o "$HERE/build/wn-image"
    build_cache_store "$IMAGE_KEY" "$HERE/build/image.stamp" "$HERE/build/wn-image"
  fi
  ARCHIVE_KEY="$(native_key 'archive O2 Wall Wextra libarchive' "$HERE/app/archive.c")"
  if ! build_cache_fresh "$ARCHIVE_KEY" "$HERE/build/archive.stamp" "$HERE/build/wn-archive"; then
    rm -f "$HERE/build/archive.stamp" "$HERE/build/wn-archive"
    cc -O2 -Wall -Wextra "$HERE/app/archive.c" \
      $(pkg-config --cflags --libs libarchive) -o "$HERE/build/wn-archive"
    build_cache_store "$ARCHIVE_KEY" "$HERE/build/archive.stamp" "$HERE/build/wn-archive"
  fi
  PDF_KEY="$(native_key 'pdf O2 Wall Wextra poppler-glib cairo fontconfig m' "$HERE/app/pdf.c")"
  if ! build_cache_fresh "$PDF_KEY" "$HERE/build/pdf.stamp" "$HERE/build/wn-pdf"; then
    rm -f "$HERE/build/pdf.stamp" "$HERE/build/wn-pdf"
    cc -O2 -Wall -Wextra "$HERE/app/pdf.c" \
      $(pkg-config --cflags --libs poppler-glib cairo fontconfig) -lm -o "$HERE/build/wn-pdf"
    build_cache_store "$PDF_KEY" "$HERE/build/pdf.stamp" "$HERE/build/wn-pdf"
  fi
  FBX_KEY="$(native_key 'fbx O2 Wall Wextra m' "$HERE/app/fbx_helper.c" "$HERE/app/fbx_shim.c" "$UFBX/ufbx.h" "$HERE/build/fbx/ufbx.o")"
  if ! build_cache_fresh "$FBX_KEY" "$HERE/build/fbx/stamp" "$HERE/build/wn-fbx"; then
    rm -f "$HERE/build/fbx/stamp" "$HERE/build/wn-fbx"
    cc -O2 -Wall -Wextra -I"$UFBX" "$HERE/app/fbx_helper.c" "$HERE/app/fbx_shim.c" \
      "$HERE/build/fbx/ufbx.o" -lm -o "$HERE/build/wn-fbx"
    build_cache_store "$FBX_KEY" "$HERE/build/fbx/stamp" "$HERE/build/wn-fbx"
  fi
  MESH_KEY="$(native_key 'mesh limits O2 PIC' "$HERE/app/mesh_limits.c")"
  if ! build_cache_fresh "$MESH_KEY" "$HERE/build/mesh.stamp" "$HERE/build/libwnmesh.a"; then
    rm -f "$HERE/build/mesh.stamp" "$HERE/build/libwnmesh.a"
    cc -c -O2 -fPIC "$HERE/app/mesh_limits.c" -o "$HERE/build/mesh_limits.o"
    ar rcs "$HERE/build/libwnmesh.a" "$HERE/build/mesh_limits.o"
    build_cache_store "$MESH_KEY" "$HERE/build/mesh.stamp" "$HERE/build/libwnmesh.a"
  fi

  # FreeType decodes profile web fonts for the existing SFNT text renderer.
  FONT_KEY="$(native_key 'font O2 Wall Wextra freetype2' "$HERE/app/font.c")"
  if ! build_cache_fresh "$FONT_KEY" "$HERE/build/font.stamp" "$HERE/build/wn-font"; then
    rm -f "$HERE/build/font.stamp" "$HERE/build/wn-font"
    cc -O2 -Wall -Wextra "$HERE/app/font.c" $(pkg-config --cflags --libs freetype2) -o "$HERE/build/wn-font"
    build_cache_store "$FONT_KEY" "$HERE/build/font.stamp" "$HERE/build/wn-font"
  fi

  # Speech helpers use the pinned multilingual CPU runtime, which sherpa-onnx
  # only publishes for Linux (and the cross targets'). Elsewhere (OpenBSD) the
  # helpers are not built and reading aloud/dictation report that they could
  # not start.
  if [ "$(uname -s)" = Linux ]; then
    bash "$HERE/scripts/build-tts.sh"
    TTS="$HERE/vendor/sherpa-onnx"
    for speech in tts stt; do
      SPEECH_KEY="$(native_key "speech $speech O2 Wall Wextra sdl3 curl glib av crypto pthread m ORIGIN/tts-lib" "$HERE/app/$speech.c" "$HERE/build/libwnipc.a" "$TTS/include" "$TTS/lib")"
      if ! build_cache_fresh "$SPEECH_KEY" "$HERE/build/$speech.stamp" "$HERE/build/wn-$speech"; then
        rm -f "$HERE/build/$speech.stamp" "$HERE/build/wn-$speech"
        cc -O2 -Wall -Wextra -I"$TTS/include" "$HERE/app/$speech.c" "$HERE/build/libwnipc.a" \
          -L"$TTS/lib" -lsherpa-onnx-c-api -Wl,-rpath,'$ORIGIN/tts-lib' \
          $(pkg-config --cflags --libs sdl3 libcurl glib-2.0 libavformat libavcodec libavutil libswresample libcrypto) -pthread -lm -o "$HERE/build/wn-$speech"
        build_cache_store "$SPEECH_KEY" "$HERE/build/$speech.stamp" "$HERE/build/wn-$speech"
      fi
    done
  fi

  # wn-webview: the process that runs a webxdc app offscreen and hands
  # the app its pixels through shared memory. Optional: without
  # webkit2gtk-4.1 there is no viewer, and .xdc attachments stay inert.
  # OpenBSD never builds or runs the host, even with WebKit installed.
  if [ "$(uname -s)" = OpenBSD ]; then
    echo "==> webxdc apps are disabled on OpenBSD"
  elif pkg-config --exists webkit2gtk-4.1 2>/dev/null; then
    WEBVIEW_KEY="$(native_key 'webview O2 pthread webkit2gtk-4.1' "$HERE/app/webview.c" "$HERE/build/libwnipc.a")"
    if ! build_cache_fresh "$WEBVIEW_KEY" "$HERE/build/webview.stamp" "$HERE/build/wn-webview"; then
      rm -f "$HERE/build/webview.stamp" "$HERE/build/wn-webview"
      cc -O2 "$HERE/app/webview.c" "$HERE/build/libwnipc.a" -pthread -o "$HERE/build/wn-webview" \
        $(pkg-config --cflags --libs webkit2gtk-4.1)
      build_cache_store "$WEBVIEW_KEY" "$HERE/build/webview.stamp" "$HERE/build/wn-webview"
    fi
  else
    echo "==> webkit2gtk-4.1 not found: webxdc apps will not run"
  fi
fi

# Emoji tiles, catalog and pixel packs are generated once by maintainers.
bash "$HERE/scripts/build-emoji.sh" "$HERE/vendor"

# Common passwords are compiled into the app, never fetched during a check.
# Copied on every run, so a new pin always reaches the #load path.
PASSWORDS="$(fetch seclists-passwords)"
PASSWORDS_LICENSE="$(fetch seclists-license)"
cp "$PASSWORDS" "$HERE/vendor/common-passwords.txt"
cp "$PASSWORDS_LICENSE" "$HERE/vendor/common-passwords.LICENSE"

# Bundled fonts, staged like the emoji tiles above so every package ships
# byte-identical faces regardless of the build host's font packages.
# Both archives are pinned by sha256; bump a pin and `rm -rf
# vendor/fonts` to restage.
#
#   JetBrainsMonoNerdFont-Regular.ttf  icons (Nerd Font private-use
#                                      codepoints, no system fallback)
#   LiberationSans-{Regular,Bold,Italic,BoldItalic}.ttf
#   LiberationMono-Regular.ttf         body, emphasis, mono
FONTS="$HERE/vendor/fonts"
# Theme faces are converted once from the pinned Sidecar revision, with
# licences and conversion provenance retained alongside the committed TTFs.
mkdir -p "$FONTS"
cp "$HERE/assets/fonts/sidecar/"*.ttf "$HERE/assets/fonts/sidecar/"*.txt "$FONTS/"
# Kalam is committed unmodified at the revision documented by its provenance.
# Check source bytes before staging so every target gets the same handwriting.
while read -r file sha; do
  echo "$sha  $HERE/assets/fonts/kalam/$file" | sha256sum -c -
done <<'KALAM'
Kalam-Regular.ttf 57cecb63d4608019371954274ae1d8c397764debd5b19d4a33c1efa4dc923c0b
Kalam-Bold.ttf 2f6576601db015d4f6c08678120277fc8510b98c06e932ce7a6a9cbff4cbdded
Kalam-OFL.txt f62ef357d3a1c3d27edd35a6e1ba350e8a8d13499797964eeadefbf0b3b15d1f
KALAM
cp "$HERE/assets/fonts/kalam/"*.ttf "$HERE/assets/fonts/kalam/"*.txt "$FONTS/"
if [ ! -f "$FONTS/JetBrainsMonoNerdFont-Regular.ttf" ]; then
  NERD_ZIP="$(fetch nerd-fonts)"
  unzip -qo "$NERD_ZIP" JetBrainsMonoNerdFont-Regular.ttf -d "$FONTS"
fi
if [ ! -f "$FONTS/LiberationSans-Regular.ttf" ] || [ ! -f "$FONTS/LiberationSans-Italic.ttf" ] || [ ! -f "$FONTS/LiberationSans-BoldItalic.ttf" ]; then
  LIBERATION="$(fetch liberation-fonts)"
  TMP="$(mktemp -d)"
  # Extract whole, then copy: --strip-components/--wildcards are GNU-only.
  tar "${TAR_OWNER[@]}" -xzf "$LIBERATION" -C "$TMP"
  for face in LiberationSans-Regular LiberationSans-Bold LiberationSans-Italic LiberationSans-BoldItalic LiberationMono-Regular; do
    cp "$TMP"/liberation-fonts-ttf-*/"$face.ttf" "$FONTS/"
  done
  rm -rf "$TMP"
fi

# Decorative profile names need mathematical alphabets and symbols that
# Liberation lacks. Keep the OFL faces identical across packages.
while read -r file name; do
  if [ ! -f "$FONTS/$file" ]; then
    face="$(fetch "$name")"
    cp "$face" "$FONTS/$file"
  fi
done <<'FONTS'
NotoSansMath-Regular.ttf noto-sans-math
NotoSansSymbols-Regular.ttf noto-sans-symbols
NotoSansSymbols2-Regular.ttf noto-sans-symbols2
FONTS
if [ ! -f "$FONTS/Noto-LICENSE.txt" ]; then
  NOTO_LICENSE="$(fetch noto-fonts-license)"
  cp "$NOTO_LICENSE" "$FONTS/Noto-LICENSE.txt"
fi

# The math font (TeX Gyre DejaVu Math, app/math.odin) is under the GUST
# Font License, with the DejaVu changes in the public domain. MicroTeX's
# copy ships only a README that names both texts, so stage them here.
# Keep GUST local: CTAN's regional mirrors are not reliably reachable from CI.
# Source: https://mirrors.ctan.org/fonts/tex-gyre-math/doc/GUST-FONT-LICENSE.txt
# SHA-256: 2bd69affc3da00715116f713f57eab9707e96daf3562ad0215987b15b9c16f73
cp "$HERE/assets/fonts/GUST-FONT-LICENSE.txt" "$FONTS/GUST-FONT-LICENSE.txt"
if [ ! -f "$FONTS/DejaVu-LICENSE.txt" ]; then
  DEJAVU_LICENSE="$(fetch dejavu-license)"
  cp "$DEJAVU_LICENSE" "$FONTS/DejaVu-LICENSE.txt"
fi

mkdir -p "$HERE/build"
if [ "${1:-}" = sources ]; then
  exit 0
fi

# The Linux odin release ships vendor/stb and vendor/cgltf without their
# built .a archives (sdlrl needs stb truetype + image, the mesh helper
# needs cgltf). When either is missing, build them inside a private
# ODIN_ROOT that symlinks the real install and swaps in writable copies
# of those two vendor dirs. OpenBSD always takes the overlay: its bindings
# name the archives for Linux only (below).
SYS_ODIN="$(env -u ODIN_ROOT odin root)"
SYS_ODIN="${SYS_ODIN%/}"
ODIN_SYS_KEY="$(native_compile_key 'Odin overlay stb cgltf' "$SYS_ODIN/base" "$SYS_ODIN/core" "$SYS_ODIN/shared" "$SYS_ODIN/vendor/stb" "$SYS_ODIN/vendor/cgltf" "$SYS_ODIN/vendor/sdl3" "$HERE"/patches/odin-openbsd-*.patch)"
ODIN_ROOT_ARG=()
OVERLAY_REBUILT=0
if [ ! -f "$SYS_ODIN/vendor/stb/lib/stb_truetype.a" ] || [ ! -f "$SYS_ODIN/vendor/cgltf/lib/cgltf.a" ] || [ "$(uname -s)" = OpenBSD ]; then
  OVERLAY="$HERE/build/odin-root"
  OVERLAY_OUTPUTS=("$OVERLAY/base" "$OVERLAY/core" "$OVERLAY/shared" "$OVERLAY/vendor/stb" "$OVERLAY/vendor/cgltf" "$OVERLAY/vendor/sdl3")
  if ! build_cache_fresh "$ODIN_SYS_KEY" "$HERE/build/odin-root.stamp" "${OVERLAY_OUTPUTS[@]}"; then
    rm -f "$HERE/build/odin-root.stamp"
    OVERLAY_REBUILT=1
    # An older overlay symlinks vendor/cgltf to the read-only install;
    # start over rather than copy into it. rm -rf does not follow links.
    rm -rf "$OVERLAY"
    mkdir -p "$OVERLAY/vendor"
    ln -sfn "$SYS_ODIN/base" "$SYS_ODIN/core" "$SYS_ODIN/shared" "$OVERLAY/"
    for entry in "$SYS_ODIN/vendor"/*; do
      case "$(basename "$entry")" in
      stb | cgltf)
        cp -r "$entry" "$OVERLAY/vendor/"
        chmod -R u+w "$OVERLAY/vendor/$(basename "$entry")"
        ;;
      *) ln -sfn "$entry" "$OVERLAY/vendor/" ;;
      esac
    done
    ODIN_ROOT="$OVERLAY" "$OVERLAY/vendor/stb/src/build_stb.sh"
    ODIN_ROOT="$OVERLAY" "$OVERLAY/vendor/cgltf/src/build_cgltf.sh"
    # The bindings pick ../lib/*.a `when ODIN_OS == .Linux` and otherwise
    # fall back to system:stb_image etc., which no OpenBSD package ships.
    # build_*.sh build the same ELF archives there; point OpenBSD at them.
    if [ "$(uname -s)" = OpenBSD ]; then
      for binding in "$OVERLAY"/vendor/stb/*/*.odin "$OVERLAY"/vendor/cgltf/*.odin; do
        sed 's/when ODIN_OS == \.Linux$/when ODIN_OS == .Linux || ODIN_OS == .OpenBSD/' "$binding" >"$binding.tmp"
        mv "$binding.tmp" "$binding"
      done
    fi
  fi
  ODIN_ROOT_ARG=(ODIN_ROOT="$OVERLAY")
fi

APP_LINK_ARGS=()
if [ "$(uname -s)" = Linux ]; then
  APPIMAGE_KEY="$(native_key 'AppImage bridge C11 O2 PIC pthread' "$HERE/scripts/build-appimage-updater.sh" "$HERE/app/appimage_update_client.c")"
  if ! build_cache_fresh "$APPIMAGE_KEY" "$HERE/build/appimage-bridge.stamp" "$HERE/build/libwnappimage.a"; then
    rm -f "$HERE/build/appimage-bridge.stamp" "$HERE/build/libwnappimage.a"
    bash "$HERE/scripts/build-appimage-updater.sh" bridge
    build_cache_store "$APPIMAGE_KEY" "$HERE/build/appimage-bridge.stamp" "$HERE/build/libwnappimage.a"
  fi
elif [ "$(uname -s)" = Darwin ]; then
  SPARKLE="$(bash "$HERE/scripts/build-sparkle-updater.sh" "$HERE/build")"
  cc -fobjc-arc -fblocks -F"$SPARKLE" -c "$HERE/app/updater_sparkle.m" -o "$HERE/build/updater_sparkle.o"
  ar rcs "$HERE/build/libwnsparkle.a" "$HERE/build/updater_sparkle.o"
fi
if [ "$(uname -s)" = OpenBSD ]; then
  # Point only this compiler overlay at the private SDL, never the system copy.
  if [ -L "$OVERLAY/vendor/sdl3" ] || [ ! -d "$OVERLAY/vendor/sdl3" ]; then
    rm -rf "$OVERLAY/vendor/sdl3"
    cp -R "$SYS_ODIN/vendor/sdl3" "$OVERLAY/vendor/sdl3"
  fi
  printf 'package sdl3\n@(export) foreign import lib {"../../../sdl/lib/libSDL3.a", "system:pthread", "system:m", "system:usbhid"}\n' \
    >"$OVERLAY/vendor/sdl3/sdl3__foreign.odin"
  # OpenBSD has no O_EXEC: Odin's pre-open would require read permission,
  # allowing writable hardlinks to helpers. Probe execute permission instead.
  # Odin's OpenBSD futex waits also panic on EAGAIN, EINTR and ECANCELED,
  # which the kernel returns for ordinary lost races and signals, and read
  # the 32-bit errno as 64 bits. Patch private copies of core/os and core/sync.
  if [ -L "$OVERLAY/core" ]; then
    rm "$OVERLAY/core"
    mkdir -p "$OVERLAY/core"
    for entry in "$SYS_ODIN/core"/*; do
      ln -s "$entry" "$OVERLAY/core/"
    done
  fi
  for pkg in os sync; do
    if [ -L "$OVERLAY/core/$pkg" ]; then
      rm "$OVERLAY/core/$pkg"
      cp -R "$SYS_ODIN/core/$pkg" "$OVERLAY/core/"
    fi
  done
  for patch in "$HERE"/patches/odin-openbsd-*.patch; do
    if apply_in_build odin-root --check "$patch" 2>/dev/null; then
      apply_in_build odin-root "$patch"
    elif ! apply_in_build odin-root --reverse --check "$patch" 2>/dev/null; then
      echo "==> $(basename "$patch") conflicts with the installed compiler" >&2
      exit 1
    fi
  done
  # Keep bundled OpenSSL/SQLCipher symbols private: system libcurl uses LibreSSL.
  APP_LINK_ARGS=('-extra-linker-flags:-Wl,--wrap=execve,--exclude-libs=libmarmot_c.a')
elif [ "$(uname -s)" = Linux ]; then
  # System libssl must not resolve crypto calls to Marmot's bundled OpenSSL.
  link_flags='-Wl,--exclude-libs=libmarmot_c.a'
  # clang searches LIBRARY_PATH after its system dirs (GCC searches it
  # first), so the Flatpak's /app/lib SDL 3.4 would lose to the SDK's
  # SDL 3.2. Explicit -L dirs precede the system ones.
  IFS=: read -ra lib_dirs <<<"${LIBRARY_PATH:-}"
  for dir in "${lib_dirs[@]}"; do
    if [ -n "$dir" ]; then
      link_flags+=" -L$dir"
    fi
  done
  APP_LINK_ARGS=("-extra-linker-flags:$link_flags")
fi
if [ "$OVERLAY_REBUILT" = 1 ]; then
  # OpenBSD modifies core and SDL bindings above; publish only their final form.
  build_cache_store "$ODIN_SYS_KEY" "$HERE/build/odin-root.stamp" "${OVERLAY_OUTPUTS[@]}"
fi

ACTIVE_ODIN="${OVERLAY:-${ODIN_ROOT:-$SYS_ODIN}}"
ODIN_INPUTS=("$ACTIVE_ODIN/base" "$ACTIVE_ODIN/core" "$ACTIVE_ODIN/shared")
ODIN_LIST="$(mktemp)"
find -L "$ACTIVE_ODIN/vendor" \( -name .git -o -name .hg -o -name .svn -o -name .env -o -name '*.env' \) -prune -o -name '*.odin' -print0 >"$ODIN_LIST"
while IFS= read -r -d '' entry; do ODIN_INPUTS+=("$entry"); done <"$ODIN_LIST"
rm -f "$ODIN_LIST"
ODIN_ENV="$(native_compile_key "Odin sources $ACTIVE_ODIN" "${ODIN_INPUTS[@]}")"
ODIN_LINK_ENV="$(native_key "Odin native $ODIN_SYS_KEY ${ODIN_ROOT_ARG[*]}" "$ACTIVE_ODIN/base" "$ACTIVE_ODIN/core" "$ACTIVE_ODIN/vendor/stb" "$ACTIVE_ODIN/vendor/cgltf" "$ACTIVE_ODIN/vendor/sdl3")"
MESH_OBJECT_KEY="$(native_compile_key "mesh Odin speed $ODIN_ENV" "$HERE/model-decoder")"
MESH_ODIN_KEY="$(native_key "mesh Odin speed $ODIN_LINK_ENV" "$HERE/model-decoder" "$HERE/build/libwnmesh.a")"
native_odin_build wn-mesh "$HERE/model-decoder" "$ACTIVE_ODIN" speed "$MESH_OBJECT_KEY" "$MESH_ODIN_KEY"
MATH_OBJECT_KEY="$(native_compile_key "math Odin speed $ODIN_ENV" "$HERE/math-decoder" "$MICROTEX/res/tex-gyre/texgyredejavu-math.clm2")"
MATH_ODIN_KEY="$(native_key "math Odin speed $ODIN_LINK_ENV" "$HERE/math-decoder" "$HERE/build/libwnmath.a" "$HERE/build/microtex/lib/libmicrotex.a" "$MICROTEX/res/tex-gyre/texgyredejavu-math.clm2")"
native_odin_build wn-math "$HERE/math-decoder" "$ACTIVE_ODIN" speed "$MATH_OBJECT_KEY" "$MATH_ODIN_KEY"
NES_OBJECT_KEY="$(native_compile_key "nes Odin speed $ODIN_ENV" "$HERE/nes-decoder")"
NES_ODIN_KEY="$(native_key "nes Odin speed $ODIN_LINK_ENV" "$HERE/nes-decoder" "$HERE/build/libwnmesh.a")"
native_odin_build wn-nes "$HERE/nes-decoder" "$ACTIVE_ODIN" speed "$NES_OBJECT_KEY" "$NES_ODIN_KEY"

# The dev host builds a reloadable library after staging these same inputs.
if [ "${1:-}" = stage ]; then
  exit 0
fi

# Remove the previous binaries first: overwriting one that is still
# mapped by a running instance leaves a half-written file whose next
# run segfaults in libc's init, long before main.
SMOKE_ODIN="$(odin root)"
SMOKE_OBJECT_KEY="$(native_compile_key "smoke Odin default $SMOKE_ODIN" "$SMOKE_ODIN/base" "$SMOKE_ODIN/core" "$SMOKE_ODIN/shared" "$HERE/tests/smoke" "$HERE/marmot")"
SMOKE_KEY="$(native_key "smoke Odin default $ODIN_SYS_KEY ${ODIN_ROOT:-}" "$SMOKE_ODIN/base" "$SMOKE_ODIN/core" "$HERE/tests/smoke" "$HERE/marmot" "$BUNDLE/lib/libmarmot_c.a")"
native_odin_build smoke "$HERE/tests/smoke" "$SMOKE_ODIN" default "$SMOKE_OBJECT_KEY" "$SMOKE_KEY"
# -o:speed: the STL orbit path needs it (200k tris: 20ms/step at
# -o:minimal vs 3.4ms; 60fps budget is 16.6ms).
APP_LIBS=("$BUNDLE/lib/libmarmot_c.a" "$HERE/build/libwnipc.a" "$HERE/build/libwndecoder.a" "$HERE/build/libwntimestamp.a" "$HERE/build/libwnws.a")
case "$(uname -s)" in
Linux) APP_LIBS+=("$HERE/build/libwnappimage.a") ;;
Darwin) APP_LIBS+=("$HERE/build/libwnsparkle.a") ;;
OpenBSD) APP_LIBS+=("$HERE/build/libwnsandbox.a" "$HERE/build/sdl/lib/libSDL3.a") ;;
esac
APP_INPUTS=("$HERE/app" "$HERE/marmot" "$HERE/lang" "$HERE/themes" "$CROP" "$CLAY/bindings/odin/clay-odin" "$HERE/vendor/common-passwords.txt" "$HERE/build/observability-tokens.toml")
APP_OBJECT_KEY="$(native_compile_key "app Odin speed $ODIN_ENV" "${APP_INPUTS[@]}")"
APP_KEY="$(native_key "app Odin speed $ODIN_LINK_ENV ${APP_LINK_ARGS[*]}" "${APP_INPUTS[@]}" "${APP_LIBS[@]}")"
native_odin_build app "$HERE/app" "$ACTIVE_ODIN" speed "$APP_OBJECT_KEY" "$APP_KEY" "${APP_LINK_ARGS[@]}"
# Unused imports: fatal in CI, a warning locally so a work-in-progress
# import does not block a build.
if ! env "${ODIN_ROOT_ARG[@]}" "$HERE/scripts/vet-imports.sh"; then
  if [ -n "${CI:-}" ]; then
    echo "==> unused imports in app/. Remove them." >&2
    exit 1
  fi
  echo "==> warning: unused imports in app/ (fatal in CI)." >&2
fi

echo "==> Done: $HERE/build/{smoke,app}"

# `just test` also runs the app package's test procs, which is what CI
# does after the build.
if [ "${1:-}" = test ]; then
  bash "$HERE/tests/build-cache-test.sh"
  bash "$HERE/tests/version-test.sh"
  bash "$HERE/tests/mdk-patches-test.sh"
  bash "$HERE/tests/emoji-bundle-test.sh"
  cc -O2 -Wall -Wextra "$HERE/tests/ws-frame-test.c" \
    $(pkg-config --cflags --libs libcurl) -o "$HERE/build/ws-frame-test"
  "$HERE/build/ws-frame-test"
  cc -O2 -Wall -Wextra "$HERE/tests/proxy-credentials-test.c" \
    $(pkg-config --cflags --libs libcurl) -o "$HERE/build/proxy-credentials-test"
  "$HERE/build/proxy-credentials-test"
  cc -O2 -Wall -Wextra "$HERE/tests/decoder-limits-test.c" -o "$HERE/build/decoder-limits-test"
  "$HERE/build/decoder-limits-test"
  cc -O2 -Wall -Wextra "$HERE/tests/timestamp-test.c" "$HERE/build/libwntimestamp.a" -o "$HERE/build/timestamp-test"
  "$HERE/build/timestamp-test"
  cc -O2 -Wall -Wextra -I"${IMAGE_ODIN%/}/vendor/stb/src" "$HERE/tests/image-test.c" \
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
  cc -std=c11 -I"$HERE/vendor/mdk/crates/marmot-c/include" "$HERE/tests/event-layout-test.c" -o "$HERE/build/event-layout-test"
  "$HERE/build/event-layout-test"
  cc -O2 -I"$HERE/build/clay" "$HERE/tests/clay_hashmap_test.c" -lm -o "$HERE/build/clay/hashmap-test"
  "$HERE/build/clay/hashmap-test"
  cc -O2 -I"$HERE/build/clay" "$HERE/tests/clay_scroll_test.c" -lm -o "$HERE/build/clay/scroll-test"
  "$HERE/build/clay/scroll-test"
  # Needs the Linux-only speech runtime (see the speech helpers above).
  if [ "$(uname -s)" = Linux ]; then
    cc -O2 -Wall -Wextra -I"$TTS/include" "$HERE/tests/stt-test.c" "$HERE/build/libwnipc.a" \
      -L"$TTS/lib" -lsherpa-onnx-c-api -Wl,-rpath,'$ORIGIN/tts-lib' \
      $(pkg-config --cflags --libs sdl3 libcurl glib-2.0 libavformat libavcodec libavutil libswresample libcrypto) -pthread -lm -o "$HERE/build/stt-test"
    "$HERE/build/stt-test"
  fi
  cc -O2 -Wall -Wextra "$HERE/tests/speech-decode-test.c" "$HERE/app/helper_ipc.c" \
    $(pkg-config --cflags --libs glib-2.0 libavformat libavcodec libavutil libswresample) \
    -pthread -lm -o "$HERE/build/speech-decode-test"
  "$HERE/build/speech-decode-test"
  env "${ODIN_ROOT_ARG[@]}" "$HERE/tests/odin.sh" app
  for check in rail_default_window rail_expand_narrow status_bar_viewports; do
    SDL_VIDEODRIVER=dummy env "${ODIN_ROOT_ARG[@]}" "$HERE/tests/odin.sh" app -define:ODIN_TEST_NAMES="$check"
  done
  SDL_VIDEODRIVER=dummy env "${ODIN_ROOT_ARG[@]}" "$HERE/tests/odin.sh" app -define:ODIN_TEST_NAMES=settings_viewport
  SDL_VIDEODRIVER=dummy env "${ODIN_ROOT_ARG[@]}" "$HERE/tests/odin.sh" app -define:ODIN_TEST_NAMES=theme_gallery_interactions
  SDL_VIDEODRIVER=dummy env "${ODIN_ROOT_ARG[@]}" "$HERE/tests/odin.sh" app -define:ODIN_TEST_NAMES=wallpaper_proportions
  SDL_VIDEODRIVER=dummy env "${ODIN_ROOT_ARG[@]}" "$HERE/tests/odin.sh" app/sdlrl
fi
