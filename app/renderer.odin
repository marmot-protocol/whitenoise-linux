// nendo renderer over the SDL3 shim (app/sdlrl). Replaced the raylib
// renderer so text input gets IME events and glyphs bake on demand
// (Japanese renders through the Noto CJK fallback stack).
package main

import "core:time"

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

_ :: fmt
_ :: os
_ :: strings

import "nendo"
import rl "sdlrl"

// Glyph atlases rasterize at size*UI_SCALE physical pixels, so glyphs
// are never drawn from an upscaled bitmap.
UI_SCALE: f32 = 1

// Global UI magnification: layout runs at 1/UI_ZOOM of the window and
// the SDL render scale blows the frame back up, so every size scales
// at once. UI_SCALE folds it in so glyph atlases stay crisp.
UI_ZOOM: f32 = 1.5

@(private)
Image_Crop :: struct {
	kind: Model_Kind,
	tex:  ^rl.Texture2D,
}

// Latin faces are bundled. CJK uses each platform's installed fallback
// fonts; Linux installations need the Noto CJK system package.
CJK_CANDIDATES := []cstring {
	"/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
}
CJK_BOLD_CANDIDATES := []cstring {
	"/usr/share/fonts/noto-cjk/NotoSansCJK-Bold.ttc",
	"/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
	"/usr/share/fonts/google-noto-cjk/NotoSansCJK-Bold.ttc",
}

// dpi * zoom, the density glyphs rasterize at. Re-run whenever UI_ZOOM
// changes: the glyph cache keys on pixel size, so new sizes bake fresh
// and stale bakes just go unused.
refresh_ui_scale :: proc() {
	UI_SCALE = max(rl.GetWindowScaleDPI().x, 1) * UI_ZOOM
	rl.SetPixelScale(UI_SCALE)
}

// Theme stacks occupy 6..29 and 96..99; profile fonts reserve 32..95.
// Native text, markdown and input measurement retain their logical role IDs.
@(private)
FONT_GALLERY_BOLD :: u16(30)
@(private)
FONT_GALLERY_TITLE :: u16(31)

@(private)
THEME_FONTS := []struct {
	family, file, bold_file: string,
	id:                      u16,
	fallback_files:          []string,
} {
	{"Manrope", "sidecar-manrope-400.ttf", "sidecar-manrope-700.ttf", 6, nil},
	{"Playfair Display", "sidecar-playfair-700.ttf", "", 8, nil},
	{"Noto Serif Display Condensed", "sidecar-noto-serif-display-cond.ttf", "", 9, nil},
	{"Bitter", "sidecar-bitter-700.ttf", "", 10, nil},
	{"Nixie Gothic", "sidecar-nixie-gothic.ttf", "", 11, nil},
	{"Limelight", "sidecar-limelight.ttf", "", 12, nil},
	{"Josefin Sans", "sidecar-josefin-sans-700.ttf", "", 13, nil},
	{"Cinzel", "sidecar-cinzel-700.ttf", "", 14, nil},
	{"Special Elite", "sidecar-special-elite.ttf", "", 15, nil},
	{"Jost", "sidecar-jost-700.ttf", "", 16, {"sidecar-manrope-700.ttf"}},
	{"Bangers", "sidecar-bangers.ttf", "", 17, {"sidecar-manrope-700.ttf"}},
	{
		"Impressed Metal",
		"sidecar-impressed-metal.ttf",
		"",
		18,
		{"sidecar-jost-700.ttf", "sidecar-manrope-700.ttf"},
	},
	{
		"Cormorant Garamond",
		"sidecar-cormorant-garamond-700.ttf",
		"",
		19,
		{"sidecar-manrope-700.ttf"},
	},
	{"Barlow Condensed", "sidecar-barlow-condensed-600.ttf", "", 20, {"sidecar-manrope-700.ttf"}},
	{
		"Fascinate",
		"sidecar-fascinate.ttf",
		"",
		21,
		{"sidecar-limelight.ttf", "sidecar-manrope-700.ttf"},
	},
	{"Fraunces", "sidecar-fraunces-soft-700.ttf", "", 22, {"sidecar-manrope-700.ttf"}},
	{"Rowdies", "sidecar-rowdies.ttf", "", 23, {"sidecar-manrope-700.ttf"}},
	{
		"IM FELL English SC",
		"sidecar-im-fell-english-sc.ttf",
		"",
		24,
		{"sidecar-cormorant-garamond-700.ttf", "sidecar-manrope-700.ttf"},
	},
	{"Pathway Gothic One", "sidecar-pathway-gothic-one.ttf", "", 25, {"sidecar-manrope-700.ttf"}},
	{"Kaisei Decol", "sidecar-kaisei-decol-500.ttf", "", 26, {"sidecar-manrope-700.ttf"}},
	{"Yuji Syuku", "sidecar-yuji-syuku.ttf", "", 27, {"sidecar-manrope-700.ttf"}},
	{"Syncopate", "sidecar-syncopate-700.ttf", "", 28, {"sidecar-manrope-700.ttf"}},
	{"Kalam", "Kalam-Regular.ttf", "Kalam-Bold.ttf", 96, nil},
	// One weight: naming it twice gives body text regular fallbacks for
	// missing glyphs and titles bold ones, like the other two-file faces.
	{"W95FA", "W95FA.otf", "W95FA.otf", 98, nil},
	// The CSS unicode-range face owns only digits and their separators.
	// Letters must reach Fell before the complete Cormorant fallback.
	{
		"Hollow Figures",
		"sidecar-hollow-figures-700.ttf",
		"",
		29,
		{
			"sidecar-im-fell-english-sc.ttf",
			"sidecar-cormorant-garamond-700.ttf",
			"sidecar-manrope-700.ttf",
		},
	},
}

