#!/bin/bash
# Install the pinned build tools for macOS packages on a Mac: the GitHub
# macOS runner today, a self-hosted Mac later. This is the Mac counterpart
# of packaging/cross/Containerfile, with the same pins.
#
# Usage: scripts/macos-setup.sh [tools-dir]
# Then:  source <tools-dir>/env   (or append <tools-dir>/path to $GITHUB_PATH)
#
# Runs under macOS's stock bash 3.2; it is what installs a newer bash.
set -euo pipefail

TOOLS="${1:-${WN_MACOS_TOOLS:-$HOME/.cache/whitenoise-macos-tools}}"
ODIN_VERSION=dev-2026-09
BUN_VERSION=1.3.10

if [ "$(uname -s)" != Darwin ]; then
  echo 'macos-setup.sh prepares a Mac; Linux and Windows builds use packaging/cross/Containerfile.' >&2
  exit 2
fi
command -v brew >/dev/null || { echo 'Install Homebrew first: https://brew.sh' >&2; exit 1; }
command -v rustup >/dev/null || { echo 'Install rustup first: https://rustup.rs' >&2; exit 1; }
xcrun --sdk macosx --show-sdk-path >/dev/null || { echo 'Install Xcode or its Command Line Tools: xcode-select --install' >&2; exit 1; }

case "$(uname -m)" in
  arm64)
    ODIN_ASSET=odin-macos-arm64-$ODIN_VERSION.tar.gz
    ODIN_SHA256=3e6cbc1f247d8d14fe02c3151272d0a5b8d6d77acb7219f5b62914e4d95d97f7
    BUN_ASSET=bun-darwin-aarch64
    BUN_SHA256=82034e87c9d9b4398ea619aee2eed5d2a68c8157e9a6ae2d1052d84d533ccd8d ;;
  x86_64)
    ODIN_ASSET=odin-macos-amd64-$ODIN_VERSION.tar.gz
    ODIN_SHA256=c1f6d6320218ec7e511093a87bdd599b72a8417a9d2a00de2c9691103562165b
    BUN_ASSET=bun-darwin-x64
    BUN_SHA256=c1d90bf6140f20e572c473065dc6b37a4b036349b5e9e4133779cc642ad94323 ;;
  *) echo "Unsupported Mac architecture: $(uname -m)" >&2; exit 2 ;;
esac

# GNU userland (the cross scripts use GNU sed/tar/find flags and bash 4+),
# plus what vcpkg's Autotools and Meson ports expect on the build machine.
brew install --quiet bash coreutils findutils gnu-sed gnu-tar cmake ninja pkgconf nasm \
  autoconf autoconf-archive automake libtool gettext gperf bison flex

mkdir -p "$TOOLS"
fetch() { # url path sha256
  if [ -f "$2" ] && echo "$3  $2" | shasum -a 256 -c --status; then return; fi
  curl -fL --retry 3 "$1" -o "$2.part"
  echo "$3  $2.part" | shasum -a 256 -c
  mv "$2.part" "$2"
}

fetch "https://github.com/odin-lang/Odin/releases/download/$ODIN_VERSION/$ODIN_ASSET" "$TOOLS/odin.tar.gz" "$ODIN_SHA256"
rm -rf "$TOOLS/odin" && mkdir -p "$TOOLS/odin"
tar -xzf "$TOOLS/odin.tar.gz" -C "$TOOLS/odin" --strip-components=1

fetch "https://github.com/oven-sh/bun/releases/download/bun-v$BUN_VERSION/$BUN_ASSET.zip" "$TOOLS/bun.zip" "$BUN_SHA256"
rm -rf "$TOOLS/$BUN_ASSET" && unzip -q -o "$TOOLS/bun.zip" -d "$TOOLS"

if [ ! -x "$TOOLS/python/bin/meson" ]; then
  python3 -m venv "$TOOLS/python"
  "$TOOLS/python/bin/pip" install --quiet --no-cache-dir meson==1.9.1 mako==1.3.10 packaging==25.0
fi

BREW="$(brew --prefix)"
{
  for dir in "$TOOLS/python/bin" "$TOOLS/odin" "$TOOLS/$BUN_ASSET" \
    "$BREW/opt/coreutils/libexec/gnubin" "$BREW/opt/findutils/libexec/gnubin" \
    "$BREW/opt/gnu-sed/libexec/gnubin" "$BREW/opt/gnu-tar/libexec/gnubin" \
    "$BREW/opt/bison/bin" "$BREW/opt/flex/bin" "$BREW/bin"; do
    echo "$dir"
  done
} > "$TOOLS/path"
# Earlier lines win: build tools, then GNU userland ahead of the BSD tools.
printf 'export PATH="%s:$PATH"\n' "$(paste -s -d : "$TOOLS/path")" > "$TOOLS/env"
echo "macOS build tools ready in $TOOLS; source $TOOLS/env before scripts/cross-build.sh."
