#!/usr/bin/env bash
# Build White Noise Linux against marmot-c from the pinned mdk revision.
# `just test` builds, then runs the app package's tests.
#
# Every third-party revision this build pins lives in DEPS_PIN, one
# `<name>-commit = <sha>` line per git checkout and one
# `<name>-file = <sha256> <url>` line per download (scripts/fetch.sh).
# vendor/mdk is cloned at mdk-commit and its C bundle staged by upstream's
# own c-bindings.sh; both steps are skipped when already present. Then the
# Odin packages build against the staticlib.
#
# Offline builds: run `scripts/build.sh fetch` (below) with network, or
# place each `-commit` checkout at vendor/<name> and each `-file` download
# at vendor/downloads/<name> and make marmot-c's crates available to cargo
# (scripts/aur-source.sh). Either way the build then fetches nothing.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
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
if [ "${1:-}" != sources ] && { [ ! -f "$BUNDLE/lib/libmarmot_c.a" ] || [ ! -f "$BUNDLE/.otlp-export" ] || [ "$(cat "$BUNDLE/.mdk-patches" 2>/dev/null || true)" != "$PATCHES_HASH" ]; }; then
  RUST_ENV=()
  if [ "$(uname -s)" = OpenBSD ]; then
    # ponytail: OpenBSD has no rustup, and its rust package (1.94) predates
    # MDK's pinned toolchain; libsqlite3-sys's build script uses cfg_select!,
    # still unstable there. Unlock that one feature on the stable compiler.
    # Drop this once the package reaches vendor/mdk/rust-toolchain.toml.
    RUST_ENV=(RUSTC_BOOTSTRAP=1 RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-Zcrate-attr=feature(cfg_select)")
  fi
  # GCC folds SQLCipher's TLS seed into overflowing relocations (sqlcipher#600).
  env "${RUST_ENV[@]}" CC="${CC:-clang}" OTLP_EXPORT=1 "$MDK/crates/marmot-c/c-bindings.sh"
  touch "$BUNDLE/.otlp-export"
  printf '%s\n' "$PATCHES_HASH" > "$BUNDLE/.mdk-patches"
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
  SDL_STAMP="$SDL_PIN NO_SHARED_MEMORY static no-dlopen-notes"
  if [ ! -f "$HERE/build/sdl/lib/libSDL3.a" ] || [ "$(cat "$HERE/build/sdl/stamp" 2>/dev/null || true)" != "$SDL_STAMP" ]; then
    cmake -S "$SDL" -B "$HERE/build/sdl-cmake" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$HERE/build/sdl" \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_C_FLAGS="${CFLAGS:-} -DNO_SHARED_MEMORY" \
      -DSDL_DLOPEN_NOTES=OFF \
      -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF
    cmake --build "$HERE/build/sdl-cmake" -j"$(getconf NPROCESSORS_ONLN)"
    cmake --install "$HERE/build/sdl-cmake"
    printf '%s\n' "$SDL_STAMP" > "$HERE/build/sdl/stamp"
  fi
  cc -O2 -fPIC -pthread -c "$HERE/app/main_sandbox.c" -o "$HERE/build/main_sandbox.o"
  cc -O2 -fPIC -pthread -c "$HERE/app/tool_broker.c" -o "$HERE/build/tool_broker.o"
  cc -O2 -fPIC -c "$HERE/app/helper_broker.c" -o "$HERE/build/helper_broker.o"
  ar rcs "$HERE/build/libwnsandbox.a" "$HERE/build/main_sandbox.o" "$HERE/build/tool_broker.o" "$HERE/build/helper_broker.o"
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
CLAY_STALE=0
for f in "$CLAY/clay.h" "${CLAY_PATCHES[@]}"; do
  if [ "$f" -nt "$HERE/build/clay/clay.a" ]; then CLAY_STALE=1; fi
done
if [ ! -f "$HERE/build/clay/clay.a" ] || [ "$CLAY_STALE" = 1 ]; then
  mkdir -p "$HERE/build/clay"
  cp "$CLAY/clay.h" "$HERE/build/clay/clay.h"
  for patch in "${CLAY_PATCHES[@]}"; do
    apply_in_build clay "$patch"
  done
  cc -x c -c -DCLAY_IMPLEMENTATION -fPIC -O2 "$HERE/build/clay/clay.h" -o "$HERE/build/clay/clay.o"
  ar rcs "$HERE/build/clay/clay.a" "$HERE/build/clay/clay.o"
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
# The stamp names the ufbx pin the object was built from, so a CI cache
# restored from another pin rebuilds instead of linking a stale object.
if [ ! -f "$HERE/build/fbx/ufbx.o" ] || [ "$(cat "$HERE/build/fbx/ufbx.stamp" 2>/dev/null || true)" != "$UFBX_PIN" ]; then
  cc -c -O2 -fPIC "$UFBX/ufbx.c" -o "$HERE/build/fbx/ufbx.o"
  echo "$UFBX_PIN" > "$HERE/build/fbx/ufbx.stamp"
fi

# Nostr event fetch (nevent cards) and Namecoin `.bit` NIP-05 resolution:
# both use one-shot websocket clients over libcurl's raw socket, framed
# in app/ws_shim.c (Nostr REQ) and app/nc_shim.c (ElectrumX JSON-RPC).
mkdir -p "$HERE/build/ws"
if [ ! -f "$HERE/build/libwnws.a" ] || \
   [ "$HERE/app/ws_shim.c" -nt "$HERE/build/libwnws.a" ] || \
   [ "$HERE/app/nc_shim.c" -nt "$HERE/build/libwnws.a" ] || \
   [ "$HERE/app/network_proxy.h" -nt "$HERE/build/libwnws.a" ] || \
   [ "$HERE/app/proxy_credentials.h" -nt "$HERE/build/libwnws.a" ]; then
  cc -c -O2 -fPIC $(pkg-config --cflags libcurl) "$HERE/app/ws_shim.c" -o "$HERE/build/ws/ws_shim.o"
  cc -c -O2 -fPIC $(pkg-config --cflags libcurl) "$HERE/app/nc_shim.c" -o "$HERE/build/ws/nc_shim.o"
  rm -f "$HERE/build/libwnws.a"
  ar rcs "$HERE/build/libwnws.a" "$HERE/build/ws/ws_shim.o" "$HERE/build/ws/nc_shim.o"
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
# MicroTeX is rebuilt only when its pin or patches change. The stamp makes
# that explicit: a restored CI cache has older mtimes than the fresh clone,
# so CMake's own staleness check would rebuild everything.
MICROTEX_STAMP="$({ echo "$MICROTEX_PIN"; cat "${MICROTEX_PATCHES[@]}"; } | sha256sum | cut -d' ' -f1)"
if [ ! -f "$HERE/build/microtex/lib/libmicrotex.a" ] || [ "$(cat "$HERE/build/microtex/stamp" 2>/dev/null || true)" != "$MICROTEX_STAMP" ]; then
  rm -rf "$HERE/build/microtex"
  cmake -S "$MICROTEX" -B "$HERE/build/microtex" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_STATIC=ON -DHAVE_CWRAPPER=ON \
    -DHAVE_LOG=OFF -DGRAPHICS_DEBUG=OFF -DHAVE_AUTO_FONT_FIND=OFF
  cmake --build "$HERE/build/microtex" --target microtex -j"$(getconf NPROCESSORS_ONLN)"
  echo "$MICROTEX_STAMP" > "$HERE/build/microtex/stamp"
  rm -f "$HERE/build/libwnmath.a"
fi
mkdir -p "$HERE/build/math"
if [ ! -f "$HERE/build/libwnmath.a" ] || [ "$HERE/app/math_shim.cpp" -nt "$HERE/build/libwnmath.a" ] || [ "$HERE/app/decoder_ipc.h" -nt "$HERE/build/libwnmath.a" ] || [ "$HERE/app/decoder_limits.h" -nt "$HERE/build/libwnmath.a" ] || [ "${MICROTEX_PATCHES[0]}" -nt "$HERE/build/libwnmath.a" ]; then
  c++ -std=c++17 -c -O2 -fPIC -Wall -Wextra -DHAVE_CWRAPPER -isystem "$MICROTEX/lib" -isystem "$HERE/build/microtex/lib" \
    $(pkg-config --cflags cairo) "$HERE/app/math_shim.cpp" -o "$HERE/build/math/math_shim.o"
  rm -f "$HERE/build/libwnmath.a"
  ar rcs "$HERE/build/libwnmath.a" "$HERE/build/math/math_shim.o"
fi

# Parent/child IPC is shared by speech and the webxdc host.
cc -c -O2 -fPIC -pthread "$HERE/app/helper_ipc.c" -o "$HERE/build/helper_ipc.o"
ar rcs "$HERE/build/libwnipc.a" "$HERE/build/helper_ipc.o"

# Attachment parsers run in helpers sharing one bounded pipe client.
cc -c -O2 -fPIC -pthread "$HERE/app/decoder_ipc.c" -o "$HERE/build/decoder_ipc.o"
ar rcs "$HERE/build/libwndecoder.a" "$HERE/build/decoder_ipc.o"
cc -c -O2 -fPIC -Wall -Wextra "$HERE/app/timestamp.c" -o "$HERE/build/timestamp.o"
ar rcs "$HERE/build/libwntimestamp.a" "$HERE/build/timestamp.o"
IMAGE_ODIN="$(env -u ODIN_ROOT odin root)"
cc -O2 -Wall -Wextra -I"${IMAGE_ODIN%/}/vendor/stb/src" "$HERE/app/image.c" \
  $(pkg-config --cflags --libs libwebp) -lm -o "$HERE/build/wn-image"
cc -O2 -Wall -Wextra "$HERE/app/archive.c" \
  $(pkg-config --cflags --libs libarchive) -o "$HERE/build/wn-archive"
cc -O2 -Wall -Wextra "$HERE/app/pdf.c" \
  $(pkg-config --cflags --libs poppler-glib cairo fontconfig) -lm -o "$HERE/build/wn-pdf"
cc -O2 -Wall -Wextra -I"$UFBX" "$HERE/app/fbx_helper.c" "$HERE/app/fbx_shim.c" \
  "$HERE/build/fbx/ufbx.o" -lm -o "$HERE/build/wn-fbx"
cc -c -O2 -fPIC "$HERE/app/mesh_limits.c" -o "$HERE/build/mesh_limits.o"
ar rcs "$HERE/build/libwnmesh.a" "$HERE/build/mesh_limits.o"

# FreeType decodes profile web fonts for the existing SFNT text renderer.
cc -O2 -Wall -Wextra "$HERE/app/font.c" $(pkg-config --cflags --libs freetype2) -o "$HERE/build/wn-font"

# Speech helpers use the pinned multilingual CPU runtime, which sherpa-onnx
# only publishes for Linux (and the cross targets'). Elsewhere (OpenBSD) the
# helpers are not built and reading aloud/dictation report that they could
# not start.
if [ "$(uname -s)" = Linux ]; then
  bash "$HERE/scripts/build-tts.sh"
  TTS="$HERE/vendor/sherpa-onnx"
  for speech in tts stt; do
    cc -O2 -Wall -Wextra -I"$TTS/include" "$HERE/app/$speech.c" "$HERE/build/libwnipc.a" \
      -L"$TTS/lib" -lsherpa-onnx-c-api -Wl,-rpath,'$ORIGIN/tts-lib' \
      $(pkg-config --cflags --libs sdl3 libcurl glib-2.0 libavformat libavcodec libavutil libswresample libcrypto) -pthread -lm -o "$HERE/build/wn-$speech"
  done
fi

# wn-webview: the process that runs a webxdc app offscreen and hands
# the app its pixels through shared memory. Optional: without
# webkit2gtk-4.1 there is no viewer, and .xdc attachments stay inert.
# OpenBSD never builds or runs the host, even with WebKit installed.
if [ "$(uname -s)" = OpenBSD ]; then
  echo "==> webxdc apps are disabled on OpenBSD"
elif pkg-config --exists webkit2gtk-4.1 2>/dev/null; then
  if [ ! -f "$HERE/build/wn-webview" ] || [ "$HERE/app/webview.c" -nt "$HERE/build/wn-webview" ] || [ "$HERE/app/webview.h" -nt "$HERE/build/wn-webview" ] || [ "$HERE/app/proxy_credentials.h" -nt "$HERE/build/wn-webview" ] || [ "$HERE/build/libwnipc.a" -nt "$HERE/build/wn-webview" ]; then
    cc -O2 "$HERE/app/webview.c" "$HERE/build/libwnipc.a" -pthread -o "$HERE/build/wn-webview" \
      $(pkg-config --cflags --libs webkit2gtk-4.1)
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
ODIN_ROOT_ARG=()
if [ ! -f "$SYS_ODIN/vendor/stb/lib/stb_truetype.a" ] || [ ! -f "$SYS_ODIN/vendor/cgltf/lib/cgltf.a" ] || [ "$(uname -s)" = OpenBSD ]; then
  OVERLAY="$HERE/build/odin-root"
  if [ ! -f "$OVERLAY/vendor/stb/lib/stb_truetype.a" ] || [ ! -f "$OVERLAY/vendor/cgltf/lib/cgltf.a" ]; then
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
  bash "$HERE/scripts/build-appimage-updater.sh" bridge
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
    > "$OVERLAY/vendor/sdl3/sdl3__foreign.odin"
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

env "${ODIN_ROOT_ARG[@]}" odin build "$HERE/model-decoder" -o:speed -out:"$HERE/build/wn-mesh"
env "${ODIN_ROOT_ARG[@]}" odin build "$HERE/math-decoder" -o:speed -out:"$HERE/build/wn-math"
env "${ODIN_ROOT_ARG[@]}" odin build "$HERE/nes-decoder" -o:speed -out:"$HERE/build/wn-nes"

# The dev host builds a reloadable library after staging these same inputs.
if [ "${1:-}" = stage ]; then
  exit 0
fi

# Remove the previous binaries first: overwriting one that is still
# mapped by a running instance leaves a half-written file whose next
# run segfaults in libc's init, long before main.
rm -f "$HERE/build/smoke" "$HERE/build/app"
odin build "$HERE/tests/smoke" -out:"$HERE/build/smoke"
# -o:speed: the STL orbit path needs it (200k tris: 20ms/step at
# -o:minimal vs 3.4ms; 60fps budget is 16.6ms).
env "${ODIN_ROOT_ARG[@]}" odin build "$HERE/app" -o:speed "${APP_LINK_ARGS[@]}" -out:"$HERE/build/app"
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
  for check in rail_default_window rail_expand_narrow status_bar_viewports login_input_required profile_edit_summary sticker_input_validation issues_empty_state folder_picker_dispatch archive_chat_dispatch folder_count_dispatch new_chat_reset_dispatch test_emoji_save_io_dispatch backup_password_dispatch invite_input_dispatch; do
    SDL_VIDEODRIVER=dummy env "${ODIN_ROOT_ARG[@]}" "$HERE/tests/odin.sh" app -define:ODIN_TEST_NAMES="$check"
  done
  SDL_VIDEODRIVER=dummy env "${ODIN_ROOT_ARG[@]}" "$HERE/tests/odin.sh" app -define:ODIN_TEST_NAMES=settings_viewport
  SDL_VIDEODRIVER=dummy env "${ODIN_ROOT_ARG[@]}" "$HERE/tests/odin.sh" app -define:ODIN_TEST_NAMES=theme_gallery_interactions
  SDL_VIDEODRIVER=dummy env "${ODIN_ROOT_ARG[@]}" "$HERE/tests/odin.sh" app -define:ODIN_TEST_NAMES=test_emoji_save_dispatch
  SDL_VIDEODRIVER=dummy env "${ODIN_ROOT_ARG[@]}" "$HERE/tests/odin.sh" app -define:ODIN_TEST_NAMES=wallpaper_proportions
  SDL_VIDEODRIVER=dummy env "${ODIN_ROOT_ARG[@]}" "$HERE/tests/odin.sh" app/sdlrl
fi
