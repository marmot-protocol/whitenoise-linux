#!/usr/bin/env bash
# Stage the official universal Sparkle binary distribution and its signing tools.
# fetch.sh verifies the DEPS_PIN SHA256 before anything is extracted.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: build-sparkle-updater.sh output-directory}"
ARCHIVE="$(bash "$HERE/scripts/fetch.sh" sparkle)"
PIN="$(sed -n 's/^sparkle-file = //p' "$HERE/DEPS_PIN")"
if [ ! -f "$OUT/sparkle/.pin" ] || [ "$(cat "$OUT/sparkle/.pin")" != "$PIN" ]; then
  mkdir -p "$OUT"
  STAGE="$(mktemp -d "$OUT/sparkle.XXXXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  tar -xJf "$ARCHIVE" -C "$STAGE"
  test -f "$STAGE/Sparkle.framework/Headers/SPUUpdater.h"
  test -x "$STAGE/bin/sign_update"
  printf '%s\n' "$PIN" > "$STAGE/.pin"
  rm -rf "$OUT/sparkle"
  mv "$STAGE" "$OUT/sparkle"
  trap - EXIT
fi
printf '%s\n' "$OUT/sparkle"
