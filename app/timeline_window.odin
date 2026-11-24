package main

import "core:fmt"
import "core:strings"
import "nendo"

@(private)
Reading_Place :: struct {
	message: string,
	offset:  f32,
}

@(private)
TIMELINE_GAP :: u16(2)

@(private)
Timeline_Shape :: struct {
	parts:   bit_set[enum u8 {
		Unread,
		Day,
		Import,
		Body,
	}],
	head:    Msg_Head,
	blocked: int,
}

@(private)
Timeline_Entry :: struct {
	index, import_from: int,
	shape:              Timeline_Shape,
	mounted:            bool,
}

@(private)
timeline_has_markers :: proc(shape: Timeline_Shape) -> bool {
	return shape.parts - {.Body} != {} || shape.blocked > 0
}

@(private)
timeline_cached_height :: proc(ui: ^Ui_State, msg: ^Msg_Ui, shape: Timeline_Shape) -> f32 {
	if msg.deleted ||
	   msg.id == ui.jump_id ||
	   msg.row_measure != ui.timeline_metric ||
	   msg.row_shape != shape ||
	   (.Body in shape.parts && msg.row_height <= 0) {return 0}
	return msg.row_inset + msg.row_height
}

@(private)
timeline_measure :: proc(ui: ^Ui_State) {
	if layout_overflow || ui.page != .Chats || ui.selected < 0 || ui.show_members {
		return
	}
	view := nendo.element(nendo.id("Timeline"))
	data := nendo.scroll(nendo.id("Timeline"))
	if !view.found || !data.found {
		return
	}
	// The scrollbar can update the requested offset after declaration.
	// Measure against the offset these boxes actually used.
	origin := view.rect.y + timeline_draw_offset
	anchor_delta: f32
	anchored := ui.scroll_pending || ui.jump_id != ""
	if i := ui.timeline_root; i >= 0 {
		msg := &ui.messages[i]
		row := nendo.element(nendo.id("MsgRow", u32(i))).rect
		top := row.y - origin
		if !anchored &&
		   msg.row_measure == ui.timeline_metric &&
		   msg.row_height > 0 &&
		   msg.row_top + timeline_draw_offset >= 0 {
			anchor_delta, anchored = top - msg.row_top, true
		}
		msg.row_top, msg.row_height = top, row.height
		// The same message can be a continued row elsewhere.
		msg.row_shape, msg.row_measure = {}, ui.timeline_metric
	}
	top := nendo.element(nendo.id("TimelineRows")).rect.y - origin
	for entry in ui.timeline_entries {
		msg := &ui.messages[entry.index]
		old_top, old_height := msg.row_top, msg.row_height
		valid := msg.row_measure == ui.timeline_metric
		has_body := .Body in entry.shape.parts
		if entry.mounted {
			index := u32(entry.index)
			body: nendo.Rect
			if has_body {body = nendo.element(nendo.id(msg.system ? "SysRow" : "MsgRow", index)).rect}
			slot := body
			if timeline_has_markers(
				entry.shape,
			) {slot = nendo.element(nendo.id("TimelineEntry", index)).rect}
			top = slot.y - origin
			msg.row_height = body.height
			msg.row_inset = has_body ? body.y - slot.y : slot.height
			msg.row_measure, msg.row_shape = ui.timeline_metric, entry.shape
		}
		msg.row_top = top + msg.row_inset
		// Advance through spacers using the same cached heights nendo used.
		top = msg.row_top + msg.row_height + f32(TIMELINE_GAP)
		if !anchored &&
		   has_body &&
		   valid &&
		   old_height > 0 &&
		   old_top + timeline_draw_offset >= 0 {
			anchor_delta = msg.row_top - old_top
			anchored = true
		}
	}
	if abs(anchor_delta) > 1 {
		data.position.y = clamp(
			data.position.y - anchor_delta,
			-max(data.content.height - data.viewport.height, 0),
			0,
		)
		scroll_jumped = true
	}
}

