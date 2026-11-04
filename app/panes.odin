package main

import marmot "../marmot"
import "core:encoding/hex"
import "core:fmt"
import "core:math"
import "core:strings"
import "nendo"
import rl "sdlrl"

Row_Chip :: enum {
	Archive,
	Unarchive,
}

@(private)
chat_timestamp :: proc(index: u32, chat: Chat_Row_Ui) {
	if nendo.box(nendo.id("ChatRowTime", index))({}) {
		nendo.text(chat.at, {font = FONT_BODY, size = 11, color = TEXT_LO, wrap = .None})
		if hovered() && !tap_size() && chat.activity_at > 0 && len(chat.at) > 0 {
			context.allocator = context.temp_allocator
			tooltip(format_full(chat.activity_at), .Above)
		}
	}
}

@(private)
chat_row_height :: proc() -> f32 {
	// Touch rows keep a 68-unit target without reserving the hover chip,
	// which floats over the row instead (chat_row).
	if tap_size() {return 68}
	return 16 + max(36, max(chip_h(), 14) + 20)
}

@(private)
ARCHIVED_ROW_H :: f32(84)

// Fixed row geometry lets the first frame skip hidden rows too. Keep the
// complete order outside this window for keyboard navigation and filtering.
@(private)
chat_rows_window :: proc(
	ui: ^Ui_State,
	rows: []Chat_Row_Ui,
	order: []int,
	container: nendo.Id,
	chip: Row_Chip,
	gap: f32,
	offset_y: f32 = 0,
	section: u32 = 0,
) {
	stride := (chip == .Unarchive ? ARCHIVED_ROW_H : chat_row_height()) + gap
	data := nendo.scroll(container)
	height := data.found ? data.viewport.height : f32(rl.GetScreenHeight()) / UI_ZOOM
	if chip == .Unarchive && data.found {
		// A restore or a narrower search can shorten the list while scrolled.
		// Clamp before windowing so the surviving rows mount in this frame.
		content_height := max(0, f32(len(order)) * stride - gap)
		data.position.y = -clamp(-data.position.y, 0, max(0, content_height - height))
	}
	offset := (data.found ? -data.position.y : 0) - offset_y
	first := clamp(int(offset / stride) - 2, 0, len(order))
	last := clamp(int((offset + height) / stride) + 3, first, len(order))
	if first > 0 {
		if nendo.box(nendo.id("ChatRowsBefore", section))(
		{height = nendo.fixed(f32(first) * stride - gap)},
		) {}
	}
	for i in order[first:last] {
		active := !ui.whip_open && chip == .Archive && ui.selected == i
		chat_row(u32(i), rows[i], active, chip)
	}
	if last < len(order) {
		if nendo.box(nendo.id("ChatRowsAfter", section))(
		{height = nendo.fixed(f32(len(order) - last) * stride - gap)},
		) {}
	}
}

@(private)
Folder_Section :: struct {
	start, count, unread: int,
}

// Why the chat list shows no rows. The search text outranks the Unread
// pill: it is the part you can edit, so its message names it.
@(private)
Chat_Rail_Empty :: enum {
	None,
	No_Chats,
	No_Matches,
	No_Unread,
	No_Groups,
	No_Whip,
}

@(private)
chat_rail_empty :: proc(total, rows: int, query: bool, scope: Chat_Filter) -> Chat_Rail_Empty {
	switch {
	case rows > 0:
		return .None
	case scope == .Whip && !query:
		return .No_Whip
	case total == 0:
		return .No_Chats
	case query:
		return .No_Matches
	case scope == .Unread:
		return .No_Unread
	case scope == .Groups:
		return .No_Groups
	}
	return .No_Chats
}

