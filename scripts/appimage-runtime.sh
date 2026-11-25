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

emit_appimage_host_env() {
  local op name marker suffix
  while read -r op name marker suffix; do
    case "$op" in
      drop)
        printf 'if [ -n "${%s-}" ] && [ "${%s-}" = "${%s}%s" ]; then unset %s; fi\n' \
          "$marker" "$name" "$marker" "$suffix" "$name"
        ;;
      trim)
        printf 'if [ -n "${%s-}" ]; then %s=${%s#"${%s}%s"}; fi\n' \
          "$marker" "$name" "$name" "$marker" "$suffix"
        ;;
      unset) printf 'unset %s\n' "$name" ;;
      *) printf 'Unknown AppImage environment rule: %s\n' "$op" >&2; return 1 ;;
    esac
  done < "${BASH_SOURCE[0]%/*}/../app/appimage-host-env.txt"
}

write_zenity_wrapper() {
  local dir="$1"
  mkdir -p "$dir"
  {
    printf '#!/bin/sh\n'
    emit_appimage_host_env
    printf 'exec zenity "$@"\n'
  } > "$dir/zenity"
  chmod 755 "$dir/zenity"
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
  case "${launcher##*/}" in
    whitenoise|wn-appimage-update) emit_appimage_host_env >> "$launcher" ;;
  esac
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
WN_APPIMAGE_AUDIO_ROOT=$APPDIR
case "$APPDIR" in
  *:*)
    exec 9< "$APPDIR" || exit 1
    WN_APPIMAGE_AUDIO_ROOT=/proc/$$/fd/9
    ;;
esac
export WN_APPIMAGE_AUDIO_ROOT
export PIPEWIRE_MODULE_DIR="${PIPEWIRE_MODULE_DIR:-$WN_APPIMAGE_AUDIO_ROOT/usr/lib}"
export SPA_PLUGIN_DIR="${SPA_PLUGIN_DIR:-$WN_APPIMAGE_AUDIO_ROOT/usr/lib/spa-0.2}"
if [ -z "${PIPEWIRE_CONFIG_NAME+x}${PIPEWIRE_CONFIG_DIR+x}${PIPEWIRE_CONFIG_PREFIX+x}" ]; then
  have_pipewire_conf() {
    [ -r "${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/$1" ] ||
      [ -r "$HOME/.config/pipewire/$1" ] || [ -r "/etc/pipewire/$1" ] ||
      [ -r "/usr/share/pipewire/$1" ]
  }
  if ! have_pipewire_conf client-rt.conf; then
    WN_APPIMAGE_AUDIO_CONF=client.conf
    if ! have_pipewire_conf client.conf; then
      WN_APPIMAGE_AUDIO_CONF=$APPDIR/usr/share/pipewire/client.conf
    fi
    PIPEWIRE_CONFIG_NAME=$WN_APPIMAGE_AUDIO_CONF
    export WN_APPIMAGE_AUDIO_CONF PIPEWIRE_CONFIG_NAME
  fi
fi
if command -v zenity >/dev/null 2>&1; then
  PATH=$WN_APPIMAGE_AUDIO_ROOT/usr/libexec/host-tools:$PATH
fi
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
