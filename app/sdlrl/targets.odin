package sdlrl

import sdl "vendor:sdl3"

// ── Off-screen targets ──────────────────────────────────────────────
//
// Render targets handle the two layer effects the app needs:
// draw a whole subtree at an opacity, and blur what is behind a modal.
//
// The blur is a bilinear downsample chain. Halving with LINEAR sampling
// lands each destination pixel exactly between four source texels, so
// one step is an exact 2x2 box filter; four steps and one stretch back
// is a ~16px radius blur for the cost of five textured quads.
//
//   frame ──▶ 1/2 ──▶ 1/4 ──▶ 1/8 ──▶ 1/16 ──stretch──▶ screen

TARGET_SLOTS :: 5 // named by the SLOT constants in renderer.odin
BLUR_STEPS :: 4
TARGET_DEPTH :: 2 // the frame, and the layer split inside it

@(private)
Target :: struct {
	tex:  ^sdl.Texture,
	w, h: i32,
}

@(private)
targets: [TARGET_SLOTS]Target
@(private)
blur_chain: [BLUR_STEPS]Target

// The view state under each bound target, so leaving one puts back
// exactly what the caller had.
@(private)
View_State :: struct {
	target:   ^sdl.Texture,
	scale:    Vector2,
	viewport: sdl.Rect,
	had_vp:   bool,
	clip:     sdl.Rect,
	had_clip: bool,
}

@(private)
target_stack: [TARGET_DEPTH]View_State
@(private)
target_depth: int

@(private)
ensure_target :: proc(t: ^Target, w, h: i32) -> bool {
	if t.tex != nil && t.w == w && t.h == h {
		return true
	}
	if t.tex != nil {
		when #config(WN_RELOAD, false) {delete_key(&live_textures, t.tex)}
		sdl.DestroyTexture(t.tex)
		t.tex = nil
	}
	if w <= 0 || h <= 0 {
		return false
	}
	tex := sdl.CreateTexture(state.renderer, .RGBA32, .TARGET, w, h)
	track_texture(tex)
	if tex == nil {
		return false
	}
	sdl.SetTextureBlendMode(tex, {.BLEND})
	sdl.SetTextureScaleMode(tex, .LINEAR)
	t^ = {tex, w, h}
	return true
}

// Physical pixels, which is what a target must cover: the render scale
// folds the DPI density in, so the window's logical size is smaller.
@(private)
frame_size :: proc() -> (w, h: i32) {
	return i32(f32(GetScreenWidth()) * state.density), i32(f32(GetScreenHeight()) * state.density)
}

// Send everything drawn from here until EndTarget into slot instead of
// the window. The scale and viewport carry over, so the caller's
// coordinates mean the same thing they did on screen. False means the
// GPU refused the texture and the caller should just draw normally.
BeginTarget :: proc(slot: int) -> bool {
	w, h := frame_size()
	if target_depth >= TARGET_DEPTH || !ensure_target(&targets[slot], w, h) {
		return false
	}
	saved := &target_stack[target_depth]
	saved^ = capture_view()
	if !sdl.SetRenderTarget(state.renderer, targets[slot].tex) {
		return false
	}
	target_depth += 1
	sdl.SetRenderDrawColor(state.renderer, 0, 0, 0, 0)
	sdl.RenderClear(state.renderer)
	sdl.SetRenderScale(state.renderer, saved.scale.x, saved.scale.y)
	if saved.had_vp {
		sdl.SetRenderViewport(state.renderer, &saved.viewport)
	}
	return true
}

EndTarget :: proc() {
	if target_depth == 0 {
		return
	}
	target_depth -= 1
	restore_view(target_stack[target_depth])
}

@(private)
capture_view :: proc() -> (saved: View_State) {
	if current, bound := sdl.GetRenderTarget(state.renderer).?; bound {
		saved.target = current
	}
	sdl.GetRenderScale(state.renderer, &saved.scale.x, &saved.scale.y)
	saved.had_vp = sdl.RenderViewportSet(state.renderer)
	sdl.GetRenderViewport(state.renderer, &saved.viewport)
	saved.had_clip = sdl.RenderClipEnabled(state.renderer)
	sdl.GetRenderClipRect(state.renderer, &saved.clip)
	return
}

@(private)
restore_view :: proc(saved: View_State) {
	view := saved // the rects go back by pointer, so they need an address
	sdl.SetRenderTarget(state.renderer, view.target)
	sdl.SetRenderScale(state.renderer, view.scale.x, view.scale.y)
	sdl.SetRenderViewport(state.renderer, view.had_vp ? &view.viewport : nil)
	sdl.SetRenderClipRect(state.renderer, view.had_clip ? &view.clip : nil)
}

// Physical pixels, no viewport, no clip: a target is a picture of the
// window, so it goes back on 1:1 whatever the layout scale is.
@(private)
begin_raw :: proc() -> View_State {
	saved := capture_view()
	sdl.SetRenderScale(state.renderer, 1, 1)
	sdl.SetRenderViewport(state.renderer, nil)
	sdl.SetRenderClipRect(state.renderer, nil)
	return saved
}

