// Theme toml parser tests.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
theme_hex_color :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_hex_color("\"#0d0d28ff\""), [4]f32{13, 13, 40, 255})
	testing.expect_value(t, parse_hex_color("\"#ff5a5a30\""), [4]f32{255, 90, 90, 48})
	testing.expect_value(t, parse_hex_color("\"#123456\""), [4]f32{18, 52, 86, 255})
	testing.expect_value(t, parse_hex_color("\"oops\""), [4]f32{255, 0, 255, 255})
}

TEST_THEME :: `name = "Test"
accent-name-1 = "Coin gold"
accent-name-2 = "Pixel blue"
accent-name-3 = "Arcade pink"
accent-name-4 = "Sunset orange"
accent-name-5 = "Orchid"

[colors]
bg = "#010203ff"
text-hi = "#f4efddff"
accent-base = [
    "#ffd93dff",
    "#6b8cffff",
    "#ff6b9dff",
    "#ff8c42ff",
    "#c9a0dcff",
]

[style]
pixel-metrics = true
synth-grid = false
r-scale = 0.0
border-w = 2.0
`

@(test)
theme_parse :: proc(t: ^testing.T) {
	pack := parse_theme("Test", "test", TEST_THEME, default_pack())
	defer {for label in pack.accent_names {delete(label)}}
	testing.expect_value(t, pack.bg, [4]f32{1, 2, 3, 255})
	testing.expect_value(t, pack.text_hi, [4]f32{244, 239, 221, 255})
	testing.expect_value(t, pack.accent_base[1], [4]f32{107, 140, 255, 255})
	testing.expect_value(t, pack.accent_base[4], [4]f32{201, 160, 220, 255})
	testing.expect_value(
		t,
		pack.accent_names,
		[5]string{"Coin gold", "Pixel blue", "Arcade pink", "Sunset orange", "Orchid"},
	)
	testing.expect_value(t, pack.r_scale, f32(0))
	testing.expect_value(t, pack.border_w, f32(2))
	testing.expect(t, pack.pixel_metrics)
	testing.expect(t, !pack.synth_grid)
}

@(test)
theme_amoled_monochrome :: proc(t: ^testing.T) {
	pack := parse_theme("AMOLED", "amoled", #load("../themes/amoled.toml", string), default_pack())
	defer delete(pack.font)

	for descriptor, token in THEME_TOKENS {
		entry := theme_token_pointer(&pack, token)
		#partial switch descriptor.kind {
		case .Color:
			color := (cast(^[4]f32)entry)^
			#partial switch token {
			case .Sidebar_Text, .Card_Text, .Header_Text, .Popover_Text:
				if color.a == 0 {continue} 	// Use the regular foreground.
			}
			testing.expect(t, color == BLACK || color == WHITE)
		case .Colors, .Ink:
			for color in (cast(^[5][4]f32)entry)^ {
				testing.expect(t, color == BLACK || color == WHITE)
			}
		}
	}
	for fill, slot in pack.accent_base {
		testing.expect(t, theme_test_contrast(pack.on_accent[slot], fill) >= 4.5)
	}
}

@(test)
theme_inherit :: proc(t: ^testing.T) {
	base := parse_theme("Base", "base", TEST_THEME, default_pack())
	defer {for label in base.accent_names {delete(label)}}
	child := parse_theme(
		"Child",
		"child",
		"base = \"base\"\naccent-name-3 = \"Rose\"\n\n[colors]\nbg = \"#050607ff\"\n",
		base,
	)
	defer delete(child.accent_names[2])

	// Overridden key takes; everything else rides the base.
	testing.expect_value(t, child.bg, [4]f32{5, 6, 7, 255})
	testing.expect_value(t, child.text_hi, base.text_hi)
	testing.expect_value(t, child.accent_base[2], base.accent_base[2])
	testing.expect_value(
		t,
		child.accent_names,
		[5]string{"Coin gold", "Pixel blue", "Rose", "Sunset orange", "Orchid"},
	)
	testing.expect_value(t, base.accent_names[2], "Arcade pink")
	testing.expect_value(t, child.r_scale, f32(0))
	testing.expect(t, child.pixel_metrics)
	testing.expect_value(t, child.name, "Child")
}

