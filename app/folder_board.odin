// The Folders settings page: every inbox row, grouped the way the rail groups
// them, with drag and drop.
//
//   press ──move > DRAG_MIN──► dragging ──release──► drop
//     │                          │ row:    keep it in the section under the pointer
//     └──release──► click        └ folder: move it to the insertion line
//
// The board has fixed-height rows, so layout is plain arithmetic:
// drawing windows it and the pointer maps to a row
// without asking nendo about elements that are not mounted.
package main

import "core:fmt"
import "core:strings"

import "nendo"
import rl "sdlrl"

@(private)
Board_Drag_Kind :: enum {
	None,
	Row,
	Folder,
}

@(private)
Board_Drag :: struct {
	kind:   Board_Drag_Kind,
	folder: int, // the held folder's index (kind == .Folder)
	key:    string, // the held inbox row's stable key, owned (kind == .Row)
	from:   [2]f32, // press point, logical px
	active: bool, // moved past DRAG_MIN: the release drops instead of clicking
	target: int, // section under the pointer (row) or insertion slot (folder)
}

@(private = "file")
ICON_GRIP :: "\uf0c9"

@(private = "file")
BOARD_HEAD_H :: f32(40)
@(private = "file")
BOARD_ROW_H :: f32(40)
@(private = "file")
BOARD_EMPTY_H :: f32(32)
@(private = "file")
BOARD_GAP :: f32(10)
@(private = "file")
BOARD_EDGE :: f32(32) // pointer this close to the top or bottom scrolls a drag

@(private = "file")
board_create_at: int = -1 // folder count when the board opened Create

// Sections as the rail files them, plus each section's content y.
@(private = "file")
Board :: struct {
	sections: []Folder_Section,
	grouped:  []Inbox_Row,
	tops:     []f32,
	height:   f32,
}

@(private = "file")
board_section_h :: proc(count: int) -> f32 {
	return(
		settings_tap_size(BOARD_HEAD_H) +
		(count == 0 ? BOARD_EMPTY_H : f32(count) * settings_tap_size(BOARD_ROW_H)) +
		BOARD_GAP \
	)
}

@(private = "file")
board_build :: proc(ui: ^Ui_State) -> Board {
	sections, grouped := inbox_sections(ui, inbox_all(ui))
	tops := make([]f32, len(sections), context.temp_allocator)
	y: f32
	for section, i in sections {
		tops[i] = y
		y += board_section_h(section.count)
	}
	return {sections, grouped, tops, y}
}

// The section at content y, clamped to the first and last; `row` is the
// inbox row inside it, -1 for the header and -2 for the empty slot or gap.
@(private = "file")
board_at :: proc(board: Board, y: f32) -> (section, row: int) {
	for top, i in board.tops {
		if i + 1 < len(board.tops) && y >= board.tops[i + 1] {continue}
		local := y - top
		if local < settings_tap_size(BOARD_HEAD_H) {return i, -1}
		row = int((local - settings_tap_size(BOARD_HEAD_H)) / settings_tap_size(BOARD_ROW_H))
		return i, row < board.sections[i].count ? row : -2
	}
	return 0, -2
}

// The pointer in nendo's logical pixels, devctl's when it holds one.
@(private = "file")
board_mouse :: proc() -> [2]f32 {
	m := rl.GetMousePosition()
	if test_pointer_on {
		m = transmute(rl.Vector2)test_pointer
	}
	return {m.x / UI_ZOOM, m.y / UI_ZOOM}
}

// What scrolls the board: on a phone the board grows to its content inside
// the settings page scroll, so a finger on a row scrolls the page; wider,
// the board is its own scroll container below the page's actions.
@(private = "file")
board_scroller :: proc() -> nendo.Id {
	return single_pane() ? nendo.id("SettingsPage") : nendo.id("FolderBoard")
}

// Pointer to board content y; ok is false outside the visible board.
@(private = "file")
board_pointer :: proc() -> (y: f32, ok: bool) {
	box := nendo.element(nendo.id("FolderBoard"))
	view := nendo.element(board_scroller())
	if !box.found || !view.found {return 0, false}
	p := board_mouse()
	b, v := box.rect, view.rect
	inside :=
		p.x >= b.x &&
		p.x < b.x + b.width &&
		p.y >= max(b.y, v.y) &&
		p.y < min(b.y + b.height, v.y + v.height)
	y = p.y - b.y
	// The page scroll already moved the board's box; its own scroll did not.
	if !single_pane() {
		scroll := nendo.scroll(nendo.id("FolderBoard"))
		if !scroll.found {return 0, false}
		y -= scroll.position.y
	}
	return y, inside
}

