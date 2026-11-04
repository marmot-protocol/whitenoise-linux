package main

import marmot "../marmot"
import "core:fmt"
import "core:strings"
import "nendo"

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
	if nendo.box(nendo.id("ArchivedRow", index))(
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
			if nendo.box(nendo.id("ChatRowPrevClip", index))(
			{
				width = nendo.grow(),
				height = nendo.fixed(16),
				align = {y = .Center},
				clip = {x = true},
			},
			) {
				row_preview(index, chat.preview)
			}
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
		if nendo.box(nendo.id("ChatUnarch", index))(
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
			height = nendo.grow(min = single_pane() ? 84 : 0),
			direction = .Column,
			gap = 8,
			clip = {y = true, scroll = true},
		},
		) {
			chat_rows_window(
				ui,
				ui.archived[:],
				order[:count],
				nendo.id("ArchivedList"),
				.Unarchive,
				8,
			)
			if count == 0 && len(filter) > 0 {
				chat_rail_hint(
					"ArchiveNoMatch",
					tr("Try a different search."),
					"ArchiveClearSearch",
					tr("Clear search"),
					tr("No matching chats"),
				)
			}
			if count == 0 && len(filter) == 0 {
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
