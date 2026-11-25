#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../scripts/appimage-runtime.sh"

root="${1:?temporary test directory required}"
appdir="$root/old:mount"
bin="$appdir/usr/bin"
lib="$appdir/usr/lib"
host="$root/host tools"
mkdir -p "$bin" "$lib" "$host" "$root/config/pipewire"
touch "$root/config/pipewire/client-rt.conf"
ln -s /bin/sh "$bin/whitenoise.elf"
ln -s "$(cc -print-file-name="$APPIMAGE_LOADER")" "$lib/$APPIMAGE_LOADER"
ln -s /usr/bin/env "$host/zenity"
write_zenity_wrapper "$appdir/usr/libexec/host-tools"
write_appimage_launcher "$bin/whitenoise" ../lib whitenoise.elf

old=/proc/1/fd/9
export WN_APPIMAGE_AUDIO_ROOT="$old" WN_APPIMAGE_AUDIO_CONF=client.conf
export PIPEWIRE_MODULE_DIR="$old/usr/lib" SPA_PLUGIN_DIR="$old/usr/lib/spa-0.2" PIPEWIRE_CONFIG_NAME=client.conf
export PATH="$old/usr/libexec/host-tools:$host:/usr/bin:/bin" XDG_CONFIG_HOME="$root/config"
"$bin/whitenoise" -eu -c '
  root=/proc/$$/fd/9
  [ "$APPDIR" = "$2" ]
  [ "$WN_APPIMAGE_AUDIO_ROOT" = "$root" ]
  [ "$PIPEWIRE_MODULE_DIR" = "$root/usr/lib" ]
  [ "$SPA_PLUGIN_DIR" = "$root/usr/lib/spa-0.2" ]
  [ -z "${PIPEWIRE_CONFIG_NAME+x}${WN_APPIMAGE_AUDIO_CONF+x}" ]
  [ "$(command -v zenity)" = "$root/usr/libexec/host-tools/zenity" ]

  check_host() {
    if printf "%s\n" "$1" | grep -Eq "^(WN_APPIMAGE_AUDIO_(ROOT|CONF)|PIPEWIRE_MODULE_DIR|SPA_PLUGIN_DIR|PIPEWIRE_CONFIG_NAME)="; then
      return 1
    fi
    printf "%s\n" "$1" | grep -Fxq "PATH=$2"
  }
  export WN_APPIMAGE_AUDIO_CONF=client.conf PIPEWIRE_CONFIG_NAME=client.conf
  check_host "$(zenity)" "$1"

  result=$(PIPEWIRE_MODULE_DIR=/host/modules SPA_PLUGIN_DIR=/host/plugins PIPEWIRE_CONFIG_NAME=/host/client.conf zenity)
  for setting in PIPEWIRE_MODULE_DIR=/host/modules SPA_PLUGIN_DIR=/host/plugins PIPEWIRE_CONFIG_NAME=/host/client.conf; do
    printf "%s\n" "$result" | grep -Fxq "$setting"
  done
' sh "$host:/usr/bin:/bin" "$appdir"
