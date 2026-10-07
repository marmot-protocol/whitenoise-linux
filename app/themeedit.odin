// The theme editor: every token the engine reads, with derivation as
// the default rather than the ceiling.
//
// A box left empty derives (theme.odin), and its placeholder shows the
// value derivation would produce, so the whole pack is visible and any
// part of it is overridable. That keeps a saved theme terse: only what
// was actually typed is written.
//
//   open  ─► working pack appended to theme_packs, made active
//   edit  ─► recompose toml ─► reparse ─► working pack updated (live)
//   save  ─► written to <data-dir>/themes/<slug>.toml via adopt_theme
//   cancel─► working pack dropped, previous theme restored
package main

import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
Theme_Field_Kind :: enum {
	Color,
	Number,
	Text,
}

@(private)
Theme_Field :: struct {
	group: string, // section eyebrow, "" continues the previous one
	label: string,
	token: Theme_Token,
	kind:  Theme_Field_Kind,
	slot:  int, // accent table entry; scalars use zero
}

// The editable surface, in the order it reads on screen. Seeds first,
// because everything below them derives from them.
@(private)
THEME_FIELDS := []Theme_Field {
	{N_("IDENTITY"), N_("Name"), .Name, .Text, 0},
	{"", N_("Font"), .Font, .Text, 0},
	{N_("SEEDS"), N_("Background"), .Bg, .Color, 0},
	{"", N_("Background 2"), .Bg_2, .Color, 0},
	{"", N_("Text"), .Text_Hi, .Color, 0},
	{"", N_("Danger"), .Danger, .Color, 0},
	{"", N_("Warning"), .Warning, .Color, 0},
	{N_("ACCENTS"), N_("Accent %s"), .Accent_Base, .Color, 0},
	{"", N_("Accent %s"), .Accent_Base, .Color, 1},
	{"", N_("Accent %s"), .Accent_Base, .Color, 2},
	{"", N_("Accent %s"), .Accent_Base, .Color, 3},
	{"", N_("Accent %s"), .Accent_Base, .Color, 4},
	{"", N_("On accent"), .On_Accent, .Color, 0},
	{N_("SURFACES"), N_("Panel"), .Panel, .Color, 0},
	{"", N_("Panel 2"), .Panel_2, .Color, 0},
	{"", N_("Rail"), .Rail, .Color, 0},
	{"", N_("Elevated"), .Elevated, .Color, 0},
	{"", N_("Plate"), .Plate, .Color, 0},
	{"", N_("Card well"), .Card_Well, .Color, 0},
	{"", N_("Code plate"), .Code_Plate, .Color, 0},
	{"", N_("Field"), .Field, .Color, 0},
	{"", N_("Field hover"), .Field_Hover, .Color, 0},
	{"", N_("Hover"), .Hover, .Color, 0},
	{"", N_("Status bar"), .Status_Bar, .Color, 0},
	{N_("TEXT"), N_("Text mid"), .Text_Mid, .Color, 0},
	{"", N_("Text low"), .Text_Lo, .Color, 0},
	{"", N_("Text lowest"), .Text_Vlo, .Color, 0},
	{N_("LINES"), N_("Divider"), .Divider, .Color, 0},
	{"", N_("Field border"), .Field_Border, .Color, 0},
	{"", N_("Card border"), .Card_Border, .Color, 0},
	{"", N_("Elevated border"), .Elevated_Border, .Color, 0},
	{"", N_("Border 2"), .Border_2, .Color, 0},
	{"", N_("Avatar ring"), .Avatar_Ring, .Color, 0},
	{"", N_("Top glint"), .Top_Glint, .Color, 0},
	{N_("DEPTH"), N_("Overlay"), .Overlay, .Color, 0},
	{"", N_("Overlay strong"), .Overlay_Strong, .Color, 0},
	{"", N_("Vignette"), .Vignette, .Color, 0},
	{"", N_("Shadow soft"), .Shadow_Soft, .Color, 0},
	{"", N_("Shadow card"), .Shadow_Card, .Color, 0},
	{"", N_("Shadow popover"), .Shadow_Popover, .Color, 0},
	{"", N_("Bevel light"), .Bevel_Hi, .Color, 0},
	{"", N_("Bevel shade"), .Bevel_Lo, .Color, 0},
	{N_("MEDIA"), N_("Media backdrop"), .Media_Backdrop, .Color, 0},
	{"", N_("Chip background"), .Media_Chip_Bg, .Color, 0},
	{"", N_("Chip text"), .Media_Chip_Fg, .Color, 0},
	{"", N_("Chip outline"), .Media_Chip_Outline, .Color, 0},
	{"", N_("Control background"), .Media_Control_Bg, .Color, 0},
	{N_("METRICS"), N_("Corner scale"), .R_Scale, .Number, 0},
	{"", N_("Border width"), .Border_W, .Number, 0},
	{"", N_("Focus glow radius"), .Glow_R, .Number, 0},
	{"", N_("Shadow offset"), .Shadow_Y, .Number, 0},
	{"", N_("Bubble radius"), .Bubble_R, .Number, 0},
	{"", N_("Hover ms"), .Hover_Dur, .Number, 0},
	{"", N_("Transition ms"), .Transition_Dur, .Number, 0},
}

