#!/usr/bin/env bash
# Build White Noise Linux against marmot-c from the pinned mdk revision.
# `just test` builds, then runs the app package's tests.
#
# Every third-party revision this build pins lives in DEPS_PIN, one
# `<name>-commit = <sha>` line each. vendor/mdk is cloned at mdk-commit and
# its C bundle staged by upstream's own c-bindings.sh; both steps are skipped
# when already present. Then the Odin packages build against the staticlib.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
bash "$HERE/scripts/version.sh" >/dev/null
# One pinned revision out of DEPS_PIN, by name.
pin() { sed -n "s/^$1-commit = //p" "$HERE/DEPS_PIN"; }

MDK_REPO="https://github.com/marmot-protocol/mdk.git"
MDK_PIN="$(pin mdk)"
MDK="$HERE/vendor/mdk"
BUNDLE="$MDK/crates/marmot-c/output"
MDK_PATCHES=("$HERE/patches/mdk-send-connections.patch" "$HERE/patches/mdk-message-authority.patch" "$HERE/patches/mdk-message-tags.patch" "$HERE/patches/mdk-history-repair.patch")

if [ ! -d "$MDK" ]; then
  git clone --filter=blob:none "$MDK_REPO" "$MDK"
fi

if [ "$(git -C "$MDK" rev-parse HEAD)" != "$MDK_PIN" ]; then
  for patch in "${MDK_PATCHES[@]}"; do
    if git -C "$MDK" apply --reverse --check "$patch" 2>/dev/null; then
      git -C "$MDK" apply --reverse "$patch"
    fi
  done
  git -C "$MDK" fetch origin "$MDK_PIN"
  git -C "$MDK" checkout --detach "$MDK_PIN"
  rm -rf "$BUNDLE"
fi

# Apply Linux integration changes to the pinned MDK.
for patch in "${MDK_PATCHES[@]}"; do
  if git -C "$MDK" apply --check "$patch" 2>/dev/null; then
    git -C "$MDK" apply "$patch"
  elif ! git -C "$MDK" apply --reverse --check "$patch" 2>/dev/null; then
    echo "==> MDK patch conflicts with vendor/mdk: $patch" >&2
    exit 1
  fi
done
PATCHES_HASH="$(sha256sum "${MDK_PATCHES[@]}")"
if [ ! -f "$BUNDLE/lib/libmarmot_c.a" ] || [ ! -f "$BUNDLE/.otlp-export" ] || [ "$(cat "$BUNDLE/.mdk-patches" 2>/dev/null || true)" != "$PATCHES_HASH" ]; then
  # GCC folds SQLCipher's TLS seed into overflowing relocations (sqlcipher#600).
  CC="${CC:-clang}" OTLP_EXPORT=1 "$MDK/crates/marmot-c/c-bindings.sh"
  touch "$BUNDLE/.otlp-export"
  printf '%s\n' "$PATCHES_HASH" > "$BUNDLE/.mdk-patches"
fi

CLAY="$HERE/vendor/clay"
CLAY_PIN="$(pin clay)"
if [ ! -d "$CLAY" ]; then
  git clone --filter=blob:none https://github.com/nicbarker/clay.git "$CLAY"
  git -C "$CLAY" checkout --detach "$CLAY_PIN"
fi

# Rebuild Clay: the upstream prebuilt archive has the slot-reuse bug too.
CLAY_LIB="$CLAY/bindings/odin/clay-odin/linux/clay.a"
CLAY_PATCH="$HERE/patches/clay-hashmap.patch"
if [ ! -f "$HERE/build/clay/clay.a" ] || [ "$CLAY/clay.h" -nt "$HERE/build/clay/clay.a" ] || [ "$CLAY_PATCH" -nt "$HERE/build/clay/clay.a" ]; then
  mkdir -p "$HERE/build/clay"
  cp "$CLAY/clay.h" "$HERE/build/clay/clay.h"
  git -C "$HERE" apply --directory=build/clay "$CLAY_PATCH"
  cc -x c -c -DCLAY_IMPLEMENTATION -fPIC -O2 "$HERE/build/clay/clay.h" -o "$HERE/build/clay/clay.o"
  ar rcs "$HERE/build/clay/clay.a" "$HERE/build/clay/clay.o"
