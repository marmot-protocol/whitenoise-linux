#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/repo"
mkdir -p "$repo/scripts" "$fixture/source/emoji" "$fixture/source/emoji-licenses"
cp "$HERE/scripts/build-emoji.sh" "$HERE/scripts/fetch.sh" "$repo/scripts/"
printf 'noto-emoji-commit = original\n' > "$fixture/source/emoji-sources"
for set in noto twemoji openmoji; do
  mkdir "$fixture/source/emoji/$set"
  printf 'original\n' > "$fixture/source/emoji/$set.bin"
  printf 'license\n' > "$fixture/source/emoji-licenses/$set.txt"
done
mv "$fixture/source/emoji-licenses/noto.txt" "$fixture/source/emoji-licenses/noto-emoji.txt"
printf 'extras\n' > "$fixture/source/emoji/openmoji-extras.tsv"
printf 'catalog\n' > "$fixture/source/emoji-catalog.tsv"
make_bundle() {
  mkdir -p "$fixture/bundles"
  tar -C "$fixture/source" -cf - emoji-licenses emoji-catalog.tsv emoji-sources emoji/openmoji-extras.tsv | zstd -q -f -o "$fixture/bundles/common.tar.zst"
  for set in noto twemoji openmoji; do
    tar -C "$fixture/source" -cf - "emoji/$set" "emoji/$set.bin" | zstd -q -f -o "$fixture/bundles/$set.tar.zst"
  done
  tar -C "$fixture/bundles" -cf "$fixture/bundle.tar" common.tar.zst noto.tar.zst twemoji.tar.zst openmoji.tar.zst
  digest="$(sha256sum "$fixture/bundle.tar")"
  cat "$fixture/source/emoji-sources" > "$repo/DEPS_PIN"
  printf 'emoji-bundle-file = %s file://%s/bundle.tar\n' "${digest%% *}" "$fixture" >> "$repo/DEPS_PIN"
}
stage() { bash "$repo/scripts/build-emoji.sh" "$fixture/vendor"; }
make_bundle
stage
# A restored stamp must not hide a missing pack.
rm "$fixture/vendor/emoji/twemoji.bin"
stage
cmp "$fixture/source/emoji/twemoji.bin" "$fixture/vendor/emoji/twemoji.bin"
# A new pin replaces the whole generated tree, including removed upstream tiles.
printf 'obsolete\n' > "$fixture/vendor/emoji/noto/obsolete.png"
printf 'updated\n' > "$fixture/source/emoji/noto.bin"
make_bundle
stage
cmp "$fixture/source/emoji/noto.bin" "$fixture/vendor/emoji/noto.bin"
test ! -e "$fixture/vendor/emoji/noto/obsolete.png"
cp "$fixture/vendor/.emoji-bundle" "$fixture/installed-stamp"
# Changing only an upstream pin must invalidate an otherwise matching stamp.
cp "$repo/DEPS_PIN" "$fixture/installed-pins"
{ printf 'noto-emoji-commit = changed\n'; printf 'emoji-bundle-file = %s file://%s/bundle.tar\n' "${digest%% *}" "$fixture"; } > "$repo/DEPS_PIN"
if stage; then
  echo 'Reused an emoji bundle after its source pins changed.' >&2
  exit 1
fi
cmp "$fixture/installed-stamp" "$fixture/vendor/.emoji-bundle"
cp "$fixture/installed-pins" "$repo/DEPS_PIN"
# A valid archive for different source pins must not replace installed data.
printf 'noto-emoji-commit = changed\n' > "$fixture/source/emoji-sources"
make_bundle
printf 'noto-emoji-commit = original\n' > "$fixture/source/emoji-sources"
{ cat "$fixture/source/emoji-sources"; printf 'emoji-bundle-file = %s file://%s/bundle.tar\n' "${digest%% *}" "$fixture"; } > "$repo/DEPS_PIN"
if stage; then
  echo 'Accepted an emoji bundle for different source pins.' >&2
  exit 1
fi
cmp "$fixture/installed-stamp" "$fixture/vendor/.emoji-bundle"
cmp "$fixture/source/emoji/noto.bin" "$fixture/vendor/emoji/noto.bin"
# A failed set worker must not install the other workers' partial results.
printf 'corrupt set\n' > "$fixture/bundles/twemoji.tar.zst"
tar -C "$fixture/bundles" -cf "$fixture/bundle.tar" common.tar.zst noto.tar.zst twemoji.tar.zst openmoji.tar.zst
digest="$(sha256sum "$fixture/bundle.tar")"
{ cat "$fixture/source/emoji-sources"; printf 'emoji-bundle-file = %s file://%s/bundle.tar\n' "${digest%% *}" "$fixture"; } > "$repo/DEPS_PIN"
if stage; then
  echo 'Accepted a bundle after a set worker failed.' >&2
  exit 1
fi
cmp "$fixture/installed-stamp" "$fixture/vendor/.emoji-bundle"
cmp "$fixture/source/emoji/noto.bin" "$fixture/vendor/emoji/noto.bin"
# Checksum failure must leave the last working assets and stamp intact.
printf 'corrupt archive\n' > "$fixture/bundle.tar"
rm "$repo/vendor/downloads/emoji-bundle"
if stage; then
  echo 'Accepted an emoji bundle with the wrong checksum.' >&2
  exit 1
fi
cmp "$fixture/installed-stamp" "$fixture/vendor/.emoji-bundle"
cmp "$fixture/source/emoji/noto.bin" "$fixture/vendor/emoji/noto.bin"
echo 'Emoji bundle staging checks passed.'
