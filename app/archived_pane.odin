package main

import marmot "../marmot"
import "core:fmt"
import "core:strings"
import "nendo"
import rl "sdlrl"

@(private)
archived_apply :: proc(ui: ^Ui_State, job: ^Chat_List_Work) {
	rows := job.rows
	if rows == nil {return}
	chat_members_free(&ui.archive_members)
	previous := chat_facts_previous(ui.archived[:], job.failed_facts)
	fresh: [dynamic]Chat_Row_Ui
	for i in 0 ..< rows.rows_len {
		row := &rows.rows[i]
		if !row.row.archived {continue}
		chat := chat_work_row_to_ui(job, row, previous)
		if members, known := job.members[chat.group_id]; known {
			key, _ := delete_key(&job.members, chat.group_id)
			ui.archive_members[key] = members
		}
		append(&fresh, chat)
	}
	chats_replace(&ui.archived, fresh, fence_reads = true)
}

@(private)
Archive_Action :: enum {
	None,
	Open,
	Restore,
}

@(private)
Archive_Press :: struct {
	group_id: string,
	action:   Archive_Action,
	frame:    u32,
}

@(private)
archive_press_clear :: proc(ui: ^Ui_State) {
	delete(ui.archive_press.group_id)
	ui.archive_press = {}
}

@(private)
archive_pointer_position :: proc(page: Page, pointer: nendo.Vector2) -> nendo.Vector2 {
	if page == .Archived {
		if point, ok := rl.GetCoalescedLeftClick(); ok {
			return transmute(nendo.Vector2)point / UI_ZOOM
		}
	}
	return pointer / UI_ZOOM
}

@(private)
archive_action_at_pointer :: proc(ui: ^Ui_State) -> (action: Archive_Action, index: int) {
	// Pointer hits use the displayed layout, not the latest array indices.
	for chat, i in ui.archived {
		key := nendo.id(chat.group_id).id
		if nendo.pointer_over(nendo.id("ChatUnarch", key)) {return .Restore, i}
		if nendo.pointer_over(nendo.id("ArchivedRow", key)) {return .Open, i}
	}
	return .None, -1
}

@(private = "file")
ARCHIVED_ROW_H :: f32(84)

@(private)
select_archived_chat :: proc(ui: ^Ui_State, client: ^marmot.Client, index: int) {
	if index < 0 || index >= len(ui.archived) {return}
	ui.page = .Chats
	clear(&ui.sidebar_filter)
	id := ui.archived[index].group_id
	for chat, i in ui.chats {
		if chat.group_id == id {select_chat(ui, client, i); return}
	}
	chat := chat_clone(ui.archived[index])
	chat.search_only = true
	append(&ui.chats, chat)
	select_chat(ui, client, len(ui.chats) - 1)
}

