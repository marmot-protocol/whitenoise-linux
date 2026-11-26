#!/usr/bin/env bash
# Announce the current stable GitHub release to Zapstore and Orchard.
# Set ZAPSTORE_SIGNER to skip the bunker URL or nsec prompt.
# With a bunker, approve seven events: app, two packages, three OCI components,
# and one combined release.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=marmot-protocol/whitenoise-linux

if [ "$#" -ne 1 ]; then
  echo "Usage: scripts/publish.sh <tag>" >&2
  exit 2
fi
TAG="$1"
bash scripts/version.sh --tag "$TAG" >/dev/null

for tool in bun nak gh git jq; do
  if ! command -v "$tool" >/dev/null; then
    echo "scripts/publish.sh needs $tool on PATH." >&2
    exit 1
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
NOTES="$WORK/release-notes.md"
gh api "repos/$REPO/releases/latest" | jq -ej --arg tag "$TAG" '
  if .tag_name == $tag and .immutable == true and .draft == false and .prerelease == false
  then (.body // "")
  else error("\($tag) is not the current immutable stable GitHub release")
  end
' > "$NOTES"
git fetch -q "https://github.com/$REPO" "refs/tags/$TAG:refs/tags/$TAG"

PUBKEY="$(sed -n 's/^pubkey: //p' zapstore.yaml)"
if [ -z "${ZAPSTORE_SIGNER:-}" ]; then
  read -rsp "Release signer for $PUBKEY (bunker URL or nsec): " ZAPSTORE_SIGNER
  echo
fi
export ZAPSTORE_SIGNER
# A bunker reports its key only when it signs; scripts/zapstore.ts checks it then.
case "$ZAPSTORE_SIGNER" in
  nsec1*)
    if [ "$(printf '%s' "$ZAPSTORE_SIGNER" | nak key public)" != "$(nak decode "$PUBKEY")" ]; then
      echo "That nsec is not the key for $PUBKEY in zapstore.yaml." >&2
      exit 1
    fi
    ;;
esac

APPIMAGE="WhiteNoise-$TAG-x86_64.AppImage"
FLATPAK="WhiteNoise-$TAG-x86_64.flatpak"
ORCHARD=dev.ipf.whitenoise-linux-x86_64
METADATA="$ORCHARD.asset.json"
MANIFEST="$ORCHARD.manifest.json"
echo "Downloading packages and Orchard manifest for $TAG"
if ! gh release download "$TAG" -R "$REPO" -D "$WORK" \
  -p "$APPIMAGE" -p "$FLATPAK" -p "$METADATA" -p "$MANIFEST" -p SHA256SUMS.txt; then
  echo "Release $TAG must contain both packages, Orchard metadata/manifest and SHA256SUMS.txt." >&2
  exit 1
fi
for file in "$APPIMAGE" "$FLATPAK" "$METADATA" "$MANIFEST" SHA256SUMS.txt; do
  if [ ! -s "$WORK/$file" ]; then
    echo "Release $TAG is missing $file. Publication stopped." >&2
    exit 1
  fi
done
# Read only two exact bare-hash filenames, never arbitrary metadata paths or
# broad release patterns. Full metadata, descriptors and bytes are validated
# by zapstore.ts before the first signature. The bootstrap .oci.tgz is not an
# install component and is deliberately not announced as an asset.
HASHES="$(bun -e '
  const asset = await Bun.file(Bun.argv[1]).json();
  if (asset?.schema !== 2 || !Array.isArray(asset.components) || asset.components.length !== 2) {
    throw new Error("Orchard metadata must contain schema 2 config and layer components");
  }
  const names = asset.components.map(c => {
    if (!c || typeof c.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(c.sha256) || c.filename !== c.sha256) {
      throw new Error("Orchard component filename must be its bare SHA-256");
    }
    return c.filename;
  });
  if (new Set(names).size !== 2) {
    throw new Error("Orchard components must be distinct");
  }
  console.log(names.join("\n"));
' "$WORK/$METADATA")"
mapfile -t COMPONENTS <<< "$HASHES"
if ! gh release download "$TAG" -R "$REPO" -D "$WORK" -p "${COMPONENTS[0]}" -p "${COMPONENTS[1]}"; then
  echo "Release $TAG is missing an Orchard config or layer component." >&2
  exit 1
fi
# Every downloaded publication input must appear exactly once in the release
# checksums. Do not let an empty selection silently skip checksum validation.
for file in "$APPIMAGE" "$FLATPAK" "$METADATA" "$MANIFEST" "${COMPONENTS[@]}"; do
  if ! checksum="$(awk -v name="$file" '$2 == name { print; found++ } END { if (found != 1) exit 1 }' "$WORK/SHA256SUMS.txt")"; then
    echo "SHA256SUMS.txt must list $file exactly once." >&2
    exit 1
  fi
  printf '%s\n' "$checksum" | (cd "$WORK" && sha256sum -c --strict -)
done
bun scripts/zapstore.ts "$TAG" "$WORK/$APPIMAGE" "$WORK/$FLATPAK" "$WORK/$METADATA" "$NOTES"
echo "Announced $TAG on Zapstore and Orchard."
