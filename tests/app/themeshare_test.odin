package main

import "base:runtime"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:testing"
import rl "sdlrl"

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

@(test)
test_theme_tone_inheritance :: proc(t: ^testing.T) {
	// Overriding an inherited background must move the pack between gallery filters.
	night := parse_theme("Night", "night", "bg = \"#090909\"", default_pack())
	paper := parse_theme(
		"Paper",
		"paper",
		"base = \"night\"\nbg = \"#f9f9f9\"\ntext-hi = \"#090909\"",
		night,
	)
	ink := parse_theme(
		"Ink",
		"ink",
		"base = \"paper\"\nbg = \"#090909\"\ntext-hi = \"#f9f9f9\"",
		paper,
	)
	testing.expect_value(t, paper.tone, Theme_Tone.Light)
	testing.expect_value(t, ink.tone, Theme_Tone.Dark)
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
	set :: proc(ui: ^Ui_State, token: Theme_Token, value: string, slot := 0) {
		for field, i in THEME_FIELDS {
			if field.token == token && field.slot == slot {
				ed_set(ui, &ui.theme_fields[i], value)
				return
			}
		}
	}
	defer {
		for field in ui.theme_fields {delete(field)}
		delete(ui.theme_fields)
	}
	set(&ui, .Name, "My Theme")
	set(&ui, .Bg, "#101018")
	set(&ui, .Bg_2, "#202030")
	set(&ui, .Text_Hi, "#f0f0f0")
	set(&ui, .Accent_Base, "#ff8800", 0)
	set(&ui, .Accent_Base, "#0088ff", 1)
	set(&ui, .Accent_Base, "#88ff00", 2)
	set(&ui, .Overlay, "#12345678")
	set(&ui, .R_Scale, "0.75")
	set(&ui, .Font, "Example Font")

	toml := theme_edit_toml(&ui)
	testing.expect_value(t, theme_offer_name(toml), "My Theme")

	pack := parse_theme("My Theme", "mytheme", toml, default_pack())
	defer delete(pack.font)
	testing.expect_value(t, pack.bg, [4]f32{16, 16, 24, 255})
	testing.expect_value(t, pack.bg_2, [4]f32{32, 32, 48, 255})
	testing.expect_value(t, pack.text_hi, [4]f32{240, 240, 240, 255})
	testing.expect_value(t, pack.overlay, [4]f32{18, 52, 86, 120})
	testing.expect_value(t, pack.r_scale, f32(0.75))
	testing.expect_value(t, pack.font, "Example Font")
	testing.expect_value(t, pack.accent_base[0], [4]f32{255, 136, 0, 255})
	// Three picks fill five ramps: a slot left blank repeats the first,
	// so no accent is ever black.
	testing.expect_value(t, pack.accent_base[2], [4]f32{136, 255, 0, 255})
	testing.expect_value(t, pack.accent_base[3], pack.accent_base[0])
	testing.expect_value(t, pack.accent_base[4], pack.accent_base[0])
	// Derived, not written: a mid text tone between the ink and the page.
	testing.expect(t, pack.text_mid.r < pack.text_hi.r && pack.text_mid.r > pack.bg.r)
	// Each accent gets its own maximum-contrast ink rather than slot zero's.
	testing.expect_value(t, pack.on_accent[0], [4]f32{0, 0, 0, 255})
	testing.expect_value(t, pack.on_accent[2], [4]f32{0, 0, 0, 255})
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
	BAD :: clay.Color{255, 0, 255, 255} // what an unparseable hex becomes
	lum :: proc(c: clay.Color) -> f32 {
		return (c.r * 0.299 + c.g * 0.587 + c.b * 0.114) / 255
	}
	// Built-ins are complete definitions. Do not include machine-local packs
	// or retain a test-arena allocation in the process-global theme registry.
	for source in THEME_SOURCES {
		pack := parse_theme(source.name, source.mode, source.source, default_pack())
		defer {delete(pack.font); delete(pack.font_title); delete(pack.backdrop)}
		gap := abs(lum(pack.text_hi) - lum(pack.bg))
		testing.expectf(t, gap >= 0.35, "%s: text and background are too close", pack.name)
		// A magenta channel triple is what parse_hex_color returns for
		// an unparseable value, so it doubles as a typo detector.
		for accent in pack.accent_base {
			testing.expectf(t, accent != BAD, "%s: unparseable accent", pack.name)
		}
		testing.expectf(t, pack.bg != BAD, "%s: unparseable background", pack.name)
	}
}

