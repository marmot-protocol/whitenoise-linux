package main

import "core:c"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:text/edit"
import "core:unicode/utf8"
import "core:sync"
import "core:thread"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

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

// On-demand Twemoji tile cache for arbitrary emoji (reaction chips):
// emoji → texture from vendor/twemoji (staged by build.sh), keyed by
// the twemoji filename convention (hex codepoints joined by '-', VS16
// dropped; retried with it when the plain name misses). nil = no tile,
// caller falls back to the raw text glyph.
twemoji_dir :: proc() -> string {
	dir, _ := filepath.join({res_dir(), "twemoji"}, context.temp_allocator)
	return dir
}
emoji_tex_cache: map[string]^rl.Texture2D

// Picker catalog, loaded from vendor/emoji-catalog.tsv (staged by
// build.sh): base emoji plus a lowercase search name.
Emoji_Entry :: struct {
	emoji: string,
	name:  string,
}
emoji_catalog: [dynamic]Emoji_Entry

load_emoji_catalog :: proc() {
	catalog, _ := filepath.join({res_dir(), "emoji-catalog.tsv"}, context.temp_allocator)
	data, err := os.read_entire_file(catalog, context.allocator)
	if err != nil {
		fmt.eprintfln("emoji: catalog missing: %v", err)
		return
	}
	for line in strings.split_lines(string(data)) {
		tab := strings.index_byte(line, '\t')
		if tab <= 0 {
			continue
		}
		append(&emoji_catalog, Emoji_Entry{emoji = line[:tab], name = strings.to_lower(line[tab + 1:])})
	}
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

	plain := strings.builder_make(context.temp_allocator)
	full := strings.builder_make(context.temp_allocator)
	for r in emoji {
		if strings.builder_len(full) > 0 {
			strings.write_byte(&full, '-')
		}
		fmt.sbprintf(&full, "%x", i32(r))
		if r == 0xFE0F {
			continue
		}
		if strings.builder_len(plain) > 0 {
			strings.write_byte(&plain, '-')
		}
		fmt.sbprintf(&plain, "%x", i32(r))
	}

	tex: ^rl.Texture2D
	candidates := [2]string{strings.to_string(plain), strings.to_string(full)}
	for candidate in candidates {
		path := fmt.tprintf("%s/%s.png", twemoji_dir(), candidate)
		if !os.exists(path) {
			continue
		}
		img := rl.LoadImage(strings.clone_to_cstring(path, context.temp_allocator))
		if img.data == nil {
			continue
		}
		tex = new(rl.Texture2D)
		tex^ = rl.LoadTextureFromImage(img)
		rl.UnloadImage(img)
		rl.SetTextureFilter(tex^, .BILINEAR)
		break
	}
	emoji_tex_cache[strings.clone(emoji)] = tex
	return tex
}

PAGE_ICONS := [Page]string{
	.Chats    = ICON_CHATS,
	.Contacts = ICON_PEOPLE,
	.Archived = ICON_ARCHIVE,
	.Settings = ICON_SETTINGS,
	.Profile  = ICON_PROFILE,
}

// Palette globals, filled from the active Theme_Pack (the slint
// themes/*.toml packs, embedded and parsed in theme.odin).
ACCENT_NAMES := [5]string{"Mint", "Ocean", "Berry", "Coral", "Lavender"}

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

