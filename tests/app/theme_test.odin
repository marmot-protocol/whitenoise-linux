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
	child := parse_theme("Child", "child", "base = \"base\"\n\n[colors]\nbg = \"#050607ff\"\n", base)

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
theme_system_palette :: proc(t: ^testing.T) {
	for source in ([]string{
		"background = \"#101020\"\nforeground = \"#eeeeff\"\naccent = \"#88aaff\"\ncolor1 = \"#ff5566\"",
		"background = '#ffffff' # light\nforeground = '#112233'\naccent = '#445566'\nred = '#ff5566'",
	}) {
		pack, ok := parse_system_theme(source)
		testing.expect(t, ok)
		if !ok { continue }
		defer delete(pack.source)
		testing.expect_value(t, pack.name, "System")
		testing.expect_value(t, pack.danger, [4]f32{255, 85, 102, 255})
		testing.expect(t, pack.bg != pack.text_hi)
		testing.expect(t, pack.panel != pack.bg)
		for accent in pack.accent_base { testing.expect_value(t, accent, pack.accent_base[0]) }
		snapshot := parse_theme("Shared", "shared", pack.source, default_pack())
		testing.expect_value(t, snapshot.bg, pack.bg)
		testing.expect_value(t, snapshot.accent_base, pack.accent_base)
	}
	for source in ([]string{
		"", "background = \"#112233\"",
		"background = \"#112233\"\nforeground = \"#ffffff\"\naccent = \"#GGGGGG\"",
		"background = \"#112233\"\nforeground = \"#ffffff\"\naccent = \"#1234567\"",
	}) {
		_, ok := parse_system_theme(source)
		testing.expect(t, !ok)
	}
}
