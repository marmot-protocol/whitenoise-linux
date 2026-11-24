# Sourced by the Linux x86-64 AppImage packagers.
APPIMAGE_LOADER=ld-linux-x86-64.so.2

copy_appimage_glibc() {
  local dest="$1" libc file
  libc=$(cc -print-file-name=libc.so.6)
  cp -L "$(cc -print-file-name="$APPIMAGE_LOADER")" "$dest/$APPIMAGE_LOADER"
  # These SONAMEs come from the same glibc as the loader, not linuxdeploy.
  for file in libc.so.6 libm.so.6 libmvec.so.1 libpthread.so.0 libdl.so.2 \
    librt.so.1 libresolv.so.2 libutil.so.1 libanl.so.1 libBrokenLocale.so.1 \
    libnss_compat.so.2 libnss_dns.so.2 libnss_files.so.2 libnss_hesiod.so.2; do
    cp -L "${libc%/*}/$file" "$dest/"
  done
  if [ -f /usr/share/doc/libc6/copyright ]; then
    cp /usr/share/doc/libc6/copyright "$dest/LICENSE.glibc"
    dpkg-query -W -f='${source:Package} ${source:Version}\n' libc6 > "$dest/SOURCE.glibc"
  elif command -v pacman >/dev/null; then
    cp /usr/share/licenses/spdx/LGPL-2.1-or-later.txt "$dest/LICENSE.glibc"
    pacman -Q glibc > "$dest/SOURCE.glibc"
  fi
}

write_appimage_launcher() {
  local launcher="$1" lib="$2" elf="$3" elf_dir="${3%/*}"
  shift 3
  [ "$elf_dir" != "$elf" ] || elf_dir=.
  cat > "$launcher" <<'EOF'
#!/bin/sh
# Host preload libraries may require a different glibc.
unset LD_PRELOAD LD_AUDIT
base=${0%/*}
[ "$base" != "$0" ] || base=.
EOF
  if [ "${launcher##*/}" = whitenoise ]; then
    cat >> "$launcher" <<'EOF'
self=$(readlink -f -- "$0") || exit 1
base=${self%/*}
appdir=${base%/usr/bin}
if [ "${APPDIR-}" != "$appdir" ] && [ ! "${APPDIR-}" -ef "$appdir" ]; then
  unset APPIMAGE
fi
APPDIR=$appdir
export APPDIR
EOF
  fi
  # The loader splits on ':' and ';' before expanding $ORIGIN.
  {
    printf 'exec "$base/%s/%s/%s" --library-path '\''$ORIGIN/%s'\'' "$base/%s"' \
      "$elf_dir" "$lib" "$APPIMAGE_LOADER" "$lib" "$elf"
    if [ "$#" -gt 0 ]; then printf ' %q' "$@"; fi
    printf ' "$@"\n'
  } >> "$launcher"
  chmod 755 "$launcher"
}