// The rail's chats in rail order under the search text and the Unread
// pill, and how many it holds unfiltered. The header counts both.
@(private)
chat_rail_matches :: proc(ui: ^Ui_State) -> (matched: []int, total: int) {
	filter := strings.to_lower(string(ui.sidebar_filter[:]), context.temp_allocator)
	chats := ui.chats[:]
	order := rail_order(chats, ui.prefs.pinned)
	count := 0
	for i in order {
		chat := &chats[i]
		if chat.archived || chat.search_only {continue}
		total += 1
		if ui.chat_filter == .Whip {continue}
		if len(filter) > 0 &&
		   !strings.contains(strings.to_lower(chat.title, context.temp_allocator), filter) &&
		   !(i < len(ui.filter_hits) && ui.filter_hits[i]) {continue}
		if ui.chat_filter == .Unread &&
		   chat.unread == 0 &&
		   !ui.prefs.unread_ids[chat.group_id] {continue}
		if ui.chat_filter == .Groups &&
		   (chat.conversation_kind != .GROUP || chat.group_id == ui.prefs.notes_group) {continue}
		order[count] = i
		count += 1
	}
	return order[:count], total
}

// One scroll container owns both headers and conversations. Each section
// windows its rows at its real offset; collapsed rows leave keyboard order.
@(private)
chat_rail :: proc(ui: ^Ui_State, ordered: []Inbox_Row, total: int) {
	clear(&ui.rail_rows)
	offset_y: f32
	pending := onboard_pending(ui)
	if single_pane() && pending && ui.chat_filter == .Chats {
		get_started_pane(ui, .Inline)
		// Like the hint below, use the last measured height for row windowing
		// and keyboard reveal positions without adding another scroll owner.
		if data := nendo.element(nendo.id("GetStarted")); data.found {
			offset_y = data.rect.height + 2
		}
	}
	if !pending &&
	   !ui.prefs.recent_chats &&
	   ui.chat_filter == .Chats &&
	   len(ui.prefs.folders) == 0 &&
	   total > 0 &&
	   f32(rl.GetScreenHeight()) / UI_ZOOM >= 600 {
		chat_rail_hint(
			"ChatGroupHint",
			tr("Grouped sorts your chats into folders, and you have none yet."),
			"ChatGroupNewFolder",
			tr("New folder"),
		)
		// The rows below window from where they start; last frame's
		// height of the hint is close enough.
		if data := nendo.element(nendo.id("ChatGroupHint")); data.found {
			offset_y = data.rect.height + 2
		}
	}
	if ui.prefs.recent_chats || len(ui.prefs.folders) == 0 {
		for &row, i in ordered {
			row.top = offset_y + f32(i) * (chat_row_height() + 2)
			append(&ui.rail_rows, row)
		}
		inbox_rows_window(ui, ordered, offset_y)
		chat_rail_empty_note(ui, len(ordered), total)
		return
	}

	sections, grouped := inbox_sections(ui, ordered)
	header_h: f32 = tap_size() ? 46 : 36
	y := offset_y
	top, view_height := inbox_view()
	bottom := top + view_height
	for section, i in sections {
		// Empty folders stay out of the rail; Settings > Folders lists them.
		if section.count == 0 {continue}
		name := i < len(ui.prefs.folders) ? ui.prefs.folders[i] : ""
		collapsed := ui.prefs.collapsed_folders[name]
		rows := grouped[section.start:section.start + section.count]
		height := header_h
		if !collapsed {
			for &row, pos in rows {
				row.top = y + header_h + f32(pos) * (chat_row_height() + 2)
				append(&ui.rail_rows, row)
			}
			height += f32(len(rows)) * (chat_row_height() + 2)
		}
		// Offscreen headers need no text clips. nendo tracks every clip as
		// a scroll container, so mounting all folders exhausts its pool.
		if y + height < top - 72 || y > bottom + 72 {
			if nendo.box(nendo.id("FolderSectionGap", u32(i)))(
			{height = nendo.fixed(height - 2)},
			) {}
			y += height
			continue
		}
		folder_header(ui, u32(i), name, section.unread, collapsed, section.count)
		y += header_h // header and the list's 2px gap
		if collapsed {continue}
		inbox_rows_window(ui, rows, y, u32(i))
		y += f32(len(rows)) * (chat_row_height() + 2)
	}
	chat_rail_empty_note(ui, len(ordered), total)
}

