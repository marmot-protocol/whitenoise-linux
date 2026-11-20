#!/usr/bin/env bash
# Build the Odin client as an SDL Android application.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-android-arm64}"
STAGE="${2:-all}"
case "$TARGET" in
android-amd64) ABI=x86_64; TRIPLE=x86_64-linux-android; ODIN_TARGET=linux_amd64 ;;
android-arm64) ABI=arm64-v8a; TRIPLE=aarch64-linux-android; ODIN_TARGET=linux_arm64 ;;
*) echo 'Usage: android-build.sh {android-amd64|android-arm64} [all|backend|app|package]' >&2; exit 2 ;;
esac
case "$STAGE" in all|backend|app|package) ;; *) echo "Unknown build stage: $STAGE" >&2; exit 2 ;; esac
OUT="$HERE/build/cross/$TARGET"
PREFIX="$OUT/prefix"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
NDK="${WN_ANDROID_NDK:-$SDK/ndk/30.0.16248370}"
TOOLS="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
CC="$TOOLS/${TRIPLE}29-clang"
CXX="$TOOLS/${TRIPLE}29-clang++"
AR="$TOOLS/llvm-ar"
RANLIB="$TOOLS/llvm-ranlib"
ODIN_REAL="$(env -u ODIN_ROOT odin root)"
ODIN_REAL="${ODIN_REAL%/}"
export ANDROID_NDK_HOME="$NDK" ODIN_ANDROID_NDK="$NDK"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HERE/build/android-cargo}"
mkdir -p "$OUT"

# Bound Cargo and all of its build-script descendants, not just rustc jobs.
if [ "${WN_ANDROID_BUILD_SCOPED:-0}" != 1 ]; then
  available=0
  while read -r key value rest; do
    if [ "$key" = MemAvailable: ]; then available=$((value * 1024)); break; fi
  done < /proc/meminfo
  memory=$((available - 8589934592))
  if [ "$memory" -lt 2147483648 ]; then
    echo 'Android builds require at least 10 GiB available RAM (8 GiB reserved).' >&2
    exit 1
  fi
  if [ "$memory" -gt 6442450944 ]; then memory=6442450944; fi
  quota=$(($(getconf _NPROCESSORS_ONLN) * 80))
  if [ "$quota" -gt 800 ]; then quota=800; fi
  unit="wn-android-build-$TARGET-$$"
  systemd-run --user --scope --unit="$unit" -p "CPUQuota=$quota%" \
    -p "MemoryMax=$memory" -p MemorySwapMax=0 \
    env WN_ANDROID_BUILD_SCOPED=1 bash "$0" "$TARGET" "$STAGE" &
  runner=$!
  monitor() {
    while kill -0 "$runner" 2>/dev/null; do
      while read -r key value rest; do
        if [ "$key" = MemAvailable: ]; then available=$((value * 1024)); break; fi
      done < /proc/meminfo
      if [ "$available" -lt 8589934592 ]; then
        echo 'Stopping Android build to preserve 8 GiB available RAM.' >&2
        systemctl --user kill --kill-whom=all "$unit.scope"
        return
      fi
      sleep 1
    done
  }
  monitor & watchdog=$!
  trap 'kill "$watchdog" 2>/dev/null || true; systemctl --user kill --kill-whom=all "$unit.scope" 2>/dev/null || true' INT TERM
  result=0
  wait "$runner" || result=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  exit "$result"
fi

CFLAGS=(-O2 -fPIC -I"$PREFIX/include")
LDFLAGS=(-L"$PREFIX/lib" -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 -Wl,-z,now -Wl,-z,relro)
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH= PKG_CONFIG_SYSROOT_DIR=

build_backend() {
  local key="${TRIPLE//-/_}" upper="${TRIPLE^^}"
  upper="${upper//-/_}"
  (
    cd "$HERE/vendor/mdk"
    rustup target add "$TRIPLE"
    env -u CC -u CXX -u AR -u RANLIB -u PKG_CONFIG_LIBDIR -u PKG_CONFIG_PATH -u PKG_CONFIG_SYSROOT_DIR \
      "CC_$key=$CC" "CXX_$key=$CXX" "AR_$key=$AR" "RANLIB_$key=$RANLIB" \
      "CARGO_TARGET_${upper}_LINKER=$CC" \
      "CARGO_TARGET_${upper}_RUSTFLAGS=-C link-arg=-Wl,-z,max-page-size=16384" \
      cargo build --locked --release --target "$TRIPLE" -p marmot-c --features otlp-export -j 6
  )
  ln -sf "$CARGO_TARGET_DIR/$TRIPLE/release/libmarmot_c.a" "$OUT/libmarmot_c.a"
}

