#!/usr/bin/env bash
# Runs on the build host even for sources-only and cross-target staging.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$HERE/build"
if command -v sha256sum >/dev/null; then HASH=(sha256sum)
elif command -v gsha256sum >/dev/null; then HASH=(gsha256sum)
else HASH=(shasum -a 256)
fi
WORK="$(mktemp -d "$HERE/build/emoji-pack.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
if command -v odin >/dev/null; then
  STB="$(env -u ODIN_ROOT odin root)"
  STB="${STB%/}/vendor/stb/src"
else
  # OpenBSD CI stages sources on Linux before installing Odin in its VM.
  # Reuse that build's pinned Odin header; this is not a new library dependency.
  STB="$HERE/build/emoji-stb-a2fb372b76e81ef31fbbc8a2cf2b4fdf5ac6c924"
  if [ ! -f "$STB/stb_image.h" ]; then
    mkdir -p "$STB"
    curl -sSfL https://raw.githubusercontent.com/odin-lang/Odin/a2fb372b76e81ef31fbbc8a2cf2b4fdf5ac6c924/vendor/stb/src/stb_image.h -o "$WORK/stb_image.h"
    mv "$WORK/stb_image.h" "$STB/stb_image.h"
  fi
fi
# One pack per staged set: vendor/emoji/<set>/ -> vendor/emoji/<set>.bin.
# Rows follow the base catalog, then the set's own <set>-extras.tsv when
# it has one, the same order app/emoji.odin loads them in.
for SET in noto twemoji openmoji; do
  TILES="$HERE/vendor/emoji/$SET"
  PACK="$HERE/vendor/emoji/$SET.bin"
  STAMP="$HERE/vendor/.emoji-$SET-inputs"
  CATALOG="$WORK/$SET.tsv"
  cat "$HERE/vendor/emoji-catalog.tsv" > "$CATALOG"
  if [ -f "$HERE/vendor/emoji/$SET-extras.tsv" ]; then
    cat "$HERE/vendor/emoji/$SET-extras.tsv" >> "$CATALOG"
  fi
  # Content hashes include names, additions and deletions, not just newer mtimes.
  # Hash files in batches to stay within ARG_MAX on every supported host.
  # The merged catalog is hashed from stdin: its temporary path changes per run.
  {
    "${HASH[@]}" "$HERE/scripts/emoji-pack.c" "$HERE/scripts/build-emoji-pack.sh" "$STB/stb_image.h"
    "${HASH[@]}" < "$CATALOG"
  } > "$WORK/manifest"
  find "$TILES" -type f -name '*.png' -exec "${HASH[@]}" {} + | LC_ALL=C sort >> "$WORK/manifest"
  INPUTS="$("${HASH[@]}" < "$WORK/manifest")"
  if [ -f "$PACK" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$INPUTS" ]; then
    continue
  fi
  if [ ! -x "$WORK/emoji-pack" ]; then
    # CC/CFLAGS may describe a foreign target. Only HOST_CC selects this executable.
    "${HOST_CC:-cc}" -std=c99 -O2 -Wall -Wextra -I"$STB" "$HERE/scripts/emoji-pack.c" -lm -o "$WORK/emoji-pack"
  fi
  "$WORK/emoji-pack" "$CATALOG" "$TILES" "$PACK"
  printf '%s\n' "$INPUTS" > "$WORK/inputs"
  mv "$WORK/inputs" "$STAMP"
done
