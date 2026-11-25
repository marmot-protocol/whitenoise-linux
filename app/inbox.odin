package main

import marmot "../marmot"
import "core:slice"
import "core:unicode"
import "core:unicode/utf8"
import "nendo"
import rl "sdlrl"

@(private)
INBOX_GAP :: u16(2)

@(private)
Folder_Sort :: enum {
	Recent,
	Name,
	Unread,
}

@(private)
Inbox_Row :: struct {
	index:          int,
	key:            string,
	activity_at:    u64,
	top:            f32, // relative to InboxRows, including folder headers
	pinned, unread: bool,
}

@(private)
inbox_rows :: proc(ui: ^Ui_State, chats: []int, source: []Chat_Row_Ui = nil) -> []Inbox_Row {
	chat_source := source != nil ? source : ui.chats[:]
	rows := make([]Inbox_Row, len(chats), context.temp_allocator)
	for index, at in chats {
		chat := &chat_source[index]
		rows[at] = {
			index       = index,
			key         = chat.group_id,
			activity_at = chat.activity_at > 100_000_000_000 ? chat.activity_at / 1000 : chat.activity_at,
			pinned      = ui.prefs.pinned[chat.group_id],
			unread      = chat.unread > 0 || ui.prefs.unread_ids[chat.group_id],
		}
	}
	slice.sort_by_cmp(rows, inbox_recent_compare)
	return rows
}

@(private = "file")
inbox_recent_compare :: proc(a, b: Inbox_Row) -> slice.Ordering {
	if a.pinned != b.pinned {return a.pinned ? .Less : .Greater}
	if a.activity_at != b.activity_at {return a.activity_at > b.activity_at ? .Less : .Greater}
	if a.index != b.index {return a.index < b.index ? .Less : .Greater}
	return .Equal
}

@(private = "file")
inbox_title_compare :: proc(a, b: string) -> slice.Ordering {
	a, b := a, b
	for len(a) > 0 && len(b) > 0 {
		x, x_len := utf8.decode_rune(a)
		y, y_len := utf8.decode_rune(b)
		if x != y {
			x, y = unicode.to_lower(x), unicode.to_lower(y)
			if x != y {return x < y ? .Less : .Greater}
		}
		a, b = a[x_len:], b[y_len:]
	}
	if len(a) == len(b) {return .Equal}
	return len(a) < len(b) ? .Less : .Greater
}

@(private)
inbox_all :: proc(ui: ^Ui_State) -> []Inbox_Row {
	chats := make([dynamic]int, 0, len(ui.chats), context.temp_allocator)
	for chat, index in ui.chats {if !chat.archived && !chat.search_only {append(&chats, index)}}
	return inbox_rows(ui, chats[:])
}

@(private)
inbox_sections :: proc(
	ui: ^Ui_State,
	rows: []Inbox_Row,
	allocator := context.temp_allocator,
	source: []Chat_Row_Ui = nil,
) -> (
	[]Folder_Section,
	[]Inbox_Row,
) {
	chat_source := source != nil ? source : ui.chats[:]
	sections := make([]Folder_Section, len(ui.prefs.folders) + 1, allocator)
	grouped := make([]Inbox_Row, len(rows), allocator)
	lookup := folder_lookup(ui)
	row_slots := make([]int, len(rows), context.temp_allocator)
	for row, index in rows {
		slot := chat_folder_slot(ui, &chat_source[row.index], lookup)
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
	if len(ui.prefs.folder_sorts) > 0 {
		for name, index in ui.prefs.folders {
			section := sections[index]
			if section.count < 2 {continue}
			members := grouped[section.start:section.start + section.count]
			for len(members) > 0 && members[0].pinned {members = members[1:]}
			#partial switch ui.prefs.folder_sorts[name] {
			case .Name:
				slice.sort_by_cmp_with_data(
					members,
					proc(a, b: Inbox_Row, data: rawptr) -> slice.Ordering {
						chats := (^[]Chat_Row_Ui)(data)^
						order := inbox_title_compare(chats[a.index].title, chats[b.index].title)
						return order != .Equal ? order : inbox_recent_compare(a, b)
					},
					&chat_source,
				)
			case .Unread:
				slice.sort_by_cmp(members, proc(a, b: Inbox_Row) -> slice.Ordering {
					if a.unread != b.unread {return a.unread ? .Less : .Greater}
					return inbox_recent_compare(a, b)
				})
			}
		}
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
