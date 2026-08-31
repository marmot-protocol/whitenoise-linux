// Deterministic fallback avatars, the avatar_for port: any key hashes
// to a stable color + initials so every row always renders something.
// Profile pictures layer on top later.
package main

import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// FNV-1a, the same stable-hash idea the slint app uses.
avatar_hash :: proc(key: string) -> u32 {
	hash: u32 = 2166136261
	for b in transmute([]u8)key {
		hash = (hash ~ u32(b)) * 16777619
	}
	return hash
}

// Hue from the hash, fixed saturation/value tuned for dark and light.
avatar_color :: proc(key: string) -> clay.Color {
	hue := f32(avatar_hash(key) % 360)
	return hsv(hue, 0.45, 0.62)
}

hsv :: proc(h, s, v: f32) -> clay.Color {
	c := v * s
	x := c * (1 - abs(mod(h / 60, 2) - 1))
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

mod :: proc(a, b: f32) -> f32 {
	return a - b * f32(int(a / b))
}

// Up to two initials: word starts for names, leading chars for ids.
avatar_initials :: proc(name: string) -> string {
	fields := strings.fields(name, context.temp_allocator)
	if len(fields) >= 2 {
		return strings.concatenate({fields[0][:1], fields[1][:1]}, context.temp_allocator)
	}
	if len(name) >= 2 {
		return name[:2]
	}
	return name
}

// A profile picture when one is loaded (pre-masked round pixels from
// drain_pics), else a colored circle with centered initials.
// `ring` draws an accent halo around the circle: callers pass a fading
// color when the person just said something, so the eye lands on who
// spoke before it lands on what they said.
avatar :: proc(id_str: string, index: u32, key: string, name: string, size: f32, tex: ^rl.Texture2D = nil, ring: clay.Color = {}) {
	halo := ring.a > 0 ? clay.BorderElementConfig{color = ring, width = {2, 2, 2, 2, 0}} : {}
	if tex != nil {
		if clay.UI(clay.ID(id_str, index))(
		{
			layout = {sizing = {width = clay.SizingFixed(size), height = clay.SizingFixed(size)}},
			image = {imageData = tex},
			cornerRadius = rr(size / 2),
			border = halo,
		},
		) {}
		return
	}
	if clay.UI(clay.ID(id_str, index))(
	{
		layout = {sizing = {width = clay.SizingFixed(size), height = clay.SizingFixed(size)}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = avatar_color(key),
		cornerRadius = rr(size / 2),
		border = halo,
	},
	) {
		clay.Text(avatar_initials(name), {fontId = FONT_BODY, fontSize = u16(size * 0.4), textColor = {255, 255, 255, 235}})
	}
}