@(private)
THEME_FLAGS := []struct {
	label: string,
	token: Theme_Token,
} {
	{N_("Bevelled surfaces"), .Bevel},
	{N_("Hard shadows"), .Hard_Shadow},
	{N_("Focus glow"), .Focus_Glow},
	{N_("Outline surfaces"), .Outline_Surfaces},
	{N_("Bracket labels"), .Bracket_Labels},
	{N_("Invert selected text"), .Selected_Inverts_Text},
	{N_("Fast motion"), .Motion_Fast},
	{N_("Pixel metrics"), .Pixel_Metrics},
}

// "" is a valid pick: no scene at all.
THEME_BACKDROPS := []string {
	"",
	"deco",
	"blinds",
	"stripes",
	"waves",
	"airmail",
	"synth",
	"dust",
	"scan",
}

@(private = "file")
hex_color :: proc(c: clay.Color) -> string {
	if c.a != 255 {
		return fmt.tprintf("#%02x%02x%02x%02x", int(c.r), int(c.g), int(c.b), int(c.a))
	}
	return fmt.tprintf("#%02x%02x%02x", int(c.r), int(c.g), int(c.b))
}

// Read the actual token through the same descriptor the parser writes.
@(private)
theme_field_hint :: proc(pack: ^Theme_Pack, field: Theme_Field) -> string {
	entry := theme_token_pointer(pack, field.token)
	switch THEME_TOKENS[field.token].kind {
	case .Color:
		color := (cast(^clay.Color)entry)^
		if field.token == .Bg_2 && color.a == 0 {return N_("flat")}
		return hex_color(color)
	case .Colors, .Ink:
		return hex_color((cast(^[5]clay.Color)entry)^[field.slot])
	case .Number:
		return fmt.tprintf(field.token == .R_Scale ? "%.2f" : "%.0f", (cast(^f32)entry)^)
	case .Text:
		value := (cast(^string)entry)^
		if len(value) > 0 {return value}
		return field.token == .Name ? N_("Name") : N_("Default stack")
	case .Flag:
		return (cast(^bool)entry)^ ? "true" : "false"
	}
	return ""
}

// Seed the boxes from the pack being copied. Only the identity and the
// four seeds start filled: the rest show their derived value and stay
// empty until they are actually overridden.
theme_edit_open :: proc(ui: ^Ui_State) {
	pack := theme_packs[clamp(ui.theme, 0, len(theme_packs) - 1)]

	clear(&ui.theme_fields)
	for field in THEME_FIELDS {
		buf: [dynamic]u8
		#partial switch field.token {
		case .Name:
			append(&buf, fmt.tprintf(tr("%s copy"), pack.name))
		case .Bg, .Text_Hi, .Danger:
			append(&buf, theme_field_hint(&pack, field))
		case .Accent_Base:
			if field.slot < 3 {append(&buf, theme_field_hint(&pack, field))}
		case .Bg_2:
			if pack.bg_2.a > 0 {append(&buf, theme_field_hint(&pack, field))}
		}
		append(&ui.theme_fields, buf)
	}

	clear(&ui.theme_flags)
	for flag in THEME_FLAGS {
		append(&ui.theme_flags, (cast(^bool)theme_token_pointer(&pack, flag.token))^)
	}
	ui.theme_backdrop = pack.backdrop

	// A working slot, so every keystroke previews on the real UI
	// without touching the pack being copied.
	ui.theme_prev = ui.theme
	ui.theme_edit = true
	ui.theme_edit_idx = 0
	ui.focus = .ThemeSeed
	ui.theme_slot = len(theme_packs)
	append(&theme_packs, pack)
	ui.theme = ui.theme_slot
	delete(ui.theme_last)
	ui.theme_last = "" // forces the first preview
	delete(ui.theme_base)
	ui.theme_base = strings.clone(theme_edit_toml(ui))
	theme_edit_preview(ui)
}


