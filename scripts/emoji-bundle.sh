#!/usr/bin/env bash
# Generate, then upload to the deps release and pin the printed SHA-256.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$HERE/build"
WORK="$(mktemp -d "$HERE/build/emoji-bundle.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
bash "$HERE/scripts/emoji-source.sh" "$WORK/vendor"
sed -n '/^noto-emoji-/p; /^twemoji-/p; /^openmoji-/p; /^emojis-/p' "$HERE/DEPS_PIN" > "$WORK/vendor/emoji-sources"
INPUTS="$({
  cat "$WORK/vendor/emoji-sources" "$HERE/scripts/emoji-source.sh" \
    "$HERE/scripts/build-emoji-pack.sh" "$HERE/scripts/emoji-pack.c" "$HERE/scripts/emoji-bundle.sh"
} | sha256sum)"
OUT="$HERE/build/emoji-128-${INPUTS%% *}.tar"
# Fixed metadata and one compression thread make repeated generations identical.
mkdir "$WORK/bundles"
pack() {
  local name="$1"
  shift
  tar -C "$WORK/vendor" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    --mode=u+rw,go+r,go-w --format=ustar -cf - "$@" | \
    zstd -q -19 -T1 -o "$WORK/bundles/$name.tar.zst"
}
pack common emoji-licenses emoji-catalog.tsv emoji-sources emoji/openmoji-extras.tsv
PIDS=()
for SET in noto twemoji openmoji; do
  pack "$SET" "emoji/$SET" "emoji/$SET.bin" &
  PIDS+=("$!")
done
STATUS=0
for PID in "${PIDS[@]}"; do
  wait "$PID" || STATUS=1
done
test "$STATUS" = 0
tar -C "$WORK/bundles" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
  --mode=u+rw,go+r,go-w --format=ustar -cf "$WORK/bundle.tar" common.tar.zst noto.tar.zst twemoji.tar.zst openmoji.tar.zst
mv "$WORK/bundle.tar" "$OUT"
sha256sum "$OUT"