@(private = "file")
chat_rail_empty_note :: proc(ui: ^Ui_State, rows, total: int) {
	switch chat_rail_empty(
		total,
		rows,
		len(ui.sidebar_filter) > 0 || ui.chat_folder != "",
		ui.chat_filter,
	) {
	case .None:
	case .No_Chats:
		nendo.text(tr("No chats yet"), {font = FONT_BODY, size = 13, color = TEXT_DIM})
	case .No_Whip:
		nendo.text(tr("No Whip projects"), {font = FONT_BODY, size = 13, color = TEXT_DIM})
	case .No_Matches:
		chat_rail_hint(
			"ChatListNoMatch",
			tr("Try a different search."),
			"ChatListClearSearch",
			tr("Clear search"),
			tr("No matching chats"),
		)
	case .No_Unread:
		chat_rail_hint(
			"ChatListNoUnread",
			tr("You have read every chat."),
			"ChatListShowAll",
			tr("Show all chats"),
			tr("No unread chats"),
		)
	case .No_Groups:
		chat_rail_hint(
			"ChatListNoGroups",
			tr("Groups you join will appear here."),
			"ChatListShowAll",
			tr("Show all chats"),
			tr("No groups yet"),
		)
	}
}

// A short note in the chat list with one way out of the state it names.
@(private)
chat_rail_hint :: proc(id_str, sub, button_id, button: string, title := "") {
	if nendo.box(nendo.id(id_str))(
	{
		width = nendo.grow(),
		direction = .Column,
		padding = {left = 4, right = 4, top = 6, bottom = 8},
		gap = 6,
	},
	) {
		if len(title) > 0 {
			nendo.text(title, {font = FONT_TITLE, size = 14, color = TEXT})
		}
		nendo.text(sub, {font = FONT_BODY, size = 12, color = TEXT_DIM})
		micro_button(button_id, button)
	}
}

@(private)
folder_header :: proc(
	ui: ^Ui_State,
	index: u32,
	name: string,
	unread: int,
	collapsed: bool,
	count: int,
) {
	if nendo.box(nendo.id("FolderHeader", index))(
	{
		width = nendo.grow(),
		height = nendo.fixed(tap_size() ? tap_min() : 34),
		padding = {left = 4, right = 4},
		gap = 8,
		align = {y = .Center},
		color = hovered() ? HOVER : {},
		radius = rr(6),
	},
	) {
		if nendo.box(nendo.id("FolderChevron", index))(
		{width = nendo.fixed(20), align = {x = .Center}},
		) {
			nendo.text(
				collapsed ? ICON_RIGHT : ICON_DOWN,
				{font = FONT_ICON, size = 16, color = TEXT_DIM},
			)
		}
		folder_icon(ui, name, 16)
		if nendo.box(nendo.id("FolderHeaderName", index))(
		{width = nendo.grow(), clip = {x = true}},
		) {
			nendo.text(
				name == "" ? tr("Unfiled") : name,
				{font = FONT_TITLE, size = 13, color = unread > 0 ? TEXT : TEXT_DIM, wrap = .None},
			)
		}
		if collapsed {
			nendo.text(fmt.tprintf("%d", count), {font = FONT_BODY, size = 12, color = TEXT_DIM})
		}
		if unread > 0 {
			if nendo.box(nendo.id("FolderUnread", index))(
			{
				padding = {left = 6, right = 6, top = 2, bottom = 2},
				color = SELECTED,
				radius = rr(7),
			},
			) {
				nendo.text(
					fmt.tprintf("%d", unread),
					{font = FONT_BODY, size = 11, color = ACCENT},
				)
			}
		}
		if name != "" {
			if nendo.box(nendo.id("FolderMenuBtn", index))(
			{
				width = nendo.fit(min = tap_size() ? tap_min() : 0),
				height = nendo.fit(min = tap_size() ? tap_min() : 0),
				padding = {left = 6, right = 6, top = 4, bottom = 4},
				align = {x = .Center, y = .Center},
				color = hovered() ? SELECTED : {},
				radius = rr(5),
			},
			) {
				nendo.text("···", {font = FONT_TITLE, size = 13, color = TEXT_LO})
				if hovered() {tooltip(tr("Folder options"))}
			}
		}
	}
}

