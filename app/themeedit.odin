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

Theme_Field_Kind :: enum {
	Color,
	Number,
	Text,
}

Theme_Field :: struct {
	group: string, // section eyebrow, "" continues the previous one
	label: string,
	key:   string, // the toml key it writes
	kind:  Theme_Field_Kind,
}

// The editable surface, in the order it reads on screen. Seeds first,
// because everything below them derives from them.
THEME_FIELDS := []Theme_Field {
	{"IDENTITY", N_("Name"), "name", .Text},
	{"", N_("Font"), "font", .Text},
	{"SEEDS", N_("Background"), "bg", .Color},
	{"", N_("Background 2"), "bg-2", .Color},
	{"", N_("Text"), "text-hi", .Color},
	{"", N_("Danger"), "danger", .Color},
	{"", N_("Warning"), "warning", .Color},
	{"ACCENTS", N_("Accent 1"), "accent-1", .Color},
	{"", N_("Accent 2"), "accent-2", .Color},
	{"", N_("Accent 3"), "accent-3", .Color},
	{"", N_("Accent 4"), "accent-4", .Color},
	{"", N_("Accent 5"), "accent-5", .Color},
	{"", N_("On accent"), "on-accent", .Color},
	{"SURFACES", N_("Panel"), "panel", .Color},
	{"", N_("Panel 2"), "panel-2", .Color},
	{"", N_("Rail"), "rail", .Color},
	{"", N_("Elevated"), "elevated", .Color},
	{"", N_("Plate"), "plate", .Color},
	{"", N_("Card well"), "card-well", .Color},
	{"", N_("Code plate"), "code-plate", .Color},
	{"", N_("Field"), "field", .Color},
	{"", N_("Field hover"), "field-hover", .Color},
	{"", N_("Hover"), "hover", .Color},
	{"", N_("Status bar"), "status-bar", .Color},
	{"TEXT", N_("Text mid"), "text-mid", .Color},
	{"", N_("Text low"), "text-lo", .Color},
	{"", N_("Text lowest"), "text-vlo", .Color},
	{"LINES", N_("Divider"), "divider", .Color},
	{"", N_("Field border"), "field-border", .Color},
	{"", N_("Card border"), "card-border", .Color},
	{"", N_("Elevated border"), "elevated-border", .Color},
	{"", N_("Border 2"), "border-2", .Color},
	{"", N_("Avatar ring"), "avatar-ring", .Color},
	{"", N_("Top glint"), "top-glint", .Color},
	{"DEPTH", N_("Overlay"), "overlay", .Color},
	{"", N_("Overlay strong"), "overlay-strong", .Color},
	{"", N_("Vignette"), "vignette", .Color},
	{"", N_("Shadow soft"), "shadow-soft", .Color},
	{"", N_("Shadow card"), "shadow-card", .Color},
	{"", N_("Shadow popover"), "shadow-popover", .Color},
	{"", N_("Bevel light"), "bevel-hi", .Color},
	{"", N_("Bevel shade"), "bevel-lo", .Color},
	{"MEDIA", N_("Media backdrop"), "media-backdrop", .Color},
	{"", N_("Chip background"), "media-chip-bg", .Color},
	{"", N_("Chip text"), "media-chip-fg", .Color},
	{"", N_("Chip outline"), "media-chip-outline", .Color},
	{"", N_("Control background"), "media-control-bg", .Color},
	{"METRICS", N_("Corner scale"), "r-scale", .Number},
	{"", N_("Border width"), "border-w", .Number},
	{"", N_("Focus glow radius"), "glow-r", .Number},
	{"", N_("Shadow offset"), "shadow-y", .Number},
	{"", N_("Bubble radius"), "bubble-r", .Number},
	{"", N_("Hover ms"), "hover-dur", .Number},
	{"", N_("Transition ms"), "transition-dur", .Number},
}

THEME_FLAGS := []struct {
	label: string,
	key:   string,
} {
	{N_("Bevelled surfaces"), "bevel"},
	{N_("Hard shadows"), "hard-shadow"},
	{N_("Focus glow"), "focus-glow"},
	{N_("Outline surfaces"), "outline-surfaces"},
	{N_("Bracket labels"), "bracket-labels"},
	{N_("Invert selected text"), "selected-inverts-text"},
	{N_("Fast motion"), "motion-fast"},
	{N_("Pixel metrics"), "pixel-metrics"},
}

