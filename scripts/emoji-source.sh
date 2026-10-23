#!/usr/bin/env bash
# Maintainer-only source recipe for the pinned emoji bundle.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="${1:?staging directory required}"
mkdir -p "$VENDOR"
RENDERER="$(rsvg-convert --version)"
if [ "${RENDERER%%$'\n'*}" != "rsvg-convert version 2.62.3" ] || [ "$(pkg-config --modversion cairo)" != 1.18.4 ]; then
  echo 'Emoji bundle generation requires librsvg 2.62.3 and cairo 1.18.4.' >&2
  exit 1
fi
TAR_OWNER=()
if [ "$(uname -s)" = Linux ]; then TAR_OWNER=(--no-same-owner); fi
fetch() { bash "$HERE/scripts/fetch.sh" "$1" </dev/null; }
# Emoji art: one folder of 128x128 PNG tiles per set the user can pick in
# Appearance, for the picker packs and reaction chips (any emoji, not
# just the embedded quick-react six). Licence texts go to emoji-licenses.
#
#   vendor/emoji/noto/      googlefonts/noto-emoji at noto-emoji-commit (Apache 2.0),
#                           from the subset archive pinned as noto-emoji-file
#   vendor/emoji/twemoji/   twemoji-assets crate SVGs, sha256-pinned (CC-BY 4.0)
#   vendor/emoji/openmoji/  OpenMoji release SVG zip, sha256-pinned (CC BY-SA 4.0)
#
# Noto ships 128px PNGs. Twemoji and OpenMoji ship PNGs only at 72px (and
# OpenMoji at 618px), so their SVGs are rasterized with rsvg-convert.
# The side must match EMOJI_SIDE in app/emoji.odin and scripts/emoji-pack.c;
# a change restages every set. Delete a set's folder to restage it.
EMOJI="$VENDOR/emoji"
EMOJI_LICENSES="$VENDOR/emoji-licenses"
EMOJI_SIDE=128
EMOJI_SIDE_STAMP="$VENDOR/.emoji-side"
mkdir -p "$EMOJI" "$EMOJI_LICENSES"
if [ "$(cat "$EMOJI_SIDE_STAMP" 2>/dev/null || true)" != "$EMOJI_SIDE" ]; then
  rm -rf "$EMOJI/noto" "$EMOJI/twemoji" "$EMOJI/openmoji"
fi

