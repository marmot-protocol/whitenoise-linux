// Hold a message, and the quick reactions fan out around the pointer.
//
// The same emoji the context menu offers, one gesture shorter: press,
// wait, and they open into a ring around the press point, staggered so
// they read as one hand opening. Slide onto one and let go.
//
//        ❤️  👍  😂          a full circle from 12 o'clock,
//     🎉    ● press  🔥      clockwise, so the ring holds all
//        😮  😢  🙏          16 without crowding
//
// It composes with the two other things a press can start: a drag
// scrolls (which needs movement, and the fan needs stillness), and a
// press on a body selects text (a zero-length selection on release
// changes nothing).
package main

import "core:math"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

FAN_HOLD :: 0.45 // seconds of stillness before the fan opens
FAN_STILL :: f32(5) // px of drift still counts as holding
FAN_RADIUS :: f32(62)
FAN_CELL :: f32(34)
FAN_TILE :: f32(22)
FAN_FROM :: f32(270) // degrees, first cell: 12 o'clock, then clockwise
FAN_STAGGER :: 0.045 // seconds between one cell arriving and the next
FAN_IN :: 0.16 // seconds one cell takes to arrive
FAN_PICK :: f32(1.25) // how much the cell under the pointer grows

@(private = "file")
Fan :: struct {
	msg_id: string,
	at:     [2]f32, // press point, layout coords
	open:   f64, // when it opened
	held:   f64, // when the press started, 0 for none
	hover:  int, // cell under the pointer, -1 for none
}

@(private = "file")
fan: Fan

// Wide enough that the cells don't touch: the ring's circumference has
// to fit `count` cells side by side, with a tenth of a cell between.
@(private = "file")
fan_radius :: proc(count: int) -> f32 {
	return max(FAN_RADIUS, f32(count) * FAN_CELL * 1.1 / (2 * math.PI))
}

fan_open :: proc() -> bool {
	return fan.open > 0
}

// Where cell i sits, and how far it has arrived (0 hidden, 1 landed).
@(private = "file")
fan_cell :: proc(index, count: int) -> (x, y, t: f32) {
	angle := (FAN_FROM + 360 * f32(index) / f32(max(count, 1))) * math.PI / 180
	t = f32(clamp((rl.GetTime() - fan.open - f64(index) * FAN_STAGGER) / FAN_IN, 0, 1))
	reach := fan_radius(count) * ease_back(t)
	return fan.at.x + math.cos(angle) * reach, fan.at.y + math.sin(angle) * reach, t
}

// Watch the press: still for long enough over a message opens the fan,
// and a release either picks a cell or drops it.
handle_react_fan :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	pos := rl.GetMousePosition()
	at := [2]f32{pos.x / UI_ZOOM, pos.y / UI_ZOOM}

	if rl.IsMouseButtonReleased(.LEFT) {
		if fan_open() && fan.hover >= 0 && fan.hover < len(ui.prefs.quick_reactions) {
			message_op(ui, client, .React, fan.msg_id, ui.prefs.quick_reactions[fan.hover])
			drag_moved = true // this release was a gesture, not a click
		}
		fan = {hover = -1}
		return
	}
	if !rl.IsMouseButtonDown(.LEFT) {
		fan = {hover = -1}
		return
	}
	if fan_open() {
		// Nearest cell within its own radius, so a slide onto one arms
		// it and a slide off drops it.
		fan.hover = -1
		for i in 0 ..< len(ui.prefs.quick_reactions) {
			x, y, _ := fan_cell(i, len(ui.prefs.quick_reactions))
			if (at.x - x) * (at.x - x) + (at.y - y) * (at.y - y) < FAN_CELL * FAN_CELL / 4 {
				fan.hover = i
			}
		}
		anim_moving += 1
		return
	}
	if rl.IsMouseButtonPressed(.LEFT) {
		fan = {at = at, held = rl.GetTime(), hover = -1}
		// Only over a message, and only where a reaction means anything.
		if !motion_on() || modal_open(ui) || ui.ctx_open || len(ui.prefs.quick_reactions) == 0 {
			fan.held = 0
			return
		}
		fan.msg_id = ""
		for msg, i in ui.messages {
			if clay.PointerOver(clay.ID("MsgRow", u32(i))) && !msg.deleted {
				fan.msg_id = msg.id
				break
			}
		}
		if fan.msg_id == "" {
			fan.held = 0
		}
		return
	}
	if fan.held == 0 {
		return
	}
	// Drifted: this press is a drag or a selection, not a hold.
	if abs(at.x - fan.at.x) > FAN_STILL || abs(at.y - fan.at.y) > FAN_STILL {
		fan.held = 0
		return
	}
	if rl.GetTime() - fan.held > FAN_HOLD {
		fan.open = rl.GetTime()
		play_sound(.Pop)
	}
	anim_moving += 1
}

// The cells themselves, declared at the root so they cross whatever
// they are over.
fan_layer :: proc(ui: ^Ui_State) {
	if !fan_open() {
		return
	}
	count := len(ui.prefs.quick_reactions)
	for emoji, i in ui.prefs.quick_reactions {
		x, y, t := fan_cell(i, count)
		if t <= 0 {
			continue
		}
		anim_moving += 1
		picked := fan.hover == i
		size := FAN_CELL * t * anim_to(anim_key(clay.ID("FanCell", u32(i)).id, 5), picked ? FAN_PICK : 1, 26)
		if clay.UI(clay.ID("FanCell", u32(i)))(
		{
			layout = {sizing = {width = clay.SizingFixed(size), height = clay.SizingFixed(size)}, childAlignment = {x = .Center, y = .Center}},
			floating = {attachTo = .Root, zIndex = 29, offset = {x - size / 2, y - size / 2}, attachment = {element = .LeftTop, parent = .LeftTop}},
			backgroundColor = picked ? ACCENT : CARD,
			cornerRadius = rr(size / 2),
			border = {color = picked ? ACCENT : ELEVATED_BORDER, width = bw()},
		},
		) {
			if tex := quick_tile(emoji); tex != nil {
				if clay.UI(clay.ID("FanTile", u32(i)))(
				{layout = {sizing = {width = clay.SizingFixed(FAN_TILE * t)}}, aspectRatio = {1}, image = {imageData = tex}},
				) {}
			} else {
				clay.Text(emoji, {fontId = FONT_BODY, fontSize = 15, textColor = TEXT})
			}
		}
	}
}