// "" is a valid pick: no scene at all.
THEME_BACKDROPS := []string{"", "deco", "blinds", "stripes", "waves", "airmail", "synth", "dust", "scan"}

@(private = "file")
hex6 :: proc(c: clay.Color) -> string {
	return fmt.tprintf("#%02x%02x%02x", int(c.r), int(c.g), int(c.b))
}

// The value derivation would give this key for the pack being edited,
// shown as the box's placeholder so an empty box is never a mystery.
@(private = "file")
derived_hint :: proc(pack: Theme_Pack, key: string) -> string {
	switch key {
	case "name":
		return N_("Name")
	case "font":
		return N_("Default stack")
	case "bg":
		return hex6(pack.bg)
	case "bg-2":
		return pack.bg_2.a > 0 ? hex6(pack.bg_2) : N_("flat")
	case "text-hi":
		return hex6(pack.text_hi)
	case "danger":
		return hex6(pack.danger)
	case "warning":
		return hex6(pack.warning)
	case "accent-1":
		return hex6(pack.accent_base[0])
	case "accent-2":
		return hex6(pack.accent_base[1])
	case "accent-3":
		return hex6(pack.accent_base[2])
	case "accent-4":
		return hex6(pack.accent_base[3])
	case "accent-5":
		return hex6(pack.accent_base[4])
	case "on-accent":
		return hex6(pack.on_accent)
	case "panel":
		return hex6(pack.panel)
	case "panel-2":
		return hex6(pack.panel_2)
	case "rail":
		return hex6(pack.rail)
	case "elevated":
		return hex6(pack.elevated)
	case "plate":
		return hex6(pack.plate)
	case "card-well":
		return hex6(pack.card_well)
	case "code-plate":
		return hex6(pack.code_plate)
	case "field":
		return hex6(pack.field)
	case "field-hover":
		return hex6(pack.field_hover)
	case "hover":
		return hex6(pack.hover)
	case "status-bar":
		return hex6(pack.status_bar)
	case "text-mid":
		return hex6(pack.text_mid)
	case "text-lo":
		return hex6(pack.text_lo)
	case "text-vlo":
		return hex6(pack.text_vlo)
	case "divider":
		return hex6(pack.divider)
	case "field-border":
		return hex6(pack.field_border)
	case "card-border":
		return hex6(pack.card_border)
	case "elevated-border":
		return hex6(pack.elevated_border)
	case "border-2":
		return hex6(pack.border_2)
	case "avatar-ring":
		return hex6(pack.avatar_ring)
	case "top-glint":
		return hex6(pack.top_glint)
	case "overlay":
		return hex6(pack.overlay)
	case "overlay-strong":
		return hex6(pack.overlay_strong)
	case "vignette":
		return hex6(pack.vignette)
	case "shadow-soft":
		return hex6(pack.shadow_soft)
	case "shadow-card":
		return hex6(pack.shadow_card)
	case "shadow-popover":
		return hex6(pack.shadow_popover)
	case "bevel-hi":
		return hex6(pack.bevel_hi)
	case "bevel-lo":
		return hex6(pack.bevel_lo)
	case "media-backdrop":
		return hex6(pack.media_backdrop)
	case "media-chip-bg":
		return hex6(pack.media_chip_bg)
	case "media-chip-fg":
		return hex6(pack.media_chip_fg)
	case "media-chip-outline":
		return hex6(pack.media_chip_outline)
	case "media-control-bg":
		return hex6(pack.media_control_bg)
	case "r-scale":
		return fmt.tprintf("%.2f", pack.r_scale)
	case "border-w":
		return fmt.tprintf("%.0f", pack.border_w)
	case "glow-r":
		return fmt.tprintf("%.0f", pack.glow_r)
	case "shadow-y":
		return fmt.tprintf("%.0f", pack.shadow_y)
	case "bubble-r":
		return fmt.tprintf("%.0f", pack.bubble_r)
	case "hover-dur":
		return fmt.tprintf("%.0f", pack.hover_dur)
	case "transition-dur":
		return fmt.tprintf("%.0f", pack.transition_dur)
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
		switch field.key {
		case "name":
			append(&buf, fmt.tprintf("%s copy", pack.name))
		case "bg":
			append(&buf, hex6(pack.bg))
		case "text-hi":
			append(&buf, hex6(pack.text_hi))
		case "danger":
			append(&buf, hex6(pack.danger))
		case "accent-1":
			append(&buf, hex6(pack.accent_base[0]))
		case "accent-2":
			append(&buf, hex6(pack.accent_base[1]))
		case "accent-3":
			append(&buf, hex6(pack.accent_base[2]))
		case "bg-2":
			if pack.bg_2.a > 0 {
				append(&buf, hex6(pack.bg_2))
			}
		}
		append(&ui.theme_fields, buf)
	}

	clear(&ui.theme_flags)
	for flag in THEME_FLAGS {
		append(&ui.theme_flags, theme_flag_of(pack, flag.key))
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
	theme_edit_preview(ui)
}

@(private = "file")
theme_flag_of :: proc(pack: Theme_Pack, key: string) -> bool {
	switch key {
	case "bevel":
		return pack.bevel
	case "hard-shadow":
		return pack.hard_shadow
	case "focus-glow":
		return pack.focus_glow
	case "outline-surfaces":
		return pack.outline_surfaces
	case "bracket-labels":
		return pack.bracket_labels
	case "selected-inverts-text":
		return pack.selected_inverts_text
	case "motion-fast":
		return pack.motion_fast
	case "pixel-metrics":
		return pack.pixel_metrics
	}
	return false
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
	// Field index by key, so the sections below can pull what they need.
	idx :: proc(key: string) -> int {
		for field, i in THEME_FIELDS {
			if field.key == key {
				return i
			}
		}
		return -1
	}

	name := val(ui, idx("name"))
	if len(name) == 0 {
		name = "Custom"
	}
	fmt.sbprintfln(&b, "# Written by the theme editor.")
	fmt.sbprintfln(&b, "name = \"%s\"", name)
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "[colors]")

	for field, i in THEME_FIELDS {
		if field.kind != .Color {
			continue
		}
		v := val(ui, i)
		if len(v) == 0 || strings.has_prefix(field.key, "accent-") {
			continue
		}
		fmt.sbprintfln(&b, "%s = \"%s\"", field.key, v)
	}

	// The five accent ramps are one table, so they are written together
	// and only when at least one slot was filled. A blank slot repeats
	// the first, which keeps every slot a real color.
	first := ""
	any := false
	for n in 1 ..= 5 {
		if v := val(ui, idx(fmt.tprintf("accent-%d", n))); len(v) > 0 {
			any = true
			if len(first) == 0 {
				first = v
			}
		}
	}
	if any {
		fmt.sbprintln(&b, "accent-base = [")
		for n in 1 ..= 5 {
			v := val(ui, idx(fmt.tprintf("accent-%d", n)))
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
			fmt.sbprintfln(&b, "%s = %s", field.key, v)
		}
	}
	for flag, i in THEME_FLAGS {
		if i < len(ui.theme_flags) && ui.theme_flags[i] {
			fmt.sbprintfln(&b, "%s = true", flag.key)
		}
	}
	if len(ui.theme_backdrop) > 0 {
		fmt.sbprintfln(&b, "backdrop = \"%s\"", ui.theme_backdrop)
	}
	if font := val(ui, idx("font")); len(font) > 0 {
		fmt.sbprintfln(&b, "font = \"%s\"", font)
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
	live := theme_packs[clamp(ui.theme_slot, 0, len(theme_packs) - 1)]

	if clay.UI(clay.ID("ThemeEdit"))(
	{
		layout = {sizing = {width = clay.SizingFixed(modal_w(clay.ID("ThemeEdit"), THEME_EDIT_W + 36))}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(18), childGap = 8},
		backgroundColor = CARD,
		cornerRadius = rr(14),
		border = {color = CARD_BORDER, width = bw()},
		floating = {attachTo = .Root, zIndex = 16, offset = {0, rise(clay.ID("ThemeEdit"))}, attachment = {element = .CenterCenter, parent = .CenterCenter}},
	},
	) {
		if clay.UI(clay.ID("ThemeEditHead"))(
		{layout = {sizing = {width = clay.SizingFixed(THEME_EDIT_W)}, layoutDirection = .TopToBottom, childGap = 2}},
		) {
			clay.Text(tr("Edit theme"), {fontId = FONT_TITLE, fontSize = 16, textColor = TEXT})
			clay.Text(
				tr("An empty box derives its value. The window previews as you type."),
				{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO},
			)
		}

		if clay.UI(clay.ID("ThemeEditScroll"))(
		{
			layout = {sizing = {width = clay.SizingFixed(THEME_EDIT_W), height = clay.SizingFixed(THEME_EDIT_H)}, layoutDirection = .TopToBottom, childGap = 3},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			for field, i in THEME_FIELDS {
				if len(field.group) > 0 {
					if clay.UI(clay.ID("ThemeGroup", u32(i)))({layout = {padding = {top = 8, bottom = 2}}}) {
						eyebrow(field.group)
					}
				}
				theme_field_row(ui, live, field, i)
			}

			if clay.UI(clay.ID("ThemeFlagsEyebrow"))({layout = {padding = {top = 10, bottom = 2}}}) {
				eyebrow("STYLE")
			}
			if clay.UI(clay.ID("ThemeFlags"))(
			{layout = {sizing = {width = clay.SizingFixed(THEME_EDIT_W)}, layoutDirection = .TopToBottom, childGap = 3}},
			) {
				for flag, i in THEME_FLAGS {
					if clay.UI(clay.ID("ThemeFlagRow", u32(i)))(
					{layout = {sizing = {width = clay.SizingFixed(THEME_EDIT_W)}, childGap = 10, childAlignment = {y = .Center}}},
					) {
						clay.Text(tr(flag.label), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
						if clay.UI(clay.ID("ThemeFlagGap", u32(i)))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
						on := i < len(ui.theme_flags) && ui.theme_flags[i]
						theme_chip_indexed("ThemeFlag", u32(i), on ? "On" : "Off", on)
					}
				}
			}

			if clay.UI(clay.ID("ThemeBackdropEyebrow"))({layout = {padding = {top = 10, bottom = 2}}}) {
				eyebrow("BACKDROP")
			}
			for row in 0 ..< (len(THEME_BACKDROPS) + THEME_BACKDROPS_PER_ROW - 1) / THEME_BACKDROPS_PER_ROW {
				if clay.UI(clay.ID("ThemeBackdrops", u32(row)))(
				{layout = {sizing = {width = clay.SizingFixed(THEME_EDIT_W)}, childGap = 4, padding = {bottom = 4}}},
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

		if clay.UI(clay.ID("ThemeEditActions"))({layout = {sizing = {width = clay.SizingFixed(THEME_EDIT_W)}, childGap = 10, padding = {top = 6}}}) {
			micro_button("ThemeEditCancel", "Cancel")
			if clay.UI(clay.ID("ThemeEditGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			micro_button("ThemeEditSave", "Save and use", ACCENT)
		}
	}
}

@(private = "file")
theme_field_row :: proc(ui: ^Ui_State, live: Theme_Pack, field: Theme_Field, i: int) {
	if clay.UI(clay.ID("ThemeSeedRow", u32(i)))(
	{layout = {sizing = {width = clay.SizingFixed(THEME_EDIT_W)}, childGap = 8, childAlignment = {y = .Center}}},
	) {
		clay.Text(tr(field.label), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
		if clay.UI(clay.ID("ThemeSeedGap", u32(i)))({layout = {sizing = {width = clay.SizingGrow()}}}) {}

		// The swatch shows the effective color: what was typed, or the
		// derived value the placeholder names.
		if field.kind == .Color {
			typed := strings.trim_space(string(ui.theme_fields[i][:]))
			shown := len(typed) > 0 ? typed : derived_hint(live, field.key)
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
		input_box(ui, fmt.tprintf("ThemeSeedBox%d", i), &ui.theme_fields[i], derived_hint(live, field.key), focused, 130)
	}
}

// Input while the editor is open; true when the frame was consumed.
handle_theme_edit :: proc(ui: ^Ui_State) -> bool {
	if !ui.theme_edit {
		return false
	}
	if rl.IsKeyPressed(.ESCAPE) || clicked("ThemeEditCancel") {
		theme_edit_close(ui, .Discard)
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
			ui.client_status = strings.clone(tr("Couldn't save the theme. Check the name and colors and try again."))
			return true
		}
		ui.theme = slot
		apply_theme(ui.theme, ui.accent)
		save_settings(ui)
		toast(ui, "Theme saved")
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
@(private = "file")
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
