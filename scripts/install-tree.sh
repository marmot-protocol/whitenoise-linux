#!/usr/bin/env bash
# Install the built app and everything it reads at runtime under a
# prefix, in the layout res_dir (app/paths.odin) expects:
#
#   <prefix>/bin/whitenoise
#   <prefix>/share/whitenoise-linux/{twemoji,emoji-catalog.tsv,fonts}
#   <prefix>/share/{applications,icons,metainfo}/<id>.*
#
# Usage: install-tree.sh <prefix> <id>
#   The AppImage passes AppDir/usr and the plain name; the Flatpak passes
#   /app and its reverse-DNS app id. Run after scripts/build.sh.
set -euo pipefail

PREFIX="$1"
ID="$2"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

RES="$PREFIX/share/whitenoise-linux"
mkdir -p "$PREFIX/bin" "$RES/fonts" "$PREFIX/share/applications" \
  "$PREFIX/share/icons/hicolor/256x256/apps" "$PREFIX/share/metainfo"

cp "$HERE/build/app" "$PREFIX/bin/whitenoise"
cp "$HERE/build/wn-tts" "$HERE/build/wn-stt" "$PREFIX/bin/"
mkdir -p "$RES/licenses"
cp "$HERE/build/wn-font" "$RES/"
cp "$HERE/vendor/crop-circles/LICENSE" "$RES/licenses/crop-circles.txt"
cp "$HERE/vendor/crop-circles/README.txt" "$RES/licenses/crop-circles-notices.txt"
cp "$HERE/vendor/sherpa-onnx/LICENSE" "$RES/licenses/sherpa-onnx.txt"
cp "$HERE/vendor/sherpa-onnx/LICENSE-onnxruntime" "$RES/licenses/onnxruntime.txt"
cp "$HERE/vendor/sherpa-onnx/ThirdPartyNotices-onnxruntime.txt" "$RES/licenses/onnxruntime-third-party.txt"
cp "$HERE/docs/tts.md" "$RES/licenses/speech-model.md"
cp "$HERE/docs/stt.md" "$RES/licenses/dictation-model.md"
mkdir -p "$RES/tts-lib"
cp "$HERE/build/tts-lib/"*.so "$RES/tts-lib/"
# The webxdc host process, only when webkit2gtk was present at build time.
# The app looks for it beside its own binary.
if [ -x "$HERE/build/wn-webview" ]; then
  cp "$HERE/build/wn-webview" "$PREFIX/bin/"
fi
cp -r "$HERE/vendor/twemoji" "$RES/"
cp "$HERE/vendor/emoji-catalog.tsv" "$RES/"
# Fonts are staged and sha256-pinned by scripts/build.sh, so every package ships
# byte-identical faces.
cp "$HERE"/vendor/fonts/*.ttf "$RES/fonts/"
cp "$HERE/vendor/fonts/Noto-LICENSE.txt" "$RES/licenses/noto-fonts.txt"

sed "s|@ID@|$ID|g" "$HERE/assets/whitenoise-linux.desktop" \
  > "$PREFIX/share/applications/$ID.desktop"
sed "s|@ID@|$ID|g" "$HERE/assets/whitenoise-linux.metainfo.xml" \
  > "$PREFIX/share/metainfo/$ID.metainfo.xml"
cp "$HERE/assets/whitenoise-linux.png" "$PREFIX/share/icons/hicolor/256x256/apps/$ID.png"
