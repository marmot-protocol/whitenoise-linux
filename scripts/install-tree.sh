#!/usr/bin/env bash
# Install the built app and everything it reads at runtime under a
# prefix, in the layout res_dir and helper_path (app/paths.odin) expect:
#
#   <prefix>/bin/whitenoise
#   <prefix>/lib/whitenoise-linux/{wn-*,tts-lib}
#   <prefix>/share/whitenoise-linux/{emoji,emoji-catalog.tsv,fonts}
#   <prefix>/share/{applications,icons,metainfo}/<id>.*
#
# Helpers are programs, so they live under lib/, not share/: distribution
# policy (and Arch's namcap) reserves share/ for architecture-independent
# data.
#
# Usage: install-tree.sh <prefix> <id>
#   The AppImage passes AppDir/usr and the plain name; the Flatpak passes
#   /app and its reverse-DNS app id. Run after scripts/build.sh.
set -euo pipefail

PREFIX="$1"
ID="$2"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

RES="$PREFIX/share/whitenoise-linux"
LIB="$PREFIX/lib/whitenoise-linux"
mkdir -p "$PREFIX/bin" "$LIB" "$RES/fonts" "$PREFIX/share/applications" \
  "$PREFIX/share/icons/hicolor/256x256/apps" "$PREFIX/share/metainfo"

cp "$HERE/build/app" "$PREFIX/bin/whitenoise"
# Speech helpers and their runtime exist only where build.sh builds them
# (Linux; see there). Elsewhere reading aloud/dictation report they
# could not start.
SPEECH=
if [ "$(uname -s)" = Linux ]; then SPEECH=1; fi
if [ -n "$SPEECH" ]; then cp "$HERE/build/wn-tts" "$HERE/build/wn-stt" "$LIB/"; fi
if [ "$(uname -s)" = Linux ]; then cp "$HERE/build/wn-location" "$LIB/"; fi
mkdir -p "$RES/licenses"
cp "$HERE/build/wn-font" "$HERE/build/wn-image" "$HERE/build/wn-archive" "$HERE/build/wn-pdf" \
  "$HERE/build/wn-mesh" "$HERE/build/wn-fbx" "$HERE/build/wn-math" "$HERE/build/wn-nes" "$LIB/"
if [ "${WN_PACKAGE_APPIMAGE:-}" = 1 ]; then
  cp "$HERE/build/wn-appimage-update" "$LIB/"
  cp -a "$HERE/build/appimage-update-lib" "$LIB/"
fi
cp "$HERE/app/assets/agents/"*-LICENSE.txt "$RES/licenses/"
cp "$HERE/vendor/crop-circles/LICENSE" "$RES/licenses/crop-circles.txt"
cp "$HERE/vendor/common-passwords.LICENSE" "$RES/licenses/seclists.txt"
cp "$HERE/vendor/crop-circles/README.txt" "$RES/licenses/crop-circles-notices.txt"
if [ -n "$SPEECH" ]; then
  cp "$HERE/vendor/sherpa-onnx/LICENSE" "$RES/licenses/sherpa-onnx.txt"
  cp "$HERE/vendor/sherpa-onnx/LICENSE-onnxruntime" "$RES/licenses/onnxruntime.txt"
  cp "$HERE/vendor/sherpa-onnx/ThirdPartyNotices-onnxruntime.txt" "$RES/licenses/onnxruntime-third-party.txt"
fi
# Bragi and the TeX Gyre DejaVu Math font it typesets with are compiled
# and #loaded into wn-math; ship their licenses (the font: GUST Font
# License, DejaVu changes public domain; texts staged by build.sh).
cp "$HERE/vendor/bragi/LICENSE" "$RES/licenses/bragi.txt"
if [ "$(uname -s)" = OpenBSD ]; then cp "$HERE/vendor/sdl/LICENSE.txt" "$RES/licenses/sdl.txt"; fi
cp "$HERE/vendor/bragi/res/tex-gyre/README-TeX-Gyre-DejaVu-Math.txt" "$RES/licenses/tex-gyre-dejavu-math.txt"
cp "$HERE/vendor/fonts/GUST-FONT-LICENSE.txt" "$RES/licenses/gust-font-license.txt"
cp "$HERE/vendor/fonts/DejaVu-LICENSE.txt" "$RES/licenses/dejavu.txt"
if [ -n "$SPEECH" ]; then
  cp "$HERE/docs/tts.md" "$RES/licenses/speech-model.md"
  cp "$HERE/docs/stt.md" "$RES/licenses/dictation-model.md"
  mkdir -p "$LIB/tts-lib"
  cp "$HERE/build/tts-lib/"*.so "$LIB/tts-lib/"
fi
# The webxdc host process, only when webkit2gtk was present at build time.
# Never ship it on OpenBSD, including leftovers from earlier installs.
if [ "$(uname -s)" = OpenBSD ]; then
  rm -f "$LIB/wn-webview"
elif [ -x "$HERE/build/wn-webview" ]; then
  cp "$HERE/build/wn-webview" "$LIB/"
fi
# Every selectable set: emoji/<set>/ tiles plus the emoji/<set>.bin pack.
cp -r "$HERE/vendor/emoji" "$RES/"
cp "$HERE/vendor/emoji-licenses/"*.txt "$RES/licenses/"
cp "$HERE/vendor/emoji-catalog.tsv" "$RES/"
# Fonts are staged and sha256-pinned by scripts/build.sh, so every package ships
# byte-identical faces.
cp "$HERE"/vendor/fonts/*.ttf "$RES/fonts/"
cp "$HERE/vendor/fonts/Noto-LICENSE.txt" "$RES/licenses/noto-fonts.txt"
cp "$HERE/assets/fonts/sidecar/"*.txt "$RES/licenses/"
cp "$HERE/assets/fonts/kalam/"*.txt "$RES/licenses/"

sed "s|@ID@|$ID|g" "$HERE/assets/whitenoise-linux.desktop" \
  > "$PREFIX/share/applications/$ID.desktop"
sed "s|@ID@|$ID|g" "$HERE/assets/whitenoise-linux.metainfo.xml" \
  > "$PREFIX/share/metainfo/$ID.metainfo.xml"
cp "$HERE/assets/whitenoise-linux.png" "$PREFIX/share/icons/hicolor/256x256/apps/$ID.png"