prepare_odin() {
  local root="$OUT/odin-root" entry name
  rm -rf "$root"
  mkdir -p "$root/vendor"
  cp -a "$ODIN_REAL/core" "$root/core"
  ln -s "$ODIN_REAL/base" "$root/base"
  ln -s "$ODIN_REAL/shared" "$root/shared"
  for entry in "$ODIN_REAL/vendor/"*; do
    name="${entry##*/}"
    case "$name" in
    stb | cgltf)
      cp -a "$entry" "$root/vendor/$name"
      rm -rf "$root/vendor/$name/lib"
      mkdir -p "$root/vendor/$name/lib"
      ;;
    *) ln -s "$entry" "$root/vendor/$name" ;;
    esac
  done
  for name in image image_write image_resize truetype rect_pack vorbis sprintf; do
    ln -s "$OUT/stb/stb_$name.a" "$root/vendor/stb/lib/stb_$name.a"
  done
  ln -s "$OUT/cgltf.a" "$root/vendor/cgltf/lib/cgltf.a"
  patch --batch --forward -d "$root" -p1 < "$HERE/patches/odin-android-runtime.patch"
  patch --batch --forward -d "$root" -p1 < "$HERE/patches/odin-android-syscalls.patch"
  export ODIN_ROOT="$root"
}

odin_object() {
  odin build "$HERE/$1" -target:"$ODIN_TARGET" -subtarget:android -minimum-os-version:29 \
    -define:WN_TARGET="$TARGET" -build-mode:obj -use-single-module -reloc-mode:pic \
    -out:"$OUT/$2.o"
}

build_native() {
  local source
  prepare_odin
  for source in helper_ipc decoder_ipc timestamp mesh_limits ws_shim; do
    "$CC" "${CFLAGS[@]}" -c "$HERE/app/$source.c" -o "$OUT/$source.o"
  done
  "$AR" rcs "$OUT/libwnipc.a" "$OUT/helper_ipc.o"
  "$AR" rcs "$OUT/libwndecoder.a" "$OUT/decoder_ipc.o"
  "$AR" rcs "$OUT/libwntimestamp.a" "$OUT/timestamp.o"
  "$AR" rcs "$OUT/libwnmesh.a" "$OUT/mesh_limits.o"
  "$AR" rcs "$OUT/libwnws.a" "$OUT/ws_shim.o"
  "$CC" "${CFLAGS[@]}" -c "$ODIN_REAL/vendor/cgltf/src/cgltf.c" -o "$OUT/cgltf.o"
  "$AR" rcs "$OUT/cgltf.a" "$OUT/cgltf.o"
  env -u WN_METRICS_WRITE_TOKEN -u WN_AUDIT_WRITE_TOKEN bash "$HERE/scripts/observability.sh"
  odin_object app app
  "$TOOLS/llvm-objcopy" --redefine-sym main=wn_odin_main "$OUT/app.o" "$OUT/android-app.o"
  "$CC" "${CFLAGS[@]}" -shared "$OUT/android-app.o" "$HERE/packaging/android/native/main.c" \
    "$OUT/libwnws.a" "$OUT/libwnipc.a" "$OUT/libwndecoder.a" "$OUT/libwntimestamp.a" \
    "$OUT/stb/stb.a" "$OUT/libmarmot_c.a" \
    "${LDFLAGS[@]}" -Wl,--exclude-libs=libmarmot_c.a -Wl,--no-undefined \
    -lSDL3 -lmpv -lcurl -llog -landroid -ldl -lm -o "$OUT/libmain.so"

  # These parsers retain their existing bounded, separate-process protocols.
  "$CC" "${CFLAGS[@]}" "$HERE/app/image.c" -I"$ODIN_REAL/vendor/stb/src" \
    "${LDFLAGS[@]}" -lwebp -lm -o "$OUT/wn-image"
  "$CC" "${CFLAGS[@]}" "$HERE/app/font.c" $(pkg-config --cflags --libs freetype2) \
    "${LDFLAGS[@]}" -lm -o "$OUT/wn-font"
  "$CC" "${CFLAGS[@]}" "$HERE/app/archive.c" "${LDFLAGS[@]}" -larchive -lm -o "$OUT/wn-archive"
  "$CC" "${CFLAGS[@]}" -I"$HERE/vendor/ufbx" "$HERE/app/fbx_helper.c" \
    "$HERE/app/fbx_shim.c" "$HERE/vendor/ufbx/ufbx.c" "${LDFLAGS[@]}" -lm -o "$OUT/wn-fbx"
  odin_object model-decoder mesh
  "$CC" "$OUT/mesh.o" "$OUT/libwnmesh.a" "$OUT/cgltf.a" "${LDFLAGS[@]}" -lm -o "$OUT/wn-mesh"
  odin_object nes-decoder nes
  "$CC" "$OUT/nes.o" "$OUT/libwnmesh.a" "${LDFLAGS[@]}" -lm -o "$OUT/wn-nes"
  "$CC" "${CFLAGS[@]}" "$HERE/app/pdf.c" $(pkg-config --cflags --libs poppler-glib cairo fontconfig) \
    "${LDFLAGS[@]}" -lm -o "$OUT/wn-pdf"
  "$CXX" "${CFLAGS[@]}" -std=c++17 -I"$HERE/vendor/bragi/capi/include" \
    $(pkg-config --cflags cairo) -c "$HERE/app/math_shim.cpp" -o "$OUT/math-shim.o"
  "$AR" rcs "$OUT/libwnmath.a" "$OUT/math-shim.o"
  odin_object math-decoder math
  "$CXX" "$OUT/math.o" "$OUT/libwnmath.a" $(pkg-config --libs cairo) \
    "${LDFLAGS[@]}" -lm -o "$OUT/wn-math"
}

