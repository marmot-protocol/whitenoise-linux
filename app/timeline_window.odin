package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:fmt"
import "core:strings"

@(private)
Reading_Place :: struct {
	message: string,
	offset:  f32,
}

// Measure new rows once, then retain their height while off screen.
// One viewport of overscan keeps wheel/fling movement ahead of the clip.
@(private)
timeline_skip :: proc(ui: ^Ui_State, msg: Msg_Ui) -> bool {
	if msg.row_height <= 0 ||
	   msg.deleted ||
	   msg.id == ui.jump_id ||
	   msg.row_measure != ui.timeline_metric {
		return false
	}
	data := clay.GetScrollContainerData(clay.ID("Timeline"))
	if !data.found {
		return false
	}
	y := msg.row_top + data.scrollPosition.y
	h := data.scrollContainerDimensions.height
	return y + msg.row_height < -h || y > 2 * h
}

@(private)
timeline_measure :: proc(ui: ^Ui_State) {
	if layout_overflow || ui.page != .Chats || ui.selected < 0 || ui.show_members {
		return
	}
	view := clay.GetElementData(clay.ID("Timeline"))
	data := clay.GetScrollContainerData(clay.ID("Timeline"))
	if !view.found || !data.found {
		return
	}
	cur := thread_cur(ui)
	// Keep the first visible row in place when an attachment above it grows.
	anchor_delta: f32
	anchored := ui.scroll_pending || ui.jump_id != ""
	for &msg, i in ui.messages {
		if msg.thread_of != cur && msg.id != cur {
			continue
		}
		row := clay.GetElementData(clay.ID(msg.system ? "SysRow" : "MsgRow", u32(i)))
		if row.found {
			// The scrollbar can change the requested offset during layout. Measure
			// against the offset these boxes used, so anchoring cannot undo a drag.
			top := row.boundingBox.y - view.boundingBox.y - timeline_draw_offset
			if !anchored &&
			   msg.row_height > 0 &&
			   msg.row_measure == ui.timeline_metric &&
			   msg.row_top + timeline_draw_offset >= 0 {
				anchor_delta = top - msg.row_top
				anchored = true
			}
			msg.row_height = row.boundingBox.height
			msg.row_top = top
			msg.row_measure = ui.timeline_metric
		}
	}
	if abs(anchor_delta) > 1 {
		data.scrollPosition.y = clamp(
			data.scrollPosition.y - anchor_delta,
			-max(data.contentDimensions.height - data.scrollContainerDimensions.height, 0),
			0,
		)
		scroll_jumped = true
	}
}

@(private)
reading_remember :: proc(ui: ^Ui_State) {
	if ui.whip_open ||
	   ui.page != .Chats ||
	   ui.selected < 0 ||
	   ui.selected >= len(ui.chats) ||
	   ui.timeline_loading ||
	   ui.timeline_paging ||
	   ui.search_open ||
	   ui.issues_open ||
	   thread_cur(ui) != "" ||
	   ui.jump_id != "" ||
	   ui.messages_account != ui.account_ref ||
	   ui.messages_group != ui.chats[ui.selected].group_id ||
	   clay.GetCurrentContext() == nil {return}
	data := clay.GetScrollContainerData(clay.ID("Timeline"))
	view := clay.GetElementData(clay.ID("Timeline"))
	if !data.found || !view.found {return}
	key := fmt.tprintf("%s:%s", ui.account_ref, ui.messages_group)
	place, exists := ui.reading_places[key]
	if ui.scroll_pending ||
	   data.scrollPosition.y <=
		   -max(data.contentDimensions.height - data.scrollContainerDimensions.height, 0) + 1 {
		if exists {delete(place.message); ui.reading_places[key] = {}}
		return
	}
	for msg, i in ui.messages {
		if msg.thread_of != "" || msg.system {continue}
		row := clay.GetElementData(clay.ID("MsgRow", u32(i)))
		if !row.found ||
		   row.boundingBox.y + row.boundingBox.height <= view.boundingBox.y {continue}
		if row.boundingBox.y >= view.boundingBox.y + view.boundingBox.height {break}
		if exists {delete(place.message)} else {key = strings.clone(key)}
		ui.reading_places[key] = {strings.clone(msg.id), row.boundingBox.y - view.boundingBox.y}
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
	if ui.reading_pending.message != ui.jump_id {ui.reading_pending = {}}
	if ui.jump_id != "" && !ui.timeline_loading && !ui.timeline_paging && !gs_seek_jump(ui) {
		aligned := true
		for msg, i in ui.messages {
			if msg.id != ui.jump_id {continue}
			row := clay.GetElementData(clay.ID("MsgRow", u32(i)))
			view := clay.GetElementData(clay.ID("Timeline"))
			data := clay.GetScrollContainerData(clay.ID("Timeline"))
			if row.found && view.found && data.found {
				delta :=
					(row.boundingBox.y + row.boundingBox.height / 2) -
					(view.boundingBox.y + view.boundingBox.height / 2)
				if ui.reading_pending.message != "" {
					delta = row.boundingBox.y - view.boundingBox.y - ui.reading_pending.offset
				}
				target := clamp(
					data.scrollPosition.y - delta,
					-max(data.contentDimensions.height - data.scrollContainerDimensions.height, 0),
					0,
				)
				aligned = abs(target - data.scrollPosition.y) < 1
				data.scrollPosition.y = target
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
		if data := clay.GetScrollContainerData(clay.ID("Timeline")); data.found {
			data.scrollPosition.y = -max(
				data.contentDimensions.height - data.scrollContainerDimensions.height,
				0,
			)
			scroll_jumped = true
			ui.scroll_pending = false
		}
	}
}
