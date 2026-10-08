package main

import "core:math"
import "core:encoding/hex"
import "core:fmt"
import "core:strings"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"
import marmot "../marmot"

Row_Chip :: enum {
	Archive,
	Unarchive,
}

@(private)
chat_row_height :: proc() -> f32 {
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
	container: clay.ElementId,
	chip: Row_Chip,
	gap: f32,
	offset_y: f32 = 0,
	section: u32 = 0,
) {
	stride := (chip == .Unarchive ? ARCHIVED_ROW_H : chat_row_height()) + gap
	data := clay.GetScrollContainerData(container)
	height :=
		data.found ? data.scrollContainerDimensions.height : f32(rl.GetScreenHeight()) / UI_ZOOM
	if chip == .Unarchive && data.found {
		// A restore or a narrower search can shorten the list while scrolled.
		// Clamp before windowing so the surviving rows mount in this frame.
		content_height := max(0, f32(len(order)) * stride - gap)
		data.scrollPosition.y = -clamp(-data.scrollPosition.y, 0, max(0, content_height - height))
	}
	offset := (data.found ? -data.scrollPosition.y : 0) - offset_y
	first := clamp(int(offset / stride) - 2, 0, len(order))
	last := clamp(int((offset + height) / stride) + 3, first, len(order))
	if first > 0 {
		if clay.UI(clay.ID("ChatRowsBefore", section))(
		{layout = {sizing = {height = clay.SizingFixed(f32(first) * stride - gap)}}},
		) {}
	}
	for i in order[first:last] {
		chat_row(u32(i), rows[i], chip == .Archive && ui.selected == i, chip)
	}
	if last < len(order) {
		if clay.UI(clay.ID("ChatRowsAfter", section))(
		{layout = {sizing = {height = clay.SizingFixed(f32(len(order) - last) * stride - gap)}}},
		) {}
	}
}

@(private)
Folder_Section :: struct {
	start, count, unread: int,
}

// Stable partition: input is already pinned-first, then activity order.
// Unknown assignments stay visible under Unfiled rather than disappearing;
// chats nobody placed by hand file by folder rules (chat_folder_slot).
@(private)
chat_folder_sections :: proc(
	ui: ^Ui_State,
	order: []int,
	allocator := context.temp_allocator,
) -> (
	[]Folder_Section,
	[]int,
) {
	sections := make([]Folder_Section, len(ui.prefs.folders) + 1, allocator)
	ordered := make([]int, len(order), allocator)
	slots := make(map[string]int, len(ui.prefs.folders), allocator)
	defer delete(slots)
	for name, i in ui.prefs.folders {slots[name] = i}
	slot_of := make([]int, len(order), context.temp_allocator)
	for i, k in order {
		chat := &ui.chats[i]
		slot := chat_folder_slot(ui, chat, slots)
		slot_of[k] = slot
		sections[slot].count += 1
		if chat.unread > 0 || ui.prefs.unread_ids[chat.group_id] {
			sections[slot].unread += 1
		}
	}
	start := 0
	for &section in sections {
		section.start = start
		start += section.count
		section.count = 0
	}
	for i, k in order {
		section := &sections[slot_of[k]]
		ordered[section.start + section.count] = i
		section.count += 1
	}
	return sections, ordered
}