// Put a target back on the window. `scale` grows or shrinks it about
// the center, which is how a whole modal layer lifts in and falls away.
DrawTarget :: proc(slot: int, alpha: f32, scale: f32 = 1) {
	t := targets[slot]
	if t.tex == nil || alpha <= 0 {
		return
	}
	saved := begin_raw()
	defer restore_view(saved)
	sdl.SetTextureAlphaMod(t.tex, u8(clamp(alpha, 0, 1) * 255))
	w, h := f32(t.w) * scale, f32(t.h) * scale
	dest := sdl.FRect{(f32(t.w) - w) / 2, (f32(t.h) - h) / 2, w, h}
	sdl.RenderTexture(state.renderer, t.tex, nil, &dest)
	sdl.SetTextureAlphaMod(t.tex, 255)
}

// The same target, out of focus. Drawn over the sharp one at a rising
// alpha, this is a lens pulling off the page rather than a cut.
DrawTargetBlurred :: proc(slot: int, alpha: f32) {
	t := targets[slot]
	if t.tex == nil || alpha <= 0 {
		return
	}
	saved := begin_raw()
	defer restore_view(saved)

	src := t
	built := 0
	for i in 0 ..< BLUR_STEPS {
		w, h := max(t.w >> u32(i + 1), 1), max(t.h >> u32(i + 1), 1)
		if !ensure_target(&blur_chain[i], w, h) {
			break
		}
		sdl.SetRenderTarget(state.renderer, blur_chain[i].tex)
		sdl.SetRenderDrawColor(state.renderer, 0, 0, 0, 0)
		sdl.RenderClear(state.renderer)
		dest := sdl.FRect{0, 0, f32(w), f32(h)}
		sdl.SetTextureAlphaMod(src.tex, 255)
		sdl.RenderTexture(state.renderer, src.tex, nil, &dest)
		src = blur_chain[i]
		built = i + 1
	}
	// Walk back up the chain: one straight 16x stretch shows its texel
	// grid as blocky gradients, while doubling through the levels
	// bilinear-filters the reconstruction at every step.
	for i := built - 2; i >= 0; i -= 1 {
		sdl.SetRenderTarget(state.renderer, blur_chain[i].tex)
		sdl.SetRenderDrawColor(state.renderer, 0, 0, 0, 0)
		sdl.RenderClear(state.renderer)
		dest := sdl.FRect{0, 0, f32(blur_chain[i].w), f32(blur_chain[i].h)}
		sdl.SetTextureAlphaMod(src.tex, 255)
		sdl.RenderTexture(state.renderer, src.tex, nil, &dest)
		src = blur_chain[i]
	}
	sdl.SetRenderTarget(state.renderer, saved.target)
	if src.tex == t.tex {
		return // no scratch texture: leave the sharp frame alone
	}
	sdl.SetTextureAlphaMod(src.tex, u8(clamp(alpha, 0, 1) * 255))
	dest := sdl.FRect{0, 0, f32(t.w), f32(t.h)}
	sdl.RenderTexture(state.renderer, src.tex, nil, &dest)
	sdl.SetTextureAlphaMod(src.tex, 255)
}

// Copy one target onto another, whole. Used to hold the frame that was
// on screen a moment ago while the next one takes its place.
CopyTarget :: proc(dst_slot, src_slot: int) -> bool {
	src := targets[src_slot]
	if src.tex == nil || !ensure_target(&targets[dst_slot], src.w, src.h) {
		return false
	}
	saved := begin_raw()
	defer restore_view(saved)
	sdl.SetRenderTarget(state.renderer, targets[dst_slot].tex)
	sdl.SetRenderDrawColor(state.renderer, 0, 0, 0, 0)
	sdl.RenderClear(state.renderer)
	sdl.SetTextureAlphaMod(src.tex, 255)
	sdl.RenderTexture(state.renderer, src.tex, nil, nil)
	return true
}

// One rectangle of a target, scaled about its centre and translated within
// its original clip. Geometry is in window points; DPI density stays here.
DrawTargetRegion :: proc(
	slot: int,
	x, y, w, h: f32,
	alpha: f32,
	scale: f32 = 1,
	offset_x: f32 = 0,
) {
	t := targets[slot]
	if t.tex == nil || alpha <= 0 || w <= 0 || h <= 0 {
		return
	}
	saved := begin_raw()
	defer restore_view(saved)
	src := sdl.FRect{x * state.density, y * state.density, w * state.density, h * state.density}
	grow := sdl.FRect{src.w * (scale - 1) / 2, src.h * (scale - 1) / 2, 0, 0}
	dest := sdl.FRect{src.x - grow.x, src.y - grow.y, src.w * scale, src.h * scale}
	dest.x += offset_x * state.density
	// Clipped to where it belongs, so a scaled-up region can't spill
	// past the card it is dissolving inside.
	clip := sdl.Rect{i32(src.x), i32(src.y), i32(src.w), i32(src.h)}
	sdl.SetRenderClipRect(state.renderer, &clip)
	sdl.SetTextureAlphaMod(t.tex, u8(clamp(alpha, 0, 1) * 255))
	sdl.RenderTexture(state.renderer, t.tex, &src, &dest)
	sdl.SetTextureAlphaMod(t.tex, 255)
}
