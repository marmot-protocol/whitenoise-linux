package main

import "core:fmt"
import "nendo"
import rl "sdlrl"

// Centered placeholder with a title and a sub line.
centered_note :: proc(id_str: string, title: string, sub: string) {
	if nendo.box(nendo.id(id_str))(
	{
		width = nendo.grow(),
		height = nendo.grow(),
		direction = .Column,
		align = {x = .Center, y = .Center},
		gap = 8,
	},
	) {
		nendo.text(title, {font = FONT_TITLE, size = 24, color = TEXT_DIM})
		if len(sub) > 0 {
			nendo.text(sub, {font = FONT_BODY, size = 14, color = TEXT_DIM})
		}
	}
}

// Section eyebrow, ALL CAPS.
eyebrow :: proc(text: string) {
	// A stencilled theme brackets its captions: [ACTIONS], not ACTIONS.
	label := BRACKET_LABELS ? fmt.tprintf("[%s]", text) : text
	nendo.text(label, {font = FONT_BODY, size = 12, color = TEXT_DIM, spacing = 2})
}

// Small bordered chip: 11px label, hairline border, hover fill.
// Pass a color to tint border and label (DANGER).
micro_button :: proc(id_str: string, label: string, color: nendo.Color = {}) {
	tinted := color.a != 0
	down := press_down(nendo.id(id_str))
	if nendo.box(nendo.id(id_str))(
	{
		width = nendo.fit(tap_size() ? tap_min() : 0, 0),
		height = nendo.fit(tap_size() ? tap_min() : 0, 0),
		padding = {left = 10, right = 10, top = 5 + down, bottom = 5 - down},
		align = {x = .Center, y = .Center},
		color = hovered() ? HOVER : {},
		radius = rr(7),
		border = {color = tinted ? color : FIELD_BORDER, width = bw()},
	},
	) {
		nendo.text(
			label,
			{font = FONT_BODY, size = tap_size() ? 12 : 11, color = tinted ? color : TEXT_DIM},
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
	caption: string,
	font: u16 = FONT_TITLE,
) {
	FONT_TITLE := font
	if nendo.box(nendo.id(fmt.tprintf("%sQrPlate", prefix)))(
	{
		width = nendo.grow(),
		direction = .Column,
		padding = {top = 8, bottom = 16},
		align = {x = .Center},
	},
	) {
		if nendo.box(nendo.id(fmt.tprintf("%sFingerprint", prefix)))(
		{direction = width < 424 ? .Column : .Row, gap = 16},
		) {
			if nendo.box(nendo.id(fmt.tprintf("%sPatternCard", prefix)))(
			{
				direction = .Column,
				padding = nendo.pad(16),
				gap = 12,
				align = {x = .Center},
				color = CARD,
				radius = rr(10),
				border = {color = FIELD_BORDER, width = bw()},
			},
			) {
				crop_circle(fmt.tprintf("%sCircle", prefix), 0, key, 160, .Square)
				nendo.text(
					tr("Visual fingerprint"),
					{font = FONT_TITLE, size = 12, color = TEXT_DIM},
				)
			}
			if qr != nil {
				if nendo.box(nendo.id(fmt.tprintf("%sScanCard", prefix)))(
				{
					width = nendo.fixed(192),
					direction = .Column,
					padding = nendo.pad(16),
					gap = 12,
					align = {x = .Center},
					color = CARD,
					radius = rr(10),
					border = {color = FIELD_BORDER, width = bw()},
				},
				) {
					if nendo.box(nendo.id(fmt.tprintf("%sQr", prefix)))(
					{width = nendo.fixed(160), height = nendo.fixed(160), image = qr},
					) {}
					nendo.text(tr("Public key"), {font = FONT_TITLE, size = 12, color = TEXT_DIM})
					nendo.text(caption, {font = FONT_BODY, size = 12, color = TEXT_DIM})
				}
			}
		}
	}
}


theme_chip_indexed :: proc(id_str: string, index: u32, label: string, active: bool) {
	if nendo.box(nendo.id(id_str, index))(
	{
		height = nendo.fit(tap_size() ? tap_min() : 0, 0),
		padding = {left = 14, right = 14, top = 8, bottom = 8},
		align = {x = .Center, y = .Center},
		color = active ? ACCENT : ROW_BG,
		radius = rr(8),
		border = active ? {} : nendo.Border{color = FIELD_BORDER, width = bw()},
	},
	) {
		nendo.text(label, {font = FONT_BODY, size = 14, color = active ? ON_ACCENT : TEXT})
	}
}

// Header actions expand to show their label while active; an inactive
// action names itself in a tooltip on hover instead.
header_chip :: proc(id_str: string, glyph: string, active: bool, label: string) {
	pad := tap_size() ? u16(13) : u16(8)
	if nendo.box(nendo.id(id_str))(
	{
		width = nendo.fit(min = tap_size() ? tap_min() : 0),
		height = nendo.fit(min = tap_size() ? tap_min() : 0),
		padding = {left = 10, right = 10, top = pad, bottom = pad},
		align = {x = .Center, y = .Center},
		color = active ? ACCENT : hovered() ? HOVER : ROW_BG,
		radius = rr(8),
	},
	) {
		nendo.text(glyph, {font = FONT_ICON, size = 14, color = active ? ON_ACCENT : TEXT})
		header_label(label, active && !single_pane())
	}
}

@(private)
HEADER_LABEL_SECS :: f32(0.1)

@(private)
header_label :: proc(label: string, active: bool) {
	if !active && hovered() {tooltip(label)}
	id := nendo.id_local("HeaderLabel")
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
	if nendo.box(id)(
	{width = nendo.fixed(width * progress), padding = {left = 6}, clip = {x = true}},
	) {
		nendo.text(
			label,
			{
				font = FONT_BODY,
				size = 13,
				color = fade(active ? ON_ACCENT : TEXT, progress),
				wrap = .None,
			},
		)
	}
}
