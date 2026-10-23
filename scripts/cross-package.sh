#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/scripts/build-cache.sh"
package_allowed() {
  local path="$1" resolved
  case "/$path/" in */.git/* | */.hg/* | */.svn/* | */.env/* | *.env/*) return 1 ;; esac
  if command -v realpath >/dev/null 2>&1; then
    resolved="$(realpath "$path")" || return 1
  else
    resolved="$(bun --eval 'console.log(require("node:fs").realpathSync(Bun.argv[Bun.argv.length - 1]))' "$path")" || return 1
  fi
  case "/$resolved/" in */.git/* | */.hg/* | */.svn/* | */.env/* | *.env/*) return 1 ;; esac
  return 0
}
stage_clean() {
  local excluded link listing root="${1:-$STAGE}"
  excluded="$(find "$root" \( -name .git -o -name .hg -o -name .svn -o -name .env -o -name '*.env' \) -print -quit)" || return 1
  [ -z "$excluded" ] || return 1
  listing="$(mktemp)"
  if ! find "$root" -type l -print0 >"$listing"; then
    rm -f "$listing"
    return 1
  fi
  while IFS= read -r -d '' link; do
    if ! package_allowed "$link"; then
      rm -f "$listing"
      return 1
    fi
  done <"$listing"
  rm -f "$listing"
}
find_curl() {
  local listing path
  listing="$(mktemp)"
  if ! find "$PREFIX" \( -name .git -o -name .hg -o -name .svn -o -name .env -o -name '*.env' \) -prune -o \
    -type f -name "curl$EXE" -print0 >"$listing"; then
    rm -f "$listing"
    return 1
  fi
  while IFS= read -r -d '' path; do
    if package_allowed "$path"; then
      printf '%s\n' "$path"
      rm -f "$listing"
      return 0
    fi
  done <"$listing"
  rm -f "$listing"
  return 1
}
copy_resources() {
  mkdir -p "$2"
  TAR_OPTIONS= tar -C "$1" --exclude=.git --exclude=.hg --exclude=.svn --exclude=.env --exclude='*.env' -cf - . |
    TAR_OPTIONS= tar -C "$2" --no-same-owner -xpf -
  if ! stage_clean "$2"; then
    echo 'Copied resources contain excluded paths or symlink targets' >&2
    return 1
  fi
}
TARGET="${1:?target required}"
OUT="$HERE/build/cross/$TARGET"
PREFIX="${WN_CROSS_PREFIX:?cross-build.sh must provide dependency prefix}"
TTS="${WN_CROSS_TTS:?cross-build.sh must provide speech runtime}"
SYSROOT="${WN_CROSS_SYSROOT:-}"
VERSION="${WN_RELEASE_VERSION:-$(bash "$HERE/scripts/version.sh")}"
case "$VERSION" in *[!a-zA-Z0-9._+-]*)
  echo 'Invalid archive version' >&2
  exit 2
  ;;
esac
NAME="WhiteNoise-$VERSION-$TARGET"
STAGE="$OUT/package/$NAME"
EXE=
# Linux keeps every helper program in the private usr/lib/whitenoise-linux:
# usr/bin holds only the app, and usr/share only data.
case "$TARGET" in
linux-arm64 | linux-amd64)
  SYSTEM=linux
  BIN="$STAGE/usr/bin"
  RES="$STAGE/usr/share/whitenoise-linux"
  HELPERS="$STAGE/usr/lib/whitenoise-linux"
  DECODERS="$HELPERS"
  TRIPLE=aarch64-linux-gnu
  [ "$TARGET" = linux-arm64 ] || TRIPLE=x86_64-linux-gnu
  ;;
windows-amd64)
  SYSTEM=windows
  BIN="$STAGE"
  RES="$STAGE/resources"
  EXE=.exe
  HELPERS="$BIN"
  DECODERS="$RES"
  ;;
darwin-amd64 | darwin-arm64)
  SYSTEM=darwin
  STAGE="$STAGE/White Noise.app"
  BIN="$STAGE/Contents/MacOS"
  RES="$STAGE/Contents/Resources/whitenoise-linux"
  HELPERS="$BIN"
  DECODERS="$RES"
  ;;
*)
  echo "Unsupported target: $TARGET" >&2
  exit 2
  ;;
esac
# Keep the pure dependency closure separate from release/signing operations.
# Hash runtime candidates, not the sysroot's headers/static archives or SDK.
CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
if [ "$(uname -s)" = Darwin ]; then CA_BUNDLE=/etc/ssl/cert.pem; fi
# cp dereferences these globbed leaves; reject excluded targets even on hits,
# rather than relying on the enclosing directory's filtered content key.
for resource in "$HERE/vendor/emoji-licenses/"*.txt "$HERE/vendor/fonts/"*.ttf "$HERE/vendor/fonts/"*.txt; do
  if [ ! -f "$resource" ] || ! package_allowed "$resource"; then
    echo 'Missing or excluded required package resource' >&2
    exit 1
  fi
done
STAGE_STAMP="$OUT/package/$NAME.stage.stamp"
STAGE_KEY=
STAGE_HIT=false
if [ "$SYSTEM" != darwin ]; then
  INPUTS=("$HERE/scripts/cross-package.sh" "$HERE/scripts/cross-bundle.js"
    "$HERE/scripts/build-cache.sh" "$CA_BUNDLE" "$(command -v bun)" "$(command -v tar)"
    "$HERE/vendor/emoji" "$HERE/vendor/emoji-licenses" "$HERE/vendor/emoji-catalog.tsv"
    "$HERE/vendor/fonts" "$HERE/vendor/crop-circles/LICENSE"
    "$HERE/vendor/crop-circles/README.txt" "$HERE/vendor/common-passwords.LICENSE"
    "$HERE/vendor/microtex/LICENSE"
    "$HERE/vendor/microtex/res/tex-gyre/README-TeX-Gyre-DejaVu-Math.txt"
    "$HERE/docs/tts.md" "$HERE/docs/stt.md" "$TTS/LICENSE"
    "$TTS/LICENSE-onnxruntime" "$TTS/ThirdPartyNotices-onnxruntime.txt")
  for helper in whitenoise wn-tts wn-stt wn-font wn-image wn-archive wn-pdf wn-mesh wn-fbx wn-math wn-nes; do
    INPUTS+=("$OUT/$helper$EXE")
  done
  ROOTS=("$PREFIX" "$TTS")
  if [ "$SYSTEM" = linux ]; then
    ROOTS+=("$SYSROOT/lib")
    INPUTS+=("$OUT/wn-webview" "$PREFIX/bin/curl" "$(command -v readelf)"
    "$(command -v patchelf)" "$(command -v glib-compile-schemas)")
    for dir in webkit2gtk-4.1 gstreamer-1.0 gio; do
      if [ -d "$PREFIX/lib/$TRIPLE/$dir" ]; then INPUTS+=("$PREFIX/lib/$TRIPLE/$dir"); fi
    done
    for dir in glib-2.0 gstreamer-1.0 mime fontconfig fonts; do
      if [ -d "$PREFIX/share/$dir" ]; then INPUTS+=("$PREFIX/share/$dir"); fi
    done
    if [ -d "$PREFIX/libexec" ]; then INPUTS+=("$PREFIX/libexec"); fi
    INPUT_LIST="$(mktemp)"
    if ! find -L "$SYSROOT/usr/share/doc" -maxdepth 2 \
      \( -name .git -o -name .hg -o -name .svn -o -name .env -o -name '*.env' \) -prune -o \
      -path "$SYSROOT/usr/share/doc/*/copyright" -print0 >"$INPUT_LIST"; then
      rm -f "$INPUT_LIST"
      exit 1
    fi
    while IFS= read -r -d '' copyright; do
      if package_allowed "$copyright"; then INPUTS+=("$copyright"); fi
    done <"$INPUT_LIST"
    rm -f "$INPUT_LIST"
  else
    ROOTS+=("${WN_CROSS_WINDOWS_RUNTIME:?}/x86_64-w64-mingw32" "${WN_CROSS_VELOPACK:?}/lib")
    INPUTS+=("$WN_CROSS_WINDOWS_RUNTIME/LICENSE.TXT"
      "$WN_CROSS_WINDOWS_RUNTIME/x86_64-w64-mingw32/share/mingw32"
      "$WN_CROSS_VELOPACK/LICENSE" "$HERE/vendor/mpv/LICENSE.GPL"
      "$HERE/vendor/libplacebo/LICENSE" "$(command -v x86_64-w64-mingw32-objdump)")
    for license in "$PREFIX/share/"*/copyright; do
      if package_allowed "$license"; then INPUTS+=("$license"); fi
    done
    CURL="$(find_curl)"
    test -n "$CURL"
    INPUTS+=("$CURL")
  fi
  for root in "${ROOTS[@]}"; do
    test -d "$root"
    INPUT_LIST="$(mktemp)"
    if ! find -H "$root" \( -name .git -o -name .hg -o -name .svn -o -name .env -o -name '*.env' \) -prune -o \
      \( -type f -o -type l \) \( -name '*.so*' -o -name '*.dll' -o -name '*.dylib' \) -print0 >"$INPUT_LIST"; then
      rm -f "$INPUT_LIST"
      exit 1
    fi
    # Dangling optional search candidates are not usable dependencies. Losing a
    # previously usable file still changes this input list and forces bundling.
    while IFS= read -r -d '' library; do
      if [ -f "$library" ] && package_allowed "$library"; then INPUTS+=("$library"); fi
    done <"$INPUT_LIST"
    rm -f "$INPUT_LIST"
  done
  for input in "${INPUTS[@]}"; do
    if ! package_allowed "$input"; then
      echo 'Missing or excluded required package input' >&2
      exit 1
    fi
  done
  STAGE_KEY="$(build_cache_key "package-stage-v1 target=$TARGET version=$VERSION prefix=$PREFIX tts=$TTS sysroot=$SYSROOT" "${INPUTS[@]}")"
  if build_cache_fresh "$STAGE_KEY" "$STAGE_STAMP" "$STAGE" && stage_clean; then
    STAGE_HIT=true
    printf 'Cached package stage %s\n' "$NAME"
  fi
else
  echo 'Package cache disabled for macOS: rerun nested code signing and Sparkle release handling.'
fi
if [ "$STAGE_HIT" = false ]; then
  # Remove stale output only after the content/output check, never before it.
  rm -f "$STAGE_STAMP"
  rm -rf "$OUT/package/$NAME"
  mkdir -p "$BIN" "$HELPERS" "$RES/fonts" "$RES/licenses"
  cp "$OUT/whitenoise$EXE" "$BIN/"
  cp "$OUT/wn-tts$EXE" "$OUT/wn-stt$EXE" "$HELPERS/"
  # Outside Linux, decoder helpers are resolved from resources, or beside the
  # app on Windows.
  cp "$OUT/wn-font$EXE" "$OUT/wn-image$EXE" "$OUT/wn-archive$EXE" "$OUT/wn-pdf$EXE" \
    "$OUT/wn-mesh$EXE" "$OUT/wn-fbx$EXE" "$OUT/wn-math$EXE" "$OUT/wn-nes$EXE" "$DECODERS/"
  if [ "$SYSTEM" = windows ]; then
    # DLL lookup starts at each helper's executable directory.
    cp "$OUT/wn-font$EXE" "$OUT/wn-image$EXE" "$OUT/wn-archive$EXE" "$OUT/wn-pdf$EXE" \
      "$OUT/wn-mesh$EXE" "$OUT/wn-fbx$EXE" "$OUT/wn-math$EXE" "$OUT/wn-nes$EXE" "$BIN/"
    cp "${WN_CROSS_WINDOWS_RUNTIME:?}/LICENSE.TXT" "$RES/licenses/llvm-runtime.txt"
    copy_resources "$WN_CROSS_WINDOWS_RUNTIME/x86_64-w64-mingw32/share/mingw32" "$RES/licenses/mingw-runtime"
    cp "${WN_CROSS_VELOPACK:?}/LICENSE" "$RES/licenses/velopack.txt"
  fi
  copy_resources "$HERE/vendor/emoji" "$RES/emoji"
  cp "$HERE/vendor/emoji-licenses/"*.txt "$RES/licenses/"
  cp "$HERE/vendor/emoji-catalog.tsv" "$RES/"
  cp "$HERE/vendor/fonts/"*.ttf "$RES/fonts/"
  cp "$HERE/vendor/fonts/"*.txt "$RES/licenses/"
  cat >"$RES/fonts.conf" <<'FONTCONFIG'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig><dir prefix="relative">fonts</dir><cachedir prefix="xdg">fontconfig</cachedir></fontconfig>
FONTCONFIG
  cp "$HERE/vendor/crop-circles/LICENSE" "$RES/licenses/crop-circles.txt"
  cp "$HERE/vendor/common-passwords.LICENSE" "$RES/licenses/seclists.txt"
  cp "$HERE/vendor/crop-circles/README.txt" "$RES/licenses/crop-circles-notices.txt"
  cp "$HERE/vendor/microtex/LICENSE" "$RES/licenses/microtex.txt"
  cp "$HERE/vendor/microtex/res/tex-gyre/README-TeX-Gyre-DejaVu-Math.txt" "$RES/licenses/tex-gyre-dejavu-math.txt"
  cp "$TTS/LICENSE" "$RES/licenses/sherpa-onnx.txt"
  cp "$TTS/LICENSE-onnxruntime" "$RES/licenses/onnxruntime.txt"
  cp "$TTS/ThirdPartyNotices-onnxruntime.txt" "$RES/licenses/onnxruntime-third-party.txt"
  cp "$HERE/docs/tts.md" "$RES/licenses/speech-model.md"
  cp "$HERE/docs/stt.md" "$RES/licenses/dictation-model.md"
  # The build host's CA bundle: Ubuntu's in the container, the system LibreSSL
  # bundle on a Mac (macOS has no /etc/ssl/certs).
  cp "$CA_BUNDLE" "$RES/cacert.pem"

  if [ "$SYSTEM" = linux ]; then
    cp "$OUT/wn-webview" "$PREFIX/bin/curl" "$HELPERS/"
    # WebKit and GStreamer load these subprocesses/plugins dynamically: ELF
    # DT_NEEDED alone cannot discover them. Include their data as well.
    mkdir -p "$STAGE/usr/lib" "$STAGE/usr/share"
    for dir in webkit2gtk-4.1 gstreamer-1.0 gio; do
      if [ -d "$PREFIX/lib/$TRIPLE/$dir" ]; then
        copy_resources "$PREFIX/lib/$TRIPLE/$dir" "$STAGE/usr/lib/$dir"
      fi
    done
    for dir in glib-2.0 gstreamer-1.0 mime fontconfig fonts; do
      if [ -d "$PREFIX/share/$dir" ]; then copy_resources "$PREFIX/share/$dir" "$STAGE/usr/share/$dir"; fi
    done
    glib-compile-schemas "$STAGE/usr/share/glib-2.0/schemas"
    if [ -d "$PREFIX/libexec" ]; then copy_resources "$PREFIX/libexec" "$STAGE/usr/libexec"; fi
    # License texts only; the rest of usr/share/doc is changelogs and manuals.
    while IFS= read -r -d '' copyright; do
      if ! package_allowed "$copyright"; then continue; fi
      package="$(basename "$(dirname "$copyright")")"
      mkdir -p "$RES/licenses/ubuntu-packages/$package"
      cp -L "$copyright" "$RES/licenses/ubuntu-packages/$package/copyright"
    done < <(find -L "$SYSROOT/usr/share/doc" -maxdepth 2 \
      \( -name .git -o -name .hg -o -name .svn -o -name .env -o -name '*.env' \) -prune -o \
      -path "$SYSROOT/usr/share/doc/*/copyright" -print0)
    cat >"$STAGE/whitenoise" <<'LAUNCH'
#!/usr/bin/env sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export LD_LIBRARY_PATH="$root/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export XDG_DATA_DIRS="$root/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export GSETTINGS_SCHEMA_DIR="$root/usr/share/glib-2.0/schemas"
export GIO_MODULE_DIR="$root/usr/lib/gio/modules"
export GST_PLUGIN_SYSTEM_PATH_1_0="$root/usr/lib/gstreamer-1.0"
export WEBKIT_EXEC_PATH="$root/usr/lib/webkit2gtk-4.1"
export WEBKIT_INJECTED_BUNDLE_PATH="$root/usr/lib/webkit2gtk-4.1/injected-bundle"
export SSL_CERT_FILE="$root/usr/share/whitenoise-linux/cacert.pem"
export CURL_CA_BUNDLE="$SSL_CERT_FILE"
exec "$root/usr/bin/whitenoise" "$@"
LAUNCH
    chmod +x "$STAGE/whitenoise"
  else
    CURL="$(find_curl)"
    test -n "$CURL"
    cp "$CURL" "$BIN/"
    for license in "$PREFIX/share/"*/copyright; do
      if ! package_allowed "$license"; then continue; fi
      cp "$license" "$RES/licenses/$(basename "$(dirname "$license")").txt"
    done
    cp "$HERE/vendor/mpv/LICENSE.GPL" "$RES/licenses/mpv.txt"
    cp "$HERE/vendor/libplacebo/LICENSE" "$RES/licenses/libplacebo.txt"
  fi
  if [ "$SYSTEM" = darwin ]; then
    SPARKLE="${WN_CROSS_SPARKLE:?cross-build.sh must provide Sparkle distribution}"
    read -r MAC_BUILD_VERSION MAC_DISPLAY_VERSION < <(bun "$HERE/scripts/sparkle-package.js" versions "$VERSION")
    SPARKLE_PUBLIC_KEY="$(tr -d '\r\n' <"$HERE/packaging/sparkle-public-key.txt")"
    if [[ ! "$SPARKLE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
      echo 'Invalid committed Sparkle Ed25519 public key' >&2
      exit 2
    fi
    # No unsigned release feed: fail before packaging an advertised update.
    if { [ -n "${WN_RELEASE_VERSION:-}" ] || [ "${GITHUB_REF_TYPE:-}" = tag ]; } && [ -z "${WN_SPARKLE_PRIVATE_KEY:-}" ]; then
      echo 'macOS release packaging requires WN_SPARKLE_PRIVATE_KEY' >&2
      exit 2
    fi
    mkdir -p "$STAGE/Contents/Frameworks"
    cat >"$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>whitenoise</string>
<key>CFBundleIdentifier</key><string>dev.ipf.whitenoise</string>
<key>CFBundleName</key><string>White Noise</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$MAC_DISPLAY_VERSION</string>
<key>CFBundleVersion</key><string>$MAC_BUILD_VERSION</string>
<key>SUFeedURL</key><string>https://github.com/marmot-protocol/whitenoise-linux/releases/latest/download/appcast-${TARGET#darwin-}.xml</string>
<key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
<key>SUSignedFeedFailureExpirationInterval</key><integer>0</integer>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSMicrophoneUsageDescription</key><string>Record voice messages and transcribe speech.</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Marmot</string><key>CFBundleURLSchemes</key><array><string>marmot</string></array></dict></array>
</dict></plist>
PLIST
  fi
  # ONNX can load provider libraries dynamically, outside the loader's import
  # table. Stage the complete pinned runtime before walking its dependencies.
  case "$SYSTEM" in
  linux)
    RUNTIME="$HELPERS/tts-lib"
    SUFFIX='*.so*'
    ;;
  windows)
    RUNTIME="$STAGE"
    SUFFIX='*.dll'
    ;;
  darwin)
    RUNTIME="$STAGE/Contents/Frameworks"
    SUFFIX='*.dylib'
    ;;
  esac
  mkdir -p "$RUNTIME"
  while IFS= read -r -d '' library; do
    if ! package_allowed "$library"; then continue; fi
    cp -L "$library" "$RUNTIME/$(basename "$library")"
  done < <(find "$TTS/lib" \( -name .git -o -name .hg -o -name .svn -o -name .env -o -name '*.env' \) -prune -o \
    -name "$SUFFIX" -print0)
  ROOTS=("$PREFIX" "$TTS")
  if [ "$SYSTEM" = windows ]; then
    ROOTS+=("${WN_CROSS_WINDOWS_RUNTIME:?LLVM-MinGW runtime root required}/x86_64-w64-mingw32" "$WN_CROSS_VELOPACK/lib")
  fi
  if [ "$SYSTEM" = linux ]; then ROOTS+=("$SYSROOT/lib"); fi
  bun "$HERE/scripts/cross-bundle.js" "$SYSTEM" "$STAGE" "${ROOTS[@]}"
  if [ "$SYSTEM" = windows ]; then
    # The resource helper cannot load DLLs from its parent's directory. Keep the
    # executable only beside the app; helper_path resolves this first.
    rm "$RES/wn-font.exe" "$RES/wn-image.exe" "$RES/wn-archive.exe" "$RES/wn-pdf.exe" \
      "$RES/wn-mesh.exe" "$RES/wn-fbx.exe" "$RES/wn-math.exe" "$RES/wn-nes.exe"
  fi
  if [ "$SYSTEM" = darwin ]; then
    # Do not let cross-bundle relocate, flatten, or invalidate Sparkle's nested
    # helpers. ditto retains the versioned framework symlinks and permissions.
    ditto "$SPARKLE/Sparkle.framework" "$STAGE/Contents/Frameworks/Sparkle.framework"
    cp "$SPARKLE/LICENSE" "$RES/licenses/sparkle.txt"
    # Upstream's Developer-ID helpers cannot authenticate an ad-hoc host over
    # Sparkle IPC. Re-sign the intact nested code inside-out for this host,
    # preserving helper entitlements. This is NOT publisher authentication;
    # only the mandatory EdDSA archive/feed signatures establish update trust.
    SPARKLE_FRAMEWORK="$STAGE/Contents/Frameworks/Sparkle.framework"
    for service in "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/"*.xpc; do
      codesign --force --sign - --timestamp=none --preserve-metadata=entitlements "$service"
    done
    codesign --force --sign - --timestamp=none --preserve-metadata=entitlements "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
    codesign --force --sign - --timestamp=none --preserve-metadata=entitlements "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
    codesign --force --sign - --timestamp=none --preserve-metadata=entitlements "$SPARKLE_FRAMEWORK"
    # Install-name changes above invalidate signatures, and Apple silicon runs
    # no unsigned code. Sign every Mach-O file inside-out (helpers also live in
    # Resources, which --deep skips), then the bundle. Ad-hoc: no Developer ID
    # or notarization, so Gatekeeper asks once on first launch.
    # find's order is arbitrary, so sign in two passes: Frameworks and
    # Resources first, then Contents/MacOS. Signing the bundle's main
    # executable signs the bundle, which codesign refuses while any nested
    # dylib is still unsigned ("In subcomponent: …/Frameworks/libwebp…").
    sign_macho() {
      local file
      while IFS= read -r -d '' file; do
        # `case`, not `file | grep -q`: grep exiting early can fail the pipe
        # under pipefail and silently skip a file.
        case "$(file --brief "$file")" in
        Mach-O*) codesign --force --sign - --timestamp=none "$file" ;;
        esac
      done
    }
    sign_macho < <(find "$STAGE/Contents" -type f ! -path "$STAGE/Contents/MacOS/*" ! -path "$SPARKLE_FRAMEWORK/*" -print0)
    sign_macho < <(find "$STAGE/Contents/MacOS" -type f -print0)
    codesign --force --sign - --timestamp=none "$STAGE"
    codesign --verify --strict --deep "$STAGE"
  fi
  if ! stage_clean; then
    echo 'Package stage contains excluded paths or symlink targets' >&2
    exit 1
  fi
  if [ "$SYSTEM" != darwin ]; then
    build_cache_store "$STAGE_KEY" "$STAGE_STAMP" "$STAGE"
  fi
