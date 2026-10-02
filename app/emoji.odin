package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

quick_tile :: proc(emoji: string) -> ^rl.Texture2D {
	if tex := emoji_tex(emoji); tex != nil {
		return tex
	}
	for entry, i in QUICK_REACT {
		if entry.emoji == emoji {
			return &quick_react_tex[i]
		}
	}
	return nil
}

// Emoji art sets the user picks in Appearance. Each is staged by
// scripts/build.sh as res_dir()/emoji/<dir>/ tiles plus the catalog's
// pixel pack at res_dir()/emoji/<dir>.bin. Noto is first so older
// settings files, which lack the field, get it.
Emoji_Set :: enum {
	Noto,
	Twemoji,
	OpenMoji,
}
@(private)
EMOJI_SET_DIRS := [Emoji_Set]string {
	.Noto     = "noto",
	.Twemoji  = "twemoji",
	.OpenMoji = "openmoji",
}
@(private)
EMOJI_SET_NAMES := [Emoji_Set]string {
	.Noto     = "Noto",
	.Twemoji  = "Twemoji",
	.OpenMoji = "OpenMoji",
}
@(private)
emoji_set: Emoji_Set
@(private)
emoji_pack: []u8

// On-demand tile cache for arbitrary emoji (reaction chips): emoji to
// texture from the active set, pack first, then its tile folder keyed
// by the staged name (lowercase hex codepoints joined by '-', VS16
// dropped). nil = no tile, caller falls back to the raw text glyph.
emoji_tex_cache: map[string]^rl.Texture2D

@(private)
EMOJI_SIDE :: 128 // matches scripts/build.sh and scripts/emoji-pack.c
@(private)
EMOJI_RECORD_BYTES :: 1 + EMOJI_SIDE * EMOJI_SIDE * 4
@(private)
emoji_pixels: map[string][]u8

// Plain UI text shares the tile cache with messages. Resolve whole
// graphemes so flags, skin tones, and joined emoji occupy one cell.
// Private-use graphemes count too (OpenMoji's E000 goldfish), and so
// does any grapheme carrying VS16 or a ZWJ: "\u2B21\uFE0F\u200D\U0001F7E8"
// starts with a text symbol but asks for emoji presentation. Graphemes
// no set draws fall back to the text glyph.
@(private)
text_emoji :: proc(text: string) -> ^rl.Texture2D {
	if strings.contains(text, "\uFE0E") {return nil}
	r, _ := utf8.decode_rune_in_string(text)
	if !unicode.is_emoji_extended_pictographic(r) &&
	   !unicode.is_regional_indicator(r) &&
	   !(r >= 0xE000 && r <= 0xF8FF) &&
	   !strings.contains(text, "\uFE0F") &&
	   !strings.contains(text, "\u200D") &&
	   !strings.contains(text, "\u20E3") {
		return nil
	}
	return emoji_tex(text)
}

// Picker catalog: the base rows from emoji-catalog.tsv, shared by every
// set, then the active set's own emoji/<set>-extras.tsv rows when it
// has any. Each row is an emoji plus a lowercase search name; the
// set's pack holds one pixel record per row in that order.
Emoji_Entry :: struct {
	emoji:  string,
	name:   string,
	pixels: []u8,
}
emoji_catalog: [dynamic]Emoji_Entry
@(private)
emoji_base_rows: int
@(private)
emoji_extras: []u8 // backs the extras rows' emoji strings

load_emoji_catalog :: proc() {
	catalog, _ := filepath.join({res_dir(), "emoji-catalog.tsv"}, context.temp_allocator)
	data, err := os.read_entire_file(catalog, context.allocator)
	if err != nil {
		fmt.eprintfln("emoji: catalog missing: %v", err)
		return
	}
	catalog_append(data)
	emoji_base_rows = len(emoji_catalog)
}

// "emoji<TAB>search words" lines; the emoji strings slice into `data`.
@(private = "file")
catalog_append :: proc(data: []u8) {
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		tab := strings.index_byte(line, '\t')
		if tab <= 0 {
			continue
		}
		append(
			&emoji_catalog,
			Emoji_Entry{emoji = line[:tab], name = strings.to_lower(line[tab + 1:])},
		)
	}
}

