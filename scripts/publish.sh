#!/usr/bin/env bash
# Publish a release everywhere, in order:
#
#   1. GitHub. scripts/release.sh bumps APP_VERSION, tags and pushes. The tag
#      starts .github/workflows/release.yml, which builds every package,
#      creates the GitHub release and then updates the AUR.
#   2. Zapstore. Once the GitHub release exists, its AppImage and Flatpak are
#      downloaded, checked against its SHA256SUMS.txt, and announced by
#      scripts/zapstore.ts, signed by you.
#
#   scripts/publish.sh          cut a new release, then both steps
#   scripts/publish.sh <tag>    an existing tag: wait for its GitHub
#                               release if needed, then Zapstore
#
# The signer is asked for first, so the build runs unattended: a bunker URL
# (Amber, nsec.app, `nak bunker`) or an nsec for zapstore.yaml's pubkey,
# read without echo. ZAPSTORE_SIGNER in the environment skips the prompt.
# With a bunker, approve four events at the end: app, two assets, release.
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
  read -rsp "Zapstore signer for $PUBKEY (bunker URL or nsec): " ZAPSTORE_SIGNER
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

# 1. GitHub
if [ "$#" -eq 0 ]; then
  scripts/release.sh
  TAG="$(git tag --points-at HEAD 'v*-build.*')"
else
  TAG="$1"
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

# 2. Zapstore
APPIMAGE="WhiteNoise-$TAG-x86_64.AppImage"
FLATPAK="WhiteNoise-$TAG-x86_64.flatpak"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "Downloading $APPIMAGE and $FLATPAK"
gh release download "$TAG" -R "$REPO" -D "$WORK" -p "$APPIMAGE" -p "$FLATPAK" -p SHA256SUMS.txt
# The digests the asset events pin must be the ones the release lists.
for file in "$APPIMAGE" "$FLATPAK"; do
  awk -v name="$file" '$2 == name' "$WORK/SHA256SUMS.txt" | (cd "$WORK" && sha256sum -c --strict -)
done
bun scripts/zapstore.ts "$TAG" "$WORK/$APPIMAGE" "$WORK/$FLATPAK"
echo "Published $TAG on GitHub and Zapstore."
