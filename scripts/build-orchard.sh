#!/usr/bin/env bash
# Build only Orchard's pure-Rust publisher, never its GUI or installer.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$HERE/build/orchard-source"
TARGET="$HERE/build/orchard-target"
ARCHIVE="$(bash "$HERE/scripts/fetch.sh" orchard-source)"
# Preserve tar symlink targets and replace unstable match guards so the
# pinned publisher builds on stable Rust without changing registry parsing.
PATCHES=("$HERE"/patches/orchard-*.patch)
stamp="$(sha256sum "$ARCHIVE" "${PATCHES[@]}")"
if [[ ! -f "$SOURCE/.source-stamp" ]] || [[ "$(<"$SOURCE/.source-stamp")" != "$stamp" ]]; then
  rm -rf "$SOURCE"
  mkdir -p "$SOURCE"
  tar -xzf "$ARCHIVE" --strip-components=1 -C "$SOURCE"
  for patch_file in "${PATCHES[@]}"; do
    patch --directory="$SOURCE" -p1 --forward --batch < "$patch_file"
  done
  printf '%s\n' "$stamp" > "$SOURCE/.source-stamp"
fi
mkdir -p "$TARGET"
cargo build --locked --release --manifest-path "$SOURCE/Cargo.toml" \
  --package orchard-publish --bin orchard-publish --target-dir "$TARGET"
install -m 0755 "$TARGET/release/orchard-publish" "$HERE/build/orchard-publish"
