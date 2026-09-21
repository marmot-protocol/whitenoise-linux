package main

import "core:os"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:testing"

// The slug is a filename and a map key, so anything that could escape
// either has to be gone.
@(test)
test_theme_slug :: proc(t: ^testing.T) {
	testing.expect_value(t, theme_slug("Par Avion", context.temp_allocator), "paravion")
	testing.expect_value(t, theme_slug("Film Noir", context.temp_allocator), "filmnoir")
	testing.expect_value(t, theme_slug("../../etc/passwd", context.temp_allocator), "etcpasswd")
	testing.expect_value(t, theme_slug("a/b\\c.d", context.temp_allocator), "abcd")
	// Nothing usable left means the pack is refused outright.
	testing.expect_value(t, theme_slug("///", context.temp_allocator), "")
	// Bounded, so a long name cannot make a long path.
	testing.expect(
		t,
		len(
			theme_slug(strings.repeat("x", 500, context.temp_allocator), context.temp_allocator),
		) <=
		24,
	)
}

// An incoming pack is untrusted: only a sized, named, seeded one is
// worth offering.
@(test)
test_theme_offer_name :: proc(t: ^testing.T) {
	ok := "name = \"Shared\"\n\n[colors]\nbg = \"#101010ff\"\n"
	testing.expect_value(t, theme_offer_name(ok), "Shared")

	testing.expect_value(t, theme_offer_name(""), "")
	// No name, or a name that slugs to nothing.
	testing.expect_value(t, theme_offer_name("[colors]\nbg = \"#101010ff\"\n"), "")
	testing.expect_value(t, theme_offer_name("name = \"///\"\n[colors]\nbg = \"#101010ff\"\n"), "")
	// No bg seed: every derivation rule starts there.
	testing.expect_value(
		t,
		theme_offer_name("name = \"Shared\"\n[colors]\ntext-hi = \"#ffffffff\"\n"),
		"",
	)
	// Oversized payloads are dropped before parsing.
	big := strings.concatenate(
		{ok, strings.repeat("#pad\n", 4000, context.temp_allocator)},
		context.temp_allocator,
	)
	testing.expect_value(t, theme_offer_name(big), "")
}

// What the editor writes must be what the parser reads back: seeds in,
// same seeds out, with the rest derived.
@(test)
test_theme_edit_round_trip :: proc(t: ^testing.T) {
	ui: Ui_State
	for _ in THEME_FIELDS {
		buf: [dynamic]u8
		append(&ui.theme_fields, buf)
	}
	set :: proc(ui: ^Ui_State, key: string, value: string) {
		for field, i in THEME_FIELDS {
			if field.key == key {
				ed_set(ui, &ui.theme_fields[i], value)
				return
			}
		}
	}
	set(&ui, "name", "My Theme")
	set(&ui, "bg", "#101018")
	set(&ui, "bg-2", "#202030")
	set(&ui, "text-hi", "#f0f0f0")
	set(&ui, "accent-1", "#ff8800")
	set(&ui, "accent-2", "#0088ff")
	set(&ui, "accent-3", "#88ff00")

	toml := theme_edit_toml(&ui)
	testing.expect_value(t, theme_offer_name(toml), "My Theme")

	pack := parse_theme("My Theme", "mytheme", toml, default_pack())
	testing.expect_value(t, pack.bg, [4]f32{16, 16, 24, 255})
	testing.expect_value(t, pack.bg_2, [4]f32{32, 32, 48, 255})
	testing.expect_value(t, pack.text_hi, [4]f32{240, 240, 240, 255})
	testing.expect_value(t, pack.accent_base[0], [4]f32{255, 136, 0, 255})
	// Three picks fill five ramps: a slot left blank repeats the first,
	// so no accent is ever black.
	testing.expect_value(t, pack.accent_base[2], [4]f32{136, 255, 0, 255})
	testing.expect_value(t, pack.accent_base[3], pack.accent_base[0])
	testing.expect_value(t, pack.accent_base[4], pack.accent_base[0])
	// Derived, not written: a mid text tone between the ink and the page.
	testing.expect(t, pack.text_mid.r < pack.text_hi.r && pack.text_mid.r > pack.bg.r)
	// Ink on that orange is dark, picked by luma rather than declared.
	testing.expect_value(t, pack.on_accent, [4]f32{0, 0, 0, 255})
}

