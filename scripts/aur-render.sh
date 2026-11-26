#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tag=${WN_RC_TAG:?Missing RC tag}
bash scripts/aur-bin.sh "$tag" "dist/WhiteNoise-$tag-archlinux-x86_64.tar.zst" build/aur
install -D -m 0644 packaging/arch/whitenoise-linux-git/PKGBUILD build/aur/whitenoise-linux-git/PKGBUILD
# makepkg refuses to run as root.
useradd -m builder
chown -R builder build/aur
su builder -c "scripts/aur-source.sh '$tag' build/aur"
for pkg in whitenoise-linux-bin whitenoise-linux-git; do
  su builder -c "cd build/aur/$pkg && makepkg --printsrcinfo > .SRCINFO"
done