// One scroll container owns both headers and conversations. Each section
// windows its rows at its real offset; collapsed rows leave keyboard order.
@(private)
chat_rail :: proc(ui: ^Ui_State) {
	filter := strings.to_lower(string(ui.sidebar_filter[:]), context.temp_allocator)
	order := rail_order(ui.chats[:], ui.prefs.pinned)
	count := 0
	for i in order {
		chat := &ui.chats[i]
		if chat.search_only {continue}
		if len(filter) > 0 &&
		   !strings.contains(strings.to_lower(chat.title, context.temp_allocator), filter) &&
		   !(i < len(ui.filter_hits) && ui.filter_hits[i]) {continue}
		if ui.unread_only && chat.unread == 0 && !ui.prefs.unread_ids[chat.group_id] {continue}
		order[count] = i
		count += 1
	}
	clear(&ui.rail_rows)
	matched := order[:count]
	if ui.prefs.recent_chats || len(ui.prefs.folders) == 0 {
		append(&ui.rail_rows, ..matched)
		chat_rows_window(ui, ui.chats[:], matched, clay.ID("ChatList"), .Archive, 2)
		if len(matched) == 0 {
			clay.Text(
				tr("No chats yet"),
				{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
			)
		}
		return
	}

	sections, grouped := chat_folder_sections(ui, matched)
	y: f32
	view := clay.GetScrollContainerData(clay.ID("ChatList"))
	top := view.found ? max(0, -view.scrollPosition.y) : 0
	bottom :=
		top +
		(view.found ? view.scrollContainerDimensions.height : f32(rl.GetScreenHeight()) / UI_ZOOM)
	for section, i in sections {
		// Empty folders stay out of the rail; Settings > Folders lists them.
		if section.count == 0 {continue}
		name := i < len(ui.prefs.folders) ? ui.prefs.folders[i] : ""
		collapsed := ui.prefs.collapsed_folders[name]
		rows := grouped[section.start:section.start + section.count]
		height: f32 = 36
		if !collapsed {
			append(&ui.rail_rows, ..rows)
			height += f32(len(rows)) * (chat_row_height() + 2)
		}
		// Offscreen headers need no text clips. Clay tracks every clip as
		// a scroll container, so mounting all folders exhausts its pool.
		if y + height < top - 72 || y > bottom + 72 {
			if clay.UI(clay.ID("FolderSectionGap", u32(i)))(
			{layout = {sizing = {height = clay.SizingFixed(height - 2)}}},
			) {}
			y += height
			continue
		}
		folder_header(ui, u32(i), name, section.unread, collapsed)
		y += 36 // header and the list's 2px gap
		if collapsed {continue}
		chat_rows_window(ui, ui.chats[:], rows, clay.ID("ChatList"), .Archive, 2, y, u32(i))
		y += f32(len(rows)) * (chat_row_height() + 2)
	}
	if len(matched) == 0 {
		clay.Text(tr("No chats yet"), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
	}
}

@(private)
folder_header :: proc(ui: ^Ui_State, index: u32, name: string, unread: int, collapsed: bool) {
	if clay.UI(clay.ID("FolderHeader", index))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(34)},
			padding = {left = 4, right = 4},
			childGap = 8,
			childAlignment = {y = .Center},
		},
		backgroundColor = hovered() ? HOVER : {},
		cornerRadius = rr(6),
	},
	) {
		if clay.UI(clay.ID("FolderChevron", index))(
		{layout = {sizing = {width = clay.SizingFixed(10)}, childAlignment = {x = .Center}}},
		) {
			clay.Text(
				collapsed ? "›" : "⌄",
				{fontId = FONT_TITLE, fontSize = 15, textColor = TEXT_DIM},
			)
		}
		folder_icon(ui, name, 16)
		if clay.UI(clay.ID("FolderHeaderName", index))(
		{layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}},
		) {
			clay.Text(
				name == "" ? tr("Unfiled") : name,
				{
					fontId = FONT_TITLE,
					fontSize = 13,
					textColor = unread > 0 ? TEXT : TEXT_DIM,
					wrapMode = .None,
				},
			)
		}
		if unread > 0 {
			if clay.UI(clay.ID("FolderUnread", index))(
			{
				layout = {padding = {left = 6, right = 6, top = 2, bottom = 2}},
				backgroundColor = SELECTED,
				cornerRadius = rr(7),
			},
			) {
				clay.Text(
					fmt.tprintf("%d", unread),
					{fontId = FONT_BODY, fontSize = 11, textColor = ACCENT},
				)
			}
		}
		if name != "" {
			if clay.UI(clay.ID("FolderMenuBtn", index))(
			{
				layout = {
					padding = {left = 6, right = 6, top = 4, bottom = 4},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = hovered() ? SELECTED : {},
				cornerRadius = rr(5),
			},
			) {
				clay.Text("···", {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT_LO})
				if hovered() {tooltip(tr("Folder options"))}
			}
		}
	}
}