fi
cp "$HERE/build/clay/clay.a" "$CLAY_LIB"

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

# FBX support: ufbx (single-file MIT reader) plus app/fbx_shim.c, the
# flat C API the Odin viewer binds. FBX is a versioned proprietary
# format with skinning and animation curves; ufbx already reads every
# flavor, so only the shim is ours. Archived into build/ so a stale
# object can't survive a shim edit.
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

mkdir -p "$HERE/build/fbx"
if [ ! -f "$HERE/build/fbx/ufbx.o" ]; then
  cc -c -O2 -fPIC "$UFBX/ufbx.c" -o "$HERE/build/fbx/ufbx.o"
fi
if [ ! -f "$HERE/build/fbx/fbx_shim.o" ] || [ "$HERE/app/fbx_shim.c" -nt "$HERE/build/fbx/fbx_shim.o" ]; then
  cc -c -O2 -fPIC -I"$UFBX" "$HERE/app/fbx_shim.c" -o "$HERE/build/fbx/fbx_shim.o"
  rm -f "$HERE/build/libwnfbx.a"
fi
if [ ! -f "$HERE/build/libwnfbx.a" ]; then
  ar rcs "$HERE/build/libwnfbx.a" "$HERE/build/fbx/ufbx.o" "$HERE/build/fbx/fbx_shim.o"
fi

# Nostr event fetch (nevent cards): a websocket REQ over libcurl's
# raw socket, framed in app/ws_shim.c.
mkdir -p "$HERE/build/ws"
if [ ! -f "$HERE/build/libwnws.a" ] || [ "$HERE/app/ws_shim.c" -nt "$HERE/build/libwnws.a" ]; then
  cc -c -O2 -fPIC "$HERE/app/ws_shim.c" -o "$HERE/build/ws/ws_shim.o"
  rm -f "$HERE/build/libwnws.a"
  ar rcs "$HERE/build/libwnws.a" "$HERE/build/ws/ws_shim.o"
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
MICROTEX="$HERE/vendor/microtex"
MICROTEX_PIN="$(pin microtex)"
MICROTEX_PATCH="$HERE/patches/microtex-isolation.patch"
if [ ! -d "$MICROTEX" ]; then
  git clone --filter=blob:none https://github.com/NanoMichael/MicroTeX.git "$MICROTEX"
fi
if [ "$(git -C "$MICROTEX" rev-parse HEAD)" != "$MICROTEX_PIN" ]; then
  git -C "$MICROTEX" checkout -- .
  git -C "$MICROTEX" fetch origin "$MICROTEX_PIN"
  git -C "$MICROTEX" checkout --detach "$MICROTEX_PIN"
  rm -rf "$HERE/build/microtex"
fi
if git -C "$MICROTEX" apply --check "$MICROTEX_PATCH" 2>/dev/null; then
  git -C "$MICROTEX" apply "$MICROTEX_PATCH"
elif ! git -C "$MICROTEX" apply --reverse --check "$MICROTEX_PATCH" 2>/dev/null; then
  echo "==> MicroTeX patch conflicts with vendor/microtex: $MICROTEX_PATCH" >&2
  exit 1
fi
if [ ! -f "$HERE/build/microtex/CMakeCache.txt" ]; then
  cmake -S "$MICROTEX" -B "$HERE/build/microtex" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_STATIC=ON -DHAVE_CWRAPPER=ON \
    -DHAVE_LOG=OFF -DGRAPHICS_DEBUG=OFF -DHAVE_AUTO_FONT_FIND=OFF