chat_row :: proc(index: u32, chat: Chat_Row_Ui, active: bool, chip: Row_Chip) {
	chat := chat
	if chip == .Unarchive {
		archived_row(index, chat)
		return
	}
	if g_ui != nil &&
	   len(g_ui.sidebar_filter) > 0 &&
	   int(index) < len(g_ui.filter_previews) &&
	   g_ui.filter_previews[index] != "" {
		chat.preview = g_ui.filter_previews[index]
	}
	if nendo.box(nendo.id("ChatRow", index))(
	{width = nendo.grow(), height = nendo.fixed(chat_row_height())},
	) {
		if nendo.box(nendo.id("ChatRowSlide", index))(
		{
			width = nendo.grow(),
			gap = 0,
			color = active ? SELECTED : (hovered() ? HOVER : {}),
			radius = rr(6),
		},
		) {
			if nendo.box(nendo.id("ChatRowBar", index))(
			{
				width = nendo.fixed(3),
				height = nendo.grow(),
				color = active ? ACCENT : {},
				radius = rr(2),
			},
			) {}
			if nendo.box(nendo.id("ChatRowBody", index))(
			{
				width = nendo.grow(),
				direction = .Column,
				padding = {left = 8, right = 8, top = 8, bottom = 8},
				gap = 5,
			},
			) {
				// Avatar left; two stacked lines right: title and time,
				// then preview and delivery tick.
				if nendo.box(nendo.id("ChatRowMain", index))(
				{width = nendo.grow(), gap = 10, align = {y = .Center}},
				) {
					peephole_avatar(
						"ChatAvatar",
						index,
						chat.avatar_key,
						chat.title,
						36,
						chat_pic(chat),
						nendo.pointer_over(nendo.id("ChatAvatar", index)) ? .Open : .Closed,
					)
					if nendo.box(nendo.id("ChatRowLines", index))(
					{width = nendo.grow(), direction = .Column, gap = 4},
					) {
						// Reserves the hover chip's height, so the row keeps its size
						// as the pointer crosses it.
						if nendo.box(nendo.id("ChatRowTop", index))(
						{
							width = nendo.grow(),
							height = nendo.fit(min = tap_size() ? 20 : chip_h()),
							gap = 8,
							align = {y = .Center},
						},
						) {
							// One clipped line: a long unbroken name would otherwise
							// push the time and badge out of the row.
							if nendo.box(nendo.id("ChatRowTitleClip", index))(
							{
								width = single_pane() ? nendo.grow() : nendo.fit(),
								clip = {x = true},
							},
							) {
								nendo.text(
									chat.title,
									{font = FONT_TITLE, size = 14, color = TEXT, wrap = .None},
								)
							}
							// Row-action markers (rowactions.odin): pinned rows lead
							// the rail, muted rows raise no notification.
							if g_prefs != nil && g_prefs.pinned[chat.group_id] {
								nendo.text(
									ICON_PIN,
									{font = FONT_ICON, size = 10, color = ACCENT_DIM},
								)
							}
							if chat.muted {
								nendo.text(
									ICON_BELL_OFF,
									{font = FONT_ICON, size = 10, color = TEXT_LO},
								)
							}
							if chat.pending {
								nendo.text(
									tr("INVITE"),
									{font = FONT_BODY, size = 10, color = ACCENT, spacing = 1},
								)
							}
							if nendo.box(nendo.id("ChatRowGap", index))(
							{width = single_pane() ? nendo.fixed(0) : nendo.grow()},
							) {}
							if chat.unread == 0 &&
							   g_prefs != nil &&
							   g_prefs.unread_ids[chat.group_id] {
								// Manual "Mark unread" reminder: a dot, no count.
								nendo.text("•", {font = FONT_TITLE, size = 16, color = ACCENT})
							}
							if chat.unread > 0 {
								unread_badge(nendo.id("ChatRowBadge", index), chat.unread)
							}
							chat_timestamp(index, chat)
							// Archive and the other row actions live in this menu,
							// which right-click and long-press also open. A finger
							// uses long-press; a pointer on a narrow window gets the
							// chip floating at the row's edge.
							if tap_size() {
								if hovered() && !rl.TouchActive() {
									if nendo.box(nendo.id("ChatMenuFloat", index))(
									{
										floating = {
											attach_to = .Element,
											parent = nendo.id("ChatRowSlide", index).id,
											attach = {
												element = .Right_Center,
												parent = .Right_Center,
											},
											offset = {-6, 0},
											z = 2,
										},
									},
									) {action_chip("ChatMenu", index, "···")}
								}
							} else if hovered() {
								action_chip("ChatMenu", index, "···")
							}
						}
						if nendo.box(nendo.id("ChatRowPrev", index))(
						{width = nendo.grow(), gap = 6, align = {y = .Center}},
						) {
							if len(chat.preview) > 0 {
								// One clipped line. A preview with an emoji, mention
								// or link renders as several inline elements, which
								// nendo would otherwise stack down the row; clipping
								// the axis gives them unbounded width instead, so the
								// overflow is cut rather than wrapped.
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
							} else if nendo.box(nendo.id("ChatRowPrevGap", index))(
							{width = nendo.grow()},
							) {
								// Holds the tick right; a preview's clip grows there itself.
							}
							// An unacked optimistic send outranks the stored delivery
							// state: the row is mid-send, whatever the last confirmed
							// message says.
							if state := chat_send_state(chat.group_id); state != .Idle {
								send_spinner(index, state)
							} else if chat.tick == .DELIVERED || chat.tick == .PENDING {
								delivery_tick(chat.group_id, index, chat.tick)
							} else if chat.tick == .FAILED {
								nendo.text("!", {font = FONT_TITLE, size = 11, color = DANGER})
							}
						}
					}
				}
			}
		}
	}
}

