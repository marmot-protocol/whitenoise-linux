#!/usr/bin/env bash
# Publish a release everywhere, in order:
#
#   1. GitHub. scripts/release.sh bumps APP_VERSION, tags and pushes. The tag
#      starts .github/workflows/release.yml, which builds every package,
#      creates the GitHub release and then updates the AUR.
#   2. Zapstore and Orchard. Once the GitHub release exists, its AppImage,
#      Flatpak bundle and direct-download OCI components are downloaded,
#      checked against SHA256SUMS.txt, and announced together by
#      scripts/zapstore.ts, signed by you. No registry or second release.
#
#   scripts/publish.sh          cut a new release, then both steps
#   scripts/publish.sh <tag>    an existing tag: wait for its GitHub
#                               release if needed, then Zapstore and Orchard
#
# The signer is asked for first, so the build runs unattended: a bunker URL
# (Amber, nsec.app, `nak bunker`) or an nsec for zapstore.yaml's pubkey,
# read without echo. ZAPSTORE_SIGNER in the environment skips the prompt.
# With a bunker, approve seven events: app, two packages, three OCI components,
# and one combined release. Older releases without Orchard outputs fail closed.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=marmot-protocol/whitenoise-linux
POLL_SECONDS=30

if [ "$#" -gt 1 ]; then
  echo "Usage: scripts/publish.sh [tag]" >&2
  exit 2
fi
for tool in bun nak gh git; do
  if ! command -v "$tool" >/dev/null; then
    echo "scripts/publish.sh needs $tool on PATH." >&2
    exit 1
  fi
done

PUBKEY="$(sed -n 's/^pubkey: //p' zapstore.yaml)"
if [ -z "${ZAPSTORE_SIGNER:-}" ]; then
  read -rsp "Release signer for $PUBKEY (bunker URL or nsec): " ZAPSTORE_SIGNER
  echo
fi
export ZAPSTORE_SIGNER
# A wrong nsec is caught now rather than after the build. A bunker reports
# its key only when it signs; scripts/zapstore.ts checks it then.
case "$ZAPSTORE_SIGNER" in
  nsec1*)
    if [ "$(printf '%s' "$ZAPSTORE_SIGNER" | nak key public)" != "$(nak decode "$PUBKEY")" ]; then
      echo "That nsec is not the key for $PUBKEY in zapstore.yaml." >&2
      exit 1
    fi
    ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. GitHub. release.sh deliberately leaves this checkout's HEAD unchanged.
if [ "$#" -eq 0 ]; then
  scripts/release.sh --tag-output "$WORK/release-tag"
  if [ ! -s "$WORK/release-tag" ]; then
    echo 'No release was created; publication stopped.' >&2
    exit 1
  fi
  TAG="$(<"$WORK/release-tag")"
else
  TAG="$1"
fi
if [[ ! "$TAG" =~ ^v[0-9]{4}\.([1-9]|1[0-2])\.([1-9]|[12][0-9]|3[01])-build\.([1-9][0-9]*)$ ]]; then
  echo "Expected a release tag like v2026.10.21-build.1, got '$TAG'." >&2
  exit 2
fi
if [ "$#" -gt 0 ]; then
  git fetch -q "https://github.com/$REPO" "refs/tags/$TAG:refs/tags/$TAG"
fi

echo "Waiting for the GitHub release $TAG: https://github.com/$REPO/actions"
until gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; do
  # The run can take a moment to appear after the push. A finished run
  # with no release means a build job failed.
  run="$(gh run list -R "$REPO" --workflow release.yml --branch "$TAG" -L 1 \
    --json status,url -q '.[0] | select(.status == "completed") | .url')"
  if [ -n "$run" ]; then
    echo "The release workflow finished without publishing $TAG: $run" >&2
    exit 1
  fi
  sleep "$POLL_SECONDS"
done

# 2. One combined Zapstore / Orchard release
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
bun scripts/zapstore.ts "$TAG" "$WORK/$APPIMAGE" "$WORK/$FLATPAK" "$WORK/$METADATA"
echo "Published $TAG on GitHub, Zapstore and Orchard."