// Reparse what the boxes currently spell into the working slot and
// apply it, so the window is the preview.
theme_edit_preview :: proc(ui: ^Ui_State) {
	if ui.theme_slot < 0 || ui.theme_slot >= len(theme_packs) {
		return
	}
	toml := theme_edit_toml(ui)
	name := toml_str_key(toml, "name")
	pack := parse_theme(strings.clone(name), "editing", strings.clone(toml), default_pack())
	pack.source = strings.clone(toml)
	theme_packs[ui.theme_slot] = pack
	apply_theme(ui.theme_slot, ui.accent)
}

// Compose the pack: identity, then every box that was actually filled.
// An empty box writes nothing, which is what leaves it derived.
theme_edit_toml :: proc(ui: ^Ui_State) -> string {
	b := strings.builder_make(context.temp_allocator)
	val :: proc(ui: ^Ui_State, i: int) -> string {
		if i >= len(ui.theme_fields) {
			return ""
		}
		return strings.trim_space(string(ui.theme_fields[i][:]))
	}
	// An accent slot is a view into the accent-base token, not a TOML key.
	idx :: proc(token: Theme_Token, slot := 0) -> int {
		for field, i in THEME_FIELDS {
			if field.token == token && field.slot == slot {
				return i
			}
		}
		return -1
	}

	name := val(ui, idx(.Name))
	if len(name) == 0 {
		name = tr("Custom")
	}
	fmt.sbprintfln(&b, "# Written by the theme editor.")
	fmt.sbprintfln(&b, "%s = \"%s\"", THEME_TOKENS[.Name].key, name)
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "[colors]")

	for field, i in THEME_FIELDS {
		if field.kind != .Color {
			continue
		}
		v := val(ui, i)
		if len(v) == 0 || field.token == .Accent_Base {
			continue
		}
		fmt.sbprintfln(&b, "%s = \"%s\"", THEME_TOKENS[field.token].key, v)
	}

	// The five accent ramps are one table, so they are written together
	// and only when at least one slot was filled. A blank slot repeats
	// the first, which keeps every slot a real color.
	first := ""
	any := false
	for slot in 0 ..< 5 {
		if v := val(ui, idx(.Accent_Base, slot)); len(v) > 0 {
			any = true
			if len(first) == 0 {
				first = v
			}
		}
	}
	if any {
		fmt.sbprintfln(&b, "%s = [", THEME_TOKENS[.Accent_Base].key)
		for slot in 0 ..< 5 {
			v := val(ui, idx(.Accent_Base, slot))
			fmt.sbprintfln(&b, "    \"%s\",", len(v) > 0 ? v : first)
		}
		fmt.sbprintln(&b, "]")
	}

	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "[style]")
	for field, i in THEME_FIELDS {
		if field.kind != .Number {
			continue
		}
		if v := val(ui, i); len(v) > 0 {
			fmt.sbprintfln(&b, "%s = %s", THEME_TOKENS[field.token].key, v)
		}
	}
	for flag, i in THEME_FLAGS {
		if i < len(ui.theme_flags) && ui.theme_flags[i] {
			fmt.sbprintfln(&b, "%s = true", THEME_TOKENS[flag.token].key)
		}
	}
	if len(ui.theme_backdrop) > 0 {
		fmt.sbprintfln(&b, "%s = \"%s\"", THEME_TOKENS[.Backdrop].key, ui.theme_backdrop)
	}
	if font := val(ui, idx(.Font)); len(font) > 0 {
		fmt.sbprintfln(&b, "%s = \"%s\"", THEME_TOKENS[.Font].key, font)
	}
	return strings.to_string(b)
}

THEME_EDIT_W :: 430 // inner width; rows are fixed to it, because a
// vertical scroll container sizes to content horizontally, and a
// growing row would push its input clean out of the modal.
THEME_EDIT_H :: 440
THEME_BACKDROPS_PER_ROW :: 5

