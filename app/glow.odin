// Additive halos. SDL_Renderer has no shaders, so a glow is the soft
// sprite (sdlrl) 9-sliced around a box and added to what is already
// there. That one texture is every light in the app: a focused field,
// a hovered accent button, a badge that just went up.
//
// It rides the Custom render command like the decor scenes do, mounted
// as a floating child that expands past its parent, so the halo spills
// outside the element it belongs to. clay emits Custom before the
// element's children, which puts the light behind the content.
package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

GLOW_SPREAD :: f32(14)
GLOW_ALPHA :: f32(120) // at strength 1; light, this is added not blended

Glow_View :: struct {
	kind:     Model_Kind, // .Glow; must stay the first field
	color:    clay.Color,
	spread:   f32,
	strength: f32, // 0..1, fades the whole halo
}

// Salt for the halo's own element id, derived from the element it
// belongs to so call sites don't invent a second name for the light.
GLOW_SALT :: u32(0x676c6f77)

// A halo around `parent`, declared inside it. `strength` is usually an
// anim_to on a hover or focus flag, so the light comes up and goes down
// with it rather than switching.
//
// A floating element takes no size from its parent (clay's `expand`
// grows the attachment box, not the element), so the halo is sized from
// the parent's previous box. An element in its first frame has none,
// which costs that one frame of light.
glow :: proc(parent: clay.ElementId, color: clay.Color, strength: f32, spread: f32 = GLOW_SPREAD) {
	box, ok := element_box(parent)
	if !ok || strength <= 0.01 || !motion_on() {
		return
	}
	view := new(Glow_View, context.temp_allocator)
	view^ = {kind = .Glow, color = color, spread = spread, strength = clamp(strength, 0, 1)}
	id := parent
	id.id ~= GLOW_SALT
	if clay.UI(id)(
	{
		layout = {sizing = {width = clay.SizingFixed(box.width + spread * 2), height = clay.SizingFixed(box.height + spread * 2)}},
		floating = {attachTo = .Parent, zIndex = -1, attachment = {element = .CenterCenter, parent = .CenterCenter}},
		custom = {customData = view},
	},
	) {}
}

// The halo for a control that lights up on hover: nothing at rest,
// full light under the pointer, eased both ways.
hover_glow :: proc(parent: clay.ElementId, color: clay.Color, on: bool) {
	glow(parent, color, anim_to(parent.id ~ GLOW_SALT, on ? 1 : 0, HOVER_RATE))
}

// The floating box already carries the spread on every side, so the
// halo is drawn around the element inside it.
glow_draw :: proc(view: ^Glow_View, bounds: clay.BoundingBox) {
	alpha := GLOW_ALPHA * view.strength
	color := rl.Color{u8(view.color.r), u8(view.color.g), u8(view.color.b), u8(clamp(alpha, 0, 255))}
	rl.DrawGlow(
		bounds.x + view.spread,
		bounds.y + view.spread,
		max(bounds.width - view.spread * 2, 1),
		max(bounds.height - view.spread * 2, 1),
		view.spread,
		color,
	)
}
