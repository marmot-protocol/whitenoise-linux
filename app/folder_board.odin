// The Folders settings page: every chat, grouped the way the rail groups
// them, with drag and drop.
//
//   press ──move > DRAG_MIN──► dragging ──release──► drop
//     │                          │ chat:   keep it in the section under the pointer
//     └──release──► click        └ folder: move it to the insertion line
//
// The board is one scroll container of fixed-height rows, so layout is
// plain arithmetic: drawing windows it and the pointer maps to a row
// without asking clay about elements that are not mounted.
package main

import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

@(private)
Board_Drag_Kind :: enum {
	None,
	Chat,
	Folder,
}

@(private)
Board_Drag :: struct {
	kind:   Board_Drag_Kind,
	folder: int, // the held folder's index (kind == .Folder)
	group:  string, // the held chat's group id, owned (kind == .Chat)
	from:   [2]f32, // press point, logical px
	active: bool, // moved past DRAG_MIN: the release drops instead of clicking
	target: int, // section under the pointer (chat) or insertion slot (folder)
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

// Sections as the rail files them, plus each section's content y.
@(private = "file")
Board :: struct {
	sections: []Folder_Section,
	grouped:  []int,
	tops:     []f32,
	height:   f32,
}

@(private = "file")
board_section_h :: proc(count: int) -> f32 {
	return BOARD_HEAD_H + (count == 0 ? BOARD_EMPTY_H : f32(count) * BOARD_ROW_H) + BOARD_GAP
}

@(private = "file")
board_build :: proc(ui: ^Ui_State) -> Board {
	order := rail_order(ui.chats[:], ui.prefs.pinned)
	sections, grouped := chat_folder_sections(ui, order[:])
	tops := make([]f32, len(sections), context.temp_allocator)
	y: f32
	for section, i in sections {
		tops[i] = y
		y += board_section_h(section.count)
	}
	return {sections, grouped, tops, y}
}

// The section at content y, clamped to the first and last; `row` is the
// chat row inside it, -1 for the header and -2 for the empty slot or gap.
@(private = "file")
board_at :: proc(board: Board, y: f32) -> (section, row: int) {
	for top, i in board.tops {
		if i + 1 < len(board.tops) && y >= board.tops[i + 1] {continue}
		local := y - top
		if local < BOARD_HEAD_H {return i, -1}
		row = int((local - BOARD_HEAD_H) / BOARD_ROW_H)
		return i, row < board.sections[i].count ? row : -2
	}
	return 0, -2
}

// The pointer in clay's logical pixels, devctl's when it holds one.
@(private = "file")
board_mouse :: proc() -> [2]f32 {
	m := rl.GetMousePosition()
	if test_pointer_on {
		m = transmute(rl.Vector2)test_pointer
	}
	return {m.x / UI_ZOOM, m.y / UI_ZOOM}
}

// Pointer to board content y; ok is false outside the board.
@(private = "file")
board_pointer :: proc() -> (y: f32, ok: bool) {
	box := clay.GetElementData(clay.ID("FolderBoard"))
	scroll := clay.GetScrollContainerData(clay.ID("FolderBoard"))
	if !box.found || !scroll.found {return 0, false}
	p := board_mouse()
	b := box.boundingBox
	inside := p.x >= b.x && p.x < b.x + b.width && p.y >= b.y && p.y < b.y + b.height
	return p.y - b.y - scroll.scrollPosition.y, inside
}

// Insertion slot for a held folder: how many folder headers sit above
// the pointer. len(folders) drops it last, just above Unfiled.
@(private = "file")
board_folder_slot :: proc(ui: ^Ui_State, board: Board, y: f32) -> int {
	slot := 0
	for i in 0 ..< len(ui.prefs.folders) {
		if board.tops[i] + BOARD_HEAD_H / 2 < y {slot = i + 1}
	}
	return slot
}

@(private = "file")
board_chat_index :: proc(ui: ^Ui_State, group_id: string) -> int {
	for chat, i in ui.chats {
		if chat.group_id == group_id {return i}
	}
	return -1
}

@(private = "file")
board_drag_clear :: proc(ui: ^Ui_State) {
	delete(ui.board_drag.group)
	ui.board_drag = {}
}

// Scroll the board while a drag hangs near its top or bottom edge.
@(private = "file")
board_autoscroll :: proc() {
	box := clay.GetElementData(clay.ID("FolderBoard"))
	scroll := clay.GetScrollContainerData(clay.ID("FolderBoard"))
	if !box.found || !scroll.found {return}
	y := board_mouse().y
	b := box.boundingBox
	span := max(0, scroll.contentDimensions.height - scroll.scrollContainerDimensions.height)
	step: f32
	if y < b.y + BOARD_EDGE {step = 8}
	if y > b.y + b.height - BOARD_EDGE {step = -8}
	scroll.scrollPosition.y = clamp(scroll.scrollPosition.y + step, -span, 0)
}

@(private = "file")
board_drop :: proc(ui: ^Ui_State) {
	drag := ui.board_drag
	switch drag.kind {
	case .None:
	case .Chat:
		if board_chat_index(ui, drag.group) < 0 {return}
		name := drag.target < len(ui.prefs.folders) ? ui.prefs.folders[drag.target] : ""
		folder_place(ui, drag.group, name)
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
		y, _ := board_pointer()
		if rl.IsMouseButtonDown(.LEFT) {
			d := board_mouse() - drag.from
			if !drag.active && d.x * d.x + d.y * d.y > DRAG_MIN * DRAG_MIN {
				drag.active = true
			}
			if !drag.active {return false}
			board := board_build(ui)
			if drag.kind == .Chat {
				drag.target, _ = board_at(board, y)
			} else {
				drag.target = board_folder_slot(ui, board, y)
			}
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
		if row == -1 && section < len(ui.prefs.folders) {
			drag^ = {
				kind   = .Folder,
				folder = section,
				from   = p,
				target = section,
			}
		} else if row >= 0 {
			chat := ui.chats[board.grouped[board.sections[section].start + row]]
			drag^ = {
				kind   = .Chat,
				group  = strings.clone(chat.group_id),
				from   = p,
				target = section,
			}
		}
		return false
	}

	if !mouse_released() {return false}
	if clicked("SettingsFolderNew") {
		open_folder_modal(ui)
		return true
	}
	for chat, i in ui.chats {
		if clay.PointerOver(clay.ID("BoardKeep", u32(i))) {
			folder_unplace(ui, chat.group_id)
			save_settings(ui)
			return true
		}
	}
	for name, i in ui.prefs.folders {
		if clay.PointerOver(clay.ID("BoardDelete", u32(i))) {
			confirm_ask(ui, .Delete_Folder, name, name)
			return true
		}
		if clay.PointerOver(clay.ID("BoardHead", u32(i))) {
			open_folder_modal(ui, rename = i)
			return true
		}
	}
	return false
}

@(private = "file")
board_spacer :: proc(id: u32, height: f32) {
	if height <= 0 {return}
	if clay.UI(clay.ID("BoardSpace", id))(
	{layout = {sizing = {height = clay.SizingFixed(height)}}},
	) {}
}

// Every chat under its folder header, windowed to what the viewport shows.
@(private)
folder_board :: proc(ui: ^Ui_State) {
	board := board_build(ui)
	drag := ui.board_drag
	dragging := drag.active

	// Fill the page below the actions; never taller than the content.
	height := max(120, f32(rl.GetScreenHeight()) / UI_ZOOM - 240)
	page := clay.GetElementData(clay.ID("SettingsPage"))
	actions := clay.GetElementData(clay.ID("SettingsFolderActions"))
	if page.found && actions.found {
		page_scroll := clay.GetScrollContainerData(clay.ID("SettingsPage"))
		offset := page_scroll.found ? page_scroll.scrollPosition.y : 0
		used := actions.boundingBox.y + actions.boundingBox.height - page.boundingBox.y - offset
		height = max(120, page.boundingBox.height - used - 30)
	}
	height = min(height, board.height)

	if clay.UI(clay.ID("FolderBoard"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(height)},
			layoutDirection = .TopToBottom,
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	},
	) {
		view := clay.GetScrollContainerData(clay.ID("FolderBoard"))
		top := view.found ? -view.scrollPosition.y - 72 : 0
		bottom := top + height + 144
		for section, i in board.sections {
			id := u32(i) * 4
			section_top := board.tops[i]
			section_h := board_section_h(section.count)
			if section_top + section_h < top || section_top > bottom {
				board_spacer(id, section_h)
				continue
			}
			target := dragging && drag.kind == .Chat && drag.target == i
			insert := dragging && drag.kind == .Folder && drag.target == i
			board_header(ui, i, section.count, target, insert)
			if section.count == 0 {
				board_empty(i, target)
			} else {
				rows := board.grouped[section.start:][:section.count]
				row_top := section_top + BOARD_HEAD_H
				first := clamp(int((top - row_top) / BOARD_ROW_H), 0, len(rows))
				last := clamp(int((bottom - row_top) / BOARD_ROW_H) + 1, first, len(rows))
				board_spacer(id + 1, f32(first) * BOARD_ROW_H)
				for index in rows[first:last] {
					board_chat(ui, index, i)
				}
				board_spacer(id + 2, f32(len(rows) - last) * BOARD_ROW_H)
			}
			board_spacer(id + 3, BOARD_GAP)
		}
	}
	scrollbar(clay.ID("FolderBoard"))
	if dragging {
		board_ghost(ui)
	}
}

@(private = "file")
board_header :: proc(ui: ^Ui_State, index, count: int, target, insert: bool) {
	folder := index < len(ui.prefs.folders)
	name := folder ? ui.prefs.folders[index] : ""
	held := ui.board_drag.active && ui.board_drag.kind == .Folder && ui.board_drag.folder == index
	border := clay.BorderElementConfig {
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
	if clay.UI(clay.ID("BoardHead", u32(index)))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(BOARD_HEAD_H)},
			padding = {left = 6, right = 18},
			childGap = 10,
			childAlignment = {y = .Center},
		},
		backgroundColor = target ? SELECTED : (folder && hovered() && !ui.board_drag.active ? HOVER : {}),
		border = border,
		cornerRadius = target ? rr(6) : {},
	},
	) {
		// Unfiled can't move; it keeps the grip's width so the icons align.
		clay.Text(
			ICON_GRIP,
			{
				fontId = FONT_ICON,
				fontSize = 12,
				textColor = held ? ACCENT : (folder ? TEXT_LO : {}),
			},
		)
		folder_icon(ui, name, 16)
		if clay.UI(clay.ID("BoardHeadName", u32(index)))(
		{layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}},
		) {
			clay.Text(
				folder ? name : tr("Unfiled"),
				{fontId = FONT_TITLE, fontSize = 13, textColor = TEXT, wrapMode = .None},
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
			clay.Text(summary, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
		}
		clay.Text(
			fmt.tprintf("%d", count),
			{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
		)
		if folder {
			if clay.UI(clay.ID("BoardDelete", u32(index)))(
			{
				layout = {
					sizing = {clay.SizingFixed(26), clay.SizingFixed(26)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(6),
			},
			) {
				clay.Text(ICON_TRASH, {fontId = FONT_ICON, fontSize = 14, textColor = DANGER})
				if hovered() {
					tooltip(tr("Delete"))
					cursor_raise(.Pointer)
				}
			}
			on_delete := clay.PointerOver(clay.ID("BoardDelete", u32(index)))
			if hovered() && !ui.board_drag.active && !on_delete {
				tooltip(tr("Click to edit, drag to reorder."))
				cursor_raise(.Pointer)
			}
		}
	}
}

@(private = "file")
board_empty :: proc(index: int, target: bool) {
	if clay.UI(clay.ID("BoardEmpty", u32(index)))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(BOARD_EMPTY_H)},
			padding = {left = 34},
			childAlignment = {y = .Center},
		},
	},
	) {
		clay.Text(
			target ? tr("Drop here") : tr("No chats yet"),
			{fontId = FONT_BODY, fontSize = 12, textColor = target ? ACCENT : TEXT_LO},
		)
	}
}