// A light pack and a dark one must both derive legibly from the same
// rules: surfaces step away from the page in whichever direction the
// page is not.
@(test)
test_derive_both_polarities :: proc(t: ^testing.T) {
	dark := parse_theme("D", "d", "name = \"D\"\n[colors]\nbg = \"#0a0a0aff\"\n", default_pack())
	light := parse_theme("L", "l", "name = \"L\"\n[colors]\nbg = \"#f5f5f5ff\"\n", default_pack())

	// Text is picked against the page when the pack names none.
	testing.expect(t, dark.text_hi.r > dark.bg.r)
	testing.expect(t, light.text_hi.r < light.bg.r)
	// Panels lift off the page in both.
	testing.expect(t, dark.panel.r > dark.bg.r)
	testing.expect(t, light.panel.r < light.bg.r)
}

// Every built-in pack must be legible: enough contrast between the ink
// and the page, and an accent that is not the page. This is what
// catches a mistyped hex in a hand-written pack.
@(test)
test_builtin_packs_legible :: proc(t: ^testing.T) {
	load_themes()
	testing.expect(t, len(theme_packs) >= 16, "the eight new packs load")

	BAD :: clay.Color{255, 0, 255, 255} // what an unparseable hex becomes
	lum :: proc(c: clay.Color) -> f32 {
		return (c.r * 0.299 + c.g * 0.587 + c.b * 0.114) / 255
	}
	for pack in theme_packs {
		gap := abs(lum(pack.text_hi) - lum(pack.bg))
		if gap < 0.35 {
			testing.fail_now(
				t,
				strings.concatenate(
					{pack.name, ": text and background are too close"},
					context.temp_allocator,
				),
			)
		}
		// A magenta channel triple is what parse_hex_color returns for
		// an unparseable value, so it doubles as a typo detector.
		for accent in pack.accent_base {
			if accent == BAD {
				testing.fail_now(
					t,
					strings.concatenate(
						{pack.name, ": unparseable accent"},
						context.temp_allocator,
					),
				)
			}
		}
		if pack.bg == BAD {
			testing.fail_now(
				t,
				strings.concatenate(
					{pack.name, ": unparseable background"},
					context.temp_allocator,
				),
			)
		}
	}
}

// The active pack is read every frame by layout while the index is
// written by menus, adoption and deletion. A stale index must clamp,
// not panic: saving a theme once returned an index that a removal
// underneath it had already invalidated, and the next frame's
// theme_packs[ui.theme] took the whole app down.
@(test)
test_active_pack_clamps :: proc(t: ^testing.T) {
	load_themes()
	ui: Ui_State

	ui.theme = len(theme_packs) + 5 // past the end, as a stale index is
	testing.expect_value(t, active_theme(&ui), len(theme_packs) - 1)
	testing.expect_value(t, active_pack(&ui).name, theme_packs[len(theme_packs) - 1].name)

	ui.theme = -3
	testing.expect_value(t, active_theme(&ui), 0)
}

// Saving twice must not grow the list twice: adopting by slug replaces,
// and the index it returns has to stay valid.
@(test)
test_adopt_theme_replaces_by_slug :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("", "wn-theme-test", context.temp_allocator)
	if dir_err != nil {
		return // no writable temp dir; the path is exercised elsewhere
	}
	defer os.remove_all(dir)

	saved := data_home
	data_home = dir
	defer data_home = saved

	load_themes()

	// Lengths are not asserted: theme_packs is a package global and the
	// suite runs tests in parallel, so identity is the stable contract.
	first := adopt_theme("name = \"Adopted\"\n\n[colors]\nbg = \"#101010ff\"\n")
	testing.expect(t, first >= 0 && first < len(theme_packs), "adopted index is in range")
	testing.expect_value(t, theme_packs[first].name, "Adopted")
	testing.expect(t, theme_packs[first].custom, "an adopted pack is deletable")

	// Same name again: the slot is reused, not appended, so the index
	// the caller already holds stays valid.
	second := adopt_theme("name = \"Adopted\"\n\n[colors]\nbg = \"#202020ff\"\n")
	testing.expect_value(t, second, first)
	testing.expect(t, second >= 0 && second < len(theme_packs), "reused index is in range")
	testing.expect_value(t, theme_packs[second].bg, [4]f32{32, 32, 32, 255})
}
