#!/usr/bin/env bash
# Boot an unpacked cross-release in isolation, then require its screenshot.
# Usage: cross-smoke.sh <target> <package-root> [linux-sysroot]
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <linux-arm64|linux-amd64|windows-amd64|darwin-arm64|darwin-amd64> <package-root> [linux-sysroot]" >&2
  exit 2
fi
target="$1"
root="$(realpath "$2")"
run=()
case "$target" in
  linux-arm64|linux-amd64)
    exe="$root/usr/bin/whitenoise"
    cpu=aarch64; [ "$target" = linux-arm64 ] || cpu=x86_64
    # Another architecture runs under QEMU with the target's glibc.
    if [ "$(uname -m)" != "$cpu" ]; then
      if [ "$#" != 3 ]; then
        echo "$target smoke on this host requires a target sysroot." >&2
        exit 2
      fi
      sysroot="$(realpath "$3")"
      run=("qemu-$cpu")
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
    if [ "$(uname -s)" != Darwin ]; then
      echo "macOS runtime smoke runs on a Mac." >&2
      exit 2
    fi
    exe="$root/White Noise.app/Contents/MacOS/whitenoise"
    # An Apple silicon Mac runs the Intel bundle through Rosetta.
    if [ "$target" = darwin-amd64 ] && [ "$(uname -m)" = arm64 ]; then run=(arch -x86_64); fi
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
if [ "$target" = linux-arm64 ] || [ "$target" = linux-amd64 ]; then
  # Set the guest path, not LD_LIBRARY_PATH for the host's QEMU executable.
  libs="$root/usr/lib:$root/usr/share/whitenoise-linux/tts-lib"
  if [ "${#run[@]}" -gt 0 ]; then
    # Only glibc comes from the target distro. Every other dependency must
    # resolve from the shipped package, not the build sysroot.
    runtime="$work/sysroot"
    loader=ld-linux-aarch64.so.1; [ "$cpu" = aarch64 ] || loader=ld-linux-x86-64.so.2
    mkdir -p "$runtime/lib/$cpu-linux-gnu"
    cp -L "$sysroot/lib/$loader" "$runtime/lib/"
    for lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libresolv.so.2 libutil.so.1; do
      cp -L "$sysroot/lib/$cpu-linux-gnu/$lib" "$runtime/lib/$cpu-linux-gnu/"
    done
    # Odin walks absolute directories using openat from /. Keep temporary
    # data on the host /tmp rather than inside QEMU's loader prefix.
    ln -s /tmp "$runtime/tmp"
    run+=(-L "$runtime")
    run+=(-E "LD_LIBRARY_PATH=$libs")
    # QEMU user-mode execve hands the next executable to the host kernel;
    # neither -L nor -E follows a decoder's empty-environment exec. Give the
    # app a temporary package view whose helpers explicitly re-enter QEMU.
    # The original, read-only package still supplies every ELF and library.
    view="$work/package"
    mkdir -p "$view"
    cp -as "$root/." "$view/"
    # /proc/self/exe must name the view, not resolve a symlink back to root.
    rm "$view/usr/bin/whitenoise"
    cp "$exe" "$view/usr/bin/whitenoise"
    qemu="$(command -v "qemu-$cpu")"
    for helper in "$root/usr/bin/"* "$root/usr/share/whitenoise-linux/"wn-*; do
      [ -f "$helper" ] && [ -x "$helper" ] || continue
      [ "$helper" != "$exe" ] || continue
      file --brief "$helper" | grep -q '^ELF ' || continue
      wrapper="$view/${helper#"$root"/}"
      rm "$wrapper"
      # Bash's %q keeps arbitrary package paths literal even with no env.
      {
        printf '#!/bin/bash\nexec '
        printf '%q ' "$qemu" -L "$runtime" -E "LD_LIBRARY_PATH=$libs" "$helper"
        printf '"$@"\n'
      } > "$wrapper"
      chmod +x "$wrapper"
    done
    exe="$view/usr/bin/whitenoise"
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
