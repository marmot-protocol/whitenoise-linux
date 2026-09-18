// Selecting text inside a message body: drag to select, double-click
// for word mode (the drag then extends by whole words), Ctrl+C or the
// primary selection to copy.
//
// A selection lives inside one rendered text block (a paragraph, a list
// item, a plain body), which is the unit body_text draws. Each drawn
// line registers itself during the build with the byte range it covers
// inside that block, so the handler can turn a pointer position into a
// byte offset after layout, the same way the input fields do.
package main

import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// One selectable line laid out this frame. Rebuilt every build; the
// text slices point into the message's own strings, which outlive the
// frame.
Sel_Line :: struct {
	id:    u32, // the clay id body_line used
	block: u32, // body_text's id base: the selection's scope
	start: int, // byte offset of this line inside block_text
	text:  string,
	block_text: string,
	size:  u16,
	tile_px: f32,
}

sel_lines: [dynamic]Sel_Line

// True while a press-drag is selecting, so the release that ends it
// doesn't also count as a click on whatever is under the pointer.
sel_dragging: bool

@(private)
Selection_Unit :: enum { Character, Word, Sentence }

sel_register :: proc(id, block: u32, start: int, text, block_text: string, size: u16, tile_px: f32) {
	append(&sel_lines, Sel_Line{id, block, start, text, block_text, size, tile_px})
}

// The part of `line` that is selected, as byte offsets into the line.
// {-1, -1} when this line has nothing selected.
sel_range :: proc(block: u32, line_start, line_len: int) -> [2]int {
	ui := g_ui
	if ui == nil || !ui.sel_on || ui.sel_block != block {
		return {-1, -1}
	}
	lo, hi := min(ui.sel_a, ui.sel_b), max(ui.sel_a, ui.sel_b)
	lo = clamp(lo - line_start, 0, line_len)
	hi = clamp(hi - line_start, 0, line_len)
	if hi <= lo {
		return {-1, -1}
	}
	return {lo, hi}
}

sel_clear :: proc(ui: ^Ui_State) {
	ui.sel_on = false
	ui.sel_unit = .Character
	delete(ui.sel_copy)
	ui.sel_copy = ""
}

// Byte offset of the character nearest the pointer in one laid-out
// line, or ok = false when the pointer isn't over it.
@(private = "file")
sel_offset_in :: proc(line: Sel_Line, mx, my: f32) -> (offset: int, over: bool) {
	box := clay.GetElementData(clay.ID("BodyLine", line.id))
	if !box.found {
		return 0, false
	}
	b := box.boundingBox
	if my < b.y || my > b.y + b.height {
		return 0, false
	}
	// Past either end of the line clamps to that end, so a drag that
	// leaves the text sideways still selects the whole line.
	switch {
	case mx <= b.x:
		return line.start, true
	case mx >= b.x + b.width:
		return line.start + len(line.text), true
	}
	return line.start + hit_plain(line.text, mx - b.x, line.size, line.tile_px), true
}

// The line under the pointer, preferring the block already being
// selected so a drag that strays over a neighbouring message keeps
// extending the original selection.
@(private = "file")
sel_hit :: proc(ui: ^Ui_State, mx, my: f32, block_only: bool) -> (line: Sel_Line, offset: int, ok: bool) {
	best_gap := max(f32)
	for candidate in sel_lines {
		if block_only && candidate.block != ui.sel_block {
			continue
		}
		if off, over := sel_offset_in(candidate, mx, my); over {
			return candidate, off, true
		}
		// Not on the line: remember the vertically nearest one, so a
		// drag above or below the block still tracks.
		if !block_only {
			continue
		}
		box := clay.GetElementData(clay.ID("BodyLine", candidate.id))
		if !box.found {
			continue
		}
		b := box.boundingBox
		gap := my < b.y ? b.y - my : my - (b.y + b.height)
		if gap < best_gap {
			best_gap = gap
			line = candidate
			offset = my < b.y ? candidate.start : candidate.start + len(candidate.text)
			ok = true
		}
	}
	return
}

// Bounds of the word around `at`, whitespace-delimited.
sel_word_at :: proc(text: string, at: int) -> (lo, hi: int) {
	is_space :: proc(c: u8) -> bool {
		return c == ' ' || c == '\t' || c == '\n' || c == '\r'
	}
	lo = clamp(at, 0, len(text))
	hi = lo
	for lo > 0 && !is_space(text[lo - 1]) {
		lo -= 1
	}
	for hi < len(text) && !is_space(text[hi]) {
		hi += 1
	}
	return
}

