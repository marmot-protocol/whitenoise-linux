package main

import clay "../vendor/clay/bindings/odin/clay-odin"

// Measure new rows once, then retain their height while off screen.
// One viewport of overscan keeps wheel/fling movement ahead of the clip.
@(private)
timeline_skip :: proc(ui: ^Ui_State, msg: Msg_Ui) -> bool {
	if msg.row_height <= 0 || msg.deleted || sel_dragging ||
		msg.id == ui.jump_id || msg.row_measure != ui.timeline_metric {
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
		if msg.thread_of != cur || msg.system {
			continue
		}
		row := clay.GetElementData(clay.ID("MsgRow", u32(i)))
		if row.found {
			top := row.boundingBox.y - view.boundingBox.y - data.scrollPosition.y
			if !anchored && msg.row_height > 0 && msg.row_measure == ui.timeline_metric &&
				msg.row_top + data.scrollPosition.y >= 0 {
				anchor_delta = top - msg.row_top
				anchored = true
			}
			msg.row_height = row.boundingBox.height
			msg.row_top = top
			msg.row_measure = ui.timeline_metric
		}
	}
	if abs(anchor_delta) > 1 {
		data.scrollPosition.y = clamp(data.scrollPosition.y - anchor_delta,
			-max(data.contentDimensions.height - data.scrollContainerDimensions.height, 0), 0)
		scroll_jumped = true
	}
}