chat_row :: proc(index: u32, chat: Chat_Row_Ui, active: bool, chip: Row_Chip) {
	if chip == .Unarchive {
		archived_row(index, chat)
		return
	}
	if clay.UI(clay.ID("ChatRow", index))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(chat_row_height())},
		},
	},
	) {
		if clay.UI(clay.ID("ChatRowSlide", index))(
		{
			layout = {sizing = {width = clay.SizingGrow()}, childGap = 0},
			backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
			cornerRadius = rr(6),
		},
		) {
			if clay.UI(clay.ID("ChatRowBar", index))(
			{
				layout = {sizing = {width = clay.SizingFixed(3), height = clay.SizingGrow()}},
				backgroundColor = active ? ACCENT : {},
				cornerRadius = rr(2),
			},
			) {}
			if clay.UI(clay.ID("ChatRowBody", index))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					padding = {left = 8, right = 8, top = 8, bottom = 8},
					childGap = 5,
				},
			},
			) {
				// Avatar left; two stacked lines right: title and time,
				// then preview and delivery tick.
				if clay.UI(clay.ID("ChatRowMain", index))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						childGap = 10,
						childAlignment = {y = .Center},
					},
				},
				) {
					peephole_avatar(
						"ChatAvatar",
						index,
						chat.avatar_key,
						chat.title,
						36,
						chat_pic(chat),
						clay.PointerOver(clay.ID("ChatAvatar", index)) ? .Open : .Closed,
					)
					if clay.UI(clay.ID("ChatRowLines", index))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							layoutDirection = .TopToBottom,
							childGap = 4,
						},
					},
					) {
						// Reserves the hover chip's height, so the row keeps its size
						// as the pointer crosses it.
						if clay.UI(clay.ID("ChatRowTop", index))(
						{
							layout = {
								sizing = {
									width = clay.SizingGrow(),
									height = clay.SizingFit({min = chip_h()}),
								},
								childGap = 8,
								childAlignment = {y = .Center},
							},
						},
						) {
							// One clipped line: a long unbroken name would otherwise
							// push the time and badge out of the row.
							if clay.UI(clay.ID("ChatRowTitleClip", index))(
							{clip = {horizontal = true}},
							) {
								clay.Text(
									chat.title,
									{
										fontId = FONT_TITLE,
										fontSize = 14,
										textColor = TEXT,
										wrapMode = .None,
									},
								)
							}
							// Row-action markers (rowactions.odin): pinned rows lead
							// the rail, muted rows raise no notification.
							if g_prefs != nil && g_prefs.pinned[chat.group_id] {
								clay.Text(
									ICON_PIN,
									{fontId = FONT_ICON, fontSize = 10, textColor = ACCENT_DIM},
								)
							}
							if chat.muted {
								clay.Text(
									ICON_BELL_OFF,
									{fontId = FONT_ICON, fontSize = 10, textColor = TEXT_LO},
								)
							}
							if chat.pending {
								clay.Text(
									tr("INVITE"),
									{
										fontId = FONT_BODY,
										fontSize = 10,
										textColor = ACCENT,
										letterSpacing = 1,
									},
								)
							}
							if clay.UI(clay.ID("ChatRowGap", index))(
							{layout = {sizing = {width = clay.SizingGrow()}}},
							) {}
							if chat.unread == 0 &&
							   g_prefs != nil &&
							   g_prefs.unread_ids[chat.group_id] {
								// Manual "Mark unread" reminder: a dot, no count.
								clay.Text(
									"•",
									{fontId = FONT_TITLE, fontSize = 16, textColor = ACCENT},
								)
							}
							if chat.unread > 0 {
								// A badge that just went up swells and rocks: the one
								// motion in the rail that has to survive peripheral
								// vision.
								count := fmt.tprintf("%d", chat.unread)
								pop, _, _ := bump(clay.ID("ChatRowBadge", index).id, count)
								pad := bump_pad(pop)
								rock := u16(clamp((pop - 1) * 8, 0, 3))
								if clay.UI(clay.ID("ChatRowBadge", index))(
								{
									layout = {
										padding = {
											left = 7 + pad + rock,
											right = 7 + pad - min(rock, 7),
											top = 2,
											bottom = 2,
										},
									},
									backgroundColor = ACCENT,
									cornerRadius = rr(9),
								},
								) {
									// A badge that just went up carries light with it,
									// which is what catches the eye off to the side.
									glow(
										clay.ID("ChatRowBadge", index),
										ACCENT,
										clamp((pop - 1) * 4, 0, 1),
										12,
									)
									clay.Text(
										count,
										{fontId = FONT_BODY, fontSize = 12, textColor = BG},
									)
								}
							}
							clay.Text(
								chat.at,
								{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
							)
							// Archive and the other row actions live in this menu,
							// which right-click and long-press also open.
							if hovered() {
								action_chip("ChatMenu", index, "···")
							}
						}
						if clay.UI(clay.ID("ChatRowPrev", index))(
						{
							layout = {
								sizing = {width = clay.SizingGrow()},
								childGap = 6,
								childAlignment = {y = .Center},
							},
						},
						) {
							if len(chat.preview) > 0 {
								// One clipped line. A preview with an emoji, mention
								// or link renders as several inline elements, which
								// clay would otherwise stack down the row; clipping
								// the axis gives them unbounded width instead, so the
								// overflow is cut rather than wrapped.
								if clay.UI(clay.ID("ChatRowPrevClip", index))(
								{
									layout = {
										sizing = {
											width = clay.SizingGrow(),
											height = clay.SizingFixed(16),
										},
										childAlignment = {y = .Center},
									},
									clip = {horizontal = true},
								},
								) {
									row_preview(index, chat.preview)
								}
							} else if clay.UI(clay.ID("ChatRowPrevGap", index))(
							{layout = {sizing = {width = clay.SizingGrow()}}},
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
								clay.Text(
									"!",
									{fontId = FONT_TITLE, fontSize = 11, textColor = DANGER},
								)
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
	clip, laid_out := element_box(clay.ID("ChatRowPrevClip", index))
	if laid_out &&
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
		clay.Text("!", {fontId = FONT_TITLE, fontSize = 11, textColor = DANGER})
		return
	}
	// Breathing rather than blinking: each dot rides the same wave a
	// third of a turn behind the one before it, so the light travels
	// along the row instead of stepping between three states.
	color := state == .Queued ? TEXT_LO : ACCENT_DIM
	if clay.UI(clay.ID("ChatRowSending", index))(
	{layout = {childGap = 3, childAlignment = {y = .Center}}},
	) {
		for i in 0 ..< 3 {
			wave := f32(math.sin(rl.GetTime() * 4 - f64(i) * 0.7)) * 0.5 + 0.5
			if clay.UI(clay.ID("ChatRowSendDot", index * 8 + u32(i)))(
			{
				layout = {sizing = {width = clay.SizingFixed(3), height = clay.SizingFixed(3)}},
				backgroundColor = mix_color(FIELD_BORDER, color, wave),
				cornerRadius = rr(2),
			},
			) {}
		}
	}
	anim_moving += 1
}

// One switcher row: avatar, name over npub tail, ACTIVE badge on the
// row you're looking at, chevron hinting the tap.
account_row :: proc(ui: ^Ui_State, index: u32, active: bool) {
	if clay.UI(clay.ID("AccountRow", index))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {left = 12, right = 14, top = 10, bottom = 10},
			childGap = 12,
			childAlignment = {y = .Center},
		},
		backgroundColor = hovered() ? HOVER : (active ? ROW_BG : {}),
		cornerRadius = rr(10),
		border = active ? clay.BorderElementConfig{color = ACCENT, width = bw()} : {},
	},
	) {
		avatar(
			"AccountAvatar",
			index,
			ui.account_ids[index],
			ui.accounts[index],
			40,
			url_pic(ui.account_pics[index]),
		)
		if clay.UI(clay.ID("AccountRowCol", index))(
		{layout = {layoutDirection = .TopToBottom, childGap = 2}},
		) {
			clay.Text(ui.accounts[index], {fontId = FONT_TITLE, fontSize = 14, textColor = TEXT})
			clay.Text(
				npub_tail(ui.account_npubs[index]),
				{fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO},
			)
			if int(index) < len(ui.account_signing) &&
			   ui.account_signing[index].external {nip46_status_ui(ui, ui.account_ids[index], index)}
		}
		if clay.UI(clay.ID("AccountRowGap", index))(
		{layout = {sizing = {width = clay.SizingGrow()}}},
		) {}
		if active {
			clay.Text(
				tr("ACTIVE"),
				{fontId = FONT_MONO, fontSize = 10, textColor = ACCENT, letterSpacing = 2},
			)
		}
		account_remove_button("AccountRemove", index)
		clay.Text("›", {fontId = FONT_BODY, fontSize = 16, textColor = TEXT_LO})
	}
}

