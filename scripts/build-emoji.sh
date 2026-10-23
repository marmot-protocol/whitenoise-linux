#!/usr/bin/env bash
# Stage the same emoji bytes on every build host, without SVG rendering.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="${1:?staging directory required}"
PIN="$(sed -n 's/^emoji-bundle-file = //p' "$HERE/DEPS_PIN")"
SOURCES="$(sed -n '/^noto-emoji-/p; /^twemoji-/p; /^openmoji-/p; /^emojis-/p' "$HERE/DEPS_PIN")"
INPUTS="$(printf '%s\n%s\n' "$PIN" "$SOURCES")"
STAMP="$VENDOR/.emoji-bundle"
if [ "$(cat "$STAMP" 2>/dev/null || true)" = "$INPUTS" ] && \
   [ -d "$VENDOR/emoji/noto" ] && [ -d "$VENDOR/emoji/twemoji" ] && [ -d "$VENDOR/emoji/openmoji" ] && \
   [ -f "$VENDOR/emoji/noto.bin" ] && [ -f "$VENDOR/emoji/twemoji.bin" ] && [ -f "$VENDOR/emoji/openmoji.bin" ] && \
   [ -f "$VENDOR/emoji/openmoji-extras.tsv" ] && [ -f "$VENDOR/emoji-catalog.tsv" ] && [ -d "$VENDOR/emoji-licenses" ]; then
  exit 0
fi
ARCHIVE="$(bash "$HERE/scripts/fetch.sh" emoji-bundle)"
mkdir -p "$VENDOR"
WORK="$(mktemp -d "$VENDOR/.emoji-bundle.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TAR_OWNER=()
if [ "$(uname -s)" = Linux ]; then TAR_OWNER=(--no-same-owner); fi
tar "${TAR_OWNER[@]}" -xf "$ARCHIVE" -C "$WORK"
mkdir "$WORK/emoji"
PIDS=()
for SET in common noto twemoji openmoji; do
  (zstd -dc "$WORK/$SET.tar.zst" | tar "${TAR_OWNER[@]}" -mxf - -C "$WORK") &
  PIDS+=("$!")
done
STATUS=0
for PID in "${PIDS[@]}"; do
  wait "$PID" || STATUS=1
done
test "$STATUS" = 0
printf '%s\n' "$SOURCES" > "$WORK/expected-sources"
cmp "$WORK/emoji-sources" "$WORK/expected-sources"
for SET in noto twemoji openmoji; do
  test -d "$WORK/emoji/$SET"
  test -f "$WORK/emoji/$SET.bin"
done
for LICENSE in noto-emoji twemoji openmoji; do
  test -f "$WORK/emoji-licenses/$LICENSE.txt"
done
test -f "$WORK/emoji/openmoji-extras.tsv"
test -f "$WORK/emoji-catalog.tsv"
rm -rf "$VENDOR/emoji" "$VENDOR/emoji-licenses"
mv "$WORK/emoji" "$WORK/emoji-licenses" "$WORK/emoji-catalog.tsv" "$VENDOR/"
rm -f "$VENDOR/.emoji-side" "$VENDOR/.emoji-noto-pin" "$VENDOR/.emoji-catalog-version" \
  "$VENDOR/.emoji-noto-inputs" "$VENDOR/.emoji-twemoji-inputs" "$VENDOR/.emoji-openmoji-inputs"
printf '%s\n' "$INPUTS" > "$STAMP"