@(test)
theme_str_key :: proc(t: ^testing.T) {
	testing.expect_value(t, toml_str_key(TEST_THEME, "name"), "Test")
	testing.expect_value(t, toml_str_key(TEST_THEME, "base"), "")
	testing.expect_value(t, toml_str_key("base = \"dark\"\n", "base"), "dark")
}

@(test)
theme_tokens_and_hints :: proc(t: ^testing.T) {
	pack := parse_theme(
		"Typed",
		"typed",
		`
[colors]
bg = "#01020380"
bg-2 = "#11223344"
overlay = "#12345678"
banner = "#abcdef90"
shadow-float = "#10203040"
media-chip-outline = "#30405060"
accent-hi = [
    "#11223344",
    "#22334455",
    "#33445566",
    "#44556677",
    "#55667788",
]
[style]
r-scale = 0.75
glow-r = 7
shadow-y = 4
bubble-r = 12
hover-dur = 80
transition-dur = 160
transition-dur = not-a-number
pixel-metrics = true
synth-grid = true
paper-doodles = true
scanlines = true
hard-shadow = true
focus-glow = true
bevel = true
outline-surfaces = true
selected-inverts-text = true
bracket-labels = true
motion-fast = true
font = "Example Font"
backdrop = "waves"
`,
		default_pack(),
	)
	defer {delete(pack.font); delete(pack.backdrop)}
	testing.expect_value(t, pack.bg, [4]f32{1, 2, 3, 128})
	testing.expect_value(t, pack.banner, [4]f32{171, 205, 239, 144})
	testing.expect_value(t, pack.shadow_float, [4]f32{16, 32, 48, 64})
	testing.expect_value(t, pack.media_chip_outline, [4]f32{48, 64, 80, 96})
	testing.expect_value(t, pack.accent_hi[4], [4]f32{85, 102, 119, 136})
	testing.expect_value(t, pack.r_scale, f32(0.75))
	testing.expect_value(t, pack.glow_r, f32(7))
	testing.expect_value(t, pack.shadow_y, f32(4))
	testing.expect_value(t, pack.bubble_r, f32(12))
	testing.expect_value(t, pack.hover_dur, f32(80))
	testing.expect_value(t, pack.transition_dur, f32(160))
	testing.expect(
		t,
		pack.pixel_metrics && pack.synth_grid && pack.paper_doodles && pack.scanlines,
	)
	testing.expect(t, pack.hard_shadow && pack.focus_glow && pack.bevel && pack.outline_surfaces)
	testing.expect(t, pack.selected_inverts_text && pack.bracket_labels && pack.motion_fast)
	testing.expect_value(t, pack.font, "Example Font")
	testing.expect_value(t, pack.backdrop, "waves")
	testing.expect_value(t, theme_field_hint(&pack, {token = .Bg}), "#01020380")
	testing.expect_value(t, theme_field_hint(&pack, {token = .Bg_2}), "#11223344")
	testing.expect_value(t, theme_field_hint(&pack, {token = .Overlay}), "#12345678")
	testing.expect_value(t, theme_field_hint(&pack, {token = .Accent_Hi, slot = 4}), "#55667788")
	testing.expect_value(t, theme_field_hint(&pack, {token = .R_Scale}), "0.75")
	testing.expect_value(t, theme_field_hint(&pack, {token = .Glow_R}), "7")
	testing.expect_value(t, theme_field_hint(&pack, {token = .Name}), "Typed")
	testing.expect_value(t, theme_field_hint(&pack, {token = .Font}), "Example Font")
	testing.expect_value(t, theme_field_hint(&pack, {token = .Bevel}), "true")
}