@(private)
Theme_Font_Role :: enum {
	Body,
	Title,
}

@(private)
theme_font_stack :: proc(family: string, role: Theme_Font_Role) -> u16 {
	for face in THEME_FONTS {
		if face.family == family {
			return face.id + (role == .Title && face.bold_file != "" ? u16(1) : u16(0))
		}
	}
	return role == .Title ? FONT_TITLE : FONT_BODY
}

// Whether a pack names a bundled face for body or titles, which is what
// the "Theme font" switch can turn off.
@(private)
pack_ships_face :: proc(pack: ^Theme_Pack) -> bool {
	body := theme_font_stack(pack.font, .Body) != FONT_BODY
	title := theme_font_stack(pack.font_title, .Title) != FONT_TITLE
	return body || title
}

@(private)
theme_fonts_loaded: bool

@(private)
applied_text_scale: f32 = 1

@(private)
apply_theme_fonts :: proc() {
	if !theme_fonts_loaded {return}
	body_changed := rl.SelectFontStack(FONT_BODY, theme_font_stack(THEME_FONT, .Body))
	title_changed := rl.SelectFontStack(FONT_TITLE, theme_font_stack(THEME_FONT_TITLE, .Title))
	italic_changed := rl.SelectFontStack(
		FONT_ITALIC,
		CHALK_DRAWN ? theme_font_stack(THEME_FONT, .Body) : FONT_ITALIC,
	)
	bold_italic_changed := rl.SelectFontStack(
		FONT_BOLD_ITALIC,
		CHALK_DRAWN ? theme_font_stack(THEME_FONT_TITLE, .Title) : FONT_BOLD_ITALIC,
	)
	scale_changed := applied_text_scale != rl.TextScale
	applied_text_scale = rl.TextScale
	if !body_changed &&
	   !title_changed &&
	   !italic_changed &&
	   !bold_italic_changed &&
	   !scale_changed {return}
	// Logical IDs are stable, so geometry caches cannot detect this switch.
	wrap_clear()
	if nendo.current_context() != nil {
		nendo.reset_measure_cache()
		anim_snap_all()
	}
}

