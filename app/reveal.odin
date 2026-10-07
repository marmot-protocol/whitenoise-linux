// The theme change and the vault unlock, revealed rather than swapped.
//
// The old frame is captured the moment the theme is picked (or the
// vault opens), then held over the new one and cut away by a circle
// growing out of the click.
// SDL_Renderer cannot clip to a circle, so the held frame is drawn as
// a textured ring: a fan of quads from the circle's edge out past the
// window corners, sampling the snapshot at each vertex.
//
//   ╔═══════════╗   ▓ the old frame, still drawn
//   ║▓▓▓▓▓▓▓▓▓▓▓║   ○ the new theme, showing through the hole
//   ║▓▓▓╭───╮▓▓▓║
//   ║▓▓▓│ ○ │▓▓▓║   the hole grows from the pointer until it has
//   ║▓▓▓╰───╯▓▓▓║   swallowed the furthest corner
//   ╚═══════════╝
//
// The unlock warps the ring as well: each band samples the snapshot
// nearer the center than it sits, so the old frame bulges outward
// ahead of the hole like a shockwave, and darkens toward its edge.
//
//   sample radius = r - warp * inner * e^(-(r - inner) / REVEAL_FALLOFF)
package main

import "core:math"

import rl "sdlrl"

REVEAL_SECS :: 0.5
REVEAL_SEGS :: 64
REVEAL_BANDS :: 8 // radial steps, so the warp bends instead of stretching
REVEAL_OUT :: f32(1.2) // outer radius, as a share of the window diagonal
REVEAL_FALLOFF :: f32(140) // points past the rim where the warp fades out

@(private)
Reveal_Style :: enum {
	Cut, // a clean circle (theme change)
	Warp, // the old frame bulges out ahead of the hole (unlock)
}

@(private = "file")
Reveal :: struct {
	shot:   rl.Texture2D,
	at:     [2]f32, // window point the change was clicked at
	start:  f64,
	warp:   f32, // 0 cuts, 1 bulges
	armed:  bool, // theme picked this frame, not yet captured
	theme:  int,
	accent: int,
}

@(private = "file")
reveal: Reveal

// Pick a theme. The change is deferred to the end of this frame so the
// frame still on screen (the old theme) is the one captured.
theme_switch :: proc(ui: ^Ui_State, theme: int, accent: int) {
	settings_theme_preview_reset(ui)
	ui.theme_menu_open = false
	if !motion_on() || reveal.armed {
		apply_theme(theme, accent)
		ui.theme, ui.accent = theme, accent
		save_settings(ui)
		return
	}
	pos := rl.GetMousePosition()
	reveal.armed = true
	reveal.theme, reveal.accent = theme, accent
	reveal.at = {pos.x / UI_ZOOM, pos.y / UI_ZOOM}
	ui.theme, ui.accent = theme, accent
	save_settings(ui)
}

// Hold the frame drawn so far (before it is presented) and open it
// from `at`, in layout points. The next draws show through the hole;
// the clock starts at the first of them, so work between the capture
// and that draw (the last boot steps) doesn't eat the animation.
@(private)
reveal_capture :: proc(at: [2]f32, style: Reveal_Style) {
	if !motion_on() {
		return
	}
	rl.UnloadTexture(reveal.shot)
	reveal.shot = rl.CaptureFrame()
	reveal.start = 0
	reveal.at = at
	reveal.warp = style == .Warp ? 1 : 0
}

// Called at the end of the draw, inside the render scale: captures on
// the frame the theme was picked, then holds the snapshot over the new
// theme until the circle has passed the last corner.
reveal_step :: proc() {
	if reveal.armed {
		reveal.armed = false
		reveal_capture(reveal.at, .Cut)
		apply_theme(reveal.theme, reveal.accent)
		// Fills ease toward their new color in the renderer; under the
		// reveal that would smear the edge, so the new theme lands whole.
		clear(&anim_cols)
		return
	}
	if reveal.shot.tex == nil {
		return
	}
	if reveal.start == 0 {
		reveal.start = rl.GetTime()
	}
	w := f32(rl.GetScreenWidth()) / UI_ZOOM
	h := f32(rl.GetScreenHeight()) / UI_ZOOM
	// The furthest corner decides when the old frame is fully gone.
	reach := max(
		math.sqrt(reveal.at.x * reveal.at.x + reveal.at.y * reveal.at.y),
		math.sqrt((w - reveal.at.x) * (w - reveal.at.x) + reveal.at.y * reveal.at.y),
		math.sqrt(reveal.at.x * reveal.at.x + (h - reveal.at.y) * (h - reveal.at.y)),
		math.sqrt((w - reveal.at.x) * (w - reveal.at.x) + (h - reveal.at.y) * (h - reveal.at.y)),
	)
	t := f32(clamp((rl.GetTime() - reveal.start) / REVEAL_SECS, 0, 1))
	if t >= 1 {
		rl.UnloadTexture(reveal.shot)
		reveal.shot = {}
		return
	}
	anim_moving += 1

	inner := ease_in_out(t) * reach
	outer := math.sqrt(w * w + h * h) * REVEAL_OUT
	pull := reveal.warp * inner
	verts := make([dynamic]rl.Vertex, context.temp_allocator)
	// One vertex at angle (c, s) and radius r: placed at r, sampled at
	// the warped radius, shaded darker where the warp is strongest.
	point :: proc(at: [2]f32, c, s, r, inner, pull, w, h: f32) -> rl.Vertex {
		bulge := pull * math.exp(-(r - inner) / REVEAL_FALLOFF)
		src := r - bulge
		shade := 1 - 0.5 * bulge / max(r, 1)
		return {
			position = {at.x + c * r, at.y + s * r},
			color = {shade, shade, shade, 1},
			tex_coord = {(at.x + c * src) / w, (at.y + s * src) / h},
		}
	}
	bands := reveal.warp > 0 ? REVEAL_BANDS : 1
	for b in 0 ..< bands {
		// Bands crowd the rim, where the warp bends hardest.
		f0, f1 := f32(b) / f32(bands), f32(b + 1) / f32(bands)
		r0 := inner + (outer - inner) * f0 * f0
		r1 := inner + (outer - inner) * f1 * f1
		for i in 0 ..< REVEAL_SEGS {
			a0 := f32(i) / REVEAL_SEGS * 2 * math.PI
			a1 := f32(i + 1) / REVEAL_SEGS * 2 * math.PI
			c0, s0 := math.cos(a0), math.sin(a0)
			c1, s1 := math.cos(a1), math.sin(a1)
			in0 := point(reveal.at, c0, s0, r0, inner, pull, w, h)
			in1 := point(reveal.at, c1, s1, r0, inner, pull, w, h)
			out0 := point(reveal.at, c0, s0, r1, inner, pull, w, h)
			out1 := point(reveal.at, c1, s1, r1, inner, pull, w, h)
			append(&verts, in0, in1, out0, in1, out1, out0)
		}
	}
	rl.DrawTrianglesClipped(verts[:], 0, 0, w, h, &reveal.shot)
}