@(private)
reading_remember :: proc(ui: ^Ui_State) {
	if ui.page != .Chats ||
	   ui.selected < 0 ||
	   ui.selected >= len(ui.chats) ||
	   ui.timeline_loading ||
	   ui.timeline_paging ||
	   ui.search_open ||
	   thread_cur(ui) != "" ||
	   ui.jump_id != "" ||
	   ui.messages_account != ui.account_ref ||
	   ui.messages_group != ui.chats[ui.selected].group_id ||
	   nendo.current_context() == nil {return}
	data := nendo.scroll(nendo.id("Timeline"))
	view := nendo.element(nendo.id("Timeline"))
	if !data.found || !view.found {return}
	key := fmt.tprintf("%s:%s", ui.account_ref, ui.messages_group)
	place, exists := ui.reading_places[key]
	if ui.scroll_pending ||
	   data.position.y <= -max(data.content.height - data.viewport.height, 0) + 1 {
		if exists {delete(place.message); ui.reading_places[key] = {}}
		return
	}
	for msg, i in ui.messages {
		if msg.thread_of != "" || msg.system {continue}
		row := nendo.element(nendo.id("MsgRow", u32(i)))
		if !row.found || row.rect.y + row.rect.height <= view.rect.y {continue}
		if row.rect.y >= view.rect.y + view.rect.height {break}
		if exists {delete(place.message)} else {key = strings.clone(key)}
		ui.reading_places[key] = {strings.clone(msg.id), row.rect.y - view.rect.y}
		return
	}
}

@(private)
reading_restore :: proc(ui: ^Ui_State) {
	ui.reading_pending = {}
	delete(ui.jump_id); ui.jump_id = ""
	ui.gs_jump_pending, ui.scroll_pending = false, true
	if ui.selected < 0 || ui.selected >= len(ui.chats) {return}
	key := fmt.tprintf("%s:%s", ui.account_ref, ui.chats[ui.selected].group_id)
	place := ui.reading_places[key]
	if place.message == "" {return}
	ui.jump_id = strings.clone(place.message)
	ui.reading_pending = place
	ui.gs_jump_pending, ui.scroll_pending = true, false
}

@(private)
reading_clear :: proc(ui: ^Ui_State) {
	ui.reading_pending = {}
	for key, place in ui.reading_places {delete(key); delete(place.message)}
	delete(ui.reading_places); ui.reading_places = nil
}

@(private)
timeline_scroll_apply :: proc(ui: ^Ui_State) {
	if !ui.scroll_pending {ui.scroll_settle = 0}
	if ui.reading_pending.message != ui.jump_id {ui.reading_pending = {}}
	if ui.jump_id != "" && !ui.timeline_loading && !ui.timeline_paging && !gs_seek_jump(ui) {
		aligned := true
		for msg, i in ui.messages {
			if msg.id != ui.jump_id {continue}
			row := nendo.element(nendo.id("MsgRow", u32(i)))
			view := nendo.element(nendo.id("Timeline"))
			data := nendo.scroll(nendo.id("Timeline"))
			if row.found && view.found && data.found {
				delta := (row.rect.y + row.rect.height / 2) - (view.rect.y + view.rect.height / 2)
				if ui.reading_pending.message != "" {
					delta = row.rect.y - view.rect.y - ui.reading_pending.offset
				}
				target := clamp(
					data.position.y - delta,
					-max(data.content.height - data.viewport.height, 0),
					0,
				)
				aligned = abs(target - data.position.y) < 1
				data.position.y = target
				scroll_jumped = true
				ui.scroll_pending = false
			}
			break
		}
		if !aligned {return}
		delete(ui.jump_id); ui.jump_id = ""
		ui.reading_pending = {}
	}
	if ui.scroll_pending && !ui.timeline_loading && !ui.timeline_paging {
		if data := nendo.scroll(nendo.id("Timeline")); data.found {
			target := -max(data.content.height - data.viewport.height, 0)
			// A jump realizes previously virtual rows. Give their actual heights
			// a few layouts to settle, but never pin a live chat indefinitely.
			settled := abs(target - data.position.y) < 1
			data.position.y = target
			scroll_jumped = true
			ui.scroll_settle += 1
			if (settled && ui.scroll_settle >= 2) || ui.scroll_settle >= 6 {
				ui.scroll_pending = false
				ui.scroll_settle = 0
			}
		}
	}
}
