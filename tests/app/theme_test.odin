// Theme toml parser tests.
// Run: ODIN_ROOT=build/odin-root tests/odin.sh app
package main

import "core:testing"

@(test)
theme_hex_color :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_hex_color("\"#0d0d28ff\""), [4]f32{13, 13, 40, 255})
	testing.expect_value(t, parse_hex_color("\"#ff5a5a30\""), [4]f32{255, 90, 90, 48})
	testing.expect_value(t, parse_hex_color("\"#123456\""), [4]f32{18, 52, 86, 255})
	testing.expect_value(t, parse_hex_color("\"oops\""), [4]f32{255, 0, 255, 255})
}

TEST_THEME :: `name = "Test"

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
	testing.expect_value(t, pack.bg, [4]f32{1, 2, 3, 255})
	testing.expect_value(t, pack.text_hi, [4]f32{244, 239, 221, 255})
	testing.expect_value(t, pack.accent_base[1], [4]f32{107, 140, 255, 255})
	testing.expect_value(t, pack.accent_base[4], [4]f32{201, 160, 220, 255})
	testing.expect_value(t, pack.r_scale, f32(0))
	testing.expect_value(t, pack.border_w, f32(2))
	testing.expect(t, pack.pixel_metrics)
	testing.expect(t, !pack.synth_grid)
}

@(test)
theme_inherit :: proc(t: ^testing.T) {
	base := parse_theme("Base", "base", TEST_THEME, default_pack())
	child := parse_theme(
		"Child",
		"child",
		"base = \"base\"\n\n[colors]\nbg = \"#050607ff\"\n",
		base,
	)

	// Overridden key takes; everything else rides the base.
	testing.expect_value(t, child.bg, [4]f32{5, 6, 7, 255})
	testing.expect_value(t, child.text_hi, base.text_hi)
	testing.expect_value(t, child.accent_base[2], base.accent_base[2])
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
