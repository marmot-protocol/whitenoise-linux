#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/scripts/appimage-runtime.sh"

appdir="${2:?AppDir required}"
usr="$appdir/usr"
helpers="$usr/lib/whitenoise-linux"
# Bundle each helper's dependencies in place before replacing it with a launcher.
LD_LIBRARY_PATH="/usr/local/sdl3/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "${1:?linuxdeploy required}" --appdir "$appdir" \
  --executable "$usr/bin/whitenoise" --deploy-deps-only "$helpers" \
  --desktop-file "$usr/share/applications/whitenoise.desktop" \
  --icon-file "$usr/share/icons/hicolor/256x256/apps/whitenoise.png"
copy_appimage_glibc "$usr/lib"
# linuxdeploy excludes these, but bundled code needs the build SDK's ABI.
cp -L "$(c++ -print-file-name=libstdc++.so.6)" \
  "$(cc -print-file-name=libgcc_s.so.1)" \
  "$(cc -print-file-name=libharfbuzz.so.0)" \
  "$(cc -print-file-name=libfreetype.so.6)" \
  "$(cc -print-file-name=libfontconfig.so.1)" \
  "$(cc -print-file-name=libpipewire-0.3.so.0)" "$usr/lib/"
for package in libstdc++6 libharfbuzz0b libfreetype6 libfontconfig1 libpipewire-0.3-0t64; do
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
