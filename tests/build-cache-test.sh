#!/usr/bin/env bash
# Exercise the actual shared cache implementation without compiling anything.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/scripts/build-cache.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src/empty" "$TMP/out" "$TMP/src/.git"
printf 'source\n' >"$TMP/src/main"
printf 'asset\n' >"$TMP/src/asset"
printf 'ignored\n' >"$TMP/src/.env"
printf 'ignored\n' >"$TMP/src/secrets.env"
printf 'ignored\n' >"$TMP/src/.git/config"
ln -s .env "$TMP/src/hidden-link"
printf 'target\n' >"$TMP/target"
ln -s ../target "$TMP/src/link"
KEY="$(build_cache_key 'compiler flags target' "$TMP/src")"
[ "$KEY" = "$(build_cache_key 'compiler flags target' "$TMP/src")" ]
[ "$KEY" != "$(build_cache_key 'different flags' "$TMP/src")" ]
printf 'changed secret\n' >"$TMP/src/.env"
printf 'changed secret\n' >"$TMP/src/secrets.env"
printf 'changed metadata\n' >"$TMP/src/.git/config"
[ "$KEY" = "$(build_cache_key 'compiler flags target' "$TMP/src")" ]
printf 'new target\n' >"$TMP/target"
[ "$KEY" != "$(build_cache_key 'compiler flags target' "$TMP/src")" ]
printf 'target\n' >"$TMP/target"
[ "$KEY" = "$(build_cache_key 'compiler flags target' "$TMP/src")" ]
rm "$TMP/src/link"
ln -s "$TMP/target" "$TMP/src/link"
[ "$KEY" != "$(build_cache_key 'compiler flags target' "$TMP/src")" ]
rm "$TMP/src/link"
ln -s ../target "$TMP/src/link"
[ "$KEY" = "$(build_cache_key 'compiler flags target' "$TMP/src")" ]
ln -s empty "$TMP/src/directory-link"
DIRECTORY_KEY="$(build_cache_key directory "$TMP/src")"
rm "$TMP/src/directory-link"
ln -s "$TMP/src/empty" "$TMP/src/directory-link"
[ "$DIRECTORY_KEY" != "$(build_cache_key directory "$TMP/src")" ]
rm "$TMP/src/directory-link"
printf 'new file\n' >"$TMP/src/added"
[ "$KEY" != "$(build_cache_key 'compiler flags target' "$TMP/src")" ]
rm "$TMP/src/added"
[ "$KEY" = "$(build_cache_key 'compiler flags target' "$TMP/src")" ]
cp -p "$TMP/src/main" "$TMP/original"
printf 'edited\n' >"$TMP/src/main"
touch -r "$TMP/original" "$TMP/src/main"
[ "$KEY" != "$(build_cache_key 'compiler flags target' "$TMP/src")" ]
cp -p "$TMP/original" "$TMP/src/main"
[ "$KEY" = "$(build_cache_key 'compiler flags target' "$TMP/src")" ]
[ "$(build_cache_key order "$TMP/src/main" "$TMP/src/asset")" = "$(build_cache_key order "$TMP/src/asset" "$TMP/src/main")" ]
# Flatpak SDKs contain links whose cross-toolchain include trees are absent.
mkdir -p "$TMP/sdk/usr/include"
SDK_EMPTY_KEY="$(build_cache_key sdk "$TMP/sdk/usr/include")"
for arch in aarch64-linux-gnu arm-linux-gnueabihf i386-linux-gnu; do
  ln -s "../$arch/include" "$TMP/sdk/usr/include/$arch"
