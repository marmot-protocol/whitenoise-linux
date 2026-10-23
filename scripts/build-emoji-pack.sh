#!/usr/bin/env bash
# Build pixel packs in the maintainer's isolated emoji staging directory.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="${1:?staging directory required}"
if command -v sha256sum >/dev/null; then HASH=(sha256sum)
elif command -v gsha256sum >/dev/null; then HASH=(gsha256sum)
else HASH=(shasum -a 256)
fi
WORK="$(mktemp -d "$VENDOR/.emoji-pack.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STB="$(env -u ODIN_ROOT odin root)"
STB="${STB%/}/vendor/stb/src"
# Rows follow the base catalog, then the set's extras, matching app/emoji.odin.
for SET in noto twemoji openmoji; do
  TILES="$VENDOR/emoji/$SET"
  PACK="$VENDOR/emoji/$SET.bin"
  CATALOG="$WORK/$SET.tsv"
  cat "$VENDOR/emoji-catalog.tsv" > "$CATALOG"
  if [ -f "$VENDOR/emoji/$SET-extras.tsv" ]; then
    cat "$VENDOR/emoji/$SET-extras.tsv" >> "$CATALOG"
  fi
  if [ ! -x "$WORK/emoji-pack" ]; then
    "${HOST_CC:-cc}" -std=c99 -O2 -Wall -Wextra -I"$STB" "$HERE/scripts/emoji-pack.c" -lm -o "$WORK/emoji-pack"
  fi
  "$WORK/emoji-pack" "$CATALOG" "$TILES" "$PACK"
done
