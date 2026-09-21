// Flights: one thing moving from where it was to where it is going,
// drawn over everything while it travels.
//
// Three moments share it, which is why it exists at all:
//   - opening a picture, its tile flies into the lightbox
//   - sending, the composer's text flies to where the row will appear
//   - reacting, the emoji flies from the pointer onto the message
//
// clay lays out the endpoints; a flight is a Root-attached floating
// element placed at the interpolated box, so it owes nothing to the
// layout it crosses.
package main

import "core:math"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

FLY_MAX :: 3 // overlapping flights are rare; the oldest slot recycles
FLY_SECS :: 0.34
FLY_FADE :: f32(0.7) // share of the flight spent at full opacity

// Round is an avatar or an emoji, Card is a picture on its way to the
// lightbox: same flight, different corners.
Fly_Shape :: enum {
	Round,
	Card,
}

Fly :: struct {
	shape: Fly_Shape,
	tex:   ^rl.Texture2D, // an avatar or emoji tile; nil draws a plate
	text:  string, // label on the plate, "" for none
	color: clay.Color,
	from:  clay.BoundingBox,
	to:    clay.BoundingBox,
	start: f64,
	secs:  f64,
	arc:   f32, // px the path bows upward at its midpoint
}

flies: [FLY_MAX]Fly

// Start a flight. Both boxes come from the previous frame's layout,
// which is where the thing visibly was and where it is going to land.
fly :: proc(
	from, to: clay.BoundingBox,
	tex: ^rl.Texture2D,
	text: string,
	color: clay.Color,
	arc: f32 = 0,
	secs: f64 = FLY_SECS,
	shape: Fly_Shape = .Round,
) {
	if !motion_on() || from.width <= 0 || to.width <= 0 {
		return
	}
	slot := 0
	for i in 1 ..< FLY_MAX {
		if flies[i].start < flies[slot].start {
			slot = i
		}
	}
	delete(flies[slot].text)
	flies[slot] = {shape, tex, strings.clone(text), color, from, to, rl.GetTime(), secs, arc}
}

// A point, for a flight that starts under the pointer.
fly_point :: proc(x, y, size: f32) -> clay.BoundingBox {
	return {x - size / 2, y - size / 2, size, size}
}

// Every running flight, drawn over the whole window. Declared once,
// last, at the root.
fly_layer :: proc() {
	for &f, i in flies {
		if f.secs <= 0 {
			continue
		}
		elapsed := rl.GetTime() - f.start
		if elapsed > f.secs {
			f.secs = 0
			delete(f.text)
			f.text = ""
			continue
		}
		anim_moving += 1

		t := f32(elapsed / f.secs)
		e := ease_in_out(t)
		// Bow the path: a straight line between two boxes reads as a
		// slide, an arc reads as a throw.
		bow := -f.arc * math.sin(math.PI * e)
		w := f.from.width + (f.to.width - f.from.width) * e
		h := f.from.height + (f.to.height - f.from.height) * e
		x := f.from.x + (f.to.x - f.from.x) * e
		y := f.from.y + (f.to.y - f.from.y) * e + bow
		alpha := clamp((1 - t) / (1 - FLY_FADE), 0, 1)

		id := clay.ID("FlyCell", u32(i))
		if f.tex != nil {
			if clay.UI(id)(
			{
				layout = {sizing = {width = clay.SizingFixed(w), height = clay.SizingFixed(h)}},
				floating = {
					attachTo = .Root,
					zIndex = 30,
					offset = {x, y},
					attachment = {element = .LeftTop, parent = .LeftTop},
				},
				image = {imageData = f.tex},
				cornerRadius = rr(f.shape == .Round ? w / 2 : 8),
				overlayColor = {255, 255, 255, alpha * 255},
			},
			) {}
			continue
		}
		if clay.UI(id)(
		{
			layout = {
				sizing = {width = clay.SizingFixed(w), height = clay.SizingFixed(h)},
				padding = {left = 10, right = 10},
				childAlignment = {x = .Center, y = .Center},
			},
			floating = {
				attachTo = .Root,
				zIndex = 30,
				offset = {x, y},
				attachment = {element = .LeftTop, parent = .LeftTop},
			},
			backgroundColor = fade(f.color, alpha),
			cornerRadius = rr(h / 2), // a pill for the send, a circle for an avatar
			clip = {horizontal = true, vertical = true},
		},
		) {
			if len(f.text) > 0 {
				clay.Text(
					f.text,
					{fontId = FONT_BODY, fontSize = 13, textColor = fade(ON_ACCENT, alpha)},
				)
			}
		}
	}
}

// ── The three flights ───────────────────────────────────────────────

SEND_ARC :: f32(46)
SEND_W_MAX :: f32(240)
REACT_SIZE :: f32(24)

// A send leaves the composer: a plate carrying the text, thrown to
// where the row is about to appear. That is the foot of the timeline
// once history fills the view, but in a fresh chat the rows stack from
// the top, so the plate lands under the last one instead of dropping
// past it into empty space.
send_arc :: proc(ui: ^Ui_State, text: string) {
	from, from_ok := element_box(clay.ID("ComposeBox"))
	view, view_ok := element_box(clay.ID("Timeline"))
	if !from_ok || !view_ok {
		return
	}
	w := min(from.width * 0.6, SEND_W_MAX)
	to := clay.BoundingBox{view.x + 56, send_land_y(ui, view), w, 32}
	// One line's worth: the plate is a gesture, not a preview.
	label := text
	if idx := strings.index_byte(label, '\n'); idx >= 0 {
		label = label[:idx]
	}
	fly(from, to, nil, label, ACCENT, SEND_ARC)
}

// Top of the row about to be appended: just under the last row the
// previous frame laid out, never below the foot of the view.
@(private = "file")
send_land_y :: proc(ui: ^Ui_State, view: clay.BoundingBox) -> f32 {
	last := view.y + 8 // an empty chat starts at the top of the content
	found := false

	// The tail is the newest optimistic row when there is one, else
	// the newest delivered message.
	for p, i in ui.pending {
		if p.group_id != ui.chats[ui.selected].group_id {
			continue
		}
		if box, ok := element_box(clay.ID("PendingRow", u32(i))); ok {
			last, found = box.y + box.height + 2, true
		}
	}
	if !found && len(ui.messages) > 0 {
		if box, ok := element_box(clay.ID("MsgRow", u32(len(ui.messages) - 1))); ok {
			last = box.y + box.height + 2
		}
	}
	return clamp(last, view.y, view.y + view.height - 40)
}

// A reaction lands on the message it belongs to, from wherever it was
// picked (a chip, the picker, the context menu, all of them under the
// pointer).
react_fly :: proc(ui: ^Ui_State, message_id: string, emoji: string) {
	tex := emoji_tex(emoji)
	if tex == nil {
		return
	}
	for msg, i in ui.messages {
		if msg.id != message_id {
			continue
		}
		row, ok := element_box(clay.ID("MsgRow", u32(i)))
		if !ok {
			return
		}
		pos := rl.GetMousePosition()
		from := fly_point(pos.x / UI_ZOOM, pos.y / UI_ZOOM, REACT_SIZE)
		to := clay.BoundingBox{row.x + 56, row.y + row.height - REACT_SIZE, REACT_SIZE, REACT_SIZE}
		fly(from, to, tex, "", {}, SEND_ARC * 0.4)
		return
	}
}