fi
# Incremental: a no-op unless the pin or the patch changed sources.
cmake --build "$HERE/build/microtex" --target microtex -j"$(nproc)"
mkdir -p "$HERE/build/math"
if [ ! -f "$HERE/build/libwnmath.a" ] || [ "$HERE/app/math_shim.cpp" -nt "$HERE/build/libwnmath.a" ] || [ "$MICROTEX_PATCH" -nt "$HERE/build/libwnmath.a" ]; then
  c++ -std=c++17 -c -O2 -fPIC -Wall -Wextra -DHAVE_CWRAPPER -isystem "$MICROTEX/lib" -isystem "$HERE/build/microtex/lib" \
    $(pkg-config --cflags cairo) "$HERE/app/math_shim.cpp" -o "$HERE/build/math/math_shim.o"
  rm -f "$HERE/build/libwnmath.a"
  ar rcs "$HERE/build/libwnmath.a" "$HERE/build/math/math_shim.o"
fi

# FreeType decodes profile web fonts for the existing SFNT text renderer.
cc -O2 -Wall -Wextra "$HERE/app/font.c" $(pkg-config --cflags --libs freetype2) -o "$HERE/build/wn-font"

# Speech helper uses the pinned multilingual CPU runtime.
bash "$HERE/scripts/build-tts.sh"
TTS="$HERE/vendor/sherpa-onnx"
for speech in tts stt; do
  cc -O2 -Wall -Wextra -I"$TTS/include" "$HERE/app/$speech.c" \
    -L"$TTS/lib" -lsherpa-onnx-c-api -Wl,-rpath,'$ORIGIN/tts-lib:$ORIGIN/../share/whitenoise-linux/tts-lib' \
    $(pkg-config --cflags --libs sdl3 libcurl glib-2.0 mpv libcrypto) -lm -o "$HERE/build/wn-$speech"
done

# wn-webview: the process that runs a webxdc app offscreen and hands
# the app its pixels through shared memory. Optional: without
# webkit2gtk-4.1 there is no viewer, and .xdc attachments stay inert.
if pkg-config --exists webkit2gtk-4.1 2>/dev/null; then
  if [ ! -f "$HERE/build/wn-webview" ] || [ "$HERE/app/webview.c" -nt "$HERE/build/wn-webview" ] || [ "$HERE/app/webview.h" -nt "$HERE/build/wn-webview" ]; then
    cc -O2 "$HERE/app/webview.c" -o "$HERE/build/wn-webview" \
      $(pkg-config --cflags --libs webkit2gtk-4.1)
  fi
else
  echo "==> webkit2gtk-4.1 not found: webxdc apps will not run"
fi

# Full Twemoji 72x72 PNG set for reaction chips (any emoji, not just
# the embedded quick-react six), staged from the pinned crates.io
# tarball of twemoji-assets.
TWEMOJI="$HERE/vendor/twemoji"
if [ ! -d "$TWEMOJI" ]; then
  TMP="$(mktemp -d)"
  curl -sSfL -A "whitenoise-build" "https://static.crates.io/crates/twemoji-assets/twemoji-assets-1.5.1+17.0.2.crate" | tar xz -C "$TMP"
  mv "$TMP"/twemoji-assets-*/assets/72x72 "$TWEMOJI"
  rm -rf "$TMP"
fi

# Emoji picker catalog: "emoji<TAB>name" per line, extracted from the
# pinned emojis crate (the same dataset the slint build walks). Skin
# tone variants are dropped to keep the grid to base emoji.
CATALOG="$HERE/vendor/emoji-catalog.tsv"
if [ ! -f "$CATALOG" ]; then
  TMP="$(mktemp -d)"
  curl -sSfL -A "whitenoise-build" "https://static.crates.io/crates/emojis/emojis-0.6.4.crate" | tar xz -C "$TMP"
  grep -o 'Emoji { emoji: "[^"]*", name: "[^"]*"' "$TMP"/emojis-0.6.4/src/gen/mod.rs |
    sed 's/Emoji { emoji: "\([^"]*\)", name: "\([^"]*\)"/\1\t\2/' |
    grep -av $'\xf0\x9f\x8f\xbb' | grep -av $'\xf0\x9f\x8f\xbc' |
    grep -av $'\xf0\x9f\x8f\xbd' | grep -av $'\xf0\x9f\x8f\xbe' |
    grep -av $'\xf0\x9f\x8f\xbf' >"$CATALOG"
  rm -rf "$TMP"
fi