// Insertion slot for a held folder: how many folder headers sit above
// the pointer. len(folders) drops it last, just above Unfiled.
@(private = "file")
board_folder_slot :: proc(ui: ^Ui_State, board: Board, y: f32) -> int {
	slot := 0
	for i in 0 ..< len(ui.prefs.folders) {
		if board.tops[i] + settings_tap_size(BOARD_HEAD_H) / 2 < y {slot = i + 1}
	}
	return slot
}

@(private = "file")
board_find_row :: proc(rows: []Inbox_Row, key: string) -> (Inbox_Row, bool) {
	for row in rows {
		if row.key == key {return row, true}
	}
	return {}, false
}

@(private = "file")
board_row_id :: proc(row: Inbox_Row) -> u32 {
	return u32(row.index) * 2 + (row.kind == .Terminal ? 1 : 0)
}

@(private = "file")
board_row_title :: proc(ui: ^Ui_State, row: Inbox_Row) -> string {
	if row.kind == .Terminal {return rl.WhipProjects()[row.index].name}
	return ui.chats[row.index].title
}

@(private = "file")
board_drag_clear :: proc(ui: ^Ui_State) {
	delete(ui.board_drag.key)
	ui.board_drag = {}
}

// Scroll the board's container while a drag hangs near its top or bottom
// edge, faster the deeper the pointer goes, past the edge included.
@(private = "file")
board_autoscroll :: proc() {
	id := board_scroller()
	box := nendo.element(id)
	scroll := nendo.scroll(id)
	if !box.found || !scroll.found {return}
	y := board_mouse().y
	b := box.rect
	depth: f32
	if y < b.y + BOARD_EDGE {depth = b.y + BOARD_EDGE - y}
	if y > b.y + b.height - BOARD_EDGE {depth = b.y + b.height - BOARD_EDGE - y}
	if depth == 0 {return}
	speed := clamp(abs(depth) * 15, 120, 1500) // px per second
	span := max(0, scroll.content.height - scroll.viewport.height)
	scroll.position.y = clamp(scroll.position.y + (depth > 0 ? speed : -speed) * anim_dt, -span, 0)
	anim_moving += 1 // keep frames coming while the finger rests at the edge
}

@(private = "file")
board_drop :: proc(ui: ^Ui_State) {
	drag := ui.board_drag
	if drag.target < 0 {return}
	switch drag.kind {
	case .None:
	case .Row:
		_, exists := board_find_row(inbox_all(ui), drag.key)
		if !exists {return}
		name := drag.target < len(ui.prefs.folders) ? ui.prefs.folders[drag.target] : ""
		folder_place(ui, drag.key, name)
		save_settings(ui)
	case .Folder:
		from, to := drag.folder, drag.target
		if from >= len(ui.prefs.folders) {return}
		if to > from {to -= 1}
		if to == from {return}
		name := ui.prefs.folders[from]
		ordered_remove(&ui.prefs.folders, from)
		inject_at(&ui.prefs.folders, to, name)
		save_settings(ui)
	}
}

