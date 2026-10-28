package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:fmt"
import "core:slice"
import "core:strings"
import rl "sdlrl"

@(private)
Inbox_Kind :: enum {
	Chat,
	Terminal,
}

@(private)
Inbox_Row :: struct {
	kind:           Inbox_Kind,
	index:          int,
	project:        u32,
	key, title:     string,
	activity_at:    u64,
	top:            f32,
	pinned, unread: bool,
}

@(private)
inbox_terminal_key :: proc(dir: string) -> string {
	key := whip_avatar_key(dir)
	if key.inbox == "" {key.inbox = fmt.aprintf("whip:%s", key.folder)}
	return key.inbox
}

@(private)
inbox_rows :: proc(ui: ^Ui_State, chats: []int, terminals: []u32) -> []Inbox_Row {
	rows := make([]Inbox_Row, len(chats) + len(terminals), context.temp_allocator)
	for index, at in chats {
		chat := &ui.chats[index]
		rows[at] = {
			kind        = .Chat,
			index       = index,
			key         = chat.group_id,
			title       = chat.title,
			activity_at = chat.activity_at > 100_000_000_000 ? chat.activity_at / 1000 : chat.activity_at,
			pinned      = ui.prefs.pinned[chat.group_id],
			unread      = chat.unread > 0 || ui.prefs.unread_ids[chat.group_id],
		}
	}
	at := 0
	for project, index in rl.WhipProjects() {
		if at == len(terminals) {break}
		if project.id != terminals[at] {continue}
		key := inbox_terminal_key(project.dir)
		rows[len(chats) + at] = {
			kind        = .Terminal,
			index       = index,
			project     = project.id,
			key         = key,
			title       = project.name,
			activity_at = max(
				project.activity_at,
				ui.prefs.whip_activity[whip_avatar_key(project.dir).folder],
			),
			pinned      = ui.prefs.pinned[key],
			unread      = project.waiting > 0,
		}
		at += 1
	}
	rows = rows[:len(chats) + at]
	slice.sort_by(rows, proc(a, b: Inbox_Row) -> bool {
		if a.pinned != b.pinned {return a.pinned}
		if a.activity_at != b.activity_at {return a.activity_at > b.activity_at}
		if a.kind != b.kind {return a.kind < b.kind}
		if a.kind == .Terminal {return a.project < b.project}
		return a.index < b.index
	})
	return rows
}

@(private)
inbox_all :: proc(ui: ^Ui_State) -> []Inbox_Row {
	chats := make([dynamic]int, 0, len(ui.chats), context.temp_allocator)
	for chat, index in ui.chats {if !chat.archived && !chat.search_only {append(&chats, index)}}
	projects := rl.WhipAvailable() ? rl.WhipProjects() : nil
	ids := make([]u32, len(projects), context.temp_allocator)
	for project, index in projects {ids[index] = project.id}
	return inbox_rows(ui, chats[:], ids)
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
		slot := len(ui.prefs.folders)
		if row.kind == .Chat {
			slot = chat_folder_slot(ui, &ui.chats[row.index], slots)
		} else if folder, placed := ui.prefs.folder_of[row.key]; placed && folder == "" {
			// Explicit Unfiled placement overrides automatic rules.
		} else if assigned, found := slots[folder]; placed && found {
			slot = assigned
		} else {
			facts := Chat_Facts {
				title  = strings.to_lower(row.title, context.temp_allocator),
				unread = row.unread,
				whip   = true,
			}
			for name, i in ui.prefs.folders {if folder_rules_match(ui.prefs.folder_rules[name], facts) {slot = i; break}}
		}
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
inbox_view :: proc() -> (top, height: f32) {
	short := f32(rl.GetScreenHeight()) / UI_ZOOM < 480
	id := clay.ID(short ? "RailContent" : "ChatList")
	data := clay.GetScrollContainerData(id)
	height =
		data.found ? data.scrollContainerDimensions.height : f32(rl.GetScreenHeight()) / UI_ZOOM
	top = data.found ? -data.scrollPosition.y : 0
	if short && data.found {
		list := clay.GetElementData(clay.ID("ChatList"))
		rail := clay.GetElementData(id)
		if list.found &&
		   rail.found {top -= list.boundingBox.y - rail.boundingBox.y - data.scrollPosition.y}
	}
	return
}

@(private)
inbox_rows_window :: proc(ui: ^Ui_State, rows: []Inbox_Row, offset_y: f32, section: u32 = 0) {
	stride := chat_row_height() + 2
	top, height := inbox_view()
	offset := top - offset_y
	first := clamp(int(offset / stride) - 2, 0, len(rows))
	last := clamp(int((offset + height) / stride) + 3, first, len(rows))
	if first > 0 {
		if clay.UI(clay.ID("InboxRowsBefore", section))(
		{layout = {sizing = {height = clay.SizingFixed(f32(first) * stride - 2)}}},
		) {}
	}
	projects := rl.WhipProjects()
	for row in rows[first:last] {
		if row.kind == .Terminal {whip_project_row(ui, projects[row.index]); continue}
		chat_row(
			u32(row.index),
			ui.chats[row.index],
			!ui.whip_open && row.index == ui.selected,
			.Archive,
		)
	}
	if last < len(rows) {
		if clay.UI(clay.ID("InboxRowsAfter", section))(
		{layout = {sizing = {height = clay.SizingFixed(f32(len(rows) - last) * stride - 2)}}},
		) {}
	}
}

@(private)
inbox_cycle :: proc(ui: ^Ui_State, client: ^marmot.Client, step: int) {
	if len(ui.rail_rows) == 0 || step == 0 {return}
	// A selection outside this filter enters from the nearest end.
	at := step > 0 ? step - 1 : step
	for row, pos in ui.rail_rows {
		selected :=
			row.kind == .Terminal ? ui.whip_open && row.project == ui.whip_project : !ui.whip_open && row.index == ui.selected
		if selected {at = pos + step; break}
	}
	row := ui.rail_rows[(at + len(ui.rail_rows)) %% len(ui.rail_rows)]
	if view := clay.GetScrollContainerData(clay.ID("ChatList")); view.found {
		top := -view.scrollPosition.y
		height := view.scrollContainerDimensions.height
		if row.top < top {top = row.top}
		if row.top + chat_row_height() > top + height {top = row.top + chat_row_height() - height}
		view.scrollPosition.y = -clamp(top, 0, max(view.contentDimensions.height - height, 0))
		scroll_residual = {}
	}
	if row.kind == .Terminal {whip_open_project(ui, row.project); return}
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
