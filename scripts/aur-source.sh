#!/usr/bin/env bash
# Write the AUR package whitenoise-linux, which builds one release from
# source, to <outdir>/whitenoise-linux/{PKGBUILD,.SRCINFO}:
#
#   scripts/aur-source.sh v2026.10.21-build.1 build/aur
#
# The AUR needs a static source list, and DEPS_PIN changes between releases,
# so the PKGBUILD is generated from the tag's DEPS_PIN: every `-commit`
# checkout becomes a git source and every `-file` download a checksummed
# file source. prepare() puts them where scripts/build.sh looks
# (vendor/<name>, vendor/downloads/<name>) and fetches marmot-c's crates;
# build() then runs without network.
#
# Run from a checkout of the tag once the tag is on GitHub: the source
# tarball's digest comes from GitHub's archive of it. Description,
# licenses, dependencies and the Odin pin come from
# packaging/arch/whitenoise-linux-git/PKGBUILD, as for whitenoise-linux-bin
# (scripts/aur-bin.sh), so the three packages cannot drift.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:?release tag required}"
OUT="${2:?output directory required}/whitenoise-linux"
VERSION="$(bash "$HERE/scripts/version.sh" "$TAG")"
REPO="https://github.com/marmot-protocol/whitenoise-linux"

# The checkouts build.sh clones, by DEPS_PIN name. The URLs repeat
# build.sh's; a new git dependency there needs a line here.
GIT_DEPS=(
  "mdk https://github.com/marmot-protocol/mdk.git"
  "clay https://github.com/nicbarker/clay.git"
  "crop-circles https://relay.cyberguy.fyi/npub1ven4zk8xxw873876gx8y9g9l9fazkye9qnwnglcptgvfwxmygscqsxddfh/crop-circles.git"
  "ufbx https://github.com/ufbx/ufbx.git"
  "microtex https://github.com/NanoMichael/MicroTeX.git"
)

TARBALL_SHA="$(curl -sSfL "$REPO/archive/refs/tags/$TAG.tar.gz" | sha256sum | cut -d' ' -f1)"

# Only top-level assignments run; the build functions are never called.
source "$HERE/packaging/arch/whitenoise-linux-git/PKGBUILD"
odin_source="${source[1]}"
odin_sha="${sha256sums[1]}"
# The -git and -bin packages provide and conflict with this one; it
# conflicts with everything else they do.
own_conflicts=()
for name in "${conflicts[@]}"; do
  if [ "$name" != whitenoise-linux ]; then
    own_conflicts+=("$name")
  fi
done

sources=("whitenoise-linux-$TAG.tar.gz::$REPO/archive/refs/tags/$TAG.tar.gz" "$odin_source")
sums=("$TARBALL_SHA" "$odin_sha")
gits=()
for dep in "${GIT_DEPS[@]}"; do
  name="${dep%% *}"
  commit="$(sed -n "s/^$name-commit = //p" "$HERE/DEPS_PIN")"
  sources+=("$name::git+${dep#* }#commit=$commit")
  sums+=(SKIP)
  gits+=("$name")
done
# Every download build.sh and build-tts.sh fetch on x86_64.
files=()
while read -r name sha url; do
  if [ "$name" = sherpa-onnx-aarch64 ]; then
    continue
  fi
  sources+=("$name::$url")
  sums+=("$sha")
  files+=("$name")
done < <(sed -n 's/^\([a-z0-9_-]*\)-file = /\1 /p' "$HERE/DEPS_PIN")

mkdir -p "$OUT"
{
  cat <<EOF
# Maintainer: TBA
#
# Builds one release from source with every input pinned below. Generated
# by scripts/aur-source.sh in
# $REPO;
# change that script or packaging/arch/whitenoise-linux-git/PKGBUILD there,
# not this file.
pkgname=whitenoise-linux
pkgver=${VERSION/+/.}
pkgrel=1
pkgdesc=${pkgdesc@Q}
arch=(x86_64)
url=${REPO@Q}
license=(${license[*]@Q})
depends=(${depends[*]@Q})
makedepends=(${makedepends[*]@Q})
optdepends=(
EOF
  printf '  %s\n' "${optdepends[@]@Q}"
  cat <<EOF
)
conflicts=(${own_conflicts[*]@Q})
# !lto: makepkg's -flto=auto turns the sqlite bundled into libmarmot_c.a
# into GCC bitcode objects, which the clang link Odin drives cannot see
# (undefined sqlite3_* at link time).
options=(!lto)
_tag=$TAG
_odin_dir=$_odin_dir
_gits=(${gits[*]})
_files=(${files[*]})
source=(
EOF
  printf '  %s\n' "${sources[@]@Q}"
  cat <<EOF
)
noextract=("\${_files[@]}")
sha256sums=(
EOF
  printf '  %s\n' "${sums[@]@Q}"
  cat <<'EOF'
)

prepare() {
  cd "whitenoise-linux-${_tag#v}"
  mkdir -p vendor/downloads
  for dep in "${_gits[@]}"; do
    ln -sfn "$srcdir/$dep" "vendor/$dep"
  done
  for dep in "${_files[@]}"; do
    ln -sfn "$srcdir/$dep" "vendor/downloads/$dep"
  done
  # Inside vendor/mdk so rustup, when present, installs the pinned toolchain.
  cd vendor/mdk
  cargo fetch --locked --target "$(rustc -vV | sed -n 's/^host: //p')"
}

build() {
  cd "whitenoise-linux-${_tag#v}"
  export PATH="$srcdir/$_odin_dir:$PATH"
  CARGO_NET_OFFLINE=true scripts/build.sh
}

package() {
  cd "whitenoise-linux-${_tag#v}"
  scripts/install-tree.sh "$pkgdir/usr" whitenoise
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  ln -s /usr/share/whitenoise-linux/licenses "$pkgdir/usr/share/licenses/$pkgname/bundled"
}
EOF
} >"$OUT/PKGBUILD"
(cd "$OUT" && makepkg --printsrcinfo >.SRCINFO)
printf 'Wrote %s\n' "$OUT/PKGBUILD"