@(private = "file")
board_chat :: proc(ui: ^Ui_State, index: int, section: int) {
	chat := ui.chats[index]
	held := ui.board_drag.active && ui.board_drag.group == chat.group_id
	placed := folder_placed(ui, chat.group_id)
	if clay.UI(clay.ID("BoardChat", u32(index)))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(BOARD_ROW_H)},
			padding = {left = 22, right = 18},
			childGap = 10,
			childAlignment = {y = .Center},
		},
		backgroundColor = held ? SELECTED : (hovered() && !ui.board_drag.active ? HOVER : {}),
		cornerRadius = rr(6),
	},
	) {
		clay.Text(
			ICON_GRIP,
			{fontId = FONT_ICON, fontSize = 12, textColor = held ? ACCENT : TEXT_LO},
		)
		avatar("BoardAvatar", u32(index), chat.avatar_key, chat.title, 24, chat_pic(chat))
		if clay.UI(clay.ID("BoardChatName", u32(index)))(
		{layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}},
		) {
			clay.Text(
				chat.title,
				{
					fontId = FONT_BODY,
					fontSize = 13,
					textColor = held ? TEXT_DIM : TEXT,
					wrapMode = .None,
				},
			)
		}
		if placed {
			board_keep(ui, index)
		} else if section < len(ui.prefs.folders) {
			clay.Text(tr("By rule"), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
		}
		if hovered() && !ui.board_drag.active {cursor_raise(.Pointer)}
	}
}

