package main

import "core:encoding/hex"
import "core:encoding/json"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import clay "../vendor/clay/bindings/odin/clay-odin"

@(private)
Profile_Style :: struct {
	refs: [2]string,
	done: [2]bool,
	colors: [3]clay.Color, // background, text, primary; alpha zero means no theme
	shape: string,
	background: string,
	tile: bool,
	fonts: [2]string,
}

@(private = "file")
profile_styles: map[string]^Profile_Style

@(private)
Profile_Style_Part :: enum { Avatar, All }

@(private = "file")
profile_style_ref :: proc(author: string, kind: u32) -> string {
	data: [42]u8
	data[0], data[1], data[2], data[3] = 0, 0, 2, 32
	_, valid := hex.decode_into_buffer(transmute([]u8)author, data[4:36])
	if len(author) != 64 || !valid { return "" }
	data[36], data[37] = 3, 4
	for i in 0 ..< 4 { data[38 + i] = u8(kind >> u32(24 - i * 8)) }
	return bech32_encode("naddr", data[:])
}

@(private)
profile_style :: proc(author: string, part := Profile_Style_Part.All) -> Profile_Style {
	if len(author) != 64 { return {} }
	style, found := profile_styles[author]
	if !found {
		style = new(Profile_Style)
		style.refs = {profile_style_ref(author, 16767), profile_style_ref(author, 0)}
		profile_styles[strings.clone(author)] = style
	}
	for ref, i in style.refs {
		if part == .Avatar && i == 0 { continue }
		if style.done[i] || ref == "" { continue }
		card := nev_lookup(ref, ref)
		if !card.done { continue }
		style.done[i] = true
		if i == 0 {
			theme := profile_theme_parse(card.raw)
			style.colors, style.background, style.tile, style.fonts = theme.colors, theme.background, theme.tile, theme.fonts
		}
		if i == 1 { style.shape = profile_shape_parse(card.content) }
	}
	return style^
}

// Require the three color tags before accepting optional fonts or media.
@(private)
profile_theme_parse :: proc(raw: string) -> (theme: Profile_Style) {
	colors := &theme.colors
	value, err := json.parse(transmute([]u8)raw, allocator = context.temp_allocator)
	if err != nil { return }
	defer json.destroy_value(value, allocator = context.temp_allocator)
	event, ok := value.(json.Object)
	if !ok { return }
	kind, _ := event["kind"].(json.Float)
	if kind != 16767 { return }
	tags, _ := event["tags"].(json.Array)
	seen: [3]bool
	for tag in tags {
		parts, ok := tag.(json.Array)
		if !ok || len(parts) < 3 { continue }
		name, _ := parts[0].(json.String)
		if name != "c" { continue }
		role, _ := parts[2].(json.String)
		index := -1
		for r, i in ([3]string{"background", "text", "primary"}) {
			if string(role) == r { index = i; break }
		}
		if index < 0 { continue }
		color, _ := parts[1].(json.String)
		if seen[index] || len(color) != 7 || color[0] != '#' { return {} }
		rgb: [3]u8
		_, valid := hex.decode_into_buffer(transmute([]u8)string(color[1:]), rgb[:])
		if !valid { return {} }
		colors[index] = {f32(rgb[0]), f32(rgb[1]), f32(rgb[2]), 255}
		seen[index] = true
	}
	if !seen[0] || !seen[1] || !seen[2] { return {} }
	for tag in tags {
		parts, ok := tag.(json.Array)
		if !ok || len(parts) < 2 { continue }
		name, _ := parts[0].(json.String)
		if name == "f" && len(parts) >= 3 {
			role := json.String("body")
			if len(parts) >= 4 { role, _ = parts[3].(json.String) }
			if role != "body" && role != "title" { continue }
			index := role == "title" ? 1 : 0
			url, _ := parts[2].(json.String)
			if theme.fonts[index] == "" && profile_asset_url(string(url)) { theme.fonts[index] = strings.clone(string(url)) }
		}
		if name != "bg" || theme.background != "" { continue }
		url, mode, mime := "", "cover", ""
		for part in parts[1:] {
			value, _ := part.(json.String)
			entry := string(value)
			if strings.has_prefix(entry, "url ") { url = entry[4:] }
			if strings.has_prefix(entry, "mode ") { mode = entry[5:] }
			if strings.has_prefix(entry, "m ") { mime = entry[2:] }
		}
		if profile_asset_url(url) && (mode == "cover" || mode == "tile") && !strings.has_prefix(mime, "video/") {
			theme.background, theme.tile = strings.clone(url), mode == "tile"
		}
	}
	return
}

@(private)
profile_shape_parse :: proc(content: string) -> string {
	value, err := json.parse(transmute([]u8)content, allocator = context.temp_allocator)
	if err != nil { return "" }
	defer json.destroy_value(value, allocator = context.temp_allocator)
	meta, ok := value.(json.Object)
	if !ok { return "" }
	shape, _ := meta["shape"].(json.String)
	text := string(shape)
	if len(text) == 0 || len(text) > 80 || !utf8.valid_string(text) || next_grapheme(text, 0) != len(text) { return "" }
	r, _ := utf8.decode_rune_in_string(text)
	if !unicode.is_emoji_extended_pictographic(r) && !unicode.is_regional_indicator(r) && !strings.contains(text, "\u20E3") { return "" }
	return strings.clone(text)
}

// Clay copies colors during layout. Restore these before laying out another pane.
@(private)
PROFILE_COLOR_SLOTS := [?]^clay.Color{&BG, &TEXT, &TEXT_DIM, &TEXT_LO, &ROW_BG, &FIELD_BORDER, &DIVIDER, &ACCENT, &ON_ACCENT, &HOVER, &PLATE, &CARD_BORDER, &CARD}

@(private)
profile_palette :: proc(colors: [len(PROFILE_COLOR_SLOTS)]clay.Color) -> (old: [len(PROFILE_COLOR_SLOTS)]clay.Color) {
	for slot, i in PROFILE_COLOR_SLOTS { old[i] = slot^; slot^ = colors[i] }
	return
}

@(private)
profile_colors :: proc(style: Profile_Style) -> (colors: [len(PROFILE_COLOR_SLOTS)]clay.Color) {
	if style.colors[0].a == 0 {
		for slot, i in PROFILE_COLOR_SLOTS { colors[i] = slot^ }
		return
	}
	bg, text, accent := style.colors[0], style.colors[1], style.colors[2]
	// Color arrays support component-wise arithmetic, including their opaque alpha.
	dim := text * 0.7 + bg * 0.3
	low := text * 0.5 + bg * 0.5
	field := bg * 0.94 + text * 0.06
	border := bg * 0.8 + text * 0.2
	on_accent := accent.r * 0.299 + accent.g * 0.587 + accent.b * 0.114 > 150 ? BLACK : WHITE
	return {bg, text, dim, low, field, border, border, accent, on_accent, bg * 0.88 + text * 0.12, field, border, field}
}

@(private)
profile_asset_url :: proc(url: string) -> bool {
	return len(url) <= 4096 && (strings.has_prefix(url, "https://") || strings.has_prefix(url, "http://")) && !strings.contains_any(url, "\r\n\x00")
}
