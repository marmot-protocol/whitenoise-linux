// The theme change, revealed rather than swapped.
//
// The old frame is captured the moment the theme is picked, then held
// over the new one and cut away by a circle growing out of the click.
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
package main

import "core:math"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

REVEAL_SECS :: 0.5
REVEAL_SEGS :: 64
REVEAL_OUT :: f32(1.2) // outer radius, as a share of the window diagonal

@(private = "file")
Reveal :: struct {
	shot:   rl.Texture2D,
	at:     [2]f32, // window point the change was clicked at
	start:  f64,
	armed:  bool, // theme picked this frame, not yet captured
	theme:  int,
	accent: int,
}

@(private = "file")
reveal: Reveal

// Pick a theme. The change is deferred to the end of this frame so the
// frame still on screen (the old theme) is the one captured.
theme_switch :: proc(ui: ^Ui_State, theme: int, accent: int) {
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

// Called at the end of the draw, inside the render scale: captures on
// the frame the theme was picked, then holds the snapshot over the new
// theme until the circle has passed the last corner.
reveal_step :: proc() {
	if reveal.armed {
		reveal.armed = false
		rl.UnloadTexture(reveal.shot)
		reveal.shot = rl.CaptureFrame()
		reveal.start = rl.GetTime()
		apply_theme(reveal.theme, reveal.accent)
		// Fills ease toward their new color in the renderer; under the
		// reveal that would smear the edge, so the new theme lands whole.
		clear(&anim_cols)
		return
	}
	if reveal.shot.tex == nil {
		return
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
	white := rl.FColor{1, 1, 1, 1}
	verts := make([dynamic]rl.Vertex, context.temp_allocator)
	point :: proc(x, y, w, h: f32, color: rl.FColor) -> rl.Vertex {
		return {position = {x, y}, color = color, tex_coord = {x / w, y / h}}
	}
	for i in 0 ..< REVEAL_SEGS {
		a0 := f32(i) / REVEAL_SEGS * 2 * math.PI
		a1 := f32(i + 1) / REVEAL_SEGS * 2 * math.PI
		c0, s0 := math.cos(a0), math.sin(a0)
		c1, s1 := math.cos(a1), math.sin(a1)
		in0 := point(reveal.at.x + c0 * inner, reveal.at.y + s0 * inner, w, h, white)
		in1 := point(reveal.at.x + c1 * inner, reveal.at.y + s1 * inner, w, h, white)
		out0 := point(reveal.at.x + c0 * outer, reveal.at.y + s0 * outer, w, h, white)
		out1 := point(reveal.at.x + c1 * outer, reveal.at.y + s1 * outer, w, h, white)
		append(&verts, in0, in1, out0, in1, out1, out0)
	}
	rl.DrawTrianglesClipped(verts[:], 0, 0, w, h, &reveal.shot)
}