@(test)
theme_accent_inheritance :: proc(t: ^testing.T) {
	ACCENTS :: `accent-base = [
    "#000000ff",
    "#ffffffff",
    "#ffc107ff",
    "#000080ff",
    "#777777ff",
]
`
	base := parse_theme("Base", "base", TEST_THEME, default_pack())
	child := parse_theme("Child", "child", "base = \"base\"\n" + ACCENTS, base)
	defer {for label in base.accent_names {delete(label)}}
	grandchild := parse_theme("Grandchild", "grandchild", "base = \"child\"\n", child)
	for pack in ([2]Theme_Pack{child, grandchild}) {
		for fill, slot in pack.accent_base {
			testing.expect(t, theme_test_contrast(pack.on_accent[slot], fill) >= 4.5)
		}
		testing.expect_value(t, pack.on_accent[0], [4]f32{255, 255, 255, 255})
		testing.expect_value(t, pack.on_accent[1], [4]f32{0, 0, 0, 255})
	}
	base = parse_theme("Explicit", "explicit", "on-accent = \"#12345678\"\n", default_pack())
	child = parse_theme("Child", "child", "base = \"explicit\"\n" + ACCENTS, base)
	grandchild = parse_theme("Grandchild", "grandchild", "base = \"child\"\n", child)
	for pack in ([3]Theme_Pack{base, child, grandchild}) {
		for ink in pack.on_accent {testing.expect_value(t, ink, [4]f32{18, 52, 86, 120})}
	}
	child = parse_theme(
		"Replace",
		"replace",
		"base = \"explicit\"\non-accent = \"#abcdef80\"\n",
		base,
	)
	for ink in child.on_accent {testing.expect_value(t, ink, [4]f32{171, 205, 239, 128})}
}

@(test)
theme_system_palette :: proc(t: ^testing.T) {
	for source in ([]string{"background = \"#101020\"\nforeground = \"#eeeeff\"\naccent = \"#88aaff\"\ncolor1 = \"#ff5566\"", "background = '#ffffff' # light\nforeground = '#112233'\naccent = '#445566'\nred = '#ff5566'"}) {
		pack, ok := parse_system_theme(source)
		testing.expect(t, ok)
		if !ok {continue}
		defer delete(pack.source)
		testing.expect_value(t, pack.name, "System")
		testing.expect_value(t, pack.danger, [4]f32{255, 85, 102, 255})
		testing.expect(t, pack.bg != pack.text_hi)
		testing.expect(t, pack.panel != pack.bg)
		for accent in pack.accent_base {testing.expect_value(t, accent, pack.accent_base[0])}
		snapshot := parse_theme("Shared", "shared", pack.source, default_pack())
		testing.expect_value(t, snapshot.bg, pack.bg)
		testing.expect_value(t, snapshot.accent_base, pack.accent_base)
	}
	for source in ([]string{"", "background = \"#112233\"", "background = \"#112233\"\nforeground = \"#ffffff\"\naccent = \"#GGGGGG\"", "background = \"#112233\"\nforeground = \"#ffffff\"\naccent = \"#1234567\""}) {
		_, ok := parse_system_theme(source)
		testing.expect(t, !ok)
	}
}

DIN_NATIVE_CSS :: `/* Din's colors: Din rewrites this block when its theme changes. Add your own below it. */
@define-color accent_bg_color #c98a4b;
@define-color accent_fg_color #ffffff;
@define-color destructive_bg_color #dc2828;
@define-color window_bg_color #131518;
@define-color window_fg_color #ece6da;
@define-color view_bg_color #171a1e;
@define-color headerbar_bg_color #202326;
@define-color headerbar_fg_color #f0f1f2;
@define-color headerbar_border_color #5d4d3c;
@define-color sidebar_bg_color #222426;
@define-color sidebar_fg_color #f3f4f5;
@define-color sidebar_border_color #494132;
@define-color card_bg_color #292c30;
@define-color card_fg_color #eaebec;
@define-color popover_bg_color #303236;
@define-color popover_fg_color #e7e8e9;
:root {
  --window-bg-color: #131518;
}
/* End of Din's colors */

@define-color window_bg_color #ff0000;
`