init_fonts :: proc() {
	timing_start := time.tick_now()
	defer local_timing_end(.fonts_init, timing_start)
	rl.SetPixelScale(UI_SCALE)
	// A packaged build ships its own copy of each face; res_font puts it
	// at the head of the stack so the binary never depends on which
	// fonts the host distro happens to have installed.
	stack :: proc(
		id: u16,
		bundled: string,
		candidates: []cstring,
		fallbacks: []cstring,
		base: string = "",
		source_fallbacks: []string = nil,
	) {
		paths := make([dynamic]cstring, context.temp_allocator)
		font := res_font(bundled)
		defer delete(font)
		if font != nil {append(&paths, font)}
		fallback_start := len(paths)
		for name in source_fallbacks {
			if path := res_font(name); path != nil {
				append(&paths, path)
			}
		}
		fallback_end := len(paths)
		defer {for path in paths[fallback_start:fallback_end] {delete(path)}}
		base_font: cstring
		if base != "" {base_font = res_font(base); append(&paths, base_font)}
		defer delete(base_font)
		append(&paths, ..candidates)
		append(&paths, ..fallbacks)
		if id != FONT_ICON {
			when ODIN_OS == .Windows {
				windir := os.get_env("WINDIR", context.temp_allocator)
				for face in ([]string{"msyh.ttc", "meiryo.ttc", "YuGothR.ttc", "malgun.ttf"}) {
					append(
						&paths,
						strings.clone_to_cstring(
							fmt.tprintf("%s/Fonts/%s", windir, face),
							context.temp_allocator,
						),
					)
				}
			} else when ODIN_OS == .Darwin {
				append(
					&paths,
					"/System/Library/Fonts/PingFang.ttc",
					"/System/Library/Fonts/Hiragino Sans GB.ttc",
					"/System/Library/Fonts/AppleSDGothicNeo.ttc",
				)
			}
		}
		fallback_fonts: [3]cstring
		defer {for path in fallback_fonts {delete(path)}}
		if id != FONT_ICON {
			for name, i in ([]string{"NotoSansMath-Regular.ttf", "NotoSansSymbols-Regular.ttf", "NotoSansSymbols2-Regular.ttf"}) {
				fallback_fonts[i] = res_font(name)
				append(&paths, fallback_fonts[i])
			}
		}
		rl.LoadFontStack(id, paths[:], text_emoji)
	}
	stack(FONT_BODY, "LiberationSans-Regular.ttf", FONT_CANDIDATES, CJK_CANDIDATES)
	stack(FONT_TITLE, "LiberationSans-Bold.ttf", TITLE_CANDIDATES, CJK_BOLD_CANDIDATES)
	stack(
		FONT_ITALIC,
		"LiberationSans-Italic.ttf",
		{
			"/usr/share/fonts/liberation/LiberationSans-Italic.ttf",
			"/usr/share/fonts/truetype/liberation/LiberationSans-Italic.ttf",
			"/usr/share/fonts/liberation-sans/LiberationSans-Italic.ttf",
		},
		CJK_CANDIDATES,
	)
	stack(
		FONT_BOLD_ITALIC,
		"LiberationSans-BoldItalic.ttf",
		{
			"/usr/share/fonts/liberation/LiberationSans-BoldItalic.ttf",
			"/usr/share/fonts/truetype/liberation/LiberationSans-BoldItalic.ttf",
			"/usr/share/fonts/liberation-sans/LiberationSans-BoldItalic.ttf",
		},
		CJK_BOLD_CANDIDATES,
	)
	stack(FONT_MONO, "LiberationMono-Regular.ttf", MONO_CANDIDATES, CJK_CANDIDATES)
	stack(FONT_ICON, "JetBrainsMonoNerdFont-Regular.ttf", ICON_CANDIDATES, nil)
	rl.IconFont = FONT_ICON // ink-boxed, so icons center in their buttons
	for face in THEME_FONTS {
		if face.bold_file != "" {
			stack(
				face.id,
				face.file,
				FONT_CANDIDATES,
				CJK_CANDIDATES,
				"LiberationSans-Regular.ttf",
			)
			stack(
				face.id + 1,
				face.bold_file,
				TITLE_CANDIDATES,
				CJK_BOLD_CANDIDATES,
				"LiberationSans-Bold.ttf",
			)
		} else {
			stack(
				face.id,
				face.file,
				TITLE_CANDIDATES,
				CJK_BOLD_CANDIDATES,
				"LiberationSans-Bold.ttf",
				face.fallback_files,
			)
		}
	}
	// Gallery typography remains stable while live previews change the app's aliases.
	rl.SelectFontStack(FONT_GALLERY_BOLD, theme_font_stack("Manrope", .Title))
	rl.SelectFontStack(FONT_GALLERY_TITLE, FONT_TITLE)
	theme_fonts_loaded = true
	apply_theme_fonts()
}

// Hand-drawn themes re-jitter every outline eight times a second, the
// "boiling line" of cel animation: nothing sits still, so the chrome
// reads as drawn rather than printed. Each edge gets its own offset
// from a hash of (element, edge, time slot), so there is no state.
BOIL_HZ :: 8
BOIL_AMP :: f32(0.9)

boil :: proc(id: u32, edge: u32) -> f32 {
	if !PAPER_DECOR || CHALK_DRAWN {
		return 0
	}
	frame_deadline = min(frame_deadline, (f64(u64(rl.GetTime() * BOIL_HZ)) + 1) / BOIL_HZ)
	h := (id ~ (edge * 0x9e3779b9) ~ (u32(rl.GetTime() * BOIL_HZ) * 0x85ebca6b)) * 0xc2b2ae35
	h ~= h >> 15
	return (f32(h % 1000) / 500 - 1) * BOIL_AMP
}

nendo_color :: proc(color: nendo.Color) -> rl.Color {
	return {u8(color.r), u8(color.g), u8(color.b), u8(color.a)}
}

measure_text :: proc(
	text: string,
	config: ^nendo.Text_Style,
	userData: rawptr,
) -> nendo.Dimensions {
	context.allocator = reload_allocator()
	size := rl.MeasureTextLine(config.font, config.size, text, f32(config.spacing))
	return {width = size.x, height = size.y}
}

// ── The frame, in two layers ────────────────────────────────────────
//
// nendo emits one flat command list, and the modal veil (shell.odin) is
// the only thing in it that separates the page from what is over the
// page: it mounts at zIndex 9, under every centered modal and over
// everything else. Splitting the list there and rendering each half
// into its own target buys the two effects nendo cannot express, a blur
// of the page behind a modal and one opacity over the whole modal
// layer, for one texture round trip while a modal is open and nothing
// at all when none is.