// Every pointer event on the Folders page: drags on any frame, clicks on
// release. True when the event was consumed.
@(private)
handle_folder_board :: proc(ui: ^Ui_State) -> bool {
	drag := &ui.board_drag
	if drag.kind != .None {
		y, inside := board_pointer()
		// Recompute on release too: the last held frame may have scrolled.
		board := board_build(ui)
		drag.target = -1
		if inside {
			if drag.kind == .Row {
				section, _ := board_at(board, y)
				end :=
					board.tops[section] +
					board_section_h(board.sections[section].count) -
					BOARD_GAP
				if y < end {drag.target = section}
			} else {
				drag.target = board_folder_slot(ui, board, y)
			}
		}
		if rl.IsMouseButtonDown(.LEFT) {
			d := board_mouse() - drag.from
			if !drag.active && d.x * d.x + d.y * d.y > DRAG_MIN * DRAG_MIN {
				drag.active = true
			}
			if !drag.active {return false}
			board_autoscroll()
			return true
		}
		// Released: a drag drops, a press that never moved falls through
		// to the clicks below.
		active := drag.active
		if active {board_drop(ui)}
		board_drag_clear(ui)
		if active {return true}
	}

	if mouse_pressed() {
		y, inside := board_pointer()
		if !inside {return false}
		board := board_build(ui)
		section, row := board_at(board, y)
		p := board_mouse()
		if single_pane() &&
		   p.x >= nendo.element(nendo.id("FolderBoard")).rect.x + 44 {return false}
		if row == -1 && section < len(ui.prefs.folders) {
			drag^ = {
				kind   = .Folder,
				folder = section,
				from   = p,
				target = section,
			}
		} else if row >= 0 {
			item := board.grouped[board.sections[section].start + row]
			drag^ = {
				kind   = .Row,
				key    = strings.clone(item.key),
				from   = p,
				target = section,
			}
		}
		return false
	}

	if !mouse_released() {return false}
	if clicked("SettingsFolderNew") {
		board_create_at = len(ui.prefs.folders)
		open_folder_modal(ui)
		return true
	}
	for row in inbox_all(ui) {
		id := board_row_id(row)
		if nendo.pointer_over(nendo.id("BoardKeep", id)) {
			folder_unplace(ui, row.key)
			save_settings(ui)
			return true
		}
		if nendo.pointer_over(nendo.id("BoardChat", id)) {
			open_folder_modal(ui, row.key)
			return true
		}
	}
	for name, i in ui.prefs.folders {
		if nendo.pointer_over(nendo.id("BoardDelete", u32(i))) {
			confirm_ask(ui, .Delete_Folder, name, name)
			return true
		}
		if nendo.pointer_over(nendo.id("BoardHead", u32(i))) {
			open_folder_modal(ui, rename = i)
			return true
		}
	}
	return false
}

@(private = "file")
board_spacer :: proc(id: u32, height: f32) {
	if height <= 0 {return}
	if nendo.box(nendo.id("BoardSpace", id))({height = nendo.fixed(height)}) {}
}

// Every inbox row under its folder header, windowed to the viewport.
@(private)
folder_board :: proc(ui: ^Ui_State) {
	board := board_build(ui)
	drag := ui.board_drag
	dragging := drag.active

	// Fill the page below the actions; never taller than the content.
	height := max(120, f32(rl.GetScreenHeight()) / UI_ZOOM - 240)
	page := nendo.element(nendo.id("SettingsPage"))
	actions := nendo.element(nendo.id("SettingsFolderActions"))
	if page.found && actions.found {
		page_scroll := nendo.scroll(nendo.id("SettingsPage"))
		offset := page_scroll.found ? page_scroll.position.y : 0
		used := actions.rect.y + actions.rect.height - page.rect.y - offset
		height = max(120, page.rect.height - used - 30)
	}
	height = min(height, board.height)
	phone := single_pane()
	if phone {height = board.height}
	box := nendo.element(nendo.id("FolderBoard"))
	if board_create_at >= 0 && !ui.folder_open {
		if board_create_at < len(ui.prefs.folders) && box.found {
			// The new folder is appended before Unfiled. Reveal its header
			// arithmetically, even when windowing has not mounted it yet.
			id := board_scroller()
			view := nendo.element(id)
			scroll := nendo.scroll(id)
			if view.found && scroll.found {
				y := box.rect.y + board.tops[board_create_at]
				if !phone {y += scroll.position.y}
				h := settings_tap_size(BOARD_HEAD_H) + BOARD_EMPTY_H
				if y < view.rect.y {
					scroll.position.y += view.rect.y - y
				} else if y + h > view.rect.y + view.rect.height {
					scroll.position.y -= y + h - view.rect.y - view.rect.height
				}
				scroll.position.y = min(0, scroll.position.y)
				scroll_jumped = true
			}
		}
		board_create_at = -1
	}

	if nendo.box(nendo.id("FolderBoard"))(
	{
		width = nendo.grow(),
		height = nendo.fixed(height),
		direction = .Column,
		clip = {y = !phone, scroll = !phone},
	},
	) {
		view := nendo.scroll(nendo.id("FolderBoard"))
		top := view.found ? -view.position.y - 72 : 0
		bottom := top + height + 144
		if phone && page.found && box.found {
			top = page.rect.y - box.rect.y - 72
			bottom = top + page.rect.height + 144
		}
		for section, i in board.sections {
			id := u32(i) * 4
			section_top := board.tops[i]
			section_h := board_section_h(section.count)
			if section_top + section_h < top || section_top > bottom {
				board_spacer(id, section_h)
				continue
			}
			target := dragging && drag.kind == .Row && drag.target == i
			insert := dragging && drag.kind == .Folder && drag.target == i
			board_header(ui, i, section.count, target, insert)
			if section.count == 0 {
				board_empty(i, target)
			} else {
				rows := board.grouped[section.start:][:section.count]
				row_top := section_top + settings_tap_size(BOARD_HEAD_H)
				first := clamp(int((top - row_top) / settings_tap_size(BOARD_ROW_H)), 0, len(rows))
				last := clamp(
					int((bottom - row_top) / settings_tap_size(BOARD_ROW_H)) + 1,
					first,
					len(rows),
				)
				board_spacer(id + 1, f32(first) * settings_tap_size(BOARD_ROW_H))
				for row in rows[first:last] {
					board_row(ui, row, i)
				}
				board_spacer(id + 2, f32(len(rows) - last) * settings_tap_size(BOARD_ROW_H))
			}
			board_spacer(id + 3, BOARD_GAP)
		}
	}
	if !phone {scrollbar(nendo.id("FolderBoard"))}
	if dragging {
		board_ghost(ui, board.grouped)
	}
}