# Bundled fonts, staged like twemoji above so every package ships
# byte-identical faces regardless of the build host's font packages.
# Both archives are pinned by sha256; bump a pin and `rm -rf
# vendor/fonts` to restage.
#
#   JetBrainsMonoNerdFont-Regular.ttf  icons (Nerd Font private-use
#                                      codepoints, no system fallback)
#   LiberationSans-{Regular,Bold,Italic,BoldItalic}.ttf
#   LiberationMono-Regular.ttf         body, emphasis, mono
FONTS="$HERE/vendor/fonts"
NERD_ZIP_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/JetBrainsMono.zip"
NERD_ZIP_SHA="fab782a66f7d3019da64f6572db9fc5d3a4bcb19f9fa13e2d8a62e3693d6396e"
LIBERATION_URL="https://github.com/liberationfonts/liberation-fonts/files/7261482/liberation-fonts-ttf-2.1.5.tar.gz"
LIBERATION_SHA="7191c669bf38899f73a2094ed00f7b800553364f90e2637010a69c0e268f25d0"
mkdir -p "$FONTS"
if [ ! -f "$FONTS/JetBrainsMonoNerdFont-Regular.ttf" ]; then
  TMP="$(mktemp -d)"
  curl -sSfL -o "$TMP/jbmono.zip" "$NERD_ZIP_URL"
  echo "$NERD_ZIP_SHA  $TMP/jbmono.zip" | sha256sum -c -
  unzip -qo "$TMP/jbmono.zip" JetBrainsMonoNerdFont-Regular.ttf -d "$FONTS"
  rm -rf "$TMP"
fi
if [ ! -f "$FONTS/LiberationSans-Regular.ttf" ] || [ ! -f "$FONTS/LiberationSans-Italic.ttf" ] || [ ! -f "$FONTS/LiberationSans-BoldItalic.ttf" ]; then
  TMP="$(mktemp -d)"
  curl -sSfL -o "$TMP/liberation.tar.gz" "$LIBERATION_URL"
  echo "$LIBERATION_SHA  $TMP/liberation.tar.gz" | sha256sum -c -
  tar -xzf "$TMP/liberation.tar.gz" -C "$FONTS" --strip-components=1 \
    --wildcards '*/LiberationSans-Regular.ttf' '*/LiberationSans-Bold.ttf' \
    '*/LiberationSans-Italic.ttf' '*/LiberationSans-BoldItalic.ttf' '*/LiberationMono-Regular.ttf'
  rm -rf "$TMP"
fi

# Decorative profile names need mathematical alphabets and symbols that
# Liberation lacks. Keep the OFL faces identical across packages.
NOTO_URL="https://raw.githubusercontent.com/notofonts/noto-fonts/ffebf8c1ee449e544955a7e813c54f9b73848eac"
while read -r file sha; do
  if [ ! -f "$FONTS/$file" ]; then
    curl -sSfL "$NOTO_URL/hinted/ttf/${file%-Regular.ttf}/$file" -o "$FONTS/$file.tmp"
    echo "$sha  $FONTS/$file.tmp" | sha256sum -c -
    mv "$FONTS/$file.tmp" "$FONTS/$file"
  fi
done <<'FONTS'
NotoSansMath-Regular.ttf 80b61fd613d3519197e64fff6f7e71fdc7f3e6526440ea4115b554ef7fd59af7
NotoSansSymbols-Regular.ttf 8f02f31959bbdf6061547a188248e13f84dc5fdd940326ec494675f453f072bb
NotoSansSymbols2-Regular.ttf 630846d528dbe4c4981370a4d0a9475a1fd1491a129bb411f8e157cdb5de13c6
FONTS
if [ ! -f "$FONTS/Noto-LICENSE.txt" ]; then
  curl -sSfL "$NOTO_URL/LICENSE" -o "$FONTS/Noto-LICENSE.txt.tmp"
  echo "0dab92d0544f7b233403f14b84a663bdbfa746982eda629e7f4f9ffe1b036feb  $FONTS/Noto-LICENSE.txt.tmp" | sha256sum -c -
  mv "$FONTS/Noto-LICENSE.txt.tmp" "$FONTS/Noto-LICENSE.txt"