@(test)
theme_din_palette :: proc(t: ^testing.T) {
	pack, ok := parse_din_theme(DIN_NATIVE_CSS)
	if !testing.expect(t, ok) {return}
	defer delete(pack.source)
	testing.expect_value(t, pack.name, "System")
	testing.expect_value(t, pack.mode, "@system")
	testing.expect_value(t, pack.collection, Theme_Collection.System)
	testing.expect_value(t, pack.tone, Theme_Tone.Dark)
	testing.expect_value(t, pack.bg, [4]f32{19, 21, 24, 255})
	testing.expect_value(t, pack.text_hi, [4]f32{236, 230, 218, 255})
	testing.expect_value(t, pack.field, [4]f32{23, 26, 30, 255})
	testing.expect_value(t, pack.status_bar, [4]f32{32, 35, 38, 255})
	testing.expect_value(t, pack.panel, [4]f32{34, 36, 38, 255})
	testing.expect_value(t, pack.elevated, [4]f32{41, 44, 48, 255})
	testing.expect_value(t, pack.tooltip, [4]f32{48, 50, 54, 255})
	testing.expect_value(t, pack.sidebar_text, [4]f32{243, 244, 245, 255})
	testing.expect_value(t, pack.card_text, [4]f32{234, 235, 236, 255})
	testing.expect_value(t, pack.header_text, [4]f32{240, 241, 242, 255})
	testing.expect_value(t, pack.popover_text, [4]f32{231, 232, 233, 255})
	testing.expect_value(t, pack.card_border, [4]f32{73, 65, 50, 255})
	testing.expect_value(t, pack.divider, [4]f32{93, 77, 60, 255})
	testing.expect_value(t, pack.danger, [4]f32{220, 40, 40, 255})
	for accent, i in pack.accent_base {
		testing.expect_value(t, accent, [4]f32{201, 138, 75, 255})
		testing.expect_value(t, pack.on_accent[i], BLACK)
	}
	testing.expect_value(t, theme_offer_name(pack.source), "Din")
	snapshot := parse_theme("Din", "din", pack.source, default_pack())
	testing.expect_value(t, snapshot.panel, pack.panel)
	testing.expect_value(t, snapshot.on_accent, pack.on_accent)
	testing.expect_value(t, snapshot.card_text, pack.card_text)

	// #797979 falls between the app's default cutoff and Din's 0.2 cutoff.
	for bg in ([2]string{"#797979", "#eeeeee"}) {
		css, _ := strings.replace_all(DIN_NATIVE_CSS, "#131518", bg, context.temp_allocator)
		css, _ = strings.replace_all(css, "#c98a4b", "#113355", context.temp_allocator)
		next, valid := parse_din_theme(css)
		if !testing.expect(t, valid) {continue}
		defer delete(next.source)
		testing.expect_value(t, next.tone, bg == "#797979" ? Theme_Tone.Dark : .Light)
		testing.expect(t, next.on_accent_explicit)
		testing.expect_value(t, next.on_accent[0], WHITE)
	}

	for edit in ([][2]string{{"/* End of Din's colors */", ""}, {"#dc2828", "#GGGGGG"}, {"sidebar_bg_color", "window_bg_color"}, {"/* Din's colors:", "/* Local override:"}}) {
		bad, _ := strings.replace_all(DIN_NATIVE_CSS, edit[0], edit[1], context.temp_allocator)
		_, valid := parse_din_theme(bad)
		testing.expect(t, !valid)
	}
}

