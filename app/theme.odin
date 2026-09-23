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

import marmot "../marmot"

THEME_SOURCES := [][2]string {
	{"Dark", #load("../themes/dark.toml", string)},
	{"Light", #load("../themes/light.toml", string)},
	{"AMOLED", #load("../themes/amoled.toml", string)},
	{"Retro", #load("../themes/retro.toml", string)},
	{"Terminal", #load("../themes/terminal.toml", string)},
	{"Crayon", #load("../themes/crayon.toml", string)},
	{"Synthwave", #load("../themes/synthwave.toml", string)},
	{"Chalkboard", #load("../themes/chalkboard.toml", string)},
	{"Speakeasy", #load("../themes/speakeasy.toml", string)},
	{"Film Noir", #load("../themes/filmnoir.toml", string)},
	{"Brownstone", #load("../themes/brownstone.toml", string)},
	{"Nixie", #load("../themes/nixie.toml", string)},
	{"Metropolis", #load("../themes/metropolis.toml", string)},
	{"Industria", #load("../themes/industria.toml", string)},
	{"Aegean", #load("../themes/aegean.toml", string)},
	{"Par Avion", #load("../themes/paravion.toml", string)},
	{"Luna", #load("../themes/luna.toml", string)},
	{"Luna Dark", #load("../themes/lunadark.toml", string)},
}

// A pack is written as seeds plus overrides: anything a pack does not
// name is derived from what it does (derive_pack), so a new theme is a
// dozen lines rather than ninety. A pack that names a `base` inherits
// instead, which is what every built-in does.
Theme_Pack :: struct {
	source:                                                 string, // the toml it was parsed from, for sharing and editing
	name:                                                   string,
	mode:                                                   string, // lowercase key `base` refers to
	bg, panel, panel_2, rail, elevated, card_border:        clay.Color,
	status_bar, banner, canvas_top:                         clay.Color,
	text_hi, text_mid, text_lo, text_vlo:                   clay.Color,
	field, field_hover, field_border, hover, plate:         clay.Color,
	plate_inset, code_plate, card_well, divider, on_accent: clay.Color,
	elevated_border, border_2:                              clay.Color,
	danger, danger_soft, danger_border:                     clay.Color,
	warning, warning_soft, warning_border:                  clay.Color,
	// Depth: the overlay behind a modal, the four shadow tints, and the
	// two bevel edges a raised surface is lit and shaded with.
	overlay, overlay_strong, vignette:                      clay.Color,
	shadow_soft, shadow_card, shadow_popover, shadow_float: clay.Color,
	bevel_hi, bevel_lo, top_glint, avatar_ring:             clay.Color,
	// Media chrome: the chips and controls that float over a picture,
	// which cannot take their colors from the page behind them.
	media_backdrop, media_chip_bg, media_chip_fg:           clay.Color,
	media_chip_outline, media_control_bg:                   clay.Color,
	accent_base, accent_hi, accent_dim:                     [5]clay.Color,
	accent_surface, accent_glow:                            [5]clay.Color,
	// [style] structural metrics, the capability flags this renderer
	// honours, and the motion durations.
	r_scale, border_w, glow_r, shadow_y, bubble_r:          f32,
	hover_dur, transition_dur:                              f32,
	pixel_metrics, synth_grid, paper_doodles, scanlines:    bool,
	hard_shadow, focus_glow, bevel, outline_surfaces:       bool,
	selected_inverts_text, bracket_labels, motion_fast:     bool,
	font:                                                   string, // family name, "" = the default stack
	backdrop:                                               string, // named scene behind the conversation, "" = none
	custom:                                                 bool, // from <data-dir>/themes, so it can be deleted
	bg_2:                                                   clay.Color, // second stop of the page wash, a == 0 = flat
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
BACKDROP := "" // the named scene behind the conversation (decor.odin)
BG_2 := clay.Color{} // second stop of the page wash, a == 0 means flat
HARD_SHADOW := false // an offset solid shadow instead of a soft one
FOCUS_GLOW := false // a soft ring around the focused field
BEVEL := false // raised surfaces get a lit top and a shaded bottom
OUTLINE_SURFACES := false // every surface takes a hairline, not just cards
SELECTED_INVERTS_TEXT := false // the selected row flips its ink
BRACKET_LABELS := false // captions render as [LABEL]
MOTION_FAST := false // shorter, snappier transitions
THEME_FONT := "" // family the pack asks for, "" = the default stack

// Depth and motion geometry, in px and ms.
GLOW_R: f32 = 3
SHADOW_Y: f32 = 2
BUBBLE_R: f32 = 10
HOVER_DUR: f32 = 110
TRANSITION_DUR: f32 = 140

// The border a focused field takes. A glowing theme widens it into a
// ring in the accent's own glow tint; a flat one keeps the hairline.
focus_border :: proc(active: bool) -> clay.BorderElementConfig {
	if !active {
		return {}
	}
	if !FOCUS_GLOW {
		return {color = ACCENT, width = bw()}
	}
	w := u16(max(GLOW_R, 1))
	return {color = ACCENT_GLOW, width = {w, w, w, w, 0}}
}

// A raised surface on a bevelled theme is lit from the top: clay gives
// one color per element, so the lit edge is the whole border and the
// shading is left to the surface under it.
bevel_border :: proc() -> clay.BorderElementConfig {
	if !BEVEL {
		return {}
	}
	return {color = BEVEL_HI, width = {1, 1, 1, 0, 0}}
}

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
	return {
		r_scale = 1,
		border_w = 1,
		glow_r = 3,
		shadow_y = 2,
		bubble_r = 10,
		hover_dur = 110,
		transition_dur = 140,
	}
}

// ── Color math, for deriving what a pack leaves unsaid ───────────────

@(private = "file")
mix :: proc(a, b: clay.Color, t: f32) -> clay.Color {
	return {
		a.r + (b.r - a.r) * t,
		a.g + (b.g - a.g) * t,
		a.b + (b.b - a.b) * t,
		a.a + (b.a - a.a) * t,
	}
}

@(private = "file")
alpha :: proc(c: clay.Color, a: f32) -> clay.Color {
	return {c.r, c.g, c.b, a}
}

// Rec. 601 luma, enough to decide whether ink on this color should be
// black or white.
@(private = "file")
luma :: proc(c: clay.Color) -> f32 {
	return (c.r * 0.299 + c.g * 0.587 + c.b * 0.114) / 255
}

BLACK :: clay.Color{0, 0, 0, 255}
WHITE :: clay.Color{255, 255, 255, 255}

// Toward the page's own extreme: on a dark theme "up" is lighter, on a
// light one it is darker, so one derivation rule serves both.
@(private = "file")
lift :: proc(c: clay.Color, ink: clay.Color, t: f32) -> clay.Color {
	return mix(c, ink, t)
}

// Fill everything the pack did not name, from the few tokens it did.
// Seeds are `bg`, `text-hi`, `danger` and `accent-base`; every other
// token has a rule here, so a twelve-line pack renders completely.
//
//   bg ────► panel ─► elevated ─► hover      (steps toward the ink)
//   text-hi ─► text-mid ─► text-lo ─► text-vlo
//   accent-base ─► hi / dim / surface / glow
//
// `present` holds the keys the source actually set, so an explicit
// value always wins over its rule.
derive_pack :: proc(p: ^Theme_Pack, present: map[string]bool) {
	has :: proc(present: map[string]bool, key: string) -> bool {
		return present[key]
	}
	// The ink is whichever extreme the text sits at: this is what makes
	// one set of rules work for a light pack and a dark one.
	ink := p.text_hi
	if !has(present, "text-hi") {
		ink = luma(p.bg) > 0.5 ? BLACK : WHITE
		p.text_hi = ink
	}
	if !has(present, "text-mid") {p.text_mid = mix(p.text_hi, p.bg, 0.30)}
	if !has(present, "text-lo") {p.text_lo = mix(p.text_hi, p.bg, 0.50)}
	if !has(present, "text-vlo") {p.text_vlo = mix(p.text_hi, p.bg, 0.68)}

	// Surfaces step away from the page a little at a time.
	if !has(present, "panel") {p.panel = lift(p.bg, ink, 0.05)}
	if !has(present, "panel-2") {p.panel_2 = lift(p.bg, ink, 0.09)}
	if !has(present, "rail") {p.rail = lift(p.bg, luma(p.bg) > 0.5 ? WHITE : BLACK, 0.35)}
	if !has(present, "elevated") {p.elevated = lift(p.bg, ink, 0.07)}
	if !has(present, "status-bar") {p.status_bar = p.panel}
	if !has(present, "banner") {p.banner = p.panel}
	if !has(present, "canvas-top") {p.canvas_top = p.bg}
	if !has(present, "plate") {p.plate = lift(p.bg, ink, 0.06)}
	if !has(present, "plate-inset") {p.plate_inset = alpha(ink, 18)}
	if !has(present, "code-plate") {p.code_plate = alpha(ink, 16)}
	if !has(present, "card-well") {p.card_well = lift(p.bg, ink, 0.09)}
	if !has(present, "field") {p.field = lift(p.bg, ink, 0.04)}
	if !has(present, "field-hover") {p.field_hover = lift(p.bg, ink, 0.10)}
	if !has(present, "hover") {p.hover = alpha(ink, 20)}

	// Lines: one hairline tint, reused at three strengths.
	if !has(present, "divider") {p.divider = alpha(ink, 28)}
	if !has(present, "field-border") {p.field_border = alpha(ink, 40)}
	if !has(present, "card-border") {p.card_border = alpha(ink, 34)}
	if !has(present, "elevated-border") {p.elevated_border = p.card_border}
	if !has(present, "border-2") {p.border_2 = alpha(ink, 22)}
	if !has(present, "avatar-ring") {p.avatar_ring = alpha(ink, 32)}
	if !has(present, "top-glint") {p.top_glint = alpha(ink, 10)}

	// Accents. A pack that names only accent-base gets the other four
	// ramps for free.
	for i in 0 ..< 5 {
		base := p.accent_base[i]
		if !has(present, "accent-hi") {p.accent_hi[i] = mix(base, WHITE, 0.25)}
		if !has(present, "accent-dim") {p.accent_dim[i] = mix(base, BLACK, 0.30)}
		if !has(present, "accent-surface") {p.accent_surface[i] = mix(p.bg, base, 0.18)}
		if !has(present, "accent-glow") {p.accent_glow[i] = alpha(base, 51)}
	}
	if !has(present, "on-accent") {
		// Ink on the accent, picked for contrast rather than declared.
		p.on_accent = luma(p.accent_base[0]) > 0.6 ? BLACK : WHITE
	}

	// Status colors keep their hue and take their soft/border pair from
	// it, so a pack only ever names the solid one.
	if !has(present, "danger") {p.danger = {230, 80, 90, 255}}
	if !has(present, "danger-soft") {p.danger_soft = alpha(p.danger, 38)}
	if !has(present, "danger-border") {p.danger_border = alpha(p.danger, 110)}
	if !has(present, "warning") {p.warning = {235, 180, 70, 255}}
	if !has(present, "warning-soft") {p.warning_soft = alpha(p.warning, 38)}
	if !has(present, "warning-border") {p.warning_border = alpha(p.warning, 110)}

	// Depth. Shadows are the page's own dark, not pure black, so a
	// light theme does not get a bruise under every card.
	shade := luma(p.bg) > 0.5 ? mix(p.bg, BLACK, 0.55) : BLACK
	if !has(present, "overlay") {p.overlay = alpha(shade, 115)}
	if !has(present, "overlay-strong") {p.overlay_strong = alpha(shade, 230)}
	if !has(present, "vignette") {p.vignette = alpha(shade, 128)}
	if !has(present, "shadow-soft") {p.shadow_soft = alpha(shade, 160)}
	if !has(present, "shadow-card") {p.shadow_card = alpha(shade, 208)}
	if !has(present, "shadow-popover") {p.shadow_popover = alpha(shade, 102)}
	if !has(present, "shadow-float") {p.shadow_float = alpha(shade, 64)}
	if !has(present, "bevel-hi") {p.bevel_hi = alpha(WHITE, 40)}
	if !has(present, "bevel-lo") {p.bevel_lo = alpha(BLACK, 90)}

	// Media chrome floats over a picture, so it is fixed light-on-dark
	// whatever the page does.
	if !has(present, "media-backdrop") {p.media_backdrop = mix(p.bg, BLACK, 0.5)}
	if !has(present, "media-chip-bg") {p.media_chip_bg = alpha(BLACK, 184)}
	if !has(present, "media-chip-fg") {p.media_chip_fg = WHITE}
	if !has(present, "media-chip-outline") {p.media_chip_outline = alpha(WHITE, 102)}
	if !has(present, "media-control-bg") {p.media_control_bg = alpha(WHITE, 34)}
}

// ── Sharing ─────────────────────────────────────────────────────────
//
// A theme travels as one custom event into a group: the toml is the
// content, the tags name it. The kind and tag shape are NIP-33
// addressable, so the same payload publishes to public relays
// unchanged if that export ever lands.
//
//   kind 30078, tags [["d","theme:<slug>"],["title","<name>"]]
//
// Anything arriving that way is untrusted: it is parsed, validated and
// shown as an offer, never applied on its own.
THEME_EVENT_KIND :: 30078
THEME_D_PREFIX :: "theme:"

// A pack's toml is bounded because it is hand-written text; a bigger
// payload is not a theme and is dropped before parsing.
THEME_MAX_BYTES :: 16 * 1024

// Filename- and key-safe form of a theme name: lowercase, letters and
// digits only. "" when nothing survives, which rejects the pack.
theme_slug :: proc(name: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for r in name {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			strings.write_rune(&b, r)
		case r >= 'A' && r <= 'Z':
			strings.write_rune(&b, r + 32)
		}
		if strings.builder_len(b) >= 24 {
			break
		}
	}
	return strings.to_string(b)
}

// Validate an incoming pack: size, a usable name, and at least the two
// seeds a theme cannot be derived without. Returns the display name,
// or "" when the payload is not a theme worth offering.
theme_offer_name :: proc(toml: string) -> string {
	if len(toml) == 0 || len(toml) > THEME_MAX_BYTES {
		return ""
	}
	name := toml_str_key(toml, "name")
	if len(theme_slug(name, context.temp_allocator)) == 0 {
		return ""
	}
	// bg is the seed every derivation rule starts from; without it the
	// pack would render as the default metrics over nothing.
	if !strings.contains(toml, "bg =") && !strings.contains(toml, "bg=") {
		return ""
	}
	return name
}

// Adopt a received pack: write it under the data dir so it survives a
// restart, parse it, and return its index in theme_packs (-1 on
// failure). A slug already taken is overwritten, which is what makes
// re-sharing an edited theme land.
adopt_theme :: proc(toml: string) -> int {
	name := theme_offer_name(toml)
	if len(name) == 0 {
		return -1
	}
	slug := theme_slug(name)

	dir := fmt.tprintf("%s/themes", data_home)
	os.make_directory(dir)
	path := fmt.tprintf("%s/%s.toml", dir, slug)
	if write_err := os.write_entire_file(path, transmute([]u8)toml); write_err != nil {
		delete(slug)
		return -1
	}

	pack := parse_theme(
		strings.clone(name),
		slug,
		strings.clone(toml),
		resolve_base(toml_str_key(toml, "base")),
	)
	pack.source = strings.clone(toml)
	pack.custom = true
	for existing, i in theme_packs {
		if existing.mode == slug {
			theme_packs[i] = pack
			return i
		}
	}
	append(&theme_packs, pack)
	return len(theme_packs) - 1
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

	scalars := map[string]^clay.Color {
		"bg"                 = &pack.bg,
		"bg-2"               = &pack.bg_2,
		"panel"              = &pack.panel,
		"panel-2"            = &pack.panel_2,
		"rail"               = &pack.rail,
		"elevated"           = &pack.elevated,
		"card-border"        = &pack.card_border,
		"elevated-border"    = &pack.elevated_border,
		"border-2"           = &pack.border_2,
		"status-bar"         = &pack.status_bar,
		"banner"             = &pack.banner,
		"canvas-top"         = &pack.canvas_top,
		"text-hi"            = &pack.text_hi,
		"text-mid"           = &pack.text_mid,
		"text-lo"            = &pack.text_lo,
		"text-vlo"           = &pack.text_vlo,
		"field"              = &pack.field,
		"field-hover"        = &pack.field_hover,
		"field-border"       = &pack.field_border,
		"hover"              = &pack.hover,
		"plate"              = &pack.plate,
		"plate-inset"        = &pack.plate_inset,
		"code-plate"         = &pack.code_plate,
		"card-well"          = &pack.card_well,
		"divider"            = &pack.divider,
		"on-accent"          = &pack.on_accent,
		"danger"             = &pack.danger,
		"danger-soft"        = &pack.danger_soft,
		"danger-border"      = &pack.danger_border,
		"warning"            = &pack.warning,
		"warning-soft"       = &pack.warning_soft,
		"warning-border"     = &pack.warning_border,
		"overlay"            = &pack.overlay,
		"overlay-strong"     = &pack.overlay_strong,
		"vignette"           = &pack.vignette,
		"shadow-soft"        = &pack.shadow_soft,
		"shadow-card"        = &pack.shadow_card,
		"shadow-popover"     = &pack.shadow_popover,
		"shadow-float"       = &pack.shadow_float,
		"bevel-hi"           = &pack.bevel_hi,
		"bevel-lo"           = &pack.bevel_lo,
		"top-glint"          = &pack.top_glint,
		"avatar-ring"        = &pack.avatar_ring,
		"media-backdrop"     = &pack.media_backdrop,
		"media-chip-bg"      = &pack.media_chip_bg,
		"media-chip-fg"      = &pack.media_chip_fg,
		"media-chip-outline" = &pack.media_chip_outline,
		"media-control-bg"   = &pack.media_control_bg,
	}
	defer delete(scalars)
	tables := map[string]^[5]clay.Color {
		"accent-base"    = &pack.accent_base,
		"accent-hi"      = &pack.accent_hi,
		"accent-dim"     = &pack.accent_dim,
		"accent-surface" = &pack.accent_surface,
		"accent-glow"    = &pack.accent_glow,
	}
	defer delete(tables)
	floats := map[string]^f32 {
		"r-scale"        = &pack.r_scale,
		"border-w"       = &pack.border_w,
		"glow-r"         = &pack.glow_r,
		"shadow-y"       = &pack.shadow_y,
		"bubble-r"       = &pack.bubble_r,
		"hover-dur"      = &pack.hover_dur,
		"transition-dur" = &pack.transition_dur,
	}
	defer delete(floats)
	bools := map[string]^bool {
		"pixel-metrics"         = &pack.pixel_metrics,
		"synth-grid"            = &pack.synth_grid,
		"paper-doodles"         = &pack.paper_doodles,
		"scanlines"             = &pack.scanlines,
		"hard-shadow"           = &pack.hard_shadow,
		"focus-glow"            = &pack.focus_glow,
		"bevel"                 = &pack.bevel,
		"outline-surfaces"      = &pack.outline_surfaces,
		"selected-inverts-text" = &pack.selected_inverts_text,
		"bracket-labels"        = &pack.bracket_labels,
		"motion-fast"           = &pack.motion_fast,
	}
	defer delete(bools)

	// Which keys the source actually set; everything else is derived.
	present := make(map[string]bool, allocator = context.temp_allocator)

	table: ^[5]clay.Color
	table_index := 0

	lines := strings.split_lines(source, context.temp_allocator)
	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 ||
		   trimmed[0] == '#' ||
		   trimmed[0] == '[' && table == nil && !strings.contains(trimmed, "\"") {
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
			present[key] = true
			continue
		}
		if entry, ok := scalars[key]; ok {
			entry^ = parse_hex_color(value)
			present[key] = true
			continue
		}
		if entry, ok := floats[key]; ok {
			if v, float_ok := strconv.parse_f32(value); float_ok {
				entry^ = v
				present[key] = true
			}
			continue
		}
		if entry, ok := bools[key]; ok {
			entry^ = value == "true"
			present[key] = true
			continue
		}
		if key == "font" {
			pack.font = strings.clone(strings.trim(value, "\""))
		}
		if key == "backdrop" {
			pack.backdrop = strings.clone(strings.trim(value, "\""))
		}
	}

	// A pack that names a base inherits the rest from it; one that
	// names none derives, which is what lets a theme be a dozen lines.
	if len(toml_str_key(source, "base")) == 0 {
		derive_pack(&pack, present)
	}
	return pack
}

// The active theme's index and pack, clamped. Layout reads the pack
// every frame while the index is written from menus, adoption and
// deletion, so an index that outlives its slot must not panic.
active_theme :: proc(ui: ^Ui_State) -> int {
	return clamp(ui.theme, 0, max(len(theme_packs) - 1, 0))
}

active_pack :: proc(ui: ^Ui_State) -> Theme_Pack {
	if len(theme_packs) == 0 {
		return default_pack()
	}
	return theme_packs[active_theme(ui)]
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
	// Idempotent: a second call reloads rather than appending a second
	// copy of every pack.
	clear(&theme_packs)
	for source in THEME_SOURCES {
		// The mode is the key `base` refers to and the name a user file
		// must not collide with, so it stays one lowercase word.
		mode, _ := strings.replace_all(strings.to_lower(source[0]), " ", "")
		base := resolve_base(toml_str_key(source[1], "base"))
		pack := parse_theme(source[0], mode, source[1], base)
		pack.source = source[1]
		append(&theme_packs, pack)
	}

	load_system_theme()
	dir := fmt.tprintf("%s/themes", data_home)
	files, read_err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if read_err != nil {
		return
	}
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool {return a.name < b.name})

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
		pack := parse_theme(strings.clone(name), mode, text, base)
		pack.source = strings.clone(text)
		pack.custom = true
		append(&theme_packs, pack)
	}
}

// Send the active pack into the picked chat as a theme event. The
// recipient sees an offer card, never an applied theme.
share_theme :: proc(ui: ^Ui_State, client: ^marmot.Client, dest: int) {
	if client == nil || dest < 0 || dest >= len(ui.chats) {
		return
	}
	pack := theme_packs[clamp(ui.theme, 0, len(theme_packs) - 1)]
	if len(pack.source) == 0 {
		ui.client_status = strings.clone(tr("Couldn't share the theme. Please try again."))
		return
	}

	// Two tag rows: the addressable id, and the name a client shows
	// without parsing the body.
	d_values := [2]cstring {
		"d",
		strings.clone_to_cstring(
			fmt.tprintf("%s%s", THEME_D_PREFIX, pack.mode),
			context.temp_allocator,
		),
	}
	title_values := [2]cstring {
		"title",
		strings.clone_to_cstring(pack.name, context.temp_allocator),
	}
	tags := [2]marmot.Message_Tag {
		{values = raw_data(d_values[:]), values_len = 2},
		{values = raw_data(title_values[:]), values_len = 2},
	}

	summary: ^marmot.Send_Summary
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	group := strings.clone_to_cstring(ui.chats[dest].group_id, context.temp_allocator)
	content := strings.clone_to_cstring(pack.source, context.temp_allocator)
	if marmot.send_custom_event(
		   client,
		   account,
		   group,
		   THEME_EVENT_KIND,
		   raw_data(tags[:]),
		   2,
		   content,
		   &summary,
	   ) !=
	   .OK {
		ui.client_status = fmt.aprintf("Couldn't share the theme. %s", marmot.last_error())
		return
	}
	marmot.send_summary_free(summary)
	toast(ui, fmt.tprintf("Theme shared with %s", ui.chats[dest].title))
}

// The strip a shared theme shows: the real derived pack, so the offer
// previews what taking it would do. Parsed once when the row loads,
// never in layout.
theme_swatches :: proc(name: string, toml: string) -> [THEME_SWATCHES]clay.Color {
	pack := parse_theme(name, "preview", toml, default_pack())
	return {
		pack.bg,
		pack.panel,
		pack.text_hi,
		pack.accent_base[0],
		pack.accent_base[2],
		pack.danger,
	}
}

// Remove a theme this device owns: its file, then its slot. Built-ins
// are compiled in and cannot go. The caller lands on the first theme,
// which is always a built-in.
delete_theme :: proc(ui: ^Ui_State, index: int) {
	if index < 0 || index >= len(theme_packs) || !theme_packs[index].custom {
		return
	}
	path := fmt.tprintf("%s/themes/%s.toml", data_home, theme_packs[index].mode)
	if err := os.remove(path); err != nil {
		ui.client_status = fmt.aprintf(
			"Couldn't delete %s. Please try again.",
			theme_packs[index].name,
		)
		return
	}

	ordered_remove(&theme_packs, index)
	ui.theme = 0
	apply_theme(ui.theme, ui.accent)
	save_settings(ui)
	toast(ui, "Theme deleted")
}