// Make `set` the art every emoji draws with: drop the old pack, extras
// rows and every texture made from them, then load the set's extras
// and point the catalog at its pack. A missing pack leaves rows without
// pixels (the picker hides them); tiles still load from the set folder.
emoji_set_load :: proc(set: Emoji_Set) {
	emoji_set = set
	for key, tex in emoji_tex_cache {
		if tex != nil {
			rl.UnloadTexture(tex^)
			free(tex)
		}
		delete(key)
	}
	clear(&emoji_tex_cache)
	clear(&emoji_pixels)
	for &entry in emoji_catalog {
		entry.pixels = nil
	}
	for entry in emoji_catalog[emoji_base_rows:] {
		delete(entry.name)
	}
	resize(&emoji_catalog, emoji_base_rows)
	delete(emoji_extras)
	emoji_extras = nil
	delete(emoji_pack)
	emoji_pack = nil

	extras := fmt.tprintf("%s/emoji/%s-extras.tsv", res_dir(), EMOJI_SET_DIRS[set])
	if os.exists(extras) {
		data, err := os.read_entire_file(extras, context.allocator)
		if err != nil {
			fmt.eprintfln("emoji: couldn't read %s: %v", extras, err)
		} else {
			emoji_extras = data
			catalog_append(data)
		}
	}

	path := fmt.tprintf("%s/emoji/%s.bin", res_dir(), EMOJI_SET_DIRS[set])
	pack, err := os.read_entire_file(path, context.allocator)
	if err != nil || !emoji_pack_valid(pack, len(emoji_catalog)) {
		fmt.eprintfln("emoji: missing or invalid pixel pack: %s (%v)", path, err)
		delete(pack)
		return
	}
	emoji_pack = pack
	for &entry, i in emoji_catalog {
		offset := 8 + i * EMOJI_RECORD_BYTES
		if pack[offset] == 0 {continue}
		entry.pixels = pack[offset + 1:offset + EMOJI_RECORD_BYTES]
		emoji_pixels[entry.emoji] = entry.pixels
	}
}

// Fixed-size RGBA records need no runtime image parser or helper process.
@(private)
emoji_pack_valid :: proc(data: []u8, count: int) -> bool {
	if len(data) < 8 || string(data[:4]) != "WNE1" {return false}
	stored := u32(data[4]) | u32(data[5]) << 8 | u32(data[6]) << 16 | u32(data[7]) << 24
	if u64(stored) != u64(count) || len(data) != 8 + count * EMOJI_RECORD_BYTES {return false}
	for i in 0 ..< count {
		if data[8 + i * EMOJI_RECORD_BYTES] > 1 {return false}
	}
	return true
}

emoji_tex :: proc(emoji: string) -> ^rl.Texture2D {
	// ":code:" is a custom emoji (recents, reaction chips); its own
	// cache handles it, and removal stays visible without a stale entry.
	if len(emoji) > 2 && emoji[0] == ':' && emoji[len(emoji) - 1] == ':' {
		return custom_tex_by_code(emoji[1:len(emoji) - 1])
	}
	if cached, ok := emoji_tex_cache[emoji]; ok {
		return cached
	}

	pixels := emoji_pixels[emoji]
	img: rl.Image
	if len(pixels) > 0 {
		img = {
			data   = raw_data(pixels),
			width  = EMOJI_SIDE,
			height = EMOJI_SIDE,
		}
	} else {
		img = emoji_image(emoji)
	}
	tex: ^rl.Texture2D
	if img.data != nil {
		tex = new(rl.Texture2D)
		tex^ = rl.LoadTextureFromImage(img)
		if len(pixels) == 0 {rl.UnloadImage(img)}
		rl.SetTextureFilter(tex^, .BILINEAR)
	}
	emoji_tex_cache[strings.clone(emoji)] = tex
	return tex
}

// The active set's tile, else the first other set that draws the emoji,
// so an emoji only OpenMoji has (its E000 goldfish) still renders as
// OpenMoji art under Noto or Twemoji.
@(private)
emoji_image :: proc(emoji: string) -> rl.Image {
	name := strings.builder_make(context.temp_allocator)
	for r in emoji {
		if r == 0xFE0F {
			continue
		}
		if strings.builder_len(name) > 0 {
			strings.write_byte(&name, '-')
		}
		fmt.sbprintf(&name, "%x", i32(r))
	}

	if image := emoji_set_image(emoji_set, strings.to_string(name)); image.data != nil {
		return image
	}
	for set in Emoji_Set {
		if set == emoji_set {
			continue
		}
		if image := emoji_set_image(set, strings.to_string(name)); image.data != nil {
			return image
		}
	}
	return {}
}