SCENE_SLOT :: 0
LAYER_SLOT :: 1
FRAME_SLOT :: 2
HOLD_SLOT :: 3
PUSH_SLOT :: 4 // incoming view while FRAME retains the displayed composite
MODAL_LIFT :: f32(0.04) // how far the modal layer scales in from
PAGE_PUSH :: f32(0.03) // how far the outgoing page pulls away from the eye

// The whole frame, composited. Everything is drawn into a target rather
// than straight at the window for one reason: the target still holds
// the frame that was on screen a moment ago, so a page switch can copy
// it aside while the next page takes its place. nendo is
// immediate mode and keeps nothing, and a GPU→CPU readback (CaptureFrame)
// is far too slow per frame; a texture that simply isn't cleared yet
// costs nothing.
draw_frame :: proc(render_commands: []nendo.Render_Command) {
	rl.ChalkDrawn = CHALK_DRAWN
	if rl.Noir && (g_prefs == nil || !g_prefs.reduce_motion) {
		GRAIN_HZ :: 24
		frame := rl.GetTime() * GRAIN_HZ
		rl.NoirFrame = u32(u64(frame) & 0xffff)
		frame_deadline = min(frame_deadline, (f64(u64(frame)) + 1) / GRAIN_HZ)
	}
	if page_held {
		page_held = false
		if !rl.CopyTarget(HOLD_SLOT, FRAME_SLOT) {
			page_t = 1
		}
	}
	pushing := page_push && page_t < 1
	slot := pushing ? PUSH_SLOT : FRAME_SLOT
	if !rl.BeginTarget(slot) {
		render_nendo(render_commands)
		reveal_step()
		return
	}
	render_nendo(render_commands)
	reveal_step() // holds the old theme's frame while the new one opens
	rl.EndTarget()
	// Retain the actual moving pair, not just its destination. A second
	// navigation click can push the partially finished transition away.
	if pushing && rl.BeginTarget(FRAME_SLOT) {
		rl.DrawTarget(PUSH_SLOT, 1)
		draw_page_transition()
		rl.EndTarget()
		slot = FRAME_SLOT
	}
	rl.DrawTarget(slot, 1)
	if !page_push {
		draw_page_transition()
	}
}

// Adjacent, opaque panes share one moving edge. Tab changes push the sidebar
// and content in opposite directions; the navigation column stays anchored.
// Chat changes move only the content. Other views retain their depth fade.
@(private = "file")
draw_page_transition :: proc() {
	if page_t >= 1 {
		return
	}
	if page_push {
		if box, ok := element_box(nendo.id("MainCard")); ok {
			push_region(box, -1)
		}
		if page_tab_push {
			if box, ok := element_box(nendo.id("RailContent")); ok {
				push_region(box, 1)
			}
		}
		return
	}
	box, ok := element_box(nendo.id("MainCard"))
	if !ok {
		return
	}
	rl.DrawTargetRegion(
		HOLD_SLOT,
		box.x * UI_ZOOM,
		box.y * UI_ZOOM,
		box.width * UI_ZOOM,
		box.height * UI_ZOOM,
		1 - page_t,
		1 + PAGE_PUSH * page_t,
	)
}

@(private = "file")
push_region :: proc(box: nendo.Rect, direction: f32) {
	width := box.width * UI_ZOOM
	travel := width * page_t
	rl.DrawTargetRegion(
		HOLD_SLOT,
		box.x * UI_ZOOM,
		box.y * UI_ZOOM,
		width,
		box.height * UI_ZOOM,
		1,
		offset_x = direction * travel,
	)
	rl.DrawTargetRegion(
		PUSH_SLOT,
		box.x * UI_ZOOM,
		box.y * UI_ZOOM,
		width,
		box.height * UI_ZOOM,
		1,
		offset_x = direction * (travel - width),
	)
}

// Index of the veil's own rectangle, or -1 when no modal is mounted.
@(private = "file")
veil_split :: proc(commands: []nendo.Render_Command) -> int {
	veil := nendo.id("ModalVeil").id
	for command, i in commands {
		if command.id == veil && command.kind == .Rectangle {
			return i
		}
	}
	return -1
}

