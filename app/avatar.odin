// Published pictures take precedence over identity and group crop circles.
package main

import "core:fmt"
import "core:math"
import "core:strings"

import "nendo"
import rl "sdlrl"

@(private = "file")
AVATAR_CROP_SCALE :: f32(0.9)

@(private)
Avatar_Hinge :: struct {
	kind:  Model_Kind,
	tex:   ^rl.Texture2D,
	angle: f32,
}

@(private)
Avatar_Erase :: struct {
	kind:     Model_Kind,
	tex:      ^rl.Texture2D,
	progress: f32,
}

// FNV-1a over the identity key. Stable for a given account.
avatar_hash :: proc(key: string) -> u32 {
	hash: u32 = 2166136261
	for b in transmute([]u8)key {
		hash = (hash ~ u32(b)) * 16777619
	}
	return hash
}

// Hue from the hash, fixed saturation/value tuned for dark and light.
avatar_color :: proc(key: string) -> nendo.Color {
	hue := f32(avatar_hash(key) % 360)
	return hsv(hue, 0.45, 0.62)
}

hsv :: proc(h, s, v: f32) -> nendo.Color {
	c := v * s
	x := c * (1 - abs(math.mod(h / 60, 2) - 1))
	m := v - c

	r, g, b: f32
	switch {
	case h < 60:
		r, g, b = c, x, 0
	case h < 120:
		r, g, b = x, c, 0
	case h < 180:
		r, g, b = 0, c, x
	case h < 240:
		r, g, b = 0, x, c
	case h < 300:
		r, g, b = x, 0, c
	case:
		r, g, b = c, 0, x
	}
	return {(r + m) * 255, (g + m) * 255, (b + m) * 255, 255}
}

// Up to two initials, keeping emoji and accented graphemes intact.
avatar_initials :: proc(name: string) -> string {
	fields := strings.fields(name, context.temp_allocator)
	if len(fields) >= 2 {
		return strings.concatenate(
			{fields[0][:next_grapheme(fields[0], 0)], fields[1][:next_grapheme(fields[1], 0)]},
			context.temp_allocator,
		)
	}
	return name[:next_grapheme(name, next_grapheme(name, 0))]
}

// A profile picture when one is loaded (pre-masked round pixels from
// drain_pics), else the key's crop circle. Initials cover loading or invalid keys.
// `ring` draws an accent halo around the circle: callers pass a fading
// color when the person just said something, so the eye lands on who
// spoke before it lands on what they said.
avatar :: proc(
	id_str: string,
	index: u32,
	key: string,
	name: string,
	size: f32,
	tex: ^rl.Texture2D = nil,
	ring: nendo.Color = {},
	hinge_angle: f32 = 0,
	erase_progress: f32 = -1,
) {
	tex := tex
	radius := size / 2
	crop := tex == nil && (len(key) == 64 || len(key) == 32)
	if crop {
		shape := g_ui != nil ? g_ui.prefs.crop_avatar_shape : Crop_Shape.Slanted
		tex = url_pic(fmt.tprintf("%s:%s", CROP_SHAPE_PREFIX[shape], key))
		if shape == .Square {radius = 0}
		if shape == .Rounded {radius = size * 0.2}
		if CHALK_DRAWN {tex = shaped_avatar(tex, "square")}
	} else {
		shape := g_ui != nil ? g_ui.prefs.avatar_shape : Avatar_Shape.Circle
		if shape == .Square {radius = 0}
		if shape == .Rounded {radius = size * 0.2}
		mask := shape == .Square ? "square" : shape == .Rounded ? "rounded" : "circle"
		if tex != nil {
			style := profile_style(key, .Avatar)
			if style.shape != "" {mask = style.shape}
		}
		tex = shaped_avatar(tex, mask)
	}
	halo := ring.a > 0 ? nendo.Border{color = ring, width = {2, 2, 2, 2, 0}} : {}
	if tex != nil {
		image_size := crop ? size * AVATAR_CROP_SCALE : size
		if nendo.box(nendo.id(id_str, index))(
		{
			width = nendo.fixed(size),
			height = nendo.fixed(size),
			align = {x = .Center, y = .Center},
			radius = nendo.radius(radius),
			border = halo,
		},
		) {
			image: rawptr = tex
			custom: rawptr
			if erase_progress >= 0 {
				view := new(Avatar_Erase, context.temp_allocator)
				view^ = {.Avatar_Erase, tex, erase_progress}
				image, custom = nil, view
			} else if hinge_angle != 0 {
				view := new(Avatar_Hinge, context.temp_allocator)
				view^ = {
					kind  = .Avatar_Hinge,
					tex   = tex,
					angle = hinge_angle,
				}
				image, custom = nil, view
			}
			if nendo.box(nendo.id("AvatarImage", nendo.id(id_str, index).id))(
			{
				width = nendo.fixed(image_size),
				height = nendo.fixed(image_size),
				image = image,
				custom = custom,
			},
			) {}
		}
		return
	}
	if nendo.box(nendo.id(id_str, index))(
	{
		width = nendo.fixed(size),
		height = nendo.fixed(size),
		align = {x = .Center, y = .Center},
		color = avatar_color(key),
		radius = nendo.radius(radius),
		border = halo,
	},
	) {
		nendo.text(
			avatar_initials(name),
			{font = FONT_BODY, size = u16(size * 0.4), color = {255, 255, 255, 235}},
		)
	}
}

@(private)
Peephole :: enum {
	Closed,
	Open,
}

// The photo as a cover over the key's crop circle: while `.Open`, it
// swings up on its top hinge and shows the identity fingerprint behind
// it. Without a photo the crop circle is all there is. The outer element
// takes `id_str`/`index`, so click handlers keyed on it keep matching.
@(private)
peephole_avatar :: proc(
	id_str: string,
	index: u32,
	key: string,
	name: string,
	size: f32,
	photo: ^rl.Texture2D,
	state: Peephole,
	ring: nendo.Color = {},
) {
	outer := nendo.id(id_str, index)
	reveal_id := nendo.id("PeepReveal", outer.id)
	reveal := anim_to(reveal_id.id, photo != nil && state == .Open ? 1 : 0)
	if photo == nil {reveal = 0}
	if nendo.box(outer)({width = nendo.fixed(size), height = nendo.fixed(size)}) {
		if reveal > 0 {
			if nendo.box(reveal_id)({width = nendo.fixed(size), height = nendo.fixed(size)}) {
				avatar("PeepCircle", outer.id, key, name, size, ring = ring)
			}
		}
		if reveal < 1 {
			if nendo.box(nendo.id("PeepCover", outer.id))(
			{
				// The remaining photo sits over the fingerprint while it is revealed.
				floating = reveal > 0 ? nendo.Floating{attach_to = .Parent, clip_to = .Parent, pointer = .Passthrough, attach = {element = .Left_Top, parent = .Left_Top}} : {},
			},
			) {
				if AVATAR_ERASE {
					avatar(
						"PeepPhoto",
						outer.id,
						key,
						name,
						size,
						photo,
						ring,
						erase_progress = reveal,
					)
				} else {
					avatar("PeepPhoto", outer.id, key, name, size, photo, ring, reveal * 180)
				}
			}
		}
	}
}