// A selection edge never lands inside a URL: the whole run goes in or
// stays out. Half a link is useless in the clipboard, and worse on
// screen, where the fragments re-parse: ".../pull/1630" with a
// selected "30" leaves ".../pull/16", a real link to another PR.
//
// Idempotent, so re-running it every drag event holds the anchor still
// once it has snapped.
sel_snap :: proc(text: string, lo, hi: int) -> (out_lo, out_hi: int) {
	out_lo, out_hi = lo, hi
	for i := 0; i < len(text); {
		end, _, ok := url_at(text, i)
		if !ok {
			i += 1
			continue
		}
		if lo > i && lo < end {
			out_lo = i
		}
		if hi > i && hi < end {
			out_hi = end
		}
		i = end
	}
	return
}

@(private = "file")
sel_snap_links :: proc(ui: ^Ui_State, text: string) {
	lo, hi := min(ui.sel_a, ui.sel_b), max(ui.sel_a, ui.sel_b)
	// A press is a point, not a selection: snapping it would select
	// the whole link and swallow the release that should open it (a
	// link card's line is nothing but its URL, so every click on the
	// card landed here).
	if lo == hi {
		return
	}
	out_lo, out_hi := sel_snap(text, lo, hi)
	if out_lo == lo && out_hi == hi {
		return
	}
	// Orientation is the drag direction; keeping it lets the drag go on
	// extending from the same anchor.
	if ui.sel_a <= ui.sel_b {
		ui.sel_a, ui.sel_b = out_lo, out_hi
	} else {
		ui.sel_a, ui.sel_b = out_hi, out_lo
	}
}

// Refresh the copy buffer from the live selection.
@(private = "file")
sel_take :: proc(ui: ^Ui_State, block_text: string) {
	lo, hi := min(ui.sel_a, ui.sel_b), max(ui.sel_a, ui.sel_b)
	lo = clamp(lo, 0, len(block_text))
	hi = clamp(hi, 0, len(block_text))
	delete(ui.sel_copy)
	ui.sel_copy = hi > lo ? strings.clone(block_text[lo:hi]) : ""
}

// Press / drag / release over message bodies. Runs after layout, like
// the other pointer handlers.
handle_body_sel :: proc(ui: ^Ui_State) {
	m := rl.GetMousePosition()
	mx := m.x / UI_ZOOM
	my := m.y / UI_ZOOM

	// I-beam over anything selectable, and it stays one for the whole
	// drag, including the part that runs off the end of the text.
	if _, _, over := sel_hit(ui, mx, my, false); over || sel_dragging {
		cursor_raise(.Text)
	}

	if rl.IsMouseButtonPressed(.LEFT) {
		line, offset, ok := sel_hit(ui, mx, my, false)
		if !ok {
			sel_clear(ui) // a press anywhere else drops the selection
			return
		}
		ui.sel_on = true
		ui.sel_block = line.block
		sel_dragging = true
		if rl.GetMouseClicks() >= 2 {
			// Drag by the same unit selected by the initial click.
			lo, hi := sel_word_at(line.block_text, offset)
			ui.sel_unit = .Word
			if rl.GetMouseClicks() >= 3 {
				lo, hi = sentence_bounds(line.block_text, offset)
				ui.sel_unit = .Sentence
			}
			ui.sel_wa = lo
			ui.sel_wb = hi
			ui.sel_a = lo
			ui.sel_b = hi
		} else {
			ui.sel_unit = .Character
			ui.sel_a = offset
			ui.sel_b = offset
		}
		sel_snap_links(ui, line.block_text)
		sel_take(ui, line.block_text)
		return
	}

	if sel_dragging && rl.IsMouseButtonDown(.LEFT) {
		line, offset, ok := sel_hit(ui, mx, my, true)
		if !ok {
			return
		}
		if ui.sel_unit != .Character {
			lo, hi := sel_word_at(line.block_text, offset)
			if ui.sel_unit == .Sentence { lo, hi = sentence_bounds(line.block_text, offset) }
			ui.sel_a = min(ui.sel_wa, lo)
			ui.sel_b = max(ui.sel_wb, hi)
		} else {
			ui.sel_b = offset
		}
		sel_snap_links(ui, line.block_text)
		sel_take(ui, line.block_text)
		return
	}

	if sel_dragging && rl.IsMouseButtonReleased(.LEFT) {
		sel_dragging = false
		if len(ui.sel_copy) == 0 {
			sel_clear(ui) // a plain click, not a drag
			return
		}
		// Select-to-copy, the same primary-selection behavior the input
		// fields have.
		rl.SetPrimaryText(strings.clone_to_cstring(ui.sel_copy, context.temp_allocator))
	}
}

// Ctrl+C with a body selection. The focused input gets first refusal:
// when it has a selection of its own, edit_text already copied it.
handle_body_copy :: proc(ui: ^Ui_State) {
	if !ui.sel_on || len(ui.sel_copy) == 0 {
		return
	}
	if !ctrl_down() || !rl.IsKeyPressed(.C) {
		return
	}
	if ui.ed_target != nil && ui.ed.selection[0] != ui.ed.selection[1] {
		return
	}
	copy_text(ui, ui.sel_copy, "Message text copied")
}
