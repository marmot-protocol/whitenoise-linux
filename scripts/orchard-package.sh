#!/usr/bin/env bash
# Prepare unsigned HTTP-hostable OCI components from a finished Flatpak build.
# Usage: scripts/orchard-package.sh <finished-build-dir> <out-dir> [release-tag]
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <finished-build-dir> <out-dir> [release-tag]" >&2
  exit 2
fi
SOURCE="$(realpath "$1")"
OUT="$2"
version="$(bash "$HERE/scripts/version.sh" "${@:3}")"
[[ -d "$SOURCE/files" && -f "$SOURCE/metadata" && -d "$SOURCE/export" ]] || {
  echo 'Expected a finished Flatpak build with files/, metadata and export/' >&2
  exit 1
}
[[ -x "$HERE/build/orchard-publish" ]] || {
  echo 'Build the publisher first with scripts/build-orchard.sh' >&2
  exit 1
}
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tree"
# Never include builder var/, SDK objects or caches. Preserve symlink targets
# and copy metadata verbatim: it remains the sandbox/runtime source of truth.
cp -a --reflink=auto "$SOURCE/files" "$SOURCE/metadata" "$SOURCE/export" "$WORK/tree/"
cp "$HERE/packaging/flatpak/orchard.publish.toml" "$WORK/orchard.publish.toml"
ORCHARD_PUBLISH_VERSION="$version" "$HERE/build/orchard-publish" \
  "$WORK/orchard.publish.toml" --prepare --arch linux-x86_64 --out "$WORK/prepared"

mkdir -p "$OUT"
BASE=dev.ipf.whitenoise-linux-x86_64
cp "$WORK/prepared/$BASE.asset.json" "$WORK/prepared/$BASE.manifest.json" \
  "$WORK/prepared/$BASE.oci.tgz" "$OUT/"
# Components are named by bare SHA256. Do not upload the internal OCI layout.
for component in "$WORK/prepared/"*; do
  if [[ "${component##*/}" =~ ^[a-f0-9]{64}$ ]]; then cp "$component" "$OUT/"; fi
done