@(private = "file")
board_header :: proc(ui: ^Ui_State, index, count: int, target, insert: bool) {
	folder := index < len(ui.prefs.folders)
	name := folder ? ui.prefs.folders[index] : ""
	held := ui.board_drag.active && ui.board_drag.kind == .Folder && ui.board_drag.folder == index
	border := nendo.Border {
		color = FIELD_BORDER,
		width = {bottom = 1},
	}
	if target {border = {
			color = ACCENT,
			width = {2, 2, 2, 2, 0},
		}}
	if insert {border = {
			color = ACCENT,
			width = {top = 3, bottom = 1},
		}}
	if nendo.box(nendo.id("BoardHead", u32(index)))(
	{
		width = nendo.grow(),
		height = nendo.fixed(settings_tap_size(BOARD_HEAD_H)),
		padding = {left = 6, right = 18},
		gap = 10,
		align = {y = .Center},
		color = target ? SELECTED : (folder && hovered() && !ui.board_drag.active ? HOVER : {}),
		border = border,
		radius = target ? rr(6) : {},
	},
	) {
		// Unfiled can't move; it keeps the grip's width so the icons align.
		nendo.text(
			ICON_GRIP,
			{font = FONT_ICON, size = 12, color = held ? ACCENT : (folder ? TEXT_LO : {})},
		)
		folder_icon(ui, name, 16)
		if nendo.box(nendo.id("BoardHeadName", u32(index)))(
		{width = nendo.grow(), clip = {x = true}},
		) {
			nendo.text(
				folder ? name : tr("Unfiled"),
				{font = FONT_TITLE, size = 13, color = TEXT, wrap = .None},
			)
		}
		if folder {
			rules := ui.prefs.folder_rules[name]
			summary := tr("No rules")
			if len(rules.rules) > 0 {
				summary = fmt.tprintf(
					tr(len(rules.rules) == 1 ? N_("%d rule") : N_("%d rules")),
					len(rules.rules),
				)
			}
			nendo.text(summary, {font = FONT_BODY, size = 11, color = TEXT_LO})
		}
		nendo.text(fmt.tprintf("%d", count), {font = FONT_BODY, size = 12, color = TEXT_DIM})
		if folder {
			if nendo.box(nendo.id("BoardDelete", u32(index)))(
			{
				width = nendo.fixed(settings_tap_size(26)),
				height = nendo.fixed(settings_tap_size(26)),
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : {},
				radius = rr(6),
			},
			) {
				nendo.text(ICON_TRASH, {font = FONT_ICON, size = 14, color = DANGER})
				if hovered() {
					tooltip(tr("Delete"))
					cursor_raise(.Pointer)
				}
			}
			on_delete := nendo.pointer_over(nendo.id("BoardDelete", u32(index)))
			if hovered() && !ui.board_drag.active && !on_delete {
				tooltip(tr("Click to edit, drag to reorder."))
				cursor_raise(.Pointer)
			}
		}
	}
}

@(private = "file")
board_empty :: proc(index: int, target: bool) {
	if nendo.box(nendo.id("BoardEmpty", u32(index)))(
	{
		width = nendo.grow(),
		height = nendo.fixed(BOARD_EMPTY_H),
		padding = {left = 34},
		align = {y = .Center},
	},
	) {
		nendo.text(
			target ? tr("Drop here") : tr("No chats or terminals yet"),
			{font = FONT_BODY, size = 12, color = target ? ACCENT : TEXT_LO},
		)
	}
}