// The row's one-line preview, ended with an ellipsis inside the
// ChatRowPrevClip it sits in. That clip is the row's only growing child,
// so its width is the room left of the tick whatever the text is, and
// last frame's box is this frame's room. A row's first frame draws the
// line uncut; the clip hides the overflow until the box exists.
//   Are you still coming to the marmot meetup to|   clipped
//   Are you still coming to the marmot meetup…   |   fitted
@(private)
row_preview :: proc(index: u32, preview: string) {
	tile_px := body_tile_size(preview, 12)
	end := strings.index_byte(preview, '\n')
	if end < 0 {
		end = len(preview)
	}
	shown := preview
	clip, laid_out := element_box(nendo.id("ChatRowPrevClip", index))
	if laid_out &&
	   clip.width >= 40 &&
	   (end < len(preview) || rune_fit(preview, 0, end, clip.width, 12, tile_px = tile_px) < end) {
		// Room for the ellipsis and the 2px gap a chip leaves before it.
		room := clip.width - rl.MeasureTextLine(FONT_BODY, 12, "…", 0).x - 2
		cut := rune_fit(preview, 0, end, room, 12, tile_px = tile_px)
		shown = fmt.tprintf("%s…", strings.trim_right_space(preview[:cut]))
	}
	body_line(0xC0000 + index, shown, 12, TEXT_DIM, tile_px = tile_px)
}

// What the rail row says about this chat's optimistic sends
// (state.odin's Pending_Send overlay).
Send_State :: enum {
	Idle,
	Sending,
	Queued, // waiting for the offline flush
	Failed,
}

chat_send_state :: proc(group_id: string) -> Send_State {
	if g_ui == nil {
		return .Idle
	}
	state := Send_State.Idle
	for p in g_ui.pending {
		if p.group_id != group_id {
			continue
		}
		// Worst news wins: a failure is what the row should say even if
		// another send is still in flight behind it.
		switch {
		case p.failed:
			return .Failed
		case p.queued:
			state = .Queued
		case state == .Idle:
			state = .Sending
		}
	}
	return state
}