@(private = "file")
emoji_set_image :: proc(set: Emoji_Set, name: string) -> rl.Image {
	path := fmt.tprintf("%s/emoji/%s/%s.png", res_dir(), EMOJI_SET_DIRS[set], name)
	if !os.exists(path) {
		return {}
	}
	return rl.LoadImage(strings.clone_to_cstring(path, context.temp_allocator))
}

PAGE_ICONS := [Page]string {
	.Chats    = ICON_CHATS,
	.Contacts = ICON_PEOPLE,
	.Archived = ICON_ARCHIVE,
	.Settings = ICON_SETTINGS,
	.Profile  = ICON_PROFILE,
}

// Palette globals, filled from the active Theme_Pack (themes/*.toml
// packs, embedded and parsed in theme.odin).
ACCENT_NAMES := [5]string{N_("Mint"), N_("Ocean"), N_("Berry"), N_("Coral"), N_("Lavender")}

BG := clay.Color{6, 7, 8, 255}
CARD := clay.Color{15, 19, 24, 255}
CARD_BORDER := clay.Color{20, 24, 29, 255}
STATUS_BAR := clay.Color{11, 13, 15, 255}
RAIL_BG := clay.Color{15, 19, 24, 255} // in-card strips; blends with CARD
ROW_BG := clay.Color{10, 13, 17, 255} // fields, chips
FIELD_BORDER := clay.Color{31, 36, 42, 255}
HOVER := clay.Color{13, 17, 20, 255}
SELECTED := clay.Color{18, 40, 32, 255}
PLATE := clay.Color{20, 26, 33, 255}
DIVIDER := clay.Color{26, 31, 37, 255}
ELEVATED_BORDER := clay.Color{36, 42, 49, 255}
BORDER_2 := clay.Color{20, 24, 29, 255}
ON_ACCENT := clay.Color{10, 20, 16, 255}
ACCENT := clay.Color{114, 240, 176, 255}
ACCENT_DIM := clay.Color{61, 214, 138, 255}
TEXT := clay.Color{228, 231, 236, 255}
TEXT_DIM := clay.Color{156, 163, 175, 255}
TEXT_LO := clay.Color{107, 114, 128, 255}
DANGER := clay.Color{255, 90, 90, 255}
DANGER_SOFT := clay.Color{255, 90, 90, 38}
DANGER_BORDER := clay.Color{255, 90, 90, 110}
WARNING := clay.Color{235, 180, 70, 255}
WARNING_SOFT := clay.Color{235, 180, 70, 38}
WARNING_BORDER := clay.Color{235, 180, 70, 110}
TEXT_VLO := clay.Color{75, 82, 96, 255}
PANEL := clay.Color{15, 19, 24, 255}
FIELD_HOVER := clay.Color{18, 23, 28, 255}
CODE_PLATE := clay.Color{255, 255, 255, 16}
CARD_WELL := clay.Color{20, 26, 33, 255}
TOP_GLINT := clay.Color{255, 255, 255, 10}
AVATAR_RING := clay.Color{255, 255, 255, 32}
ACCENT_GLOW := clay.Color{114, 240, 176, 51}
ACCENT_HI := clay.Color{150, 245, 195, 255}

// Depth: the scrim behind a modal, the tint a raised surface drops,
// and the two edges a bevelled one is lit and shaded with.
OVERLAY := clay.Color{0, 0, 0, 115}
OVERLAY_STRONG := clay.Color{0, 0, 0, 230}
VIGNETTE := clay.Color{0, 0, 0, 128}
SHADOW_CARD := clay.Color{0, 0, 0, 208}
SHADOW_POPOVER := clay.Color{0, 0, 0, 102}
BEVEL_HI := clay.Color{255, 255, 255, 40}
BEVEL_LO := clay.Color{0, 0, 0, 90}

// Chrome that floats over a picture, so it cannot take its colors
// from the page behind it.
MEDIA_BACKDROP := clay.Color{3, 4, 4, 255}
MEDIA_CHIP_BG := clay.Color{0, 0, 0, 184}
MEDIA_CHIP_FG := clay.Color{255, 255, 255, 255}
MEDIA_CHIP_OUTLINE := clay.Color{255, 255, 255, 102}
MEDIA_CONTROL_BG := clay.Color{255, 255, 255, 34}
