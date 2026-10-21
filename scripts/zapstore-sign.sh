#!/usr/bin/env bash
# Sign and publish a GitHub release to Zapstore from your machine, so the
# signing key never has to live in CI. Downloads the release's AppImage,
# checks it against the release's SHA256SUMS.txt, asks for your signer,
# then runs scripts/zapstore.ts.
#
#   scripts/zapstore-sign.sh                        latest release
#   scripts/zapstore-sign.sh v2026.10.21-build.1    a given release
#
# The signer is a bunker URL (Amber, nsec.app, `nak bunker`) or an nsec for
# the pubkey in zapstore.yaml. It is read without echo, so it stays out of
# shell history; ZAPSTORE_SIGNER in the environment skips the prompt.
# With a bunker, approve three events: app, asset, release.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=marmot-protocol/whitenoise-linux

for tool in bun nak curl jq git; do
  if ! command -v "$tool" >/dev/null; then
    echo "scripts/zapstore-sign.sh needs $tool on PATH." >&2
    exit 1
  fi
done

TAG="${1:-$(curl -sSf "https://api.github.com/repos/$REPO/releases/latest" | jq -r .tag_name)}"
APPIMAGE="WhiteNoise-$TAG-x86_64.AppImage"
DOWNLOAD="https://github.com/$REPO/releases/download/$TAG"

# zapstore.ts reads the commit and the release notes from the tag.
git fetch -q "https://github.com/$REPO" "refs/tags/$TAG:refs/tags/$TAG"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "Downloading $APPIMAGE"
curl -sSfL -o "$WORK/$APPIMAGE" "$DOWNLOAD/$APPIMAGE"
curl -sSfL -o "$WORK/SHA256SUMS.txt" "$DOWNLOAD/SHA256SUMS.txt"
# The digest the asset event will pin must be the one the release lists.
(cd "$WORK" && awk -v name="$APPIMAGE" '$2 == name' SHA256SUMS.txt | sha256sum -c -)

if [ -z "${ZAPSTORE_SIGNER:-}" ]; then
  read -rsp "Signer for $(sed -n 's/^pubkey: //p' zapstore.yaml) (bunker URL or nsec): " ZAPSTORE_SIGNER
  echo
fi
export ZAPSTORE_SIGNER
bun scripts/zapstore.ts "$TAG" "$WORK/$APPIMAGE"
