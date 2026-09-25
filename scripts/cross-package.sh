#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:?target required}"
OUT="$HERE/build/cross/$TARGET"
PREFIX="${WN_CROSS_PREFIX:?cross-build.sh must provide dependency prefix}"
TTS="${WN_CROSS_TTS:?cross-build.sh must provide speech runtime}"
SYSROOT="${WN_CROSS_SYSROOT:-}"
VERSION="${WN_RELEASE_VERSION:-$(bash "$HERE/scripts/version.sh")}"
case "$VERSION" in *[!a-zA-Z0-9._+-]*) echo 'Invalid archive version' >&2; exit 2;; esac
NAME="WhiteNoise-$VERSION-$TARGET"
STAGE="$OUT/package/$NAME"
# This is generated output owned by this script; never mix a previous package's
# dependency closure with the current build.
rm -rf "$STAGE"
EXE=
case "$TARGET" in
  linux-arm64) SYSTEM=linux; BIN="$STAGE/usr/bin"; RES="$STAGE/usr/share/whitenoise-linux" ;;
  windows-amd64) SYSTEM=windows; BIN="$STAGE"; RES="$STAGE/resources"; EXE=.exe ;;
  darwin-amd64|darwin-arm64)
    SYSTEM=darwin; STAGE="$STAGE/White Noise.app"
    BIN="$STAGE/Contents/MacOS"; RES="$STAGE/Contents/Resources/whitenoise-linux" ;;
  *) echo "Unsupported target: $TARGET" >&2; exit 2 ;;
esac
mkdir -p "$BIN" "$RES/fonts" "$RES/licenses"
cp "$OUT/whitenoise$EXE" "$OUT/wn-tts$EXE" "$OUT/wn-stt$EXE" "$BIN/"
# Font helper is resolved from the resource directory on every platform.
cp "$OUT/wn-font$EXE" "$RES/"
if [ "$SYSTEM" = windows ]; then
  # DLL lookup starts at the executable directory, including wn-font's.
  cp "$OUT/wn-font$EXE" "$BIN/"
  cp "${WN_CROSS_WINDOWS_RUNTIME:?}/LICENSE.TXT" "$RES/licenses/llvm-runtime.txt"
  cp -R "$WN_CROSS_WINDOWS_RUNTIME/x86_64-w64-mingw32/share/mingw32" "$RES/licenses/mingw-runtime"
  cp "${WN_CROSS_VELOPACK:?}/LICENSE" "$RES/licenses/velopack.txt"
fi
cp -R "$HERE/vendor/twemoji" "$RES/"
cp "$HERE/vendor/emoji-catalog.tsv" "$RES/"
cp "$HERE/vendor/fonts/"*.ttf "$RES/fonts/"
cp "$HERE/vendor/fonts/"*.txt "$RES/licenses/"
cat > "$RES/fonts.conf" <<'FONTCONFIG'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig><dir prefix="relative">fonts</dir><cachedir prefix="xdg">fontconfig</cachedir></fontconfig>
FONTCONFIG
cp "$HERE/vendor/crop-circles/LICENSE" "$RES/licenses/crop-circles.txt"
cp "$HERE/vendor/crop-circles/README.txt" "$RES/licenses/crop-circles-notices.txt"
cp "$HERE/vendor/microtex/LICENSE" "$RES/licenses/microtex.txt"
cp "$HERE/vendor/microtex/res/tex-gyre/README-TeX-Gyre-DejaVu-Math.txt" "$RES/licenses/tex-gyre-dejavu-math.txt"
cp "$TTS/LICENSE" "$RES/licenses/sherpa-onnx.txt"
cp "$TTS/LICENSE-onnxruntime" "$RES/licenses/onnxruntime.txt"
cp "$TTS/ThirdPartyNotices-onnxruntime.txt" "$RES/licenses/onnxruntime-third-party.txt"
cp "$HERE/docs/tts.md" "$RES/licenses/speech-model.md"
cp "$HERE/docs/stt.md" "$RES/licenses/dictation-model.md"
cp /etc/ssl/certs/ca-certificates.crt "$RES/cacert.pem"

if [ "$SYSTEM" = linux ]; then
  cp "$OUT/wn-webview" "$PREFIX/bin/curl" "$BIN/"
  # WebKit and GStreamer load these subprocesses/plugins dynamically: ELF
  # DT_NEEDED alone cannot discover them. Include their data as well.
  mkdir -p "$STAGE/usr/lib" "$STAGE/usr/share"
  for dir in webkit2gtk-4.1 gstreamer-1.0 gio; do
    if [ -d "$PREFIX/lib/aarch64-linux-gnu/$dir" ]; then
      cp -a "$PREFIX/lib/aarch64-linux-gnu/$dir" "$STAGE/usr/lib/"
    fi
  done
  for dir in glib-2.0 gstreamer-1.0 mime fontconfig fonts; do
    if [ -d "$PREFIX/share/$dir" ]; then cp -a "$PREFIX/share/$dir" "$STAGE/usr/share/"; fi
  done
  glib-compile-schemas "$STAGE/usr/share/glib-2.0/schemas"
  if [ -d "$PREFIX/libexec" ]; then cp -a "$PREFIX/libexec" "$STAGE/usr/"; fi
  # License texts only; the rest of usr/share/doc is changelogs and manuals.
  while IFS= read -r -d '' copyright; do
    package="$(basename "$(dirname "$copyright")")"
    mkdir -p "$RES/licenses/ubuntu-packages/$package"
    cp -L "$copyright" "$RES/licenses/ubuntu-packages/$package/copyright"
  done < <(find -L "$SYSROOT/usr/share/doc" -mindepth 2 -maxdepth 2 -name copyright -print0)
  cat > "$STAGE/whitenoise" <<'LAUNCH'
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
  CURL="$(find "$PREFIX" -type f -name "curl$EXE" -print -quit)"
  test -n "$CURL"
  cp "$CURL" "$BIN/"
  for license in "$PREFIX/share/"*/copyright; do
    cp "$license" "$RES/licenses/$(basename "$(dirname "$license")").txt"
  done
  cp "$HERE/vendor/mpv/LICENSE.GPL" "$RES/licenses/mpv.txt"
  cp "$HERE/vendor/libplacebo/LICENSE" "$RES/licenses/libplacebo.txt"
