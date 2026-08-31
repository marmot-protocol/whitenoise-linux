#+feature dynamic-literals
// Theme engine: the slint app's themes/*.toml packs, embedded at
// compile time and parsed into the same color model, so both UIs draw
// from one source of truth.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"

THEME_SOURCES := [][2]string{
	{"Dark", #load("../themes/dark.toml", string)},
	{"Light", #load("../themes/light.toml", string)},
	{"AMOLED", #load("../themes/amoled.toml", string)},
	{"Retro", #load("../themes/retro.toml", string)},
	{"Terminal", #load("../themes/terminal.toml", string)},
	{"Crayon", #load("../themes/crayon.toml", string)},
	{"Synthwave", #load("../themes/synthwave.toml", string)},
	{"Chalkboard", #load("../themes/chalkboard.toml", string)},
}

Theme_Pack :: struct {
	name:                                                 string,
	mode:                                                 string, // lowercase key `base` refers to
	bg, panel, rail, elevated, card_border, status_bar:   clay.Color,
	text_hi, text_mid, text_lo:                           clay.Color,
	field, field_border, hover, plate, divider, on_accent: clay.Color,
	elevated_border, border_2:                            clay.Color,
	danger:                                               clay.Color,
	accent_base, accent_hi, accent_dim, accent_surface:   [5]clay.Color,
	// [style] structural metrics + the capability flags this renderer
	// honours (the slint engine's ThemeStyle, minimally mirrored).
	r_scale, border_w:                                    f32,
	pixel_metrics, synth_grid, paper_doodles, scanlines:  bool,
}

theme_packs: [dynamic]Theme_Pack

// Structural metrics of the active pack, set by apply_theme. rr/bw
// route every corner radius and hairline border through them so retro
// can square corners and thicken borders without per-site branches.
R_SCALE: f32 = 1
BORDER_W: u16 = 1
SYNTH_GRID := false // the synthwave chat backdrop, a capability flag
PAPER_DECOR := false // drifting motes and hand-drawn boiling borders
SCANLINES := false // CRT scanlines and roll behind the conversation

rr :: proc(radius: f32) -> clay.CornerRadius {
	return clay.CornerRadiusAll(radius * R_SCALE)
}

bw :: proc() -> clay.BorderWidth {
	return {BORDER_W, BORDER_W, BORDER_W, BORDER_W, 0}
}

parse_hex_color :: proc(value: string) -> clay.Color {
	hex := strings.trim_prefix(strings.trim(value, "\" "), "#")
	channel :: proc(s: string) -> f32 {
		v, _ := strconv.parse_int(s, 16)
		return f32(v)
	}
	if len(hex) < 6 {
		return {255, 0, 255, 255}
	}
	color := clay.Color{channel(hex[0:2]), channel(hex[2:4]), channel(hex[4:6]), 255}
	if len(hex) >= 8 {
		color.a = channel(hex[6:8])
	}
	return color
}

// A pack with the neutral structural metrics, the start for any theme
// that names no base.
default_pack :: proc() -> Theme_Pack {
	return {r_scale = 1, border_w = 1}
}

// Top-level string key lookup (`name`, `base`), quotes stripped.
toml_str_key :: proc(source: string, key: string) -> string {
	it := source
	for line in strings.split_lines_iterator(&it) {
		trimmed := strings.trim_space(line)
		eq := strings.index(trimmed, "=")
		if eq < 0 || strings.trim_space(trimmed[:eq]) != key {
			continue
		}
		return strings.trim(strings.trim_space(trimmed[eq + 1:]), "\"")
	}
	return ""
}

// Flat parser for the theme toml schema: `key = "#hex"` scalars,
// `key = [ "#hex", ... ]` five-entry accent tables, plus the [style]
// numbers/bools this renderer honours. Starts from `base` so a user
// theme with `base = "dark"` only lists its overrides.
parse_theme :: proc(name: string, mode: string, source: string, base: Theme_Pack) -> Theme_Pack {
	pack := base
	pack.name = name
	pack.mode = mode

	scalars := map[string]^clay.Color{
		"bg" = &pack.bg,
		"panel" = &pack.panel,
		"rail" = &pack.rail,
		"elevated" = &pack.elevated,
		"card-border" = &pack.card_border,
		"elevated-border" = &pack.elevated_border,
		"border-2" = &pack.border_2,
		"status-bar" = &pack.status_bar,
		"text-hi" = &pack.text_hi,
		"text-mid" = &pack.text_mid,
		"text-lo" = &pack.text_lo,
		"field" = &pack.field,
		"field-border" = &pack.field_border,
		"hover" = &pack.hover,
		"plate" = &pack.plate,
		"divider" = &pack.divider,
		"on-accent" = &pack.on_accent,
		"danger" = &pack.danger,
	}
	defer delete(scalars)
	tables := map[string]^[5]clay.Color{
		"accent-base" = &pack.accent_base,
		"accent-hi" = &pack.accent_hi,
		"accent-dim" = &pack.accent_dim,
		"accent-surface" = &pack.accent_surface,
	}
	defer delete(tables)
	floats := map[string]^f32{
		"r-scale" = &pack.r_scale,
		"border-w" = &pack.border_w,
	}
	defer delete(floats)
	bools := map[string]^bool{
		"pixel-metrics" = &pack.pixel_metrics,
		"synth-grid" = &pack.synth_grid,
		"paper-doodles" = &pack.paper_doodles,
		"scanlines" = &pack.scanlines,
	}
	defer delete(bools)

	table: ^[5]clay.Color
	table_index := 0

	lines := strings.split_lines(source, context.temp_allocator)
	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' || trimmed[0] == '[' && table == nil && !strings.contains(trimmed, "\"") {
			// section headers like [colors]/[style] fall through here
			if table == nil {
				continue
			}
		}

		if table != nil {
			if strings.has_prefix(trimmed, "]") {
				table = nil
				continue
			}
			if strings.contains(trimmed, "#") && table_index < 5 {
				table[table_index] = parse_hex_color(strings.trim_suffix(trimmed, ","))
				table_index += 1
			}
			continue
		}

		eq := strings.index(trimmed, "=")
		if eq < 0 {
			continue
		}
		key := strings.trim_space(trimmed[:eq])
		value := strings.trim_space(trimmed[eq + 1:])

		if entry, ok := tables[key]; ok {
			table = entry
			table_index = 0
			continue
		}
		if entry, ok := scalars[key]; ok {
			entry^ = parse_hex_color(value)
			continue
		}
		if entry, ok := floats[key]; ok {
			if v, float_ok := strconv.parse_f32(value); float_ok {
				entry^ = v
			}
			continue
		}
		if entry, ok := bools[key]; ok {
			entry^ = value == "true"
		}
	}
	return pack
}

// The pack `base` names, or the neutral defaults when it names none
// (built-ins are complete definitions and name none).
resolve_base :: proc(base: string) -> Theme_Pack {
	for pack in theme_packs {
		if pack.mode == base {
			return pack
		}
	}
	return default_pack()
}

// Built-ins first (index = the settings' historical theme int), then
// any user themes from <data_home>/themes/*.toml, sorted by filename
// so ids stay stable across restarts. A user file may set
// `base = "<mode>"` to inherit an earlier pack and override a few
// keys. Bad files degrade to a default-metric pack, never block boot.
load_themes :: proc() {
	for source in THEME_SOURCES {
		mode := strings.to_lower(source[0])
		base := resolve_base(toml_str_key(source[1], "base"))
		append(&theme_packs, parse_theme(source[0], mode, source[1], base))
	}

	dir := fmt.tprintf("%s/themes", data_home)
	files, read_err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if read_err != nil {
		return
	}
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool { return a.name < b.name })

	for file in files {
		if file.type == .Directory || !strings.has_suffix(file.name, ".toml") {
			continue
		}
		mode := strings.clone(strings.trim_suffix(file.name, ".toml"))
		if collides := resolve_base(mode); collides.mode == mode {
			continue // mode name already taken by a built-in or earlier file
		}
		source, file_err := os.read_entire_file(file.fullpath, context.temp_allocator)
		if file_err != nil {
			continue
		}
		text := string(source)
		name := toml_str_key(text, "name")
		if len(name) == 0 {
			name = mode
		}
		base := resolve_base(toml_str_key(text, "base"))
		append(&theme_packs, parse_theme(strings.clone(name), mode, text, base))
	}
}