@(private)
theme_test_contrast :: proc(a, b: clay.Color) -> f64 {
	linear :: proc(c: f32) -> f64 {
		c := f64(c) / 255
		return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4)
	}
	lum :: proc(c: clay.Color) -> f64 {
		return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
	}
	hi, lo := max(lum(a), lum(b)), min(lum(a), lum(b))
	return (hi + 0.05) / (lo + 0.05)
}

@(test)
test_ink_on_reads_on_any_fill :: proc(t: ^testing.T) {


	fills: [258]clay.Color = {
		0 = {255, 193, 7, 255},
		1 = {0, 0, 128, 255},
	}
	for v in 0 ..< 256 {
		fills[2 + v] = {f32(v), f32(v), f32(v), 255}
	}
	for fill in fills {
		ratio := theme_test_contrast(ink_on(fill), fill)
		testing.expectf(t, ratio >= 4.5, "ink on %v reads at %.2f:1", fill, ratio)
		// Exercise derivation for every slot, not just the ink helper.
		base := default_pack()
		for &slot in base.accent_base {slot = fill}
		pack := parse_theme("Sweep", "sweep", "", base)
		for ink, slot in pack.on_accent {
			ratio := theme_test_contrast(ink, fill)
			testing.expectf(
				t,
				ratio >= 4.5,
				"accent slot %d on %v reads at %.2f:1",
				slot,
				fill,
				ratio,
			)
		}
	}
	testing.expect_value(t, ink_on({255, 193, 7, 255}), BLACK)
	testing.expect_value(t, ink_on({0, 0, 128, 255}), WHITE)
	// Use only the embedded sources: custom packs may explicitly opt out.
	for source in THEME_SOURCES {
		pack := parse_theme(source.name, source.mode, source.source, default_pack())
		defer {delete(pack.font); delete(pack.font_title); delete(pack.backdrop)}
		for fill, slot in pack.accent_base {
			ratio := theme_test_contrast(pack.on_accent[slot], fill)
			testing.expectf(t, ratio >= 4.5, "%s slot %d reads at %.2f:1", pack.name, slot, ratio)
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
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	// The runner frees its test arena on return; the registry outlives it.
	context.allocator = runtime.default_context().allocator
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
	// theme_packs and data_home are package globals that
	// system_theme_layout also reloads; take its locks in its order.
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	context.allocator = runtime.default_context().allocator
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

// Escape closes an untouched theme editor at once. After an edit it asks
// first, and only the confirm throws the edit away.
@(test)
test_theme_edit_escape_asks :: proc(t: ^testing.T) {
	sync.lock(&clay_test_mutex)
	defer sync.unlock(&clay_test_mutex)
	sync.lock(&test_home_lock)
	defer sync.unlock(&test_home_lock)
	context.allocator = runtime.default_context().allocator
	load_themes()
	packs := len(theme_packs)

	ui: Ui_State
	defer {
		for field in ui.theme_fields {delete(field)}
		delete(ui.theme_fields)
		delete(ui.theme_flags)
		delete(ui.theme_last)
		delete(ui.theme_base)
		delete(ui.confirm.arg)
		delete(ui.confirm.name)
	}
	press_escape :: proc(ui: ^Ui_State) {
		rl.PushKey(.ESCAPE, true)
		handle_theme_edit(ui)
		rl.PushKey(.ESCAPE, false)
	}

	theme_edit_open(&ui)
	press_escape(&ui)
	testing.expect(t, !ui.theme_edit && ui.confirm.kind == .None)
	testing.expect_value(t, len(theme_packs), packs)

	theme_edit_open(&ui)
	append(&ui.theme_fields[0], "x")
	press_escape(&ui)
	testing.expect(t, ui.theme_edit, "an edited theme stays open behind the confirm")
	testing.expect_value(t, ui.confirm.kind, Confirm_Kind.Discard_Theme_Edit)

	run_confirm(&ui, nil)
	testing.expect(t, !ui.theme_edit && ui.confirm.kind == .None)
	testing.expect_value(t, len(theme_packs), packs)
}