// Run alone: this test owns the theme registry, renderer colors and environment.
@(test)
theme_din_live :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		if !test_isolated("theme_din_live") {return}
		context.allocator = runtime.default_context().allocator
		home, err := os.make_directory_temp("", "wn-din-theme", context.temp_allocator)
		if !testing.expect(t, err == nil) {return}
		defer os.remove_all(home)
		if !testing.expect(t, os.set_env("XDG_CONFIG_HOME", home) == nil) ||
		   !testing.expect(t, os.set_env("DIN_DESKTOP_SESSION", "1") == nil) {return}
		load_themes()
		defer stop_system_theme()
		if !testing.expect(t, system_theme_index >= 0) {return}
		dir := fmt.tprintf("%s/gtk-4.0", home)
		path, temporary := fmt.tprintf("%s/gtk.css", dir), fmt.tprintf("%s/gtk.css.tmp", dir)
		if !testing.expect(t, os.make_directory(dir) == nil) {return}

		ui := Ui_State {
			theme = system_theme_index,
		}
		apply_theme(ui.theme, 0)
		testing.expect_value(t, BG, theme_packs[0].bg)
		publish :: proc(t: ^testing.T, temporary, path, css: string) -> bool {
			return(
				testing.expect(t, os.write_entire_file(temporary, transmute([]u8)css) == nil) &&
				testing.expect(t, os.rename(temporary, path) == nil) \
			)
		}
		wait_for :: proc(ui: ^Ui_State, want: [4]f32, now: f64) -> bool {
			for _ in 0 ..< 1000 {
				poll_system_theme(ui, now)
				if theme_packs[system_theme_index].bg == want {return true}
				time.sleep(time.Millisecond)
			}
			return false
		}
		desktop := read_din_appearance()
		if desktop.tone == .Light {
			if !testing.expect(t, wait_for(&ui, theme_packs[1].bg, 0)) {return}
			testing.expect_value(t, BG, theme_packs[1].bg)
		}
		if !publish(t, temporary, path, DIN_NATIVE_CSS) {return}
		dark := [4]f32{19, 21, 24, 255}
		if !testing.expect(t, wait_for(&ui, dark, 1)) {return}
		testing.expect_value(t, BG, dark)
		testing.expect_value(t, reduce_motion_enabled(&ui.prefs), desktop.reduce_motion)
		testing.expect_value(t, high_contrast_enabled(&ui.prefs), desktop.high_contrast)
		ui.prefs.motion_override, ui.prefs.reduce_motion = true, !desktop.reduce_motion
		ui.prefs.contrast_override, ui.prefs.high_contrast = true, !desktop.high_contrast
		testing.expect_value(t, reduce_motion_enabled(&ui.prefs), !desktop.reduce_motion)
		testing.expect_value(t, high_contrast_enabled(&ui.prefs), !desktop.high_contrast)
		ui.prefs.high_contrast = true
		g_prefs = &ui.prefs
		defer g_prefs = nil
		apply_theme(ui.theme, 0)
		testing.expect_value(t, TEXT_DIM, TEXT)
		testing.expect(t, theme_contrast(CARD_BORDER, CARD) >= 3)
		testing.expect(t, theme_contrast(CARD_TEXT, CARD) >= 7)

		light, _ := strings.replace_all(
			DIN_NATIVE_CSS,
			"#131518",
			"#eeeeee",
			context.temp_allocator,
		)
		if !publish(t, temporary, path, light) {return}
		if !testing.expect(t, wait_for(&ui, {238, 238, 238, 255}, 2)) {return}
		testing.expect_value(t, BG, [4]f32{238, 238, 238, 255})
		testing.expect_value(t, ui.theme_tone, Theme_Tone.Dark)

		// A desktop change updates the tile but leaves a manual theme alone.
		ui.theme = 0
		apply_theme(ui.theme, 0)
		if !publish(t, temporary, path, DIN_NATIVE_CSS) {return}
		if !testing.expect(t, wait_for(&ui, dark, 3)) {return}
		testing.expect_value(t, BG, theme_packs[0].bg)
		testing.expect_value(t, theme_packs[system_theme_index].tone, Theme_Tone.Dark)

		// Native launches through Din can have its socket but no session flag.
		if !testing.expect(t, os.unset_env("DIN_DESKTOP_SESSION")) ||
		   !testing.expect(t, os.set_env("DIN_SOCKET", "/fixture/din.sock") == nil) {return}
		load_themes()
		if !testing.expect_value(t, system_theme_index, len(THEME_SOURCES)) {return}
		testing.expect_value(t, theme_packs[system_theme_index].bg, dark)
	}
}