theme_edit_modal :: proc(ui: ^Ui_State) {
	// The pack as it currently stands, for the placeholders: they have
	// to show what derivation is doing right now, not at open.
	live := &theme_packs[clamp(ui.theme_slot, 0, len(theme_packs) - 1)]

	if clay.UI(clay.ID("ThemeEdit"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(modal_w(clay.ID("ThemeEdit"), THEME_EDIT_W + 36))},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(18),
			childGap = 8,
		},
		backgroundColor = CARD,
		cornerRadius = rr(14),
		border = {color = CARD_BORDER, width = bw()},
		floating = {
			attachTo = .Root,
			zIndex = 16,
			offset = {0, rise(clay.ID("ThemeEdit"))},
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
	},
	) {
		if clay.UI(clay.ID("ThemeEditHead"))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(THEME_EDIT_W)},
				layoutDirection = .TopToBottom,
				childGap = 2,
			},
		},
		) {
			clay.Text(tr("Edit theme"), {fontId = FONT_TITLE, fontSize = 16, textColor = TEXT})
			clay.Text(
				tr("An empty box derives its value. The window previews as you type."),
				{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO},
			)
		}

		if clay.UI(clay.ID("ThemeEditScroll"))(
		{
			layout = {
				sizing = {
					width = clay.SizingFixed(THEME_EDIT_W),
					height = clay.SizingFixed(THEME_EDIT_H),
				},
				layoutDirection = .TopToBottom,
				childGap = 3,
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			for field, i in THEME_FIELDS {
				if len(field.group) > 0 {
					if clay.UI(clay.ID("ThemeGroup", u32(i)))(
					{layout = {padding = {top = 8, bottom = 2}}},
					) {
						eyebrow(tr(field.group))
					}
				}
				theme_field_row(ui, live, field, i)
			}

			if clay.UI(clay.ID("ThemeFlagsEyebrow"))(
			{layout = {padding = {top = 10, bottom = 2}}},
			) {
				eyebrow(tr("STYLE"))
			}
			if clay.UI(clay.ID("ThemeFlags"))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(THEME_EDIT_W)},
					layoutDirection = .TopToBottom,
					childGap = 3,
				},
			},
			) {
				for flag, i in THEME_FLAGS {
					if clay.UI(clay.ID("ThemeFlagRow", u32(i)))(
					{
						layout = {
							sizing = {width = clay.SizingFixed(THEME_EDIT_W)},
							childGap = 10,
							childAlignment = {y = .Center},
						},
					},
					) {
						clay.Text(
							tr(flag.label),
							{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
						)
						if clay.UI(clay.ID("ThemeFlagGap", u32(i)))(
						{layout = {sizing = {width = clay.SizingGrow()}}},
						) {}
						on := i < len(ui.theme_flags) && ui.theme_flags[i]
						theme_chip_indexed("ThemeFlag", u32(i), on ? tr("On") : tr("Off"), on)
					}
				}
			}

			if clay.UI(clay.ID("ThemeBackdropEyebrow"))(
			{layout = {padding = {top = 10, bottom = 2}}},
			) {
				eyebrow(tr("BACKDROP"))
			}
			for row in 0 ..< (len(THEME_BACKDROPS) + THEME_BACKDROPS_PER_ROW - 1) / THEME_BACKDROPS_PER_ROW {
				if clay.UI(clay.ID("ThemeBackdrops", u32(row)))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(THEME_EDIT_W)},
						childGap = 4,
						padding = {bottom = 4},
					},
				},
				) {
					for i in row * THEME_BACKDROPS_PER_ROW ..< min((row + 1) * THEME_BACKDROPS_PER_ROW, len(THEME_BACKDROPS)) {
						name := THEME_BACKDROPS[i]
						theme_chip_indexed(
							"ThemeBackdrop",
							u32(i),
							len(name) > 0 ? name : "none",
							ui.theme_backdrop == name,
						)
					}
				}
			}
		}
		scrollbar(clay.ID("ThemeEditScroll"), 17) // the editor floats at 16

		if clay.UI(clay.ID("ThemeEditActions"))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(THEME_EDIT_W)},
				childGap = 10,
				padding = {top = 6},
			},
		},
		) {
			micro_button("ThemeEditCancel", tr("Cancel"))
			if clay.UI(clay.ID("ThemeEditGap"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			micro_button("ThemeEditSave", tr("Save and use"), ACCENT)
		}
	}
}