render_nendo :: proc(
	render_commands: []nendo.Render_Command,
	allocator := context.temp_allocator,
) {
	split := veil_split(render_commands)
	if split < 0 {
		render_range(render_commands, allocator)
		return
	}
	veil := open_t(nendo.id("ModalVeil"))
	if !rl.BeginTarget(SCENE_SLOT) {
		render_range(render_commands, allocator)
		return
	}
	render_range(render_commands[:split], allocator)
	rl.EndTarget()
	rl.DrawTarget(SCENE_SLOT, 1)
	if !SHARP_BACKDROP {rl.DrawTargetBlurred(SCENE_SLOT, veil)}

	if !rl.BeginTarget(LAYER_SLOT) {
		render_range(render_commands[split:], allocator)
		return
	}
	render_range(render_commands[split:], allocator)
	rl.EndTarget()
	rl.DrawTarget(LAYER_SLOT, veil, 1 - MODAL_LIFT * (1 - veil))
}

// A box's user_data marking a title band: on a title-wash pack its fill
// fades to ACCENT_HI, left to right, like a desktop window's caption.
// Distinct from STICKER_IMAGE, which marks images.
TITLE_BAND :: uintptr(2)

// A relief theme draws its structural borders as 3D edges, the way the
// late-90s desktop did, instead of one flat color. The border's shape
// picks the relief:
//
//   2px+ on all four sides, field fill   sunken well    text boxes, lists
//   2px+ on all four sides, other fill   raised face    buttons, cards
//   thinner or partial                   etched groove  group boxes, rules
//
// Focus rings, accents and rounded corners are not structural and stay flat.
@(private = "file")
Relief :: enum {
	Raised,
	Sunken,
	Etched,
}

@(private = "file")
relief_of :: proc(border: nendo.Border_Command) -> (Relief, bool) {
	structural :=
		border.color == FIELD_BORDER ||
		border.color == CARD_BORDER ||
		border.color == ELEVATED_BORDER ||
		border.color == DIVIDER ||
		border.color == BORDER_2
	r := border.radius
	if !RELIEF || !structural || r.top_left + r.top_right + r.bottom_left + r.bottom_right > 0 {
		return {}, false
	}
	w := border.width
	if min(w.left, w.right, w.top, w.bottom) < 2 {
		return .Etched, true
	}
	return border.fill == ROW_BG ? .Sunken : .Raised, true
}

// Two 1px frames, outer then inner. Each frame paints its top-left pair
// first and its bottom-right pair over it, so the shaded side owns the
// two corners where they meet. The darkest line is the border's color.
//
//   raised           sunken           etched
//   hi  hi  hi  dk   lo  lo  lo  hi   lo  lo  lo  hi
//   hi  gl  lo  dk   lo  dk  gl  hi   lo  hi  lo  hi
//   hi  lo  lo  dk   lo  gl  gl  hi   lo  lo  lo  hi
//   dk  dk  dk  dk   hi  hi  hi  hi   hi  hi  hi  hi
@(private = "file")
relief_border :: proc(box: nendo.Rect, border: nendo.Border_Command, relief: Relief) {
	dark := nendo_color(border.color)
	hi, lo, glint := nendo_color(BEVEL_HI), nendo_color(BEVEL_LO), nendo_color(TOP_GLINT)
	lines: [4]rl.Color // outer top-left, outer bottom-right, inner top-left, inner bottom-right
	switch relief {
	case .Raised:
		lines = {hi, dark, glint, lo}
	case .Sunken:
		lines = {lo, hi, dark, glint}
	case .Etched:
		lines = {lo, hi, hi, lo}
	}
	sides := border.width
	for color, i in lines {
		inset := f32(i / 2)
		x, y := box.x + inset, box.y + inset
		w, h := box.width - 2 * inset, box.height - 2 * inset
		if i % 2 == 0 {
			if sides.top > 0 {rl.DrawRectangleRec(x, y, w, 1, color)}
			if sides.left > 0 {rl.DrawRectangleRec(x, y, 1, h, color)}
		} else {
			if sides.bottom > 0 {rl.DrawRectangleRec(x, y + h - 1, w, 1, color)}
			if sides.right > 0 {rl.DrawRectangleRec(x + w - 1, y, 1, h, color)}
		}
	}
}

// A theme with selected-inverts-text re-inks text that sits on a
// SELECTED fill, so an opaque selection reads like a desktop list
// (white on navy) without every row choosing its own text color. The
// text tokens flip, and so does accent ink, which would vanish into an
// accent selection; status colors keep their hue. Fills match on z, so
// a menu floating over a selected row keeps its ink.
@(private = "file")
Selected_Fill :: struct {
	rect: nendo.Rect,
	z:    i16,
}

@(private = "file")
on_selection :: proc(fills: []Selected_Fill, text: ^nendo.Render_Command) -> bool {
	ink := text.text.color
	text_ink := ink == TEXT || ink == TEXT_DIM || ink == TEXT_LO || ink == TEXT_VLO
	accent_ink := ink == ACCENT || ink == ACCENT_HI || ink == ACCENT_DIM
	if !text_ink && !accent_ink {
		return false
	}
	cx := text.rect.x + text.rect.width / 2
	cy := text.rect.y + text.rect.height / 2
	for fill in fills {
		r := fill.rect
		if fill.z == text.z &&
		   cx >= r.x &&
		   cx < r.x + r.width &&
		   cy >= r.y &&
		   cy < r.y + r.height {
			return true
		}
	}
	return false
}

