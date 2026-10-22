#!/usr/bin/env bash
# Build a signed release image. The installed image's key anchors future updates.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$(realpath -- "${1:?appimagetool required}")"
APPDIR="$(realpath -- "${2:?AppDir required}")"
OUTPUT="${3:?output required}"
: "${WN_APPIMAGE_SIGNING_KEY:?AppImage releases require the dedicated signing key}"

export GNUPGHOME
GNUPGHOME="$(mktemp -d)"
cleanup() {
  gpgconf --homedir "$GNUPGHOME" --kill gpg-agent || true
  rm -rf "$GNUPGHOME"
}
trap cleanup EXIT
chmod 700 "$GNUPGHOME"
printf '%s\n' "$WN_APPIMAGE_SIGNING_KEY" | gpg --batch --import
unset WN_APPIMAGE_SIGNING_KEY
fingerprint="$(gpg --batch --show-keys --with-colons "$HERE/packaging/appimage-update-key.asc" | awk -F: '$1 == "fpr" {print $10; exit}')"
test -n "$fingerprint"
gpg --batch --list-secret-keys "$fingerprint" >/dev/null

version="$(bash "$HERE/scripts/version.sh")"
desktop-file-edit --set-key=X-AppImage-Version --set-value="$version" "$APPDIR/whitenoise.desktop"
export APPIMAGETOOL_SIGN_PASSPHRASE=""
(
  cd -- "$(dirname -- "$OUTPUT")"
  "$TOOL" --sign --sign-key "$fingerprint" \
    -u 'gh-releases-zsync|marmot-protocol|whitenoise-linux|latest|WhiteNoise-*-x86_64.AppImage.zsync' \
    "$APPDIR" "$(basename -- "$OUTPUT")"
)
