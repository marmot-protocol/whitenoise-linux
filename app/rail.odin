package main

import "core:fmt"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Shift+wheel scrolls the chat filter row sideways once folders overflow it.
@(private)
chat_filter_wheel :: proc(ui: ^Ui_State, wheel: ^rl.Vector2) {
	if ui.page != .Chats || !shift_down() || !clay.PointerOver(clay.ID("ChatFilters")) {return}
	wheel.x += wheel.y
	wheel.y = 0
}

// The expanded sidebar: section controls and the active page's list.
@(private)
rail_content :: proc(ui: ^Ui_State) {
	logged_in := len(ui.accounts) > 0

	if clay.UI(clay.ID("RailContent"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {left = 10, right = 10, top = 12, bottom = 12},
			childGap = 8,
		},
		backgroundColor = PANEL,
		// Account rows must scroll rather than raise the shell's minimum height.
		clip = {
			vertical = ui.page == .Profile || single_pane(),
			childOffset = ui.page == .Profile || single_pane() ? clay.GetScrollOffset() : clay.Vector2{},
		},
	},
	) {
		// The header counts what the chat list below shows.
		chat_rows: []int
		terminal_rows: []u32
		inbox: []Inbox_Row
		chat_total: int
		if ui.page == .Chats {
			chat_rows, chat_total = chat_rail_matches(ui)
			terminal_rows = whip_rail_matches(ui)
			if rl.WhipAvailable() {chat_total += len(rl.WhipProjects())}
			inbox = inbox_rows(ui, chat_rows, terminal_rows)
			if ui.prefs.recent_chats && ui.chat_folder != "" {
				sections, grouped := inbox_sections(ui, inbox)
				for name, i in ui.prefs.folders {
					if name != ui.chat_folder {continue}
					section := sections[i]
					inbox = grouped[section.start:section.start + section.count]
					break
				}
			}
		}
		contact_rows: []Contact_Order
		if ui.page == .Contacts {
			contact_rows = contact_rail_matches(ui)
		}
		// Profile replaces the conversation list with accounts.
		if ui.page == .Profile {
			profile_rail(ui)
		} else {
			// Section header: CHATS/CONTACTS count + new-chat button.
			if clay.UI(clay.ID("RailHead"))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow(),
						height = clay.SizingFixed(tap_size() ? 50 : 32),
					},
					childGap = 8,
					childAlignment = {y = .Center},
					padding = {top = 4, bottom = 2},
				},
			},
			) {
				head := tr("Chats")
				count := fmt.tprintf("%d", len(ui.chats))
				if ui.page == .Contacts {
					head, count = tr("People"), fmt.tprintf("%d", len(ui.contacts))
					if len(ui.sidebar_filter) > 0 {
						count = fmt.tprintf(tr("%d of %d"), len(contact_rows), len(ui.contacts))
					}
				} else if ui.page == .Chats {
					count = fmt.tprintf("%d", chat_total)
					if len(ui.sidebar_filter) > 0 ||
					   ui.chat_filter != .Chats ||
					   ui.chat_folder != "" {
						count = fmt.tprintf(tr("%d of %d"), len(inbox), chat_total)
					}
				}
				clay.Text(head, {fontId = FONT_TITLE, fontSize = 16, textColor = TEXT})
				clay.Text(count, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO})
				if clay.UI(clay.ID("RailHeadGap"))(
				{layout = {sizing = {width = clay.SizingGrow()}}},
				) {}
				if ui.page == .Chats {
					if clay.UI(clay.ID("ChatsMenuBtn"))(
					{
						layout = {
							sizing = {
								width = clay.SizingFit({min = tap_size() ? 44 : 0}),
								height = clay.SizingFit({min = tap_size() ? 44 : 0}),
							},
							padding = {left = 6, right = 6, top = 4, bottom = 4},
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = hovered() ? HOVER : {},
						cornerRadius = rr(6),
					},
					) {
						clay.Text(
							"···",
							{fontId = FONT_TITLE, fontSize = 15, textColor = TEXT_DIM},
						)
						if hovered() {tooltip(tr("Chat options"))}
					}
				}
				if ui.page != .Contacts {
					// Global-search chip, also on Ctrl+K.
					if clay.UI(clay.ID("GSearchBtn"))(
					{
						layout = {
							sizing = {
								width = clay.SizingFit({min = tap_size() ? 44 : 0}),
								height = clay.SizingFit({min = tap_size() ? 44 : 0}),
							},
							padding = {left = 8, right = 8, top = 5, bottom = 5},
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = hovered() ? HOVER : {},
						cornerRadius = rr(7),
					},
					) {
						clay.Text(
							ICON_SEARCH,
							{fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM},
						)
					}
					if clay.UI(clay.ID("NewChatBtn"))(
					{
						layout = {
							sizing = {
								width = clay.SizingFit({min = tap_size() ? 44 : 0}),
								height = clay.SizingFit({min = tap_size() ? 44 : 0}),
							},
							padding = {left = 8, right = 8, top = 3, bottom = 3},
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = hovered() ? HOVER : {},
						cornerRadius = rr(7),
					},
					) {
						clay.Text("+", {fontId = FONT_TITLE, fontSize = 18, textColor = ACCENT})
					}
				}
			}
			// Chat filter.
			if clay.UI(clay.ID("FilterBox"))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow(),
						height = clay.SizingFixed(tap_size() ? 44 : 34),
					},
					padding = {left = 12, right = 12},
					childGap = 8,
					childAlignment = {y = .Center},
				},
				backgroundColor = ROW_BG,
				cornerRadius = rr(6),
				border = {color = ui.focus == .Filter ? ACCENT : FIELD_BORDER, width = bw()},
			},
			) {
				clay.Text(ICON_SEARCH, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_LO})
				field_text(
					ui,
					"FilterBox",
					&ui.sidebar_filter,
					ui.page == .Contacts ? tr("Search contacts...") : tr("Search messages..."),
					ui.focus == .Filter,
					13,
					TEXT_LO,
				)
			}
			if ui.page == .Chats {
				if clay.UI(clay.ID("ChatFilters"))(
				{
					layout = {sizing = {width = clay.SizingGrow()}, childGap = 4},
					clip = {horizontal = true, childOffset = clay.GetScrollOffset()},
				},
				) {
					labels := #sparse[Chat_Filter]string {
						.Chats  = tr("Chats"),
						.Unread = tr("Unread"),
						.Groups = tr("Groups"),
						.Whip   = "Whip",
					}
					ids := #sparse[Chat_Filter]string {
						.Chats  = "AllPill",
						.Unread = "UnreadPill",
						.Groups = "GroupsPill",
						.Whip   = "WhipPill",
					}
					for t in Chat_Filter {
						if t == .Whip && !rl.WhipAvailable() {continue}
						active := t == ui.chat_filter && ui.chat_folder == ""
						if clay.UI(clay.ID(ids[t]))(
						{
							layout = {
								sizing = {
									width = clay.SizingFit({min = tap_size() ? 44 : 0}),
									height = clay.SizingFit({min = tap_size() ? 44 : 0}),
								},
								padding = {left = 8, right = 8, top = 5, bottom = 5},
								childAlignment = {x = .Center, y = .Center},
							},
							backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
							cornerRadius = rr(6),
						},
						) {
							clay.Text(
								labels[t],
								{
									fontId = FONT_BODY,
									fontSize = 12,
									textColor = active ? TEXT : TEXT_DIM,
								},
							)
						}
					}
					if ui.prefs.recent_chats {
						for name, i in ui.prefs.folders {
							active := name == ui.chat_folder
							if clay.UI(clay.ID("FolderPill", u32(i)))(
							{
								layout = {
									sizing = {
										width = clay.SizingFit({min = tap_size() ? 44 : 0}),
										height = clay.SizingFit({min = tap_size() ? 44 : 0}),
									},
									padding = {left = 8, right = 8, top = 5, bottom = 5},
									childGap = 4,
									childAlignment = {y = .Center},
								},
								backgroundColor = active ? SELECTED : (hovered() ? HOVER : {}),
								cornerRadius = rr(6),
							},
							) {
								folder_icon(ui, name, 12)
								clay.Text(
									name,
									{
										fontId = FONT_BODY,
										fontSize = 12,
										textColor = active ? TEXT : TEXT_DIM,
									},
								)
							}
						}
					}
				}
				scrollbar(clay.ID("ChatFilters"))
				if ui.page == .Chats &&
				   clay.UI(clay.ID("ChatViewBtn"))(
				   {
					   layout = {
						   sizing = {height = clay.SizingFit({min = tap_size() ? 44 : 0})},
						   padding = {left = 6, right = 6, top = 5, bottom = 5},
						   childAlignment = {y = .Center},
					   },
					   backgroundColor = hovered() ? HOVER : {},
					   cornerRadius = rr(6),
				   },
				   ) {
					clay.Text(
						ui.prefs.recent_chats ? tr("Recent") : tr("Grouped"),
						{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
					)
					if hovered() {
						tooltip(
							ui.prefs.recent_chats ? tr("Group chats by folder") : tr("Sort chats by recent activity"),
						)
					}
				}
			}
		}

		if ui.page == .Contacts && logged_in && !rail_narrow(ui) {
			empty := contacts_empty(len(ui.contacts), len(contact_rows), len(ui.sidebar_filter))
			if empty != .None {
				clay.Text(
					empty == .No_Matches ? tr("No matching contacts") : tr("No contacts yet"),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
				)
			}
			if empty == .No_Matches {
				if clay.UI(clay.ID("ContactsClearRow"))({layout = {padding = {left = 4}}}) {
					micro_button("ContactsClearSearch", tr("Clear search"))
				}
			}
			if clay.UI(clay.ID("ContactsExportRow"))(
			{
				layout = {
					layoutDirection = .TopToBottom,
					childGap = 8,
					padding = {left = 4, bottom = 2},
				},
			},
			) {
				micro_button("ContactsImportBtn", tr("Import contacts"))
				if len(ui.contacts) > 0 {
					if clay.UI(clay.ID("ContactsExportButtons"))({layout = {childGap = 8}}) {
						micro_button("ContactsCsvBtn", tr("Export CSV"))
						micro_button("ContactsJsonBtn", tr("Export JSON"))
					}
				}
			}
			if clay.UI(clay.ID("ContactList"))(
			{
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingGrow({min = single_pane() ? 50 : 0})},
					layoutDirection = .TopToBottom,
					childGap = 6,
				},
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
			},
			) {
				// Alphabetical with letter section headers and a name
				// filter. Rows keep their
				// ui.contacts index in the clay ID so clicks stay stable.
				last_letter: u8 = 0
				Contact_Item :: struct {
					idx:    int,
					letter: u8,
					y, end: f32,
				}
				rows := make([dynamic]Contact_Item, 0, len(contact_rows), context.temp_allocator)
				ROW_H :: f32(50)
				HEADER_H :: f32(22)
				GAP :: f32(6)
				y: f32
				for order in contact_rows {
					letter: u8 = '#'
					if !order.unnamed &&
					   len(order.key) > 0 &&
					   order.key[0] >= 'a' &&
					   order.key[0] <= 'z' {
						letter = order.key[0] - 32
					}
					header := letter != last_letter
					end := y + ROW_H + GAP + (header ? HEADER_H + GAP : 0)
					append(&rows, Contact_Item{order.idx, header ? letter : 0, y, end})
					y, last_letter = end, letter
				}
				// Keep full scroll geometry, but build only the viewport and two spare rows.
				data := clay.GetScrollContainerData(clay.ID("ContactList"))
				height :=
					data.found ? data.scrollContainerDimensions.height : f32(rl.GetScreenHeight()) / UI_ZOOM
				offset :=
					data.found ? clamp(-data.scrollPosition.y, 0, max(0, y - GAP - height)) : 0
				if data.found {data.scrollPosition.y = -offset}
				first, last := 0, len(rows)
				for first < last && rows[first].end < offset - 2 * (ROW_H + GAP) {first += 1}
				for last > first &&
				    rows[last - 1].y > offset + height + 2 * (ROW_H + GAP) {last -= 1}
				if first > 0 {
					if clay.UI(clay.ID("ContactsBefore"))(
					{layout = {sizing = {height = clay.SizingFixed(rows[first].y - GAP)}}},
					) {}
				}
				for order in rows[first:last] {
					contact := ui.contacts[order.idx]
					if order.letter != 0 {
						if clay.UI(clay.ID("ContactLetter", u32(order.idx)))(
						{
							layout = {
								sizing = {height = clay.SizingFixed(HEADER_H)},
								padding = {left = 10, top = 6, bottom = 2},
							},
						},
						) {
							clay.Text(
								fmt.tprintf("%c", order.letter),
								{
									fontId = FONT_MONO,
									fontSize = 11,
									textColor = TEXT_LO,
									letterSpacing = 2,
								},
							)
						}
					}

					selected := ui.selected_contact == order.idx
					if clay.UI(clay.ID("ContactRow", u32(order.idx)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(ROW_H)},
							padding = clay.PaddingAll(10),
							childGap = 10,
							childAlignment = {y = .Center},
						},
						backgroundColor = selected ? SELECTED : (hovered() ? HOVER : {}),
						cornerRadius = rr(12),
					},
					) {
						if selected {
							if clay.UI(clay.ID("ContactRowBar", u32(order.idx)))(
							{
								layout = {
									sizing = {
										width = clay.SizingFixed(3),
										height = clay.SizingFixed(18),
									},
								},
								backgroundColor = ACCENT,
								cornerRadius = rr(2),
							},
							) {}
						}
						avatar(
							"ContactAvatar",
							u32(order.idx),
							contact.id_hex,
							contact.name,
							30,
							url_pic(contact.pic_url),
						)
						if clay.UI(clay.ID("ContactNameClip", u32(order.idx)))(
						{
							layout = {sizing = {width = clay.SizingGrow()}},
							clip = {horizontal = true},
						},
						) {
							clay.Text(
								contact_label(ui, contact),
								{
									fontId = FONT_TITLE,
									fontSize = 14,
									textColor = TEXT,
									wrapMode = .None,
								},
							)
						}
						if selected && len(contact.npub) > 0 && !single_pane() {
							if clay.UI(clay.ID("ContactRowGap", u32(order.idx)))(
							{layout = {sizing = {width = clay.SizingGrow()}}},
							) {}
							clay.Text(
								npub_tail(contact.npub),
								{fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO},
							)
						}
					}
				}
				if last < len(rows) {
					if clay.UI(clay.ID("ContactsAfter"))(
					{layout = {sizing = {height = clay.SizingFixed(y - rows[last].y - GAP)}}},
					) {}
				}
			}
			scrollbar(clay.ID("ContactList"))
		}

		if ui.page == .Chats && logged_in && !rail_narrow(ui) {
			whip_inbox_progress(ui)
			if clay.UI(clay.ID("ChatList"))(
			{
				layout = {
					sizing = {
						clay.SizingGrow(),
						clay.SizingGrow({min = single_pane() ? chat_row_height() : 0}),
					},
					layoutDirection = .TopToBottom,
					childGap = 2,
				},
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
			},
			) {
				chat_rail(ui, inbox, chat_total)
			}
			scrollbar(clay.ID("ChatList"))
		}

	}
	if ui.page == .Profile || single_pane() {scrollbar(clay.ID("RailContent"))}
}
