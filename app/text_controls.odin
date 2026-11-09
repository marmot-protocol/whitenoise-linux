package main

import "nendo"
import rl "sdlrl"

// Blinking text caret, rendered after the text of the focused input.
// Width is in layout units; the render scale (UI_ZOOM x density)
// inflates it, so a fraction keeps it a hairline on screen.
CARET_W :: 0.7
CARET_BLINK :: 1.2 // seconds per on-off cycle
CARET_SOLID :: 0.55 // seconds it holds steady after an edit

// When the caret last moved or the text under it changed. Blinking
// through your own typing is the thing that makes a caret hard to
// follow, so an edit restarts the cycle from full.
caret_at: f64

caret_wake :: proc() {
	caret_at = rl.GetTime()
}

// Last frame's caret box, in layout units. The IME and a phone
// keyboard are placed against it.
caret_box: nendo.Rect

caret :: proc(h: f32 = 16) {
	if d := nendo.element(nendo.id_local("Caret")); d.found {
		caret_box = d.rect // one frame behind, which no one can see
		caret_box.width = CARET_W
	}
	alpha := f32(1)
	if motion_on() {
		// Timer-driven blink lets the rest of a focused chat sleep.
		next := caret_at + CARET_SOLID
		if now := rl.GetTime(); now >= next {
			phase := i64((now - next) / (CARET_BLINK / 2))
			alpha = phase % 2 == 0 ? 0 : 1
			next += f64(phase + 1) * (CARET_BLINK / 2)
		}
		frame_deadline = min(frame_deadline, next)
	}
	if nendo.box(nendo.id_local("Caret"))({width = nendo.fixed(0), height = nendo.fixed(h)}) {
		// Paint the caret without adding space between text spans.
		if nendo.box(nendo.id_local("CaretInk"))(
		{width = nendo.fixed(CARET_W), height = nendo.fixed(h), color = fade(TEXT, alpha)},
		) {}
	}
}

// Active scrollbar-thumb drag: container id (0 = none) and the
// pointer-to-thumb-top offset captured at grab, in nendo coords.
Scroll_Drag :: struct {
	container: u32,
	grab:      f32,
}
scroll_drag: Scroll_Drag

// Scrollbar for a nendo scroll container, floated on its right edge
// from the previous frame's scroll data. Wheel scrolls; the thumb is
// also hand-draggable (grab it, scroll follows the pointer).
// `z` must beat the container's own stacking context: the default sits
// above base content, a scroll region inside a floating modal passes
// something above the modal's zIndex or the thumb paints beneath it.
scrollbar :: proc(container: nendo.Id, z: i16 = 5) {
	data := nendo.scroll(container)
	if data.found &&
	   (data.content.width > data.viewport.width || data.content.height > data.viewport.height) {
		append(&drag_targets, container)
	}
	if !data.found || data.content.height <= data.viewport.height {
		return
	}
	track := data.viewport.height
	thumb := max(24, track * data.viewport.height / data.content.height)
	span := data.content.height - data.viewport.height
	travel := track - thumb
	y := travel > 0 ? -data.position.y / span * travel : 0

	thumb_id := nendo.id("ScrollThumb", container.id)
	mouse_y := rl.GetMousePosition().y / UI_ZOOM
	if !rl.TouchActive() && rl.IsMouseButtonPressed(.LEFT) && nendo.pointer_over(thumb_id) {
		scroll_drag = {container.id, mouse_y - y}
	}
	dragging := scroll_drag.container == container.id
	if dragging && travel > 0 {
		y = clamp(mouse_y - scroll_drag.grab, 0, travel)
		data.position.y = -y / travel * span
	}

	// A relief theme draws the desktop scrollbar: a light track down the
	// container's edge under a raised thumb. Others keep the hairline thumb.
	width := RELIEF ? f32(14) : f32(5)
	if RELIEF {
		if nendo.box(nendo.id("ScrollTrack", container.id))(
		{
			width = nendo.fixed(width),
			height = nendo.fixed(track),
			floating = {
				attach_to = .Element,
				parent = container.id,
				z = z,
				pointer = .Passthrough,
				attach = {element = .Right_Top, parent = .Right_Top},
			},
			color = TOP_GLINT,
		},
		) {}
	}
	if nendo.box(thumb_id)(
	{
		width = nendo.fixed(width),
		height = nendo.fixed(thumb),
		floating = {
			attach_to = .Element,
			parent = container.id,
			offset = {RELIEF ? 0 : -3, y},
			z = z,
			pointer = rl.TouchActive() ? .Passthrough : .Capture,
			attach = {element = .Right_Top, parent = .Right_Top},
		},
		color = RELIEF ? PANEL : dragging || nendo.pointer_over(thumb_id) ? ACCENT : FIELD_BORDER,
		radius = rr(3),
		border = RELIEF ? {color = CARD_BORDER, width = bw()} : {},
	},
	) {}
}