@(private)
archived_row :: proc(index: u32, chat: Chat_Row_Ui) {
	key := nendo.id(chat.group_id).id
	if nendo.box(nendo.id("ArchivedRow", key))(
	{
		width = nendo.grow(),
		height = nendo.fixed(ARCHIVED_ROW_H),
		padding = {left = 12, right = 12, top = 12, bottom = 12},
		gap = 12,
		align = {y = .Center},
		color = ROW_BG,
		radius = rr(10),
		border = {color = DIVIDER, width = bw()},
	},
	) {
		peephole_avatar(
			"ChatAvatar",
			index,
			chat.avatar_key,
			chat.title,
			40,
			chat_pic(chat),
			nendo.pointer_over(nendo.id("ChatAvatar", index)) ? .Open : .Closed,
		)
		if nendo.box(nendo.id("ArchiveRowLines", index))(
		{width = nendo.grow(), direction = .Column, gap = 4},
		) {
			if nendo.box(nendo.id("ChatRowTitleClip", index))(
			{width = nendo.grow(), height = nendo.fixed(18), clip = {x = true}},
			) {
				nendo.text(chat.title, {font = FONT_TITLE, size = 15, color = TEXT, wrap = .None})
			}
			draft := chat_draft_text(g_ui, chat)
			row_preview(
				index,
				draft != "" ? draft : chat.preview,
				draft != "" ? {} : chat.preview_icon,
				TEXT_DIM,
				draft != "" ? tr("Draft:") : "",
				ACCENT,
			)
			if nendo.box(nendo.id("ArchiveRowMeta", index))(
			{
				width = nendo.grow(),
				height = nendo.fixed(14),
				gap = 8,
				align = {y = .Center},
				clip = {x = true},
			},
			) {
				chat_timestamp(index, chat)
				if chat.muted {
					nendo.text(ICON_BELL_OFF, {font = FONT_ICON, size = 10, color = TEXT_LO})
				}
				if chat.unread > 0 {
					nendo.text(
						fmt.tprintf("%d", chat.unread),
						{font = FONT_BODY, size = 11, color = ACCENT},
					)
				}
			}
		}
		if nendo.box(nendo.id("ChatUnarch", key))(
		{
			height = nendo.fixed(tap_size() ? tap_min() : 40),
			padding = {left = 12, right = 12},
			align = {x = .Center, y = .Center},
			color = hovered() ? HOVER : SELECTED,
			radius = rr(7),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			nendo.text(tr("Restore"), {font = FONT_TITLE, size = 13, color = ACCENT, wrap = .None})
		}
	}
}

@(private = "file")
ARCHIVE_GAP :: u16(8)

@(private = "file")
archive_window :: proc(ui: ^Ui_State, id: nendo.Id, rows: []$T) {
	window := nendo.virtual_rows(id, len(rows), ARCHIVED_ROW_H, gap = ARCHIVE_GAP)
	for row in rows[window.first:window.end] {
		index: int
		when T == int {index = row} else {index = row.index}
		chat := ui.archived[index]
		// Key by chat so restoring one slides the rows below it into place.
		if nendo.box(nendo.id("ChatRowMove", nendo.id(chat.group_id).id))(
		{width = nendo.grow(), height = nendo.fixed(ARCHIVED_ROW_H), transition = layout_motion()},
		) {
			chat_row(u32(index), chat, false, .Unarchive)
		}
	}
}

@(private = "file")
archive_rows :: proc(ui: ^Ui_State, order: []int) {
	if len(ui.prefs.folders) == 0 {
		archive_window(ui, nendo.id("ArchivedRows"), order)
		return
	}
	rows := inbox_rows(ui, order, ui.archived[:])
	sections, grouped := inbox_sections(ui, rows, source = ui.archived[:])
	header_height :: f32(28)
	stride := ARCHIVED_ROW_H + f32(ARCHIVE_GAP)
	visible := make([]int, len(sections), context.temp_allocator)
	offsets := make([]f32, len(sections) + 1, context.temp_allocator)
	count := 0
	for section, i in sections {
		if section.count == 0 {continue}
		visible[count] = i
		offsets[count + 1] = offsets[count] + header_height + f32(section.count) * stride
		count += 1
	}
	window := nendo.virtual_rows(
		nendo.id("ArchivedRows"),
		offsets[:count + 1],
		gap = ARCHIVE_GAP,
		overscan = stride,
	)
	for pos in window.first ..< window.end {
		i := visible[pos]
		section := sections[i]
		id := u32(i)
		name := i < len(ui.prefs.folders) ? ui.prefs.folders[i] : ""
		if nendo.box(nendo.id("ArchiveSection", id))(
		{
			width = nendo.grow(),
			height = nendo.fixed(offsets[pos + 1] - offsets[pos]),
			direction = .Column,
			gap = ARCHIVE_GAP,
			transition = layout_motion(),
		},
		) {
			if nendo.box(nendo.id("ArchiveFolder", id))(
			{
				width = nendo.grow(),
				height = nendo.fixed(header_height),
				gap = 8,
				align = {y = .Center},
			},
			) {
				folder_icon(ui, name, 16)
				nendo.text(
					name == "" ? tr("Unfiled") : name,
					{font = FONT_TITLE, size = 14, color = TEXT},
				)
			}
			archive_window(
				ui,
				nendo.id("ArchiveFolderRows", id),
				grouped[section.start:section.start + section.count],
			)
		}
	}
}

archived_pane :: proc(ui: ^Ui_State) {
	compact := page_w(ui) < 600
	if nendo.box(nendo.id("ArchivedPage"))(
	{
		width = nendo.grow(),
		height = nendo.grow(),
		direction = .Column,
		padding = nendo.pad(compact ? 12 : 24),
		gap = 16,
		clip = {y = single_pane(), scroll = true},
	},
	) {
		if nendo.box(nendo.id("ArchiveHeader"))(
		{width = nendo.grow(), direction = compact ? .Column : .Row, gap = 12},
		) {
			if nendo.box(nendo.id("ArchiveHeading"))(
			{width = nendo.grow(), direction = .Column, gap = 10},
			) {
				if nendo.box(nendo.id("ArchiveTitle"))(
				{width = nendo.grow(), gap = 10, align = {y = .Center}},
				) {
					nendo.text(ICON_ARCHIVE, {font = FONT_ICON, size = 22, color = ACCENT})
					nendo.text(
						tr("Archived chats"),
						{font = FONT_TITLE, size = compact ? 22 : 26, color = TEXT},
					)
					nendo.text(
						fmt.tprintf("%d", len(ui.archived)),
						{font = FONT_BODY, size = 14, color = TEXT_DIM},
					)
				}
				nendo.text(
					tr("Keep your chat list focused without deleting conversations."),
					{font = FONT_BODY, size = 14, color = TEXT_DIM},
				)
			}
			// Phones already show Back and the Chats destination.
			if !single_pane(
				
			) {if nendo.box(nendo.id("ArchiveBack"))({height = nendo.fixed(tap_size() ? tap_min() : 36), padding = {left = 12, right = 12}, align = {x = .Center, y = .Center}, color = hovered() ? HOVER : ROW_BG, radius = rr(7), border = {color = FIELD_BORDER, width = bw()}}) {
					nendo.text(
						tr("Back to chats"),
						{font = FONT_TITLE, size = 13, color = TEXT_DIM},
					)
				}}
		}
		if nendo.box(nendo.id("ArchiveSearch"))(
		{
			width = nendo.grow(),
			direction = single_pane() ? .Column : .Row,
			gap = 10,
			align = {y = .Center},
		},
		) {
			if nendo.box(nendo.id("FilterBox"))(
			{
				width = nendo.grow(),
				height = nendo.fixed(tap_size() ? tap_min() : 40),
				padding = {left = 12, right = 12},
				gap = 10,
				align = {y = .Center},
				color = ROW_BG,
				radius = rr(8),
				border = {color = ui.focus == .Filter ? ACCENT_DIM : FIELD_BORDER, width = bw()},
			},
			) {
				nendo.text(ICON_SEARCH, {font = FONT_ICON, size = 13, color = TEXT_LO})
				field_text(
					ui,
					"FilterBox",
					&ui.sidebar_filter,
					tr("Search archived chats..."),
					ui.focus == .Filter,
					13,
					TEXT_LO,
				)
			}
		}
		filter := strings.to_lower(string(ui.sidebar_filter[:]), context.temp_allocator)
		order := make([]int, len(ui.archived), context.temp_allocator)
		count := 0
		for chat, i in ui.archived {
			if len(filter) > 0 &&
			   !strings.contains(strings.to_lower(chat.title, context.temp_allocator), filter) &&
			   !strings.contains(strings.to_lower(chat.preview, context.temp_allocator), filter) {
				continue
			}
			order[count] = i
			count += 1
		}
		if nendo.box(nendo.id("ArchivedList"))(
		{
			width = nendo.grow(),
			height = nendo.grow(min = single_pane() ? ARCHIVED_ROW_H : 0),
			direction = .Column,
			clip = {y = true, scroll = true},
		},
		) {
			if count > 0 {
				archive_rows(ui, order[:count])
			} else if len(filter) > 0 {
				chat_rail_hint(
					"ArchiveNoMatch",
					tr("Try a different search."),
					"ArchiveClearSearch",
					tr("Clear search"),
					tr("No matching chats"),
				)
			} else {
				if nendo.box(nendo.id("ArchiveEmpty"))(
				{
					width = nendo.grow(),
					height = nendo.grow(),
					direction = .Column,
					padding = nendo.pad(24),
					gap = 12,
					align = {x = .Center, y = .Center},
				},
				) {
					nendo.text(ICON_ARCHIVE, {font = FONT_ICON, size = 32, color = TEXT_LO})
					nendo.text(
						tr("No archived chats"),
						{font = FONT_TITLE, size = 18, color = TEXT, align = .Center},
					)
					nendo.text(
						tr("Chats you archive will appear here."),
						{font = FONT_BODY, size = 14, color = TEXT_DIM, align = .Center},
					)
				}
			}
		}
		scrollbar(nendo.id("ArchivedList"))
	}
	if single_pane() {scrollbar(nendo.id("ArchivedPage"))}
}