// Trash button on a switcher row; the click asks to remove that account
// from this device (handlers check it before the row's switch).
@(private)
account_remove_button :: proc(id_str: string, index: u32) {
	if clay.UI(clay.ID(id_str, index))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(28), height = clay.SizingFixed(28)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = hovered() ? HOVER : {},
		cornerRadius = rr(6),
	},
	) {
		if hovered() {
			tooltip(tr("Remove account"))
			cursor_raise(.Pointer)
		}
		clay.Text(
			ICON_TRASH,
			{fontId = FONT_ICON, fontSize = 13, textColor = hovered() ? DANGER : TEXT_DIM},
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
// copy-npub and a jump to the full profile for any public key.
peer_modal :: proc(ui: ^Ui_State) {
	width := modal_w(clay.ID("PeerModal"), 400)
	if clay.UI(clay.ID("PeerModal"))(
	{
		layout = {sizing = {width = clay.SizingFixed(width)}},
		floating = {
			attachTo = .Root,
			zIndex = 13,
			offset = {0, rise(clay.ID("PeerModal"))},
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
	},
	) {
		profile_card(PEER_CARD_ID, ui.peer_hex, width, .Peer_Popup)
	}
}

// Account-switcher modal, opened from the rail avatar.
accounts_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("AccountsModal"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(modal_w(clay.ID("AccountsModal"), 440))},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(20),
			childGap = 12,
		},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {
			attachTo = .Root,
			zIndex = 13,
			offset = {0, rise(clay.ID("AccountsModal"))},
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
	},
	) {
		if clay.UI(clay.ID("AcctHead"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}},
		) {
			clay.Text(tr("Accounts"), {fontId = FONT_TITLE, fontSize = 20, textColor = TEXT})
			if clay.UI(clay.ID("AcctHeadGap"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			if clay.UI(clay.ID("AcctClose"))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(26), height = clay.SizingFixed(26)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(7),
			},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}
		clay.Text(
			tr("All accounts stay connected. Switching only changes which one you're looking at."),
			{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
		)

		for _, i in ui.accounts {
			account_row(ui, u32(i), ui.account_ids[i] == ui.account_ref)
		}

		if clay.UI(clay.ID("AcctFoot"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childGap = 10, padding = {top = 6}}},
		) {
			if clay.UI(clay.ID("AcctCloseBtn"))(
			{
				layout = {padding = {left = 18, right = 18, top = 10, bottom = 10}},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(9),
				border = {color = FIELD_BORDER, width = bw()},
			},
			) {
				clay.Text(tr("Close"), {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
			}
			if clay.UI(clay.ID("AcctFootGap"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			if clay.UI(clay.ID("AddAccountBtn"))(
			{
				layout = {padding = {left = 18, right = 18, top = 10, bottom = 10}},
				backgroundColor = hovered() ? ACCENT_DIM : ACCENT,
				cornerRadius = rr(9),
			},
			) {
				clay.Text(
					tr("Add account"),
					{fontId = FONT_TITLE, fontSize = 13, textColor = ON_ACCENT},
				)
			}
		}
	}
}

nav_button :: proc(page: Page, active: bool) {
	// A fixed target keeps the vertical rail stable across icon fonts
	// and remains usable on touch screens.
	down := press_down(clay.ID("Nav", u32(page)))
	side := f32(42)
	if clay.UI(clay.ID("Nav", u32(page)))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(side), height = clay.SizingFixed(side)},
			padding = {top = down * 2},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
		cornerRadius = rr(12),
	},
	) {
		if hovered() {
			tooltip(tr(NAV_TIPS[page]), .Right)
		}
		clay.Text(
			PAGE_ICONS[page],
			{fontId = FONT_ICON, fontSize = 17, textColor = active ? ACCENT : TEXT_DIM},
		)
	}
}

// A vertical selection marker follows the active destination. Read last
// frame's box so moving between top and bottom controls eases naturally.
nav_indicator :: proc(ui: ^Ui_State) {
	box := clay.GetElementData(clay.ID("Nav", u32(ui.page)))
	if !box.found {
		return
	}
	x := anim_to(clay.ID("NavBarX").id, box.boundingBox.x - 7, 22)
	y := anim_to(clay.ID("NavBarY").id, box.boundingBox.y + (box.boundingBox.height - 20) / 2, 22)
	if clay.UI(clay.ID("NavBar"))(
	{
		layout = {sizing = {width = clay.SizingFixed(3), height = clay.SizingFixed(20)}},
		floating = {
			attachTo = .Root,
			zIndex = 6,
			offset = {x, y},
			attachment = {element = .LeftTop, parent = .LeftTop},
		},
		backgroundColor = ACCENT,
		cornerRadius = rr(1),
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