@(private = "file")
theme_field_row :: proc(ui: ^Ui_State, live: ^Theme_Pack, field: Theme_Field, i: int) {
	if clay.UI(clay.ID("ThemeSeedRow", u32(i)))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(THEME_EDIT_W)},
			childGap = 8,
			childAlignment = {y = .Center},
		},
	},
	) {
		// Accent labels number the token's five table slots from one.
		label := tr(field.label)
		if strings.contains(field.label, "%s") {
			label = fmt.tprintf(label, fmt.tprintf("%d", field.slot + 1))
		}
		clay.Text(label, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
		if clay.UI(clay.ID("ThemeSeedGap", u32(i)))(
		{layout = {sizing = {width = clay.SizingGrow()}}},
		) {}

		// The swatch shows the effective color: what was typed, or the
		// derived value the placeholder names.
		if field.kind == .Color {
			typed := strings.trim_space(string(ui.theme_fields[i][:]))
			shown := len(typed) > 0 ? typed : theme_field_hint(live, field)
			if clay.UI(clay.ID("ThemeSeedSwatch", u32(i)))(
			{
				layout = {sizing = {width = clay.SizingFixed(18), height = clay.SizingFixed(18)}},
				backgroundColor = strings.has_prefix(shown, "#") ? parse_hex_color(shown) : clay.Color{},
				cornerRadius = rr(4),
				border = {color = DIVIDER, width = bw()},
			},
			) {}
		}
		focused := ui.focus == .ThemeSeed && ui.theme_edit_idx == i
		input_box(
			ui,
			fmt.tprintf("ThemeSeedBox%d", i),
			&ui.theme_fields[i],
			tr(theme_field_hint(live, field)),
			focused,
			130,
		)
	}
}

// Input while the editor is open; true when the frame was consumed.
handle_theme_edit :: proc(ui: ^Ui_State) -> bool {
	if !ui.theme_edit {
		return false
	}
	// An untouched editor closes at once; edits ask before they are lost.
	if rl.IsKeyPressed(.ESCAPE) || clicked("ThemeEditCancel") {
		if theme_edit_toml(ui) == ui.theme_base {
			theme_edit_close(ui, .Discard)
		} else {
			confirm_ask(ui, .Discard_Theme_Edit, "")
		}
		return true
	}
	if clicked("ThemeEditSave") {
		// The working slot goes first: adopting appends, and removing a
		// slot below the new pack would shift it out from under the
		// index adopt_theme just handed back.
		toml := strings.clone(theme_edit_toml(ui), context.temp_allocator)
		theme_edit_close(ui, .Discard)

		slot := adopt_theme(toml)
		if slot < 0 {
			set_status(
				ui,
				strings.clone(
					tr("Couldn't save the theme. Check the name and colors and try again."),
				),
				.Error,
			)
			return true
		}
		ui.theme = slot
		apply_theme(ui.theme, ui.accent)
		save_settings(ui)
		toast(ui, tr("Theme saved"))
		return true
	}

	for _, i in THEME_FIELDS {
		if field_mouse(ui, &ui.theme_fields[i], fmt.tprintf("ThemeSeedBox%d", i)) {
			ui.focus = .ThemeSeed
			ui.theme_edit_idx = i
			return true
		}
	}
	for _, i in THEME_FLAGS {
		if clicked_indexed("ThemeFlag", u32(i)) {
			ui.theme_flags[i] = !ui.theme_flags[i]
			theme_edit_preview(ui)
			return true
		}
	}
	for name, i in THEME_BACKDROPS {
		if clicked_indexed("ThemeBackdrop", u32(i)) {
			ui.theme_backdrop = name
			theme_edit_preview(ui)
			return true
		}
	}

	// Any keystroke lands in a box through active_buf, so the preview
	// follows whatever the frame typed. Composing the toml is cheap;
	// reparsing it is not, so a frame that changed nothing does neither.
	if toml := theme_edit_toml(ui); toml != ui.theme_last {
		delete(ui.theme_last)
		ui.theme_last = strings.clone(toml)
		theme_edit_preview(ui)
	}
	return false
}

Theme_Edit_Exit :: enum {
	Discard,
}

// Drop the working slot and put the previous theme back.
@(private)
theme_edit_close :: proc(ui: ^Ui_State, exit: Theme_Edit_Exit) {
	if ui.theme_slot >= 0 && ui.theme_slot < len(theme_packs) {
		ordered_remove(&theme_packs, ui.theme_slot)
	}
	ui.theme_slot = -1
	ui.theme_edit = false
	ui.focus = .Compose
	ui.theme = clamp(ui.theme_prev, 0, len(theme_packs) - 1)
	apply_theme(ui.theme, ui.accent)
}