fi

# Setup.exe, the self-updating portable zip, and the update feed. With
# WN_VELOPACK_REPO set (the release job), the previous release is fetched
# first so vpk can also emit a delta for existing installs. JSIGN_* (see
# README) turns on Authenticode signing of every binary vpk ships.
velopack_pack() {
  local vpk="$WN_CROSS_VELOPACK/vpk/vpk" release="$OUT/velopack-release"
  rm -rf "$release" "$HERE/dist/$NAME.zip"
  mkdir -p "$release"
  # vpk/signing may modify its input. Never lend it the cached pure stage.
  local packdir="$OUT/velopack-stage"
  rm -rf "$packdir"
  cp -a "$STAGE" "$packdir"
  if [ -n "${WN_VELOPACK_REPO:-}" ]; then
    "$vpk" "[win]" download github --repoUrl "$WN_VELOPACK_REPO" --token "${GITHUB_TOKEN:-}" --outputDir "$release"
  fi
  local sign=()
  if [ -n "${JSIGN_STORETYPE:-}" ]; then
    # The password stays in the environment; jsign reads it via env:.
    sign=(--signTemplate "java -jar /opt/jsign/jsign.jar --storetype $JSIGN_STORETYPE --keystore ${JSIGN_KEYSTORE:?} --alias ${JSIGN_ALIAS:?} --storepass env:JSIGN_STOREPASS {{file...}}")
  fi
  "$vpk" "[win]" pack --packId WhiteNoise --packVersion "$VPK_VERSION" --channel win --runtime win-x64 \
    --packDir "$packdir" --mainExe whitenoise.exe --packTitle "White Noise" --packAuthors "Marmot Protocol" \
    --icon "$HERE/assets/whitenoise.ico" --outputDir "$release" "${sign[@]}"
  # Publish only this version's files: a downloaded previous package is
  # already attached to its own release.
  local file
  for file in "$release"/*; do
    case "$(basename "$file")" in
    *.nupkg) [[ "$file" == *"-$VPK_VERSION-"* ]] || continue ;;
    esac
    cp "$file" "$HERE/dist/"
  done
  rm -rf "$packdir"
}
pack_outputs() {
  PACK_OUTPUTS=("$OUT/velopack-release" "$PACK_MANIFEST")
  if [ -f "$PACK_MANIFEST" ]; then
    local file
    while IFS= read -r -d '' file; do
      PACK_OUTPUTS+=("$HERE/dist/$file")
    done <"$PACK_MANIFEST"
  fi
}
mkdir -p "$HERE/dist"
# Velopack orders versions by SemVer 2, which ignores "+REV" build metadata,
# so two same-day releases would compare equal. Release tags already spell
# the revision as a pre-release ("v2026.9.15-build.1"), which orders right.
VPK_VERSION="${VERSION#v}"
VPK_VERSION="${VPK_VERSION/+/-build.}"
if [ "$SYSTEM" = windows ] && [[ "$VPK_VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+-build\.[0-9]+$ ]]; then
  PACK_STAMP="$OUT/package/$NAME.velopack.stamp"
  PACK_MANIFEST="$OUT/package/$NAME.velopack.outputs"
  if [ -n "${WN_VELOPACK_REPO:-}" ] || [ -n "${JSIGN_STORETYPE:-}" ] ||
    [ -n "${WN_RELEASE_VERSION:-}" ] || [ "${GITHUB_REF_TYPE:-}" = tag ]; then
    echo 'Velopack cache disabled: rerun release download, signing and update-feed generation.'
    rm -f "$PACK_STAMP"
    velopack_pack
  else
    PACK_KEY="$(build_cache_key "velopack-v1 stage=$STAGE_KEY version=$VPK_VERSION $(dotnet --list-runtimes)" \
      "$WN_CROSS_VELOPACK/vpk" "$(command -v dotnet)" "$HERE/assets/whitenoise.ico")"
    pack_outputs
    if build_cache_fresh "$PACK_KEY" "$PACK_STAMP" "${PACK_OUTPUTS[@]}"; then
      printf 'Cached Velopack distribution %s\n' "$NAME"
    else
      rm -f "$PACK_STAMP" "$PACK_MANIFEST"
      velopack_pack
      for file in "$OUT/velopack-release/"*; do
        printf '%s\0' "$(basename "$file")" >>"$PACK_MANIFEST"
      done
      pack_outputs
      build_cache_store "$PACK_KEY" "$PACK_STAMP" "${PACK_OUTPUTS[@]}"
    fi
  fi
elif [ "$SYSTEM" = windows ]; then
  # Staging builds (non-release versions) never join the update feed.
  ARCHIVE="$HERE/dist/$NAME.zip"
  ARCHIVE_STAMP="$OUT/package/$NAME.archive.stamp"
  ARCHIVE_KEY="$(build_cache_key "zip-v1 stage=$STAGE_KEY ZIPOPT=${ZIPOPT:-} TZ=${TZ:-}" "$(command -v zip)")"
  if build_cache_fresh "$ARCHIVE_KEY" "$ARCHIVE_STAMP" "$ARCHIVE"; then
    printf 'Cached archive %s\n' "$NAME"
  else
    rm -f "$ARCHIVE_STAMP" "$ARCHIVE"
    (cd "$OUT/package" && zip -qr "$ARCHIVE" "$NAME")
    build_cache_store "$ARCHIVE_KEY" "$ARCHIVE_STAMP" "$ARCHIVE"
  fi
else
  ARCHIVE="$HERE/dist/$NAME.tar.gz"
  ARCHIVE_STAMP="$OUT/package/$NAME.archive.stamp"
  ARCHIVE_KEY=
  if [ "$SYSTEM" != darwin ]; then
    ARCHIVE_KEY="$(build_cache_key "tar-v1 stage=$STAGE_KEY TAR_OPTIONS=${TAR_OPTIONS:-} GZIP=${GZIP:-} TZ=${TZ:-}" \
      "$(command -v tar)" "$(command -v gzip)")"
  fi
  if [ "$SYSTEM" != darwin ] && build_cache_fresh "$ARCHIVE_KEY" "$ARCHIVE_STAMP" "$ARCHIVE"; then
    printf 'Cached archive %s\n' "$NAME"
  else
    rm -f "$ARCHIVE_STAMP"
    tar -C "$OUT/package" -czf "$ARCHIVE" "$NAME"
    if [ "$SYSTEM" != darwin ]; then build_cache_store "$ARCHIVE_KEY" "$ARCHIVE_STAMP" "$ARCHIVE"; fi
  fi
  if [ "$SYSTEM" = darwin ] && [ -n "${WN_SPARKLE_PRIVATE_KEY:-}" ]; then
    bun "$HERE/scripts/sparkle-package.js" publish "$HERE/dist/$NAME.tar.gz" "$VERSION" \
      "${TARGET#darwin-}" "$SPARKLE" "$HERE/packaging/sparkle-public-key.txt" \
      "$HERE/dist/appcast-${TARGET#darwin-}.xml"
  fi
fi
printf 'Packaged %s\n' "$NAME"