// The manual-placement checkbox; clearing it hands the chat to the rules.
@(private = "file")
board_keep :: proc(ui: ^Ui_State, index: int) {
	if clay.UI(clay.ID("BoardKeep", u32(index)))(
	{
		layout = {
			padding = {left = 6, right = 6, top = 4, bottom = 4},
			childGap = 6,
			childAlignment = {y = .Center},
		},
		backgroundColor = hovered() ? HOVER : {},
		cornerRadius = rr(4),
	},
	) {
		if clay.UI(clay.ID("BoardKeepBox", u32(index)))(
		{
			layout = {
				sizing = {clay.SizingFixed(16), clay.SizingFixed(16)},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = CARD,
			border = {color = ACCENT, width = {1, 1, 1, 1, 0}},
			cornerRadius = rr(2),
		},
		) {
			clay.Text(ICON_CHECK, {fontId = FONT_ICON, fontSize = 12, textColor = ACCENT})
		}
		clay.Text(tr("Placed by hand"), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
		if hovered() && !ui.board_drag.active {
			tooltip(tr("Clear to let folder rules decide."))
			cursor_raise(.Pointer)
		}
	}
}

// What the pointer carries, drawn at the pointer.
@(private = "file")
board_ghost :: proc(ui: ^Ui_State) {
	drag := ui.board_drag
	label: string
	switch drag.kind {
	case .None:
		return
	case .Chat:
		index := board_chat_index(ui, drag.group)
		if index < 0 {return}
		label = ui.chats[index].title
	case .Folder:
		if drag.folder >= len(ui.prefs.folders) {return}
		label = ui.prefs.folders[drag.folder]
	}
	p := board_mouse()
	if clay.UI(clay.ID("BoardGhost"))(
	{
		layout = {
			sizing = {width = clay.SizingFit({max = 280})},
			padding = {left = 12, right = 12, top = 8, bottom = 8},
			childGap = 8,
			childAlignment = {y = .Center},
		},
		floating = {
			attachTo = .Root,
			offset = {p.x + 14, p.y + 10},
			zIndex = 20,
			pointerCaptureMode = .Passthrough,
		},
		backgroundColor = CARD,
		border = {color = ACCENT, width = bw()},
		cornerRadius = rr(8),
	},
	) {
		if drag.kind == .Folder {
			folder_icon(ui, label, 14)
		} else {
			clay.Text(ICON_CHATS, {fontId = FONT_ICON, fontSize = 13, textColor = ACCENT})
		}
		clay.Text(label, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT, wrapMode = .None})
	}
	cursor_raise(.Grabbing)
}
