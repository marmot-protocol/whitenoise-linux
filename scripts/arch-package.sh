#!/usr/bin/env bash
# Build the Arch Linux release tarball that the AUR's whitenoise-linux-bin
# installs: dist/WhiteNoise-<version>-archlinux-x86_64.tar.zst, holding the
# install-tree.sh tree under usr/ plus the app's LICENSE.
#
# Runs on Arch (CI: the archlinux container) with the depends and
# makedepends of packaging/arch/whitenoise-linux-git/PKGBUILD installed and
# that PKGBUILD's Odin on PATH. Like that package, it fetches every pinned
# input first and then compiles inside a network namespace of its own, so
# a download the fetch step missed fails the build instead of slipping in.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${WN_RELEASE_VERSION:-$(bash "$HERE/scripts/version.sh")}"
case "$VERSION" in *[!a-zA-Z0-9._+-]*) echo 'Invalid archive version' >&2; exit 2;; esac
NAME="WhiteNoise-$VERSION-archlinux-x86_64"
STAGE="$HERE/build/arch/$NAME"

bash "$HERE/scripts/build.sh" fetch
unshare --net --map-root-user env CARGO_NET_OFFLINE=true bash "$HERE/scripts/build.sh"

rm -rf "$STAGE"
bash "$HERE/scripts/install-tree.sh" "$STAGE/usr" whitenoise
cp "$HERE/LICENSE" "$STAGE/LICENSE"

# Boot the staged tree headless, as the AppImage and Flatpak jobs do:
# SDL's dummy driver, and WN_SHOT exits after a few frames. Catches a
# missing library or a res_dir that no longer finds the packaged data.
DATA="$(mktemp -d)"
(cd "$DATA" && SDL_VIDEODRIVER=dummy WN_SHOT=1 WN_VAULT_PW=ci-smoke "$STAGE/usr/bin/whitenoise" "$DATA")
rm -rf "$DATA"

mkdir -p "$HERE/dist"
tar --zstd --owner=0 --group=0 -cf "$HERE/dist/$NAME.tar.zst" -C "$STAGE" usr LICENSE
printf 'Packaged %s\n' "$NAME"
