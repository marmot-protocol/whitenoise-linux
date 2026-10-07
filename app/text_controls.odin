package main

import clay "../vendor/clay/bindings/odin/clay-odin"
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
caret_box: clay.BoundingBox

caret :: proc(h: f32 = 16) {
	if d := clay.GetElementData(clay.ID_LOCAL("Caret")); d.found {
		caret_box = d.boundingBox // one frame behind, which no one can see
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
	if clay.UI(clay.ID_LOCAL("Caret"))(
	{layout = {sizing = {width = clay.SizingFixed(0), height = clay.SizingFixed(h)}}},
	) {
		// Paint the caret without adding space between text spans.
		if clay.UI(clay.ID_LOCAL("CaretInk"))(
		{
			layout = {sizing = {width = clay.SizingFixed(CARET_W), height = clay.SizingFixed(h)}},
			backgroundColor = fade(TEXT, alpha),
			floating = {
				attachTo = .Parent,
				clipTo = .AttachedParent,
				pointerCaptureMode = .Passthrough,
			},
		},
		) {}
	}
}

// Active scrollbar-thumb drag: container id (0 = none) and the
// pointer-to-thumb-top offset captured at grab, in clay coords.
Scroll_Drag :: struct {
	container: u32,
	grab:      f32,
}
scroll_drag: Scroll_Drag

// Scrollbar for a clay scroll container, floated on its right edge
// from the previous frame's scroll data. Wheel scrolls; the thumb is
// also hand-draggable (grab it, scroll follows the pointer).
// `z` must beat the container's own stacking context: the default sits
// above base content, a scroll region inside a floating modal passes
// something above the modal's zIndex or the thumb paints beneath it.
scrollbar :: proc(container: clay.ElementId, z: i16 = 5) {
	data := clay.GetScrollContainerData(container)
	if !data.found || data.contentDimensions.height <= data.scrollContainerDimensions.height {
		return
	}
	append(&drag_targets, container) // a finger can throw this one
	track := data.scrollContainerDimensions.height
	thumb := max(24, track * data.scrollContainerDimensions.height / data.contentDimensions.height)
	span := data.contentDimensions.height - data.scrollContainerDimensions.height
	travel := track - thumb
	y := travel > 0 ? -data.scrollPosition.y / span * travel : 0

	thumb_id := clay.ID("ScrollThumb", container.id)
	mouse_y := rl.GetMousePosition().y / UI_ZOOM
	if rl.IsMouseButtonPressed(.LEFT) && clay.PointerOver(thumb_id) {
		scroll_drag = {container.id, mouse_y - y}
	}
	dragging := scroll_drag.container == container.id
	if dragging && travel > 0 {
		y = clamp(mouse_y - scroll_drag.grab, 0, travel)
		data.scrollPosition.y = -y / travel * span
	}

	if clay.UI(thumb_id)(
	{
		layout = {sizing = {width = clay.SizingFixed(5), height = clay.SizingFixed(thumb)}},
		floating = {
			attachTo = .ElementWithId,
			parentId = container.id,
			offset = {-3, y},
			zIndex = z,
			attachment = {element = .RightTop, parent = .RightTop},
		},
		backgroundColor = dragging || clay.PointerOver(thumb_id) ? ACCENT : FIELD_BORDER,
		cornerRadius = rr(3),
	},
	) {}
}