@(private = "file")
render_range :: proc(
	render_commands: []nendo.Render_Command,
	allocator := context.temp_allocator,
) {
	overlay_colors := make([dynamic]nendo.Color, allocator)
	// ponytail: a frame shows a handful of selected rows; past 16 the
	// extra rows keep their ink. Grow this if a multi-select list lands.
	selected_fills: [16]Selected_Fill
	selected_count := 0
	for &command in render_commands {
		render_command := &command
		bounds := render_command.rect

		switch render_command.kind {
		case .None:
		case .Text:
			config := render_command.text
			text := config.text
			style := u8(uintptr(render_command.user_data))
			if style & (TEXT_CODE | TEXT_MATH | TEXT_ADDED | TEXT_REMOVED) != 0 {
				plate := CODE_PLATE
				if style & TEXT_ADDED != 0 {plate = fade(ACCENT, 0.22)}
				if style & TEXT_REMOVED != 0 {plate = fade(DANGER, 0.22)}
				rl.DrawRectangleRoundedPx(
					bounds.x,
					bounds.y,
					bounds.width,
					bounds.height,
					2,
					nendo_color(plate),
				)
			}
			ink := config.color
			if SELECTED_INVERTS_TEXT &&
			   on_selection(selected_fills[:selected_count], render_command) {
				ink = ON_ACCENT
			}
			rl.DrawTextLine(
				config.font,
				config.size,
				text,
				bounds.x,
				bounds.y,
				f32(config.spacing),
				nendo_color(ink),
			)
			if style & (TEXT_STRIKE | TEXT_REMOVED) != 0 {
				rl.DrawRectangleRec(
					bounds.x,
					bounds.y + bounds.height / 2,
					bounds.width,
					1,
					nendo_color(ink),
				)
			}
		case .Image:
			config := render_command.image
			tint := nendo.Color{255, 255, 255, 255}
			if len(overlay_colors) > 0 && overlay_colors[len(overlay_colors) - 1] != 0 {
				tint = overlay_colors[len(overlay_colors) - 1]
			}
			texture := (^rl.Texture2D)(config.image)
			if uintptr(render_command.user_data) == STICKER_IMAGE {
				sticker_draw(texture, bounds, render_command.id, nendo_color(tint))
				continue
			}
			rl.DrawTextureRect(
				texture,
				bounds.x,
				bounds.y,
				bounds.width,
				bounds.height,
				nendo_color(tint),
			)
		case .Scissor_Start:
			rl.BeginScissorMode(
				i32(math.round(bounds.x)),
				i32(math.round(bounds.y)),
				i32(math.round(bounds.width)),
				i32(math.round(bounds.height)),
			)
		case .Scissor_End:
			rl.EndScissorMode()
		case .Rectangle:
			// Every fill eases toward its new color instead of swapping.
			// Doing it here rather than at the call sites is what makes
			// hover, selection and theme changes animate app-wide for
			// free: nendo hands the renderer a stable element id, which
			// is exactly the key the motion store wants.
			config := render_command.rectangle
			fill := nendo_color(anim_color(render_command.id, config.color, HOVER_RATE))
			if uintptr(render_command.user_data) == TITLE_BAND && TITLE_WASH {
				rl.DrawRectangleGradientH(
					bounds.x,
					bounds.y,
					bounds.width,
					bounds.height,
					fill,
					nendo_color(ACCENT_HI),
				)
			} else if config.radius.top_left > 0 {
				rl.DrawRectangleRoundedPx(
					bounds.x,
					bounds.y,
					bounds.width,
					bounds.height,
					config.radius.top_left,
					fill,
				)
			} else {
				rl.DrawRectangleRec(bounds.x, bounds.y, bounds.width, bounds.height, fill)
			}
			if SELECTED_INVERTS_TEXT &&
			   config.color == SELECTED &&
			   selected_count < len(selected_fills) {
				selected_fills[selected_count] = {bounds, render_command.z}
				selected_count += 1
			}
		case .Border:
			config := render_command.border
			color := nendo_color(
				anim_color(anim_key(render_command.id, 1), config.color, HOVER_RATE),
			)
			if relief, ok := relief_of(config); ok {
				relief_border(bounds, config, relief)
				continue
			}
			min_radius := min(bounds.width, bounds.height) / 2
			tl := min(config.radius.top_left, min_radius)
			tr := min(config.radius.top_right, min_radius)
			bl := min(config.radius.bottom_left, min_radius)
			br := min(config.radius.bottom_right, min_radius)

			id := render_command.id
			if config.width.left > 0 {
				rl.DrawRectangleRec(
					bounds.x + boil(id, 0),
					bounds.y + tl,
					f32(config.width.left),
					bounds.height - tl - bl,
					color,
				)
			}
			if config.width.right > 0 {
				rl.DrawRectangleRec(
					bounds.x + bounds.width - f32(config.width.right) + boil(id, 1),
					bounds.y + tr,
					f32(config.width.right),
					bounds.height - tr - br,
					color,
				)
			}
			if config.width.top > 0 {
				rl.DrawRectangleRec(
					bounds.x + tl,
					bounds.y + boil(id, 2),
					bounds.width - tl - tr,
					f32(config.width.top),
					color,
				)
			}
			if config.width.bottom > 0 {
				rl.DrawRectangleRec(
					bounds.x + bl,
					bounds.y + bounds.height - f32(config.width.bottom) + boil(id, 3),
					bounds.width - bl - br,
					f32(config.width.bottom),
					color,
				)
			}

			// Arc centers sit exactly radius-in from the box corner so
			// the annular band lines up with the straight edge rects.
			if tl > 0 {
				rl.DrawArc(
					bounds.x + tl,
					bounds.y + tl,
					tl,
					180,
					270,
					f32(config.width.top),
					color,
				)
			}
			if tr > 0 {
				rl.DrawArc(
					bounds.x + bounds.width - tr,
					bounds.y + tr,
					tr,
					270,
					360,
					f32(config.width.top),
					color,
				)
			}
			if bl > 0 {
				rl.DrawArc(
					bounds.x + bl,
					bounds.y + bounds.height - bl,
					bl,
					90,
					180,
					f32(config.width.bottom),
					color,
				)
			}
			if br > 0 {
				rl.DrawArc(
					bounds.x + bounds.width - br,
					bounds.y + bounds.height - br,
					br,
					0,
					90,
					f32(config.width.bottom),
					color,
				)
			}
		case .Overlay_Start:
			config := render_command.overlay
			append(&overlay_colors, config.color)
		case .Overlay_End:
			pop(&overlay_colors)
		case .Custom:
			// 3D tiles; the payload's first field says which kind.
			data := render_command.custom.custom
			switch (^Model_Kind)(data)^ {
			case .Whip:
				pane := (^Whip_Payload)(data)
				rl.DrawWhipPane(
					pane.pane,
					bounds.x,
					bounds.y,
					bounds.width,
					bounds.height,
					pane.input_top,
				)
			case .Mesh:
				stl_draw((^Stl_View)(data), bounds)
			case .Spinner:
				vertices: [18 * 6]rl.Vertex
				phase := rl.GetTime() * 5
				radius := min(bounds.width, bounds.height) * 0.4
				for i in 0 ..< 18 {
					a := phase + f64(i) * math.TAU / 24
					b := a + math.TAU / 24
					points := [4][2]f32 {
						{f32(math.cos(a)), f32(math.sin(a))} * radius,
						{f32(math.cos(b)), f32(math.sin(b))} * radius,
						{f32(math.cos(b)), f32(math.sin(b))} * (radius - 2),
						{f32(math.cos(a)), f32(math.sin(a))} * (radius - 2),
					}
					for corner, k in ([6]int{0, 1, 2, 0, 2, 3}) {
						vertices[i * 6 + k] = {
							position = {
								bounds.x + bounds.width / 2 + points[corner].x,
								bounds.y + bounds.height / 2 + points[corner].y,
							},
							color    = {
								ACCENT.r / 255,
								ACCENT.g / 255,
								ACCENT.b / 255,
								ACCENT.a / 255,
							},
						}
					}
				}
				rl.DrawTrianglesClipped(
					vertices[:],
					bounds.x,
					bounds.y,
					bounds.width,
					bounds.height,
				)
			case .Gcode:
				gcode_draw((^Gcode_View)(data), bounds)
			case .Synth:
				synth_draw(bounds)
			case .Dust:
				dust_draw(bounds)
			case .Scan:
				scan_draw(bounds)
			case .Wash:
				wash_draw(bounds)
			case .Deco:
				deco_draw(bounds)
			case .Blinds:
				blinds_draw(bounds)
			case .Stripes:
				stripes_draw(bounds)
			case .Waves:
				waves_draw(bounds)
			case .Airmail:
				airmail_draw(bounds)
			case .Check:
				check_draw((^Check_View)(data), bounds)
			case .Glow:
				glow_draw((^Glow_View)(data), bounds)
			case .Shade:
				shade_draw((^Shade_View)(data), bounds)
			case .Hidden_Border:
				hidden_border_draw(bounds)
			case .Profile_Background:
				tint := nendo.Color{255, 255, 255, 255}
				if len(overlay_colors) > 0 &&
				   overlay_colors[len(overlay_colors) - 1] !=
					   0 {tint = overlay_colors[len(overlay_colors) - 1]}
				profile_background_draw((^Profile_Background)(data), bounds, nendo_color(tint))
			case .Avatar_Erase:
				view := (^Avatar_Erase)(data)
				tint := nendo.Color{255, 255, 255, 255}
				if len(overlay_colors) > 0 && overlay_colors[len(overlay_colors) - 1] != 0 {
					tint = overlay_colors[len(overlay_colors) - 1]
				}
				// Alternating sweeps erase the photo, not its geometry. Fixed ragged
				// edges move only with hover progress; reversal redraws the same strokes.
				vertices: [9 * 6]rl.Vertex
				used := 0
				for strip in 0 ..< 96 {
					row := strip / 8
					removed := clamp(view.progress * 12 - f32(row), 0, 1)
					if removed >= 1 {continue}
					y0, y1 := f32(strip) / 96, f32(strip + 1) / 96
					if removed == 0 {y1 = 1}
					front := removed
					if removed > 0 {
						h := (u32(strip) * 0x9e3779b9) ~ u32(strip * 31)
						front = clamp(front + (f32(h % 101) / 100 - 0.5) * 0.025, 0, 1)
					}
					x0, x1 := row % 2 == 0 ? front : 0, row % 2 == 0 ? 1 : 1 - front
					for uv, k in ([6]rl.Vector2{{x0, y0}, {x1, y0}, {x1, y1}, {x0, y0}, {x1, y1}, {x0, y1}}) {
						vertices[used + k] = {
							position  = {
								bounds.x + uv.x * bounds.width,
								bounds.y + uv.y * bounds.height,
							},
							color     = {tint.r / 255, tint.g / 255, tint.b / 255, tint.a / 255},
							tex_coord = {uv.x, uv.y},
						}
					}
					used += 6
					if removed == 0 {break}
				}
				rl.DrawTrianglesClipped(
					vertices[:used],
					bounds.x,
					bounds.y,
					bounds.width,
					bounds.height,
					view.tex,
				)
			case .Avatar_Hinge:
				view := (^Avatar_Hinge)(data)
				angle := view.angle * math.PI / 180
				sin, cos := math.sin(angle), math.cos(angle)
				tint := nendo.Color{255, 255, 255, 255}
				if len(overlay_colors) > 0 && overlay_colors[len(overlay_colors) - 1] != 0 {
					tint = overlay_colors[len(overlay_colors) - 1]
				}
				// The top-center hinge stays fixed. Rotate the photo, clipped to
				// the original avatar slot. The photo is pre-masked, so it keeps
				// its shape while it swings.
				uvs := [6]rl.Vector2{{0, 0}, {1, 0}, {1, 1}, {0, 0}, {1, 1}, {0, 1}}
				vertices: [6]rl.Vertex
				for uv, k in uvs {
					dx := (uv.x - 0.5) * bounds.width
					dy := uv.y * bounds.height
					vertices[k] = {
						position  = {
							bounds.x + bounds.width / 2 + dx * cos - dy * sin,
							bounds.y + dx * sin + dy * cos,
						},
						color     = {tint.r / 255, tint.g / 255, tint.b / 255, tint.a / 255},
						tex_coord = {uv.x, uv.y},
					}
				}
				rl.DrawTrianglesClipped(
					vertices[:],
					bounds.x,
					bounds.y,
					bounds.width,
					bounds.height,
					view.tex,
				)
			case .Banner:
				tint := nendo.Color{255, 255, 255, 255}
				if len(overlay_colors) > 0 && overlay_colors[len(overlay_colors) - 1] != 0 {
					tint = overlay_colors[len(overlay_colors) - 1]
				}
				banner_draw((^Banner_View)(data), bounds, tint)
			case .Image_Crop:
				tex := (^Image_Crop)(data).tex
				if tex.width <= 0 || tex.height <= 0 {continue}
				scale := max(bounds.width / f32(tex.width), bounds.height / f32(tex.height))
				tint := nendo.Color{255, 255, 255, 255}
				if len(overlay_colors) > 0 &&
				   overlay_colors[len(overlay_colors) - 1] !=
					   0 {tint = overlay_colors[len(overlay_colors) - 1]}
				// Crop from the top left to preserve the beginning of screenshots.
				// Renderer clipping leaves wheel scrolling with the timeline.
				rl.BeginScissorMode(
					i32(bounds.x),
					i32(bounds.y),
					i32(bounds.width),
					i32(bounds.height),
				)
				rl.DrawTextureRect(
					tex,
					bounds.x,
					bounds.y,
					f32(tex.width) * scale,
					f32(tex.height) * scale,
					nendo_color(tint),
				)
				rl.EndScissorMode()
			}
		}
	}
}
