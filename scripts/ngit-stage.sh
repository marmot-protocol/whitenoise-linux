#!/usr/bin/env bash
set -euo pipefail

cache=/var/cache/wn-ci
root="$cache/worktree"
if ! mountpoint -q "$cache"; then
  echo 'ngit worker requires its isolated persistent cache mount.' >&2
  exit 1
fi
if [ ! -d "$root/.git" ]; then
  git init -q "$root"
fi
git -C "$root" fetch --no-tags "$GITHUB_WORKSPACE" "$GITHUB_SHA"
git -C "$root" checkout --force --detach FETCH_HEAD

# SDK executables stay in the image; additional pinned toolchains persist.
if [ ! -d "$cache/rustup" ]; then
  mkdir -p "$cache/rustup/toolchains"
  cp /usr/local/rustup/settings.toml "$cache/rustup/settings.toml"
  for toolchain in /usr/local/rustup/toolchains/*; do
    ln -s "$toolchain" "$cache/rustup/toolchains/${toolchain##*/}"
  done
fi
mkdir -p "$cache/cargo"
printf 'CARGO_HOME=%s\nRUSTUP_HOME=%s\n' "$cache/cargo" "$cache/rustup" >>"$GITHUB_ENV"