fi
if [ "$SYSTEM" = darwin ]; then
  mkdir -p "$STAGE/Contents/Frameworks"
  cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>whitenoise</string>
<key>CFBundleIdentifier</key><string>dev.ipf.whitenoise</string>
<key>CFBundleName</key><string>White Noise</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
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
  linux) RUNTIME="$STAGE/usr/lib"; SUFFIX='*.so*' ;;
  windows) RUNTIME="$STAGE"; SUFFIX='*.dll' ;;
  darwin) RUNTIME="$STAGE/Contents/Frameworks"; SUFFIX='*.dylib' ;;
esac
mkdir -p "$RUNTIME"
while IFS= read -r -d '' library; do
  cp -L "$library" "$RUNTIME/$(basename "$library")"
done < <(find "$TTS/lib" -name "$SUFFIX" -print0)
ROOTS=("$PREFIX" "$TTS")
if [ "$SYSTEM" = windows ]; then
  ROOTS+=("${WN_CROSS_WINDOWS_RUNTIME:?LLVM-MinGW runtime root required}/x86_64-w64-mingw32" "$WN_CROSS_VELOPACK/lib")
fi
if [ "$SYSTEM" = linux ]; then ROOTS+=("$SYSROOT/lib"); fi
bun "$HERE/scripts/cross-bundle.js" "$SYSTEM" "$STAGE" "${ROOTS[@]}"
if [ "$SYSTEM" = windows ]; then
  # The resource helper cannot load DLLs from its parent's directory. Keep the
  # executable only beside the app; helper_path resolves this first.
  rm "$RES/wn-font.exe"
fi
if [ "$SYSTEM" = darwin ]; then
  # Install-name changes invalidate signatures. rcodesign runs on Linux; this
  # is ad-hoc signing, not a Developer ID signature or Apple notarization.
  rcodesign sign "$STAGE"
fi

# Setup.exe, the self-updating portable zip, and the update feed. With
# WN_VELOPACK_REPO set (the release job), the previous release is fetched
# first so vpk can also emit a delta for existing installs. JSIGN_* (see
# README) turns on Authenticode signing of every binary vpk ships.
velopack_pack() {
  local vpk="$WN_CROSS_VELOPACK/vpk/vpk" release="$OUT/velopack-release"
  rm -rf "$release" "$HERE/dist/$NAME.zip"
  mkdir -p "$release"
  if [ -n "${WN_VELOPACK_REPO:-}" ]; then
    "$vpk" "[win]" download github --repoUrl "$WN_VELOPACK_REPO" --token "${GITHUB_TOKEN:-}" --outputDir "$release"
  fi
  local sign=()
  if [ -n "${JSIGN_STORETYPE:-}" ]; then
    # The password stays in the environment; jsign reads it via env:.
    sign=(--signTemplate "java -jar /opt/jsign/jsign.jar --storetype $JSIGN_STORETYPE --keystore ${JSIGN_KEYSTORE:?} --alias ${JSIGN_ALIAS:?} --storepass env:JSIGN_STOREPASS {{file...}}")
  fi
  "$vpk" "[win]" pack --packId WhiteNoise --packVersion "$VPK_VERSION" --channel win --runtime win-x64 \
    --packDir "$STAGE" --mainExe whitenoise.exe --packTitle "White Noise" --packAuthors "Marmot Protocol" \
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
}
mkdir -p "$HERE/dist"
# Velopack orders versions by SemVer 2, which ignores "+REV" build metadata,
# so two same-day releases would compare equal. Release tags already spell
# the revision as a pre-release ("v2026.9.15-build.1"), which orders right.
VPK_VERSION="${VERSION#v}"
VPK_VERSION="${VPK_VERSION/+/-build.}"
if [ "$SYSTEM" = windows ] && [[ "$VPK_VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+-build\.[0-9]+$ ]]; then
  velopack_pack
elif [ "$SYSTEM" = windows ]; then
  # Staging builds (non-release versions) never join the update feed.
  rm -f "$HERE/dist/$NAME.zip"
  (cd "$OUT/package" && zip -qr "$HERE/dist/$NAME.zip" "$NAME")
else
  tar -C "$OUT/package" -czf "$HERE/dist/$NAME.tar.gz" "$NAME"
fi
printf 'Packaged %s\n' "$NAME"
