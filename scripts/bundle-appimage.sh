#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/scripts/appimage-runtime.sh"

appdir="${2:?AppDir required}"
usr="$appdir/usr"
helpers="$usr/lib/whitenoise-linux"
pipewire=$(realpath "$(cc -print-file-name=libpipewire-0.3.so.0)")
modules=()
for module in rt protocol-native client-node client-device adapter metadata session-manager; do
  modules+=(--library "${pipewire%/*}/pipewire-0.3/libpipewire-module-$module.so")
done
mkdir -p "$usr/lib/spa-0.2"
cp -aL "${pipewire%/*}"/spa-0.2/{support,audioconvert,videoconvert} "$usr/lib/spa-0.2/"
mkdir -p "$usr/share/pipewire"
cp /usr/share/pipewire/client.conf "$usr/share/pipewire/"
write_zenity_wrapper "$usr/libexec/host-tools"
# Bundle each helper's dependencies in place before replacing it with a launcher.
LD_LIBRARY_PATH="/usr/local/sdl3/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "${1:?linuxdeploy required}" --appdir "$appdir" \
  --executable "$usr/bin/whitenoise" --deploy-deps-only "$helpers" \
  "${modules[@]}" --deploy-deps-only "$usr/lib/spa-0.2" \
  --desktop-file "$usr/share/applications/whitenoise.desktop" \
  --icon-file "$usr/share/icons/hicolor/256x256/apps/whitenoise.png"
copy_appimage_glibc "$usr/lib"
# linuxdeploy excludes these, but bundled code needs the build SDK's ABI.
cp -L "$(c++ -print-file-name=libstdc++.so.6)" \
  "$(cc -print-file-name=libgcc_s.so.1)" \
  "$(cc -print-file-name=libharfbuzz.so.0)" \
  "$(cc -print-file-name=libfreetype.so.6)" \
  "$(cc -print-file-name=libfontconfig.so.1)" \
  "$(cc -print-file-name=libgpg-error.so.0)" "$usr/lib/"
cp "$pipewire" "$usr/lib/libpipewire-0.3.so.0"
for package in libstdc++6 libharfbuzz0b libfreetype6 libfontconfig1 libgpg-error0 libpipewire-0.3-0t64; do
  if [ -f "/usr/share/doc/$package/copyright" ]; then
    cp "/usr/share/doc/$package/copyright" "$usr/lib/LICENSE.$package"
  fi
done
mv "$usr/bin/whitenoise" "$usr/bin/whitenoise.elf"
write_appimage_launcher "$usr/bin/whitenoise" ../lib whitenoise.elf
ln -sfn usr/bin/whitenoise "$appdir/AppRun"
for helper in "$helpers"/wn-*; do
  mv "$helper" "$helper.elf"
  write_appimage_launcher "$helper" .. "${helper##*/}.elf"
done

# The updater's closure also has to work separately, after the image unmounts.
if [ "$#" -eq 3 ]; then
  cp -a "$3" "$helpers/appimage-update-lib"
fi