package_apk() {
  local apk="$OUT/apk" library name dependency normalized jar java tools
  java="${JAVA_HOME:?Set JAVA_HOME to a JDK 17 or newer installation}"
  jar="$SDK/platforms/android-36/android.jar"
  tools="$SDK/build-tools/36.0.0"
  test -f "$jar"
  test -x "$java/bin/javac"
  export PATH="$java/bin:$PATH"
  rm -rf "$apk"
  mkdir -p "$apk/lib/$ABI" "$apk/assets/whitenoise/fonts" "$apk/assets/whitenoise/licenses" "$apk/classes"
  cp "$OUT/libmain.so" "$apk/lib/$ABI/libmain.so"
  for library in "$PREFIX/lib/"*.so*; do
    name="${library##*/}"; name="${name%%.so*}.so"
    cp -L "$library" "$apk/lib/$ABI/$name"
  done
  for name in image font archive fbx mesh nes pdf math; do
    cp "$OUT/wn-$name" "$apk/lib/$ABI/libwn-$name.so"
  done
  cp "$PREFIX/bin/curl" "$apk/lib/$ABI/libwn-curl.so"
  for library in "$apk/lib/$ABI/"*.so; do
    # Android extracts only lib*.so entries; keep every DT_NEEDED name in sync.
    name="${library##*/}"
    if [ "$name" != libmain.so ] && [[ "$name" != libwn-* ]]; then
      patchelf --page-size 16384 --set-soname "$name" "$library"
    fi
    while IFS= read -r dependency; do
      normalized="${dependency%%.so*}.so"
      if [ "$normalized" != "$dependency" ]; then
        test -f "$apk/lib/$ABI/$normalized"
        patchelf --page-size 16384 --replace-needed "$dependency" "$normalized" "$library"
      fi
    done < <(patchelf --print-needed "$library")
    # Decoder processes intentionally receive an empty environment.
    patchelf --page-size 16384 --set-rpath '$ORIGIN' "$library"
  done
  cp -a "$HERE/vendor/emoji" "$apk/assets/whitenoise/"
  cp "$HERE/vendor/emoji-catalog.tsv" "$apk/assets/whitenoise/"
  cp "$HERE/vendor/fonts/"*.{ttf,otf} "$apk/assets/whitenoise/fonts/"
  cp "$HERE/vendor/emoji-licenses/"*.txt "$apk/assets/whitenoise/licenses/"
  cp "$HERE/vendor/common-passwords.LICENSE" "$apk/assets/whitenoise/licenses/seclists.txt"
  cp "$HERE/vendor/fonts/"*.txt "$apk/assets/whitenoise/licenses/"
  cp "$HERE/app/assets/agents/"*-LICENSE.txt "$apk/assets/whitenoise/licenses/"
  cp "$HERE/vendor/crop-circles/LICENSE" "$apk/assets/whitenoise/licenses/crop-circles.txt"
  cp "$HERE/vendor/crop-circles/README.txt" "$apk/assets/whitenoise/licenses/crop-circles-notices.txt"
  cp "$OUT/SDL/LICENSE.txt" "$apk/assets/whitenoise/licenses/sdl.txt"
  cp "$OUT/libplacebo/LICENSE" "$apk/assets/whitenoise/licenses/libplacebo.txt"
  cp "$OUT/mpv/"LICENSE.* "$OUT/mpv/Copyright" "$apk/assets/whitenoise/licenses/"
  cp "$HERE/vendor/bragi/res/tex-gyre/README-TeX-Gyre-DejaVu-Math.txt" "$apk/assets/whitenoise/licenses/"
  cp "$HERE/vendor/bragi/LICENSE" "$apk/assets/whitenoise/licenses/bragi.txt"
  cp "$HERE/LICENSE" "$apk/assets/whitenoise/licenses/whitenoise.txt"
  for library in "$PREFIX/share/"*/copyright; do
    if [ ! -f "$library" ]; then continue; fi
    name="${library%/copyright}"; name="${name##*/}"
    cp "$library" "$apk/assets/whitenoise/licenses/$name.txt"
  done
  cat > "$apk/assets/whitenoise/fonts.conf" <<'FONTCONFIG'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig><dir prefix="relative">fonts</dir><cachedir prefix="xdg">fontconfig</cachedir></fontconfig>
FONTCONFIG
  cp /etc/ssl/certs/ca-certificates.crt "$apk/assets/whitenoise/cacert.pem"
  cp -a "$HERE/packaging/android/res" "$apk/res"
  mkdir -p "$apk/res/drawable" "$apk/generated"
  cp "$HERE/assets/whitenoise-linux.png" "$apk/res/drawable/whitenoise.png"
  "$tools/aapt2" compile --dir "$apk/res" -o "$apk/resources.zip"
  "$tools/aapt2" link -I "$jar" --manifest "$HERE/packaging/android/AndroidManifest.xml" \
    --version-name "$(bash "$HERE/scripts/version.sh")" \
    -A "$apk/assets" --java "$apk/generated" -o "$apk/unsigned.apk" "$apk/resources.zip"
  "$java/bin/javac" --release 11 -classpath "$jar" -d "$apk/classes" \
    "$OUT/SDL/android-project/app/src/main/java/org/libsdl/app/"*.java \
    "$HERE/packaging/android/java/dev/ipf/whitenoise/linux/"*.java \
    "$apk/generated/dev/ipf/whitenoise/linux/R.java"
  mapfile -d '' classes < <(find "$apk/classes" -name '*.class' -print0)
  "$tools/d8" --min-api 29 --lib "$jar" --output "$apk" "${classes[@]}"
  (cd "$apk" && zip -q -r unsigned.apk classes.dex lib)
  "$tools/zipalign" -P 16 -f 4 "$apk/unsigned.apk" "$apk/aligned.apk"
  if [ ! -f "$HERE/build/android-debug.keystore" ]; then
    "$java/bin/keytool" -genkeypair -keystore "$HERE/build/android-debug.keystore" -storepass android \
      -keypass android -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 3650 \
      -dname CN=AndroidDebug
  fi
  "$tools/apksigner" sign --ks "$HERE/build/android-debug.keystore" --ks-key-alias androiddebugkey \
    --ks-pass pass:android --key-pass pass:android --out "$OUT/WhiteNoise-$ABI-debug.apk" "$apk/aligned.apk"
  "$tools/apksigner" verify "$OUT/WhiteNoise-$ABI-debug.apk"
  "$tools/zipalign" -c -P 16 4 "$OUT/WhiteNoise-$ABI-debug.apk"
  printf '\n%s\n' "$OUT/WhiteNoise-$ABI-debug.apk"
}

if [ "$STAGE" = all ]; then
  bash "$HERE/scripts/android-deps.sh" "$TARGET"
fi
if [ "$STAGE" = all ] || [ "$STAGE" = backend ]; then
  env -u WN_METRICS_WRITE_TOKEN -u WN_AUDIT_WRITE_TOKEN bash "$HERE/scripts/build.sh" sources
  build_backend
fi
if [ "$STAGE" = all ] || [ "$STAGE" = app ]; then build_native; fi
if [ "$STAGE" = all ] || [ "$STAGE" = package ]; then package_apk; fi
