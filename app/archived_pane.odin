package main

import "core:fmt"
import "core:strings"
import clay "../vendor/clay/bindings/odin/clay-odin"

@(private)
archived_row :: proc(index: u32, chat: Chat_Row_Ui) {
	if clay.UI(clay.ID("ChatRow", index))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(ARCHIVED_ROW_H)},
			padding = {left = 12, right = 12, top = 12, bottom = 12},
			childGap = 12,
			childAlignment = {y = .Center},
		},
		backgroundColor = ROW_BG,
		cornerRadius = rr(10),
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
			clay.PointerOver(clay.ID("ChatAvatar", index)) ? .Open : .Closed,
		)
		if clay.UI(clay.ID("ArchiveRowLines", index))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				childGap = 4,
			},
		},
		) {
			if clay.UI(clay.ID("ChatRowTitleClip", index))(
			{
				layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(18)}},
				clip = {horizontal = true},
			},
			) {
				clay.Text(
					chat.title,
					{fontId = FONT_TITLE, fontSize = 15, textColor = TEXT, wrapMode = .None},
				)
			}
			if clay.UI(clay.ID("ChatRowPrevClip", index))(
			{
				layout = {
					sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(16)},
					childAlignment = {y = .Center},
				},
				clip = {horizontal = true},
			},
			) {
				row_preview(index, chat.preview)
			}
			if clay.UI(clay.ID("ArchiveRowMeta", index))(
			{
				layout = {
					sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(14)},
					childGap = 8,
					childAlignment = {y = .Center},
				},
				clip = {horizontal = true},
			},
			) {
				clay.Text(
					chat.at,
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO, wrapMode = .None},
				)
				if chat.muted {
					clay.Text(
						ICON_BELL_OFF,
						{fontId = FONT_ICON, fontSize = 10, textColor = TEXT_LO},
					)
				}
				if chat.unread > 0 {
					clay.Text(
						fmt.tprintf("%d", chat.unread),
						{fontId = FONT_BODY, fontSize = 11, textColor = ACCENT},
					)
				}
			}
		}
		if clay.UI(clay.ID("ChatUnarch", index))(
		{
			layout = {
				sizing = {height = clay.SizingFixed(40)},
				padding = {left = 12, right = 12},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = hovered() ? HOVER : SELECTED,
			cornerRadius = rr(7),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			clay.Text(
				tr("Restore"),
				{fontId = FONT_TITLE, fontSize = 13, textColor = ACCENT, wrapMode = .None},
			)
		}
	}
}

archived_pane :: proc(ui: ^Ui_State) {
	compact := page_w(ui) < 600
	if clay.UI(clay.ID("ArchivedPage"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(compact ? 12 : 24),
			childGap = 16,
		},
	},
	) {
		if clay.UI(clay.ID("ArchiveHeader"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = compact ? .TopToBottom : .LeftToRight,
				childGap = 12,
			},
		},
		) {
			if clay.UI(clay.ID("ArchiveHeading"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					childGap = 10,
				},
			},
			) {
				if clay.UI(clay.ID("ArchiveTitle"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						childGap = 10,
						childAlignment = {y = .Center},
					},
				},
				) {
					clay.Text(
						ICON_ARCHIVE,
						{fontId = FONT_ICON, fontSize = 22, textColor = ACCENT},
					)
					clay.Text(
						tr("Archived chats"),
						{fontId = FONT_TITLE, fontSize = compact ? 22 : 26, textColor = TEXT},
					)
					clay.Text(
						fmt.tprintf("%d", len(ui.archived)),
						{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
					)
				}
				clay.Text(
					tr("Keep your chat list focused without deleting conversations."),
					{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
				)
			}
			if clay.UI(clay.ID("ArchiveBack"))(
			{
				layout = {
					sizing = {height = clay.SizingFixed(36)},
					padding = {left = 12, right = 12},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = hovered() ? HOVER : ROW_BG,
				cornerRadius = rr(7),
				border = {color = FIELD_BORDER, width = bw()},
			},
			) {
				clay.Text(
					tr("Back to chats"),
					{fontId = FONT_TITLE, fontSize = 13, textColor = TEXT_DIM},
				)
			}
		}
		if clay.UI(clay.ID("ArchiveSearch"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 10,
				childAlignment = {y = .Center},
			},
		},
		) {
			if clay.UI(clay.ID("FilterBox"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(40)},
					padding = {left = 12, right = 12},
					childGap = 10,
					childAlignment = {y = .Center},
				},
				backgroundColor = ROW_BG,
				cornerRadius = rr(8),
				border = {color = ui.focus == .Filter ? ACCENT_DIM : FIELD_BORDER, width = bw()},
			},
			) {
				clay.Text(ICON_SEARCH, {fontId = FONT_ICON, fontSize = 13, textColor = TEXT_LO})
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
			if len(ui.sidebar_filter) > 0 {
				if clay.UI(clay.ID("ArchiveClearSearch"))(
				{
					layout = {
						sizing = {height = clay.SizingFixed(40)},
						padding = {left = 10, right = 10},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = hovered() ? HOVER : {},
					cornerRadius = rr(7),
				},
				) {
					clay.Text(
						tr("Clear search"),
						{fontId = FONT_BODY, fontSize = 12, textColor = ACCENT},
					)
				}
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
		if clay.UI(clay.ID("ArchivedList"))(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				childGap = 8,
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			chat_rows_window(
				ui,
				ui.archived[:],
				order[:count],
				clay.ID("ArchivedList"),
				.Unarchive,
				8,
			)
			if count == 0 {
				if clay.UI(clay.ID("ArchiveEmpty"))(
				{
					layout = {
						sizing = {clay.SizingGrow(), clay.SizingGrow()},
						layoutDirection = .TopToBottom,
						padding = clay.PaddingAll(24),
						childGap = 12,
						childAlignment = {x = .Center, y = .Center},
					},
				},
				) {
					clay.Text(
						ICON_ARCHIVE,
						{fontId = FONT_ICON, fontSize = 32, textColor = TEXT_LO},
					)
					clay.Text(
						len(ui.archived) == 0 ? tr("No archived chats") : tr("No matching chats"),
						{
							fontId = FONT_TITLE,
							fontSize = 18,
							textColor = TEXT,
							textAlignment = .Center,
						},
					)
					clay.Text(
						len(ui.archived) == 0 ? tr("Chats you archive will appear here.") : tr("Try a different search."),
						{
							fontId = FONT_BODY,
							fontSize = 14,
							textColor = TEXT_DIM,
							textAlignment = .Center,
						},
					)
				}
			}
		}
		scrollbar(clay.ID("ArchivedList"))
	}
}