// Three dots with one lit, cycling: the rail's counterpart to the
// timeline's grayed "sending…" row.
send_spinner :: proc(index: u32, state: Send_State) {
	if state == .Failed {
		nendo.text("!", {font = FONT_TITLE, size = 11, color = DANGER})
		return
	}
	// Breathing rather than blinking: each dot rides the same wave a
	// third of a turn behind the one before it, so the light travels
	// along the row instead of stepping between three states.
	color := state == .Queued ? TEXT_LO : ACCENT_DIM
	if nendo.box(nendo.id("ChatRowSending", index))({gap = 3, align = {y = .Center}}) {
		for i in 0 ..< 3 {
			wave := f32(math.sin(rl.GetTime() * 4 - f64(i) * 0.7)) * 0.5 + 0.5
			if nendo.box(nendo.id("ChatRowSendDot", index * 8 + u32(i)))(
			{
				width = nendo.fixed(3),
				height = nendo.fixed(3),
				color = mix_color(FIELD_BORDER, color, wave),
				radius = rr(2),
			},
			) {}
		}
	}
	anim_moving += 1
}

// One switcher row: avatar, name over npub tail, ACTIVE badge on the
// row you're looking at, chevron hinting the tap.
account_row :: proc(ui: ^Ui_State, index: u32, active: bool) {
	account := ui.accounts[index]
	if nendo.box(nendo.id("AccountRow", index))(
	{
		width = nendo.grow(),
		padding = {left = 12, right = 14, top = 10, bottom = 10},
		gap = 12,
		align = {y = .Center},
		color = hovered() ? HOVER : (active ? ROW_BG : {}),
		radius = rr(10),
		border = active ? nendo.Border{color = ACCENT, width = bw()} : {},
	},
	) {
		avatar("AccountAvatar", index, account.id_hex, account.name, 40, url_pic(account.pic_url))
		if nendo.box(nendo.id("AccountRowCol", index))(
		{
			width = single_pane() ? nendo.grow() : nendo.fit(),
			direction = .Column,
			gap = 2,
			clip = {x = true},
		},
		) {
			nendo.text(account.name, {font = FONT_TITLE, size = 14, color = TEXT})
			nendo.text(npub_tail(account.npub), {font = FONT_MONO, size = 11, color = TEXT_LO})
			if account.external {nip46_status_ui(ui, account.id_hex, index)}
		}
		if nendo.box(nendo.id("AccountRowGap", index))(
		{width = single_pane() ? nendo.fixed(0) : nendo.grow()},
		) {}
		if active && !single_pane() {
			nendo.text(tr("ACTIVE"), {font = FONT_MONO, size = 10, color = ACCENT, spacing = 2})
		}
		nendo.text("›", {font = FONT_BODY, size = 16, color = TEXT_LO})
	}
}

// Trash button on a switcher row; the click asks to remove that account
// from this device (handlers check it before the row's switch).
@(private)
account_remove_button :: proc(id_str: string, index: u32) {
	if nendo.box(nendo.id(id_str, index))(
	{
		width = nendo.fixed(tap_size() ? tap_min() : 28),
		height = nendo.fixed(tap_size() ? tap_min() : 28),
		align = {x = .Center, y = .Center},
		color = hovered() ? HOVER : {},
		radius = rr(6),
	},
	) {
		if hovered() {
			tooltip(tr("Remove account"))
			cursor_raise(.Pointer)
		}
		nendo.text(
			ICON_TRASH,
			{font = FONT_ICON, size = 13, color = hovered() ? DANGER : TEXT_DIM},
		)
	}
}

// hex pubkey → npub bech32; "" when the hex is malformed.
hex_npub :: proc(hex_str: string) -> string {
	bytes, ok := hex.decode(transmute([]u8)hex_str, context.temp_allocator)
	if !ok || len(bytes) != 32 {
		return ""
	}
	return bech32_encode("npub", bytes)
}