@(private = "file")
board_row :: proc(ui: ^Ui_State, row: Inbox_Row, section: int) {
	id := board_row_id(row)
	title := board_row_title(ui, row)
	held := ui.board_drag.active && ui.board_drag.kind == .Row && ui.board_drag.key == row.key
	placed := folder_placed(ui, row.key)
	if nendo.box(nendo.id("BoardChat", id))(
	{
		width = nendo.grow(),
		height = nendo.fixed(settings_tap_size(BOARD_ROW_H)),
		padding = {left = 22, right = 18},
		gap = 10,
		align = {y = .Center},
		color = held ? SELECTED : (hovered() && !ui.board_drag.active ? HOVER : {}),
		radius = rr(6),
	},
	) {
		nendo.text(ICON_GRIP, {font = FONT_ICON, size = 12, color = held ? ACCENT : TEXT_LO})
		if row.kind == .Terminal {
			nendo.text("\ue795", {font = FONT_ICON, size = 20, color = TEXT_DIM})
		} else {
			chat := ui.chats[row.index]
			avatar("BoardAvatar", id, chat.avatar_key, title, 24, chat_pic(chat))
		}
		if nendo.box(nendo.id("BoardChatName", id))({width = nendo.grow(), clip = {x = true}}) {
			nendo.text(
				title,
				{font = FONT_BODY, size = 13, color = held ? TEXT_DIM : TEXT, wrap = .None},
			)
		}
		if placed {
			board_keep(ui, id)
		} else if section < len(ui.prefs.folders) {
			nendo.text(tr("By rule"), {font = FONT_BODY, size = 11, color = TEXT_LO})
		}
		if hovered() && !ui.board_drag.active {cursor_raise(.Pointer)}
	}
}

// The manual-placement checkbox; clearing it hands the row to the rules.
@(private = "file")
board_keep :: proc(ui: ^Ui_State, id: u32) {
	if nendo.box(nendo.id("BoardKeep", id))(
	{
		width = nendo.fit(min = settings_tap_size(28)),
		height = nendo.fit(min = settings_tap_size(24)),
		padding = {left = 6, right = 6, top = 4, bottom = 4},
		gap = 6,
		align = {y = .Center},
		color = hovered() ? HOVER : {},
		radius = rr(4),
	},
	) {
		if nendo.box(nendo.id("BoardKeepBox", id))(
		{
			width = nendo.fixed(16),
			height = nendo.fixed(16),
			align = {x = .Center, y = .Center},
			color = CARD,
			border = {color = ACCENT, width = {1, 1, 1, 1, 0}},
			radius = rr(2),
		},
		) {
			nendo.text(ICON_CHECK, {font = FONT_ICON, size = 12, color = ACCENT})
		}
		if !single_pane(
			
		) {nendo.text(tr("Placed by hand"), {font = FONT_BODY, size = 11, color = TEXT_DIM})}
		if hovered() && !ui.board_drag.active {
			tooltip(tr("Clear to let folder rules decide."))
			cursor_raise(.Pointer)
		}
	}
}

// What the pointer carries, drawn at the pointer.
@(private = "file")
board_ghost :: proc(ui: ^Ui_State, rows: []Inbox_Row) {
	drag := ui.board_drag
	label: string
	icon := ICON_CHATS
	switch drag.kind {
	case .None:
		return
	case .Row:
		row, exists := board_find_row(rows, drag.key)
		if !exists {return}
		label = board_row_title(ui, row)
		if row.kind == .Terminal {icon = "\ue795"}
	case .Folder:
		if drag.folder >= len(ui.prefs.folders) {return}
		label = ui.prefs.folders[drag.folder]
	}
	p := board_mouse()
	if nendo.box(nendo.id("BoardGhost"))(
	{
		width = nendo.fit(max = 280),
		padding = {left = 12, right = 12, top = 8, bottom = 8},
		gap = 8,
		align = {y = .Center},
		floating = {
			attach_to = .Root,
			offset = {p.x + 14, p.y + 10},
			z = 20,
			pointer = .Passthrough,
		},
		color = CARD,
		border = {color = ACCENT, width = bw()},
		radius = rr(8),
	},
	) {
		if drag.kind == .Folder {
			folder_icon(ui, label, 14)
		} else {
			nendo.text(icon, {font = FONT_ICON, size = 13, color = ACCENT})
		}
		nendo.text(label, {font = FONT_TITLE, size = 13, color = TEXT, wrap = .None})
	}
	cursor_raise(.Grabbing)
}