fi

# The math font (TeX Gyre DejaVu Math, app/math.odin) is under the GUST
# Font License, with the DejaVu changes in the public domain. MicroTeX's
# copy ships only a README that names both texts, so fetch them here.
while read -r file sha url; do
  if [ ! -f "$FONTS/$file" ]; then
    curl -sSfL "$url" -o "$FONTS/$file.tmp"
    echo "$sha  $FONTS/$file.tmp" | sha256sum -c -
    mv "$FONTS/$file.tmp" "$FONTS/$file"
  fi
done <<'LICENSES'
GUST-FONT-LICENSE.txt 2bd69affc3da00715116f713f57eab9707e96daf3562ad0215987b15b9c16f73 https://mirrors.ctan.org/fonts/tex-gyre-math/doc/GUST-FONT-LICENSE.txt
DejaVu-LICENSE.txt 7a083b136e64d064794c3419751e5c7dd10d2f64c108fe5ba161eae5e5958a93 https://raw.githubusercontent.com/dejavu-fonts/dejavu-fonts/version_2_37/LICENSE
LICENSES

mkdir -p "$HERE/build"

# The distro odin package ships vendor/stb without the built .a archives
# (the sdlrl text/image layer needs truetype + image). When they are
# missing, build them inside a private ODIN_ROOT that symlinks the real
# install and swaps in a writable copy of vendor/stb.
SYS_ODIN="$(dirname "$(realpath "$(command -v odin)")")"
ODIN_ROOT_ARG=()
if [ ! -f "$SYS_ODIN/vendor/stb/lib/stb_truetype.a" ]; then
  OVERLAY="$HERE/build/odin-root"
  if [ ! -f "$OVERLAY/vendor/stb/lib/stb_truetype.a" ]; then
    mkdir -p "$OVERLAY/vendor"
    ln -sfn "$SYS_ODIN/base" "$SYS_ODIN/core" "$SYS_ODIN/shared" "$OVERLAY/"
    for entry in "$SYS_ODIN/vendor"/*; do
      [ "$(basename "$entry")" = stb ] || ln -sfn "$entry" "$OVERLAY/vendor/"
    done
    cp -r "$SYS_ODIN/vendor/stb" "$OVERLAY/vendor/stb"
    chmod -R u+w "$OVERLAY/vendor/stb"
    (cd "$OVERLAY/vendor/stb/src" && ./build_stb.sh)
  fi
  ODIN_ROOT_ARG=(ODIN_ROOT="$OVERLAY")
fi

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
env "${ODIN_ROOT_ARG[@]}" odin build "$HERE/app" -o:speed -out:"$HERE/build/app"
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
  cc -std=c11 -I"$HERE/vendor/mdk/crates/marmot-c/include" "$HERE/tests/event-layout-test.c" -o "$HERE/build/event-layout-test"
  "$HERE/build/event-layout-test"
  cc -O2 -I"$HERE/build/clay" "$HERE/tests/clay_hashmap_test.c" -lm -o "$HERE/build/clay/hashmap-test"
  "$HERE/build/clay/hashmap-test"
  cc -O2 -Wall -Wextra -I"$TTS/include" "$HERE/tests/stt-test.c" \
    -L"$TTS/lib" -lsherpa-onnx-c-api -Wl,-rpath,'$ORIGIN/tts-lib' \
    $(pkg-config --cflags --libs sdl3 libcurl glib-2.0 mpv libcrypto) -lm -o "$HERE/build/stt-test"
  "$HERE/build/stt-test"
  env "${ODIN_ROOT_ARG[@]}" "$HERE/tests/odin.sh" app
  SDL_VIDEODRIVER=dummy env "${ODIN_ROOT_ARG[@]}" "$HERE/tests/odin.sh" app -define:ODIN_TEST_NAMES=settings_viewport
  SDL_VIDEODRIVER=dummy env "${ODIN_ROOT_ARG[@]}" "$HERE/tests/odin.sh" app/sdlrl
fi
