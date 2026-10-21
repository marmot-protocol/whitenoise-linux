#!/usr/bin/env bash
# Make the Noto emoji archive scripts/build.sh stages from: the 128px PNGs
# at noto-emoji-commit, without the 1.5 GB repository around them (GitHub's
# tarball of that commit is 1.2 GB). Packagers cannot fetch a sparse clone,
# so DEPS_PIN pins this archive by sha256 instead.
#
#   noto-emoji-<commit>/LICENSE
#   noto-emoji-<commit>/2D/png/128/*.png   every 2D tile
#   noto-emoji-<commit>/3D/png/128/*.png   only names 2D lacks (the flags)
#
# build.sh stages 3D first and lets 2D overwrite, so 3D tiles 2D also has
# never reach the app and are left out.
#
# The output is byte-reproducible (sorted names, zeroed times and owners,
# gzip -n), so anyone can rebuild it and compare the digest with DEPS_PIN.
# Bumping noto-emoji-commit: run this, upload the archive to the `deps`
# GitHub release, then update noto-emoji-file in DEPS_PIN.
#
# Usage: scripts/noto-emoji-subset.sh   (writes build/noto-emoji-128-<commit>.tar.gz)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$(sed -n 's/^noto-emoji-commit = //p' "$HERE/DEPS_PIN")"
SIDE=128
NAME="noto-emoji-$PIN"
OUT="$HERE/build/noto-emoji-$SIDE-$PIN.tar.gz"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git clone -q --filter=blob:none --depth 1 --no-checkout https://github.com/googlefonts/noto-emoji.git "$WORK/repo"
git -C "$WORK/repo" sparse-checkout set --no-cone "/2D/png/$SIDE/" "/3D/png/$SIDE/" /LICENSE
git -C "$WORK/repo" fetch -q --filter=blob:none --depth 1 origin "$PIN"
git -C "$WORK/repo" checkout -q --detach "$PIN"

TREE="$WORK/$NAME"
mkdir -p "$TREE/2D/png" "$TREE/3D/png/$SIDE"
cp "$WORK/repo/LICENSE" "$TREE/"
cp -r "$WORK/repo/2D/png/$SIDE" "$TREE/2D/png/"
for tile in "$WORK/repo/3D/png/$SIDE"/*.png; do
  if [ ! -f "$TREE/2D/png/$SIDE/${tile##*/}" ]; then
    cp "$tile" "$TREE/3D/png/$SIDE/"
  fi
done

mkdir -p "$HERE/build"
tar -C "$WORK" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
  --mode=u+rw,go+r,go-w --format=ustar -cf - "$NAME" | gzip -n -9 >"$OUT"
sha256sum "$OUT"