# Upstream names differ for the same emoji ("emoji_u1f441_200d_1f5e8",
# "1F441-FE0F-200D-1F5E8-FE0F"). Copy each tile to the one name
# app/emoji.odin and scripts/emoji-pack.c look up: lowercase hex
# codepoints joined by '-', VS16 dropped ("1f441-200d-1f5e8.png").
# Names that are not codepoint sequences are skipped.
emoji_stage() {
  local dst="$1" src name code out
  shift
  for src in "$@"; do
    name="${src##*/}"
    name="${name%.png}"
    name="${name#emoji_u}"
    out=""
    for code in ${name//[_-]/ }; do
      if [[ ! $code =~ ^[0-9a-fA-F]{1,6}$ ]]; then
        continue 2
      fi
      printf -v code '%x' "$((16#$code))"
      if [ "$code" != fe0f ]; then
        out="${out:+$out-}$code"
      fi
    done
    cp "$src" "$dst/$out.png"
  done
}

# Rasterize every SVG under $2 to an EMOJI_SIDE-square PNG in $1, keeping
# the upstream name for emoji_stage. One rsvg-convert per file, batched
# across all cores: ~4,000 files take about 2 s on 16 threads.
emoji_rasterize() {
  mkdir -p "$1"
  find "$2" -name '*.svg' -print0 | xargs -0 -n 64 -P "$(getconf _NPROCESSORS_ONLN)" sh -c '
    out="$1" side="$2"
    shift 2
    for svg; do
      name="${svg##*/}"
      rsvg-convert -w "$side" -h "$side" -o "$out/${name%.svg}.png" "$svg" || exit 255
    done
  ' sh "$1" "$EMOJI_SIDE"
}

# Noto's 128px PNGs exist only inside its 1.5 GB repository, so the pin is
# a subset archive of noto-emoji-commit made by scripts/noto-emoji-subset.sh.
# A new archive restages the set.
NOTO_PIN="$(sed -n 's/^noto-emoji-file = //p' "$HERE/DEPS_PIN")"
NOTO_STAMP="$VENDOR/.emoji-noto-pin"
if [ "$(cat "$NOTO_STAMP" 2>/dev/null || true)" != "$NOTO_PIN" ]; then
  rm -rf "$EMOJI/noto"
fi
if [ ! -d "$EMOJI/noto" ]; then
  NOTO_ARCHIVE="$(fetch noto-emoji)"
  TMP="$(mktemp -d "$VENDOR/.emoji.XXXXXX")"
  tar "${TAR_OWNER[@]}" -xzf "$NOTO_ARCHIVE" -C "$TMP"
  NOTO="$(echo "$TMP"/noto-emoji-*)"
  if [ ! -d "$NOTO/2D/png/$EMOJI_SIDE" ]; then
    echo "==> The Noto archive has no ${EMOJI_SIDE}px tiles; rebuild it with scripts/noto-emoji-subset.sh." >&2
    exit 1
  fi
  # The classic 2D set has no flags (Noto's font build waves them from
  # region-flags). The 3D set's flags are that same waved art, so stage
  # 3D first and let 2D overwrite everything it has.
  mkdir "$TMP/tiles"
  emoji_stage "$TMP/tiles" "$NOTO"/3D/png/"$EMOJI_SIDE"/*.png
  emoji_stage "$TMP/tiles" "$NOTO"/2D/png/"$EMOJI_SIDE"/*.png
  cp "$NOTO/LICENSE" "$EMOJI_LICENSES/noto-emoji.txt"
  mv "$TMP/tiles" "$EMOJI/noto"
  rm -rf "$TMP"
  printf '%s\n' "$NOTO_PIN" > "$NOTO_STAMP"
fi

if [ ! -d "$EMOJI/twemoji" ]; then
  TWEMOJI_CRATE="$(fetch twemoji)"
  TMP="$(mktemp -d "$VENDOR/.emoji.XXXXXX")"
  tar "${TAR_OWNER[@]}" -xzf "$TWEMOJI_CRATE" -C "$TMP"
  mkdir "$TMP/tiles"
  emoji_rasterize "$TMP/png" "$TMP"/twemoji-assets-*/assets/svg
  emoji_stage "$TMP/tiles" "$TMP"/png/*.png
  # The crate carries only its code licence; the graphics are CC-BY 4.0.
  printf '%s\n' \
    "Twemoji graphics: Copyright 2019 Twitter, Inc and other contributors." \
    "Licensed under CC-BY 4.0: https://creativecommons.org/licenses/by/4.0/" \
    > "$EMOJI_LICENSES/twemoji.txt"
  mv "$TMP/tiles" "$EMOJI/twemoji"
  rm -rf "$TMP"
fi

if [ ! -d "$EMOJI/openmoji" ] || [ ! -f "$EMOJI/openmoji-extras.tsv" ]; then
  rm -rf "$EMOJI/openmoji"
  OPENMOJI_ZIP="$(fetch openmoji)"
  OPENMOJI_LICENSE="$(fetch openmoji-license)"
  OPENMOJI_DATA="$(fetch openmoji-data)"
  TMP="$(mktemp -d "$VENDOR/.emoji.XXXXXX")"
  unzip -qo "$OPENMOJI_ZIP" -d "$TMP/svg"
  emoji_rasterize "$TMP/png" "$TMP/svg"
  mkdir "$TMP/tiles"
  emoji_stage "$TMP/tiles" "$TMP"/png/*.png
  # Emoji only OpenMoji draws (its private-use designs and non-RGI
  # Unicode sequences), in the base catalog's "emoji<TAB>search" form.
  # The picker appends them while OpenMoji is the active set. The JSON
  # is pretty-printed one key per line, with no escaped quotes in these
  # fields, so awk reads each object's keys and prints at its brace.
  # Single codepoints outside the private-use area ("-", U+2605 star)
  # are ordinary text, so they get VS16 (EF B8 8F) to ask for emoji
  # presentation; without it every hyphen in a message would be a tile.
  awk -F '"' '
    $2 == "emoji" { emoji = $4 }
    $2 == "hexcode" { hex = $4 }
    $2 == "group" { group = $4 }
    $2 == "annotation" { name = $4 }
    $2 == "tags" { tags = $4 }
    $2 == "openmoji_tags" { own = $4 }
    $2 == "skintone" { skin = $4 }
    /^  }/ {
      if (group ~ /^extras-/ && skin == "") {
        if (hex !~ /-/ && !(length(hex) == 4 && hex ~ /^(E|F[0-8])/)) {
          emoji = emoji "\357\270\217"
        }
        printf "%s\t%s %s %s\n", emoji, name, tags, own
      }
    }
  ' "$OPENMOJI_DATA" > "$TMP/extras.tsv"
  {
    echo "All emojis designed by OpenMoji, the open-source emoji and icon project."
    echo "https://openmoji.org/ License: CC BY-SA 4.0"
    echo
    cat "$OPENMOJI_LICENSE"
  } > "$EMOJI_LICENSES/openmoji.txt"
  mv "$TMP/tiles" "$EMOJI/openmoji"
  mv "$TMP/extras.tsv" "$EMOJI/openmoji-extras.tsv"
  rm -rf "$TMP"
fi
printf '%s\n' "$EMOJI_SIDE" > "$EMOJI_SIDE_STAMP"

# Emoji picker catalog: "emoji<TAB>name aliases" per line, extracted from
# the pinned emojis crate. Keep shortcodes (100, thumbsup, etc.) searchable.
# Skin tone variants are dropped to keep the grid to base emoji.
CATALOG="$VENDOR/emoji-catalog.tsv"
CATALOG_VERSION="emojis-0.6.4-aliases-1"
if [ ! -f "$CATALOG" ] || [ "$(cat "$VENDOR/.emoji-catalog-version" 2>/dev/null || true)" != "$CATALOG_VERSION" ]; then
  EMOJIS_CRATE="$(fetch emojis)"
  TMP="$(mktemp -d)"
  tar "${TAR_OWNER[@]}" -xzf "$EMOJIS_CRATE" -C "$TMP"
  # Only emoji, name and aliases are quoted in the pinned generated records.
  awk -F '"' '
    /Emoji { emoji: / {
      if ($2 ~ /🏻|🏼|🏽|🏾|🏿/) { next }
      search = $4
      for (i = 6; i < NF; i += 2) {
        search = search " :" $i ":"
        alias = $i
        gsub(/_/, " ", alias)
        search = search " " alias
      }
      printf "%s\t%s\n", $2, search
    }
  ' "$TMP"/emojis-0.6.4/src/gen/mod.rs >"$TMP/catalog.tsv"
  mv "$TMP/catalog.tsv" "$CATALOG"
  printf '%s\n' "$CATALOG_VERSION" >"$VENDOR/.emoji-catalog-version"
  rm -rf "$TMP"
fi
bash "$HERE/scripts/build-emoji-pack.sh" "$VENDOR"