// Open the peer-profile popup for any avatar (timeline, members panel).
open_peer :: proc(
	ui: ^Ui_State,
	client: ^marmot.Client,
	hex_id: string,
	name: string,
	pic_url: string,
) {
	ui.peer_hex = strings.clone(hex_id)
	ui.peer_name = strings.clone(name)
	ui.peer_pic = strings.clone(pic_url)
	ui.peer_npub = hex_npub(hex_id)
	if len(ui.contacts) == 0 {
		load_contacts(client, ui, .Details)
	}
	ui.peer_open = true
}

// Peer-profile popup: the same card a bare mention draws, carrying
// copy-npub, the full profile, and a direct message action.
peer_modal :: proc(ui: ^Ui_State) {
	width := modal_w(nendo.id("PeerModal"), 400)
	if nendo.box(nendo.id("PeerModal"))(
	{
		width = nendo.fixed(width),
		height = nendo.fit(max = modal_h(720)),
		clip = {y = true, scroll = true},
		floating = {
			attach_to = .Root,
			z = 13,
			offset = {0, rise(nendo.id("PeerModal"))},
			attach = {element = .Center_Center, parent = .Center_Center},
		},
	},
	) {
		profile_card(PEER_CARD_ID, ui.peer_hex, width, .Peer_Popup)
	}
	scrollbar(nendo.id("PeerModal"), 14)
}

// Account-switcher modal, opened from the rail avatar.
accounts_modal :: proc(ui: ^Ui_State) {
	if nendo.box(nendo.id("AccountsModal"))(
	{
		width = nendo.fixed(modal_w(nendo.id("AccountsModal"), 440)),
		height = nendo.fit(max = modal_h(720)),
		direction = .Column,
		padding = nendo.pad(single_pane() ? 12 : 20),
		gap = 12,
		clip = {y = true, scroll = true},
		color = CARD,
		radius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {
			attach_to = .Root,
			z = 13,
			offset = {0, rise(nendo.id("AccountsModal"))},
			attach = {element = .Center_Center, parent = .Center_Center},
		},
	},
	) {
		if nendo.box(nendo.id("AcctHead"))({width = nendo.grow(), align = {y = .Center}}) {
			nendo.text(tr("Accounts"), {font = FONT_TITLE, size = 20, color = TEXT})
			if nendo.box(nendo.id("AcctHeadGap"))({width = nendo.grow()}) {}
			if !single_pane() {
				if nendo.box(nendo.id("AcctClose"))(
				{
					width = nendo.fixed(tap_size() ? tap_min() : 26),
					height = nendo.fixed(tap_size() ? tap_min() : 26),
					align = {x = .Center, y = .Center},
					color = hovered() ? HOVER : {},
					radius = rr(7),
				},
				) {
					nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 12, color = TEXT_DIM})
				}
			}
		}
		nendo.text(
			tr("All accounts stay connected. Switching only changes which one you're looking at."),
			{font = FONT_BODY, size = 12, color = TEXT_DIM},
		)

		// Stable alphabetical display order, independent of runtime store order.
		order := make([]int, len(ui.accounts), context.temp_allocator)
		for _, i in ui.accounts {
			at := i
			for at > 0 &&
			    strings.compare(ui.accounts[order[at - 1]].name, ui.accounts[i].name) > 0 {
				order[at] = order[at - 1]
				at -= 1
			}
			order[at] = i
		}
		for i in order {
			account_row(ui, u32(i), ui.accounts[i].id_hex == ui.account_ref)
		}

		if nendo.box(nendo.id("AcctFoot"))({width = nendo.grow(), gap = 10, padding = {top = 6}}) {
			if nendo.box(nendo.id("AcctCloseBtn"))(
			{
				height = nendo.fit(min = tap_size() ? tap_min() : 0),
				padding = {left = 18, right = 18, top = 10, bottom = 10},
				align = {y = .Center},
				color = hovered() ? HOVER : {},
				radius = rr(9),
				border = {color = FIELD_BORDER, width = bw()},
			},
			) {
				nendo.text(tr("Close"), {font = FONT_TITLE, size = 13, color = TEXT})
			}
			if nendo.box(nendo.id("AcctFootGap"))({width = nendo.grow()}) {}
			if nendo.box(nendo.id("AddAccountBtn"))(
			{
				height = nendo.fit(min = tap_size() ? tap_min() : 0),
				padding = {left = 18, right = 18, top = 10, bottom = 10},
				align = {y = .Center},
				color = hovered() ? ACCENT_DIM : ACCENT,
				radius = rr(9),
			},
			) {
				nendo.text(tr("Add account"), {font = FONT_TITLE, size = 13, color = ON_ACCENT})
			}
		}
	}
	scrollbar(nendo.id("AccountsModal"), 14)
}

