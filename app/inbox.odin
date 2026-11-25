package main

import marmot "../marmot"
import "core:slice"
import "nendo"
import rl "sdlrl"

@(private)
INBOX_GAP :: u16(2)

@(private)
Inbox_Row :: struct {
	index:          int,
	key:            string,
	activity_at:    u64,
	top:            f32, // relative to InboxRows, including folder headers
	pinned, unread: bool,
}

@(private)
inbox_rows :: proc(ui: ^Ui_State, chats: []int) -> []Inbox_Row {
	rows := make([]Inbox_Row, len(chats), context.temp_allocator)
	for index, at in chats {
		chat := &ui.chats[index]
		rows[at] = {
			index       = index,
			key         = chat.group_id,
			activity_at = chat.activity_at > 100_000_000_000 ? chat.activity_at / 1000 : chat.activity_at,
			pinned      = ui.prefs.pinned[chat.group_id],
			unread      = chat.unread > 0 || ui.prefs.unread_ids[chat.group_id],
		}
	}
	slice.sort_by(rows, proc(a, b: Inbox_Row) -> bool {
		if a.pinned != b.pinned {return a.pinned}
		if a.activity_at != b.activity_at {return a.activity_at > b.activity_at}
		return a.index < b.index
	})
	return rows
}

@(private)
inbox_all :: proc(ui: ^Ui_State) -> []Inbox_Row {
	chats := make([dynamic]int, 0, len(ui.chats), context.temp_allocator)
	for chat, index in ui.chats {if !chat.archived && !chat.search_only {append(&chats, index)}}
	return inbox_rows(ui, chats[:])
}

// Stable partition keeps recent/pinned order inside every folder.
@(private)
inbox_sections :: proc(
	ui: ^Ui_State,
	rows: []Inbox_Row,
	allocator := context.temp_allocator,
) -> (
	[]Folder_Section,
	[]Inbox_Row,
) {
	sections := make([]Folder_Section, len(ui.prefs.folders) + 1, allocator)
	grouped := make([]Inbox_Row, len(rows), allocator)
	slots := make(map[string]int, len(ui.prefs.folders), context.temp_allocator)
	for name, index in ui.prefs.folders {slots[name] = index}
	row_slots := make([]int, len(rows), context.temp_allocator)
	for row, index in rows {
		slot := chat_folder_slot(ui, &ui.chats[row.index], slots)
		row_slots[index] = slot
		sections[slot].count += 1
		if row.unread {sections[slot].unread += 1}
	}
	start := 0
	for &section in sections {section.start = start; start += section.count; section.count = 0}
	for row, index in rows {
		section := &sections[row_slots[index]]
		grouped[section.start + section.count] = row
		section.count += 1
	}
	return sections, grouped
}

@(private)
inbox_draw_rows :: proc(ui: ^Ui_State, id: nendo.Id, rows: []Inbox_Row, height: f32) {
	window := nendo.virtual_rows(id, len(rows), height, gap = INBOX_GAP)
	for row in rows[window.first:window.end] {
		// Keyed by the chat rather than its slot: when activity reorders
		// the inbox, each row glides to its new place instead of jumping.
		// Filled like the rail beneath, so a row gliding past another
		// covers it instead of mixing the two rows' text.
		if nendo.box(nendo.id("InboxRowMove", nendo.id(row.key).id))(
		{width = nendo.grow(), color = PANEL, transition = layout_motion()},
		) {
			chat_row(u32(row.index), ui.chats[row.index], row.index == ui.selected, .Archive)
		}
	}
}

@(private)
inbox_cycle :: proc(ui: ^Ui_State, client: ^marmot.Client, step: int) {
	if len(ui.rail_rows) == 0 || step == 0 {return}
	// A selection outside this filter enters from the nearest end.
	at := step > 0 ? step - 1 : step
	for row, pos in ui.rail_rows {
		if row.index == ui.selected {at = pos + step; break}
	}
	row := ui.rail_rows[(at + len(ui.rail_rows)) %% len(ui.rail_rows)]
	owner := nendo.id("ChatList")
	view := nendo.scroll(owner)
	if !view.found {
		owner = nendo.id("RailContent")
		view = nendo.scroll(owner)
	}
	clip, list := nendo.element(owner), nendo.element(nendo.id("InboxRows"))
	if view.found && clip.found && list.found {
		// Recover the content position before applying any unlaid-out scroll input.
		top := list.rect.y + row.top - clip.rect.y - view.clip.offset.y + view.position.y
		delta := clamp(top, 0, max(0, view.viewport.height - chat_row_height())) - top
		view.position.y = clamp(
			view.position.y + delta,
			-max(0, view.content.height - view.viewport.height),
			0,
		)
		scroll_residual = {}
	}
	ui.page = .Chats
	select_chat(ui, client, row.index)
}

@(private)
inbox_shortcuts :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if !ctrl_down() {return}
	step := 0
	if rl.IsKeyPressed(.TAB) {
		step = shift_down() ? -1 : 1
	} else if ui.page == .Chats &&
	   shift_down() &&
	   !modal_open(ui) &&
	   !ui.new_chat_open &&
	   !ui.add_account_open {
		if key_hit(.UP) {step = -1}
		if key_hit(.DOWN) {step = 1}
	}
	if step != 0 {inbox_cycle(ui, client, step)}
}