done
SDK_KEY="$(build_cache_key sdk "$TMP/sdk/usr/include")"
[ "$SDK_KEY" != "$SDK_EMPTY_KEY" ]
[ "$SDK_KEY" = "$(build_cache_key sdk "$TMP/sdk/usr/include")" ]
DANGLING_KEY="$(build_cache_key sdk "$TMP/sdk/usr/include/aarch64-linux-gnu")"
rm "$TMP/sdk/usr/include/aarch64-linux-gnu"
ln -s ../other/include "$TMP/sdk/usr/include/aarch64-linux-gnu"
[ "$SDK_KEY" != "$(build_cache_key sdk "$TMP/sdk/usr/include")" ]
[ "$DANGLING_KEY" != "$(build_cache_key sdk "$TMP/sdk/usr/include/aarch64-linux-gnu")" ]
rm "$TMP/sdk/usr/include/aarch64-linux-gnu"
ln -s "$TMP/sdk/usr/aarch64-linux-gnu/include" "$TMP/sdk/usr/include/aarch64-linux-gnu"
[ "$SDK_KEY" != "$(build_cache_key sdk "$TMP/sdk/usr/include")" ]
rm "$TMP/sdk/usr/include/aarch64-linux-gnu"
ln -s ../aarch64-linux-gnu/include "$TMP/sdk/usr/include/aarch64-linux-gnu"
[ "$SDK_KEY" = "$(build_cache_key sdk "$TMP/sdk/usr/include")" ]
mkdir -p "$TMP/sdk/usr/aarch64-linux-gnu/include"
SDK_DIRECTORY_KEY="$(build_cache_key sdk "$TMP/sdk/usr/include")"
[ "$SDK_KEY" != "$SDK_DIRECTORY_KEY" ]
printf 'header\n' >"$TMP/sdk/usr/aarch64-linux-gnu/include/header.h"
[ "$SDK_DIRECTORY_KEY" != "$(build_cache_key sdk "$TMP/sdk/usr/include")" ]
rm "$TMP/sdk/usr/aarch64-linux-gnu/include/header.h"
rmdir "$TMP/sdk/usr/aarch64-linux-gnu/include"
[ "$SDK_KEY" = "$(build_cache_key sdk "$TMP/sdk/usr/include")" ]
printf 'header\n' >"$TMP/sdk/usr/aarch64-linux-gnu/include"
SDK_FILE_KEY="$(build_cache_key sdk "$TMP/sdk/usr/include")"
[ "$SDK_KEY" != "$SDK_FILE_KEY" ]
[ "$SDK_DIRECTORY_KEY" != "$SDK_FILE_KEY" ]
chmod +x "$TMP/sdk/usr/aarch64-linux-gnu/include"
[ "$SDK_FILE_KEY" != "$(build_cache_key sdk "$TMP/sdk/usr/include")" ]
chmod -x "$TMP/sdk/usr/aarch64-linux-gnu/include"
printf 'changed header\n' >"$TMP/sdk/usr/aarch64-linux-gnu/include"
[ "$SDK_FILE_KEY" != "$(build_cache_key sdk "$TMP/sdk/usr/include")" ]
rm "$TMP/sdk/usr/aarch64-linux-gnu/include"
[ "$SDK_KEY" = "$(build_cache_key sdk "$TMP/sdk/usr/include")" ]
ln -s "$TMP/absent.env" "$TMP/src/hidden-dangling"
[ "$KEY" = "$(build_cache_key 'compiler flags target' "$TMP/src")" ]
rm "$TMP/src/hidden-dangling"
ln -s "$TMP/missing.env/leaf" "$TMP/src/hidden-dangling"
[ "$KEY" = "$(build_cache_key 'compiler flags target' "$TMP/src")" ]
rm "$TMP/src/hidden-dangling"
printf 'binary\n' >"$TMP/out/app"
chmod +x "$TMP/out/app"
if build_cache_fresh "$KEY" "$TMP/stamp" "$TMP/out"; then exit 1; fi
build_cache_store "$KEY" "$TMP/stamp" "$TMP/out"
build_cache_fresh "$KEY" "$TMP/stamp" "$TMP/out"
for excluded in .env secrets.env .git .hg .svn; do
  printf 'must not be read\n' >"$TMP/out/$excluded"
  if build_cache_fresh "$KEY" "$TMP/stamp" "$TMP/out" 2>/dev/null; then exit 1; fi
  if build_cache_store "$KEY" "$TMP/stamp" "$TMP/out" 2>/dev/null; then exit 1; fi
  rm "$TMP/out/$excluded"
done
ln -s "$TMP/src/.env" "$TMP/out/secret-alias"
if build_cache_fresh "$KEY" "$TMP/stamp" "$TMP/out" 2>/dev/null; then exit 1; fi
if build_cache_store "$KEY" "$TMP/stamp" "$TMP/out" 2>/dev/null; then exit 1; fi
rm "$TMP/out/secret-alias"
build_cache_fresh "$KEY" "$TMP/stamp" "$TMP/out"
ln -s absent "$TMP/out/dangling"
if build_cache_fresh "$KEY" "$TMP/stamp" "$TMP/out" 2>/dev/null; then exit 1; fi
if build_cache_store "$KEY" "$TMP/stamp" "$TMP/out" 2>/dev/null; then exit 1; fi
rm "$TMP/out/dangling"
build_cache_fresh "$KEY" "$TMP/stamp" "$TMP/out"
ln -s app "$TMP/out/app-link"
build_cache_store "$KEY" "$TMP/stamp" "$TMP/out"
rm "$TMP/out/app-link"
ln -s "$TMP/out/app" "$TMP/out/app-link"
if build_cache_fresh "$KEY" "$TMP/stamp" "$TMP/out"; then exit 1; fi
rm "$TMP/out/app-link"
build_cache_store "$KEY" "$TMP/stamp" "$TMP/out"
chmod -x "$TMP/out/app"
if build_cache_fresh "$KEY" "$TMP/stamp" "$TMP/out"; then exit 1; fi
chmod +x "$TMP/out/app"
build_cache_fresh "$KEY" "$TMP/stamp" "$TMP/out"
printf 'broken\n' >"$TMP/out/app"
if build_cache_fresh "$KEY" "$TMP/stamp" "$TMP/out"; then exit 1; fi
rm "$TMP/out/app"
if build_cache_fresh "$KEY" "$TMP/stamp" "$TMP/out"; then exit 1; fi
if build_cache_store "$KEY" "$TMP/stamp" "$TMP/out/app" 2>/dev/null; then exit 1; fi
if build_cache_key missing "$TMP/missing" >/dev/null 2>&1; then exit 1; fi
mkfifo "$TMP/fifo"
if build_cache_key fifo "$TMP/fifo" >/dev/null 2>&1; then exit 1; fi
ln -s "$TMP/fifo" "$TMP/fifo-link"
if build_cache_key fifo "$TMP/fifo-link" >/dev/null 2>&1; then exit 1; fi
ln -s . "$TMP/src/cycle"
if build_cache_key cycle "$TMP/src" >/dev/null 2>&1; then exit 1; fi
rm "$TMP/src/cycle"
printf 'build cache tests passed\n'