// Shared by conversations and terminal work waiting for attention.
@(private)
unread_badge :: proc(id: nendo.Id, unread: u64) {
	if unread == 0 {return}
	count := fmt.tprintf("%d", unread)
	pop, _, _ := bump(id.id, count)
	pad := bump_pad(pop)
	rock := u16(clamp((pop - 1) * 8, 0, 3))
	if nendo.box(id)(
	{
		padding = {left = 7 + pad + rock, right = 7 + pad - min(rock, 7), top = 2, bottom = 2},
		color = ACCENT,
		radius = rr(9),
	},
	) {
		glow(id, ACCENT, clamp((pop - 1) * 4, 0, 1), 12)
		nendo.text(count, {font = FONT_BODY, size = 12, color = BG})
	}
}

nav_button :: proc(page: Page, active: bool) {
	// A fixed target keeps the vertical rail stable across icon fonts
	// and remains usable on touch screens.
	down := press_down(nendo.id("Nav", u32(page)))
	side := f32(tap_size() ? tap_min() : 42)
	if nendo.box(nendo.id("Nav", u32(page)))(
	{
		width = nendo.fixed(side),
		height = nendo.fixed(side),
		padding = {top = down * 2},
		align = {x = .Center, y = .Center},
		color = active ? SELECTED : (hovered() ? HOVER : {}),
		radius = rr(12),
	},
	) {
		if hovered() {
			tooltip(tr(NAV_TIPS[page]), .Right)
		}
		nendo.text(
			PAGE_ICONS[page],
			{font = FONT_ICON, size = 17, color = active ? ACCENT : TEXT_DIM},
		)
		if page == .Chats && rl.WhipAvailable() {
			waiting: u64
			for project in rl.WhipProjects() {waiting += u64(project.waiting)}
			if waiting > 0 {
				if nendo.box(nendo.id("TerminalInboxBadge"))(
				{
					floating = {
						attach_to = .Parent,
						attach = {element = .Center_Center, parent = .Right_Top},
						z = 2,
					},
				},
				) {unread_badge(nendo.id("TerminalInboxUnread"), waiting)}
			}
		}
	}
}

// A vertical selection marker follows the active destination. Read last
// frame's box so moving between top and bottom controls eases naturally.
nav_indicator :: proc(ui: ^Ui_State) {
	box := nendo.element(nendo.id("Nav", u32(ui.page)))
	if !box.found {
		return
	}
	x := anim_to(nendo.id("NavBarX").id, box.rect.x - 7, 22)
	y := anim_to(nendo.id("NavBarY").id, box.rect.y + (box.rect.height - 20) / 2, 22)
	if nendo.box(nendo.id("NavBar"))(
	{
		width = nendo.fixed(3),
		height = nendo.fixed(20),
		floating = {
			attach_to = .Root,
			z = 6,
			offset = {x, y},
			attach = {element = .Left_Top, parent = .Left_Top},
		},
		color = ACCENT,
		radius = rr(1),
	},
	) {}
}

NAV_TIPS := [Page]string {
	.Chats    = N_("Chats"),
	.Contacts = N_("People"),
	.Archived = N_("Archive"),
	.Settings = N_("Settings"),
	.Profile  = N_("Your profile"),
}
