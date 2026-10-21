#!/usr/bin/env bash
# Download one file pinned in DEPS_PIN as `<name>-file = <sha256> <url>` to
# vendor/downloads/<name> and print that path. A file already there with the
# pinned digest is reused without touching the network, which is how
# packagers build offline: they fetch every `-file` pin themselves and place
# it under vendor/downloads/ before running scripts/build.sh.
#
# Usage: scripts/fetch.sh <name>   e.g. `tar -xzf "$(scripts/fetch.sh twemoji)"`
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# OpenBSD's coreutils package installs GNU sha256sum as gsha256sum.
if ! command -v sha256sum >/dev/null && command -v gsha256sum >/dev/null; then
  sha256sum() { gsha256sum "$@"; }
fi

NAME="$1"
PIN="$(sed -n "s/^$NAME-file = //p" "$HERE/DEPS_PIN")"
if [ -z "$PIN" ]; then
  echo "DEPS_PIN has no $NAME-file line." >&2
  exit 1
fi
SHA="${PIN%% *}"
URL="${PIN#* }"
OUT="$HERE/vendor/downloads/$NAME"

if [ ! -f "$OUT" ] || ! printf '%s  %s\n' "$SHA" "$OUT" | sha256sum -c --status; then
  mkdir -p "$HERE/vendor/downloads"
  curl -sSfL --retry 3 -A whitenoise-build -o "$OUT.part" "$URL"
  printf '%s  %s\n' "$SHA" "$OUT.part" | sha256sum -c - >&2
  mv "$OUT.part" "$OUT"
fi
printf '%s\n' "$OUT"
