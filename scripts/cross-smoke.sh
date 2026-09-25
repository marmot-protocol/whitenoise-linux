#!/usr/bin/env bash
# Boot an unpacked cross-release in isolation, then require its screenshot.
# Usage: cross-smoke.sh <target> <package-root> [linux-sysroot]
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <linux-arm64|windows-amd64> <package-root> [linux-sysroot]" >&2
  exit 2
fi
target="$1"
root="$(realpath "$2")"
run=()
case "$target" in
  linux-arm64)
    exe="$root/usr/bin/whitenoise"
    if [ "$(uname -m)" != aarch64 ]; then
      if [ "$#" != 3 ]; then
        echo "linux-arm64 smoke on this host requires a target sysroot." >&2
        exit 2
      fi
      sysroot="$(realpath "$3")"
      run=(qemu-aarch64)
    fi
    ;;
  windows-amd64)
    # A Velopack portable root keeps the app in current/ beside Update.exe;
    # a staging zip is flat.
    exe="$root/whitenoise.exe"
    if [ -f "$root/current/whitenoise.exe" ]; then exe="$root/current/whitenoise.exe"; fi
    # Wine's desktop process needs an X server even with SDL's dummy driver.
    run=(xvfb-run -a wine)
    ;;
  darwin-*)
    echo "macOS runtime smoke requires a macOS machine; Linux cannot execute this artifact." >&2
    exit 2
    ;;
  *) echo "Unknown cross-release target: $target" >&2; exit 2 ;;
esac
if [ ! -f "$exe" ]; then
  echo "Packaged executable not found: $exe" >&2
  exit 1
fi

evidence="$PWD/$target.png"
work="$(mktemp -d)"
cleanup() {
  # wineserver outlives the app and keeps writing the prefix for a moment.
  if [ "$target" = windows-amd64 ]; then wineserver -w 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/data" "$work/config" "$work/home"
export HOME="$work/home" XDG_CONFIG_HOME="$work/config"
export XDG_DATA_HOME="$work/data" WINEPREFIX="$work/wine"
export SDL_VIDEODRIVER=dummy WN_SHOT=1 WN_VAULT_PW=ci-smoke
cd "$work"
if [ "$target" = linux-arm64 ]; then
  # Set the guest path, not LD_LIBRARY_PATH for the host's QEMU executable.
  libs="$root/usr/lib:$root/usr/share/whitenoise-linux/tts-lib"
  if [ "${#run[@]}" -gt 0 ]; then
    # Only glibc comes from the target distro. Every other dependency must
    # resolve from the shipped package, not the build sysroot.
    runtime="$work/sysroot"
    mkdir -p "$runtime/lib/aarch64-linux-gnu"
    cp -L "$sysroot/lib/ld-linux-aarch64.so.1" "$runtime/lib/"
    for lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libresolv.so.2 libutil.so.1; do
      cp -L "$sysroot/lib/aarch64-linux-gnu/$lib" "$runtime/lib/aarch64-linux-gnu/"
    done
    # Odin walks absolute directories using openat from /. Keep temporary
    # data on the host /tmp rather than inside QEMU's loader prefix.
    ln -s /tmp "$runtime/tmp"
    run+=(-L "$runtime")
    run+=(-E "LD_LIBRARY_PATH=$libs")
  else
    export LD_LIBRARY_PATH="$libs"
  fi
fi
timeout 120 "${run[@]}" "$exe"
if [ ! -f wn-odin-shot.png ] || ! file --brief wn-odin-shot.png | grep -q '^PNG image data'; then
  echo "Packaged app did not produce a PNG screenshot." >&2
  exit 1
fi
cp wn-odin-shot.png "$evidence"
printf 'Packaged %s boot: ' "$target"
file --brief wn-odin-shot.png
