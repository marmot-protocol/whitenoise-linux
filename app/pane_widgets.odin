package main

import "core:fmt"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Centered placeholder with a title and a sub line.
centered_note :: proc(id_str: string, title: string, sub: string) {
	if clay.UI(clay.ID(id_str))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childAlignment = {x = .Center, y = .Center},
			childGap = 8,
		},
	},
	) {
		clay.Text(title, {fontId = FONT_TITLE, fontSize = 24, textColor = TEXT_DIM})
		if len(sub) > 0 {
			clay.Text(sub, {fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM})
		}
	}
}

// Section eyebrow, ALL CAPS.
eyebrow :: proc(text: string) {
	// A stencilled theme brackets its captions: [ACTIONS], not ACTIONS.
	label := BRACKET_LABELS ? fmt.tprintf("[%s]", text) : text
	clay.Text(label, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM, letterSpacing = 2})
}

// Small bordered chip: 11px label, hairline border, hover fill.
// Pass a color to tint border and label (DANGER).
micro_button :: proc(id_str: string, label: string, color: clay.Color = {}) {
	tinted := color.a != 0
	down := press_down(clay.ID(id_str))
	if clay.UI(clay.ID(id_str))(
	{
		layout = {padding = {left = 10, right = 10, top = 5 + down, bottom = 5 - down}},
		backgroundColor = hovered() ? HOVER : {},
		cornerRadius = rr(7),
		border = {color = tinted ? color : FIELD_BORDER, width = bw()},
	},
	) {
		clay.Text(
			label,
			{fontId = FONT_BODY, fontSize = 11, textColor = tinted ? color : TEXT_DIM},
		)
	}
}

// marmot://profile deep link for an npub, rasterized to a texture.
// nil when the link is too long for the encoder (qr.odin).
qr_texture :: proc(npub: string) -> ^rl.Texture2D {
	image, ok := qr_image(fmt.tprintf("marmot://profile/%s?from=qr", npub))
	if !ok {
		return nil
	}
	tex := new(rl.Texture2D)
	tex^ = rl.LoadTextureFromImage(image)
	return tex
}

@(private)
identity_codes :: proc(
	prefix: string,
	key: string,
	qr: ^rl.Texture2D,
	width: f32,
	font: u16 = FONT_TITLE,
) {
	FONT_TITLE := font
	if clay.UI(clay.ID(fmt.tprintf("%sQrPlate", prefix)))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {top = 8, bottom = 16},
			childAlignment = {x = .Center},
		},
	},
	) {
		if clay.UI(clay.ID(fmt.tprintf("%sFingerprint", prefix)))(
		{layout = {layoutDirection = width < 424 ? .TopToBottom : .LeftToRight, childGap = 16}},
		) {
			if clay.UI(clay.ID(fmt.tprintf("%sPatternCard", prefix)))(
			{
				layout = {
					layoutDirection = .TopToBottom,
					padding = clay.PaddingAll(16),
					childGap = 12,
					childAlignment = {x = .Center},
				},
				backgroundColor = CARD,
				cornerRadius = rr(10),
				border = {color = FIELD_BORDER, width = bw()},
			},
			) {
				crop_circle(fmt.tprintf("%sCircle", prefix), 0, key, 160, .Square)
				clay.Text(
					tr("Visual fingerprint"),
					{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT_DIM},
				)
			}
			if qr != nil {
				if clay.UI(clay.ID(fmt.tprintf("%sScanCard", prefix)))(
				{
					layout = {
						layoutDirection = .TopToBottom,
						padding = clay.PaddingAll(16),
						childGap = 12,
						childAlignment = {x = .Center},
					},
					backgroundColor = CARD,
					cornerRadius = rr(10),
					border = {color = FIELD_BORDER, width = bw()},
				},
				) {
					if clay.UI(clay.ID(fmt.tprintf("%sQr", prefix)))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(160),
								height = clay.SizingFixed(160),
							},
						},
						image = {imageData = qr},
					},
					) {}
					clay.Text(
						tr("Scan to add"),
						{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT_DIM},
					)
				}
			}
		}
	}
}


theme_chip_indexed :: proc(id_str: string, index: u32, label: string, active: bool) {
	if clay.UI(clay.ID(id_str, index))(
	{
		layout = {padding = {left = 14, right = 14, top = 8, bottom = 8}},
		backgroundColor = active ? ACCENT : ROW_BG,
		cornerRadius = rr(8),
		border = active ? {} : clay.BorderElementConfig{color = FIELD_BORDER, width = bw()},
	},
	) {
		clay.Text(
			label,
			{fontId = FONT_BODY, fontSize = 14, textColor = active ? ON_ACCENT : TEXT},
		)
	}
}

// Header actions expand to show their label while active; an inactive
// action names itself in a tooltip on hover instead.
header_chip :: proc(id_str: string, glyph: string, active: bool, label: string) {
	pad := tap_size() ? u16(13) : u16(8)
	if clay.UI(clay.ID(id_str))(
	{
		layout = {
			padding = {left = 10, right = 10, top = pad, bottom = pad},
			childAlignment = {y = .Center},
		},
		backgroundColor = active ? ACCENT : hovered() ? HOVER : ROW_BG,
		cornerRadius = rr(8),
	},
	) {
		clay.Text(
			glyph,
			{fontId = FONT_ICON, fontSize = 14, textColor = active ? ON_ACCENT : TEXT},
		)
		header_label(label, active)
	}
}

@(private)
HEADER_LABEL_SECS :: f32(0.1)

@(private)
header_label :: proc(label: string, active: bool) {
	if !active && hovered() {tooltip(label)}
	id := clay.ID_LOCAL("HeaderLabel")
	target: f32 = active ? 1 : 0
	entry, seen := anim_vals[id.id]
	if !seen || entry.frame != anim_frame {
		step := anim_dt / HEADER_LABEL_SECS
		entry.v += clamp(target - entry.v, -step, step)
		if !motion_on() || abs(target - entry.v) < ANIM_EPS {entry.v = target}
		entry.frame = anim_frame
		anim_vals[id.id] = entry
		if entry.v != target {anim_moving += 1}
	}
	if entry.v == 0 {return}
	progress := ease_in_out(entry.v)
	width := rl.MeasureTextLine(FONT_BODY, 13, label, 0).x + 6
	if clay.UI(id)(
	{
		layout = {sizing = {width = clay.SizingFixed(width * progress)}, padding = {left = 6}},
		clip = {horizontal = true},
	},
	) {
		clay.Text(
			label,
			{
				fontId = FONT_BODY,
				fontSize = 13,
				textColor = fade(active ? ON_ACCENT : TEXT, progress),
				wrapMode = .None,
			},
		)
	}
}
