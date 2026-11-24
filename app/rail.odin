package main

import "core:fmt"

import "nendo"
import rl "sdlrl"

// Shift+wheel scrolls the chat filter row sideways once folders overflow it.
@(private)
chat_filter_wheel :: proc(ui: ^Ui_State, wheel: ^rl.Vector2) {
	if ui.page != .Chats || !shift_down() || !nendo.pointer_over(nendo.id("ChatFilters")) {return}
	wheel.x += wheel.y
	wheel.y = 0
}

// The expanded sidebar: section controls and the active page's list.
@(private)
rail_content :: proc(ui: ^Ui_State, page: Page) {
	logged_in := len(ui.accounts) > 0
	// A phone pins the inbox header and scrolls only the chat list. Short
	// windows (landscape, open keyboard) scroll the whole column instead,
	// so the list never shrinks below one row.
	pinned := page == .Chats && f32(rl.GetScreenHeight()) / UI_ZOOM >= 480
	page_scroll := page == .Profile || ((single_pane() || page == .Chats) && !pinned)

	if nendo.box(nendo.id("RailContent"))(
	{
		width = nendo.grow(),
		height = nendo.grow(),
		direction = .Column,
		padding = {left = 10, right = 10, top = 12, bottom = 12},
		gap = 8,
		color = PANEL,
		// Account rows must scroll rather than raise the shell's minimum height.
		clip = {y = page_scroll, scroll = page_scroll},
	},
	) {
		// The header counts what the chat list below shows.
		chat_rows: []int
		inbox: []Inbox_Row
		chat_total: int
		if page == .Chats {
			chat_rows, chat_total = chat_rail_matches(ui)
			inbox = inbox_rows(ui, chat_rows)
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
		if page == .Contacts {
			contact_rows = contact_rail_matches(ui)
		}
		// Profile replaces the conversation list with accounts.
		if page == .Profile {
			profile_rail(ui)
		} else {
			// Section header: CHATS/CONTACTS count + new-chat button.
			if nendo.box(nendo.id("RailHead"))(
			{
				width = nendo.grow(),
				height = nendo.fixed(tap_size() ? 50 : 32),
				gap = 8,
				align = {y = .Center},
				padding = {top = 4, bottom = 2},
			},
			) {
				// A phone has no navigation column, so the account switcher
				// rides at the head of the inbox.
				if single_pane() && page == .Chats {
					avatar(
						"RailAvatar",
						0,
						ui.account_ref,
						profile_label(nil, ui.account_ref),
						32,
						url_pic(ui.my_pic_url),
					)
				}
				head := tr("Chats")
				count := fmt.tprintf("%d", len(ui.chats))
				if page == .Contacts {
					head, count = tr("People"), fmt.tprintf("%d", len(ui.contacts))
					if len(ui.sidebar_filter) > 0 {
						count = fmt.tprintf(tr("%d of %d"), len(contact_rows), len(ui.contacts))
					}
				} else if page == .Chats {
					count = fmt.tprintf("%d", chat_total)
					if len(ui.sidebar_filter) > 0 ||
					   ui.chat_filter != .Chats ||
					   ui.chat_folder != "" {
						count = fmt.tprintf(tr("%d of %d"), len(inbox), chat_total)
					}
				}
				nendo.text(head, {font = FONT_TITLE, size = 16, color = SIDEBAR_TEXT})
				nendo.text(count, {font = FONT_BODY, size = 12, color = SIDEBAR_DIM})
				if nendo.box(nendo.id("RailHeadGap"))({width = nendo.grow()}) {}
				if page == .Chats {
					if nendo.box(nendo.id("ChatsMenuBtn"))(
					{
						width = nendo.fit(min = tap_size() ? tap_min() : 0),
						height = nendo.fit(min = tap_size() ? tap_min() : 0),
						padding = {left = 6, right = 6, top = 4, bottom = 4},
						align = {x = .Center, y = .Center},
						color = hovered() ? HOVER : {},
						radius = rr(6),
					},
					) {
						nendo.text("···", {font = FONT_TITLE, size = 15, color = TEXT_DIM})
						if hovered() {tooltip(tr("Chat options"))}
					}
				}
				if page != .Contacts {
					// Global-search chip, also on Ctrl+K.
					if nendo.box(nendo.id("GSearchBtn"))(
					{
						width = nendo.fit(min = tap_size() ? tap_min() : 0),
						height = nendo.fit(min = tap_size() ? tap_min() : 0),
						padding = {left = 8, right = 8, top = 5, bottom = 5},
						align = {x = .Center, y = .Center},
						color = hovered() ? HOVER : {},
						radius = rr(7),
					},
					) {
						nendo.text(ICON_SEARCH, {font = FONT_ICON, size = 12, color = TEXT_DIM})
					}
					if nendo.box(nendo.id("NewChatBtn"))(
					{
						width = nendo.fit(min = tap_size() ? tap_min() : 0),
						height = nendo.fit(min = tap_size() ? tap_min() : 0),
						padding = {left = 8, right = 8, top = 3, bottom = 3},
						align = {x = .Center, y = .Center},
						color = hovered() ? HOVER : {},
						radius = rr(7),
					},
					) {
						nendo.text("+", {font = FONT_TITLE, size = 18, color = ACCENT})
					}
				}
			}
			// Chat filter.
			if nendo.box(nendo.id("FilterBox"))(
			{
				width = nendo.grow(),
				height = nendo.fixed(tap_size() ? tap_min() : 34),
				padding = {left = 12, right = 12},
				gap = 8,
				align = {y = .Center},
				color = ROW_BG,
				radius = rr(6),
				border = {color = ui.focus == .Filter ? ACCENT : FIELD_BORDER, width = bw()},
			},
			) {
				nendo.text(ICON_SEARCH, {font = FONT_ICON, size = 12, color = TEXT_LO})
				field_text(
					ui,
					"FilterBox",
					&ui.sidebar_filter,
					page == .Contacts ? tr("Search contacts...") : tr("Search messages..."),
					ui.focus == .Filter,
					13,
					TEXT_LO,
				)
				if len(ui.sidebar_filter) > 0 {
					if nendo.box(nendo.id("FilterClear"))(
					{
						width = nendo.fixed(tap_size() ? tap_min() : 24),
						height = nendo.fixed(tap_size() ? tap_min() : 24),
						align = {x = .Center, y = .Center},
						color = hovered() ? HOVER : {},
						radius = rr(6),
					},
					) {
						nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 12, color = TEXT_DIM})
					}
				}
			}
			if page == .Chats {
				if nendo.box(nendo.id("ChatFilterRow"))(
				{width = nendo.grow(), gap = 4, align = {y = .Center}},
				) {
					if nendo.box(nendo.id("ChatFilters"))(
					{width = nendo.grow(), gap = 4, clip = {x = true, scroll = true}},
					) {
						labels := #sparse[Chat_Filter]string {
							.Chats  = tr("Chats"),
							.Unread = tr("Unread"),
							.Groups = tr("Groups"),
						}
						ids := #sparse[Chat_Filter]string {
							.Chats  = "AllPill",
							.Unread = "UnreadPill",
							.Groups = "GroupsPill",
						}
						for t in Chat_Filter {
							active := t == ui.chat_filter && ui.chat_folder == ""
							if nendo.box(nendo.id(ids[t]))(
							{
								width = nendo.fit(min = tap_size() ? tap_min() : 0),
								height = nendo.fit(min = tap_size() ? tap_min() : 0),
								padding = {left = 8, right = 8, top = 5, bottom = 5},
								align = {x = .Center, y = .Center},
								color = active ? SELECTED : (hovered() ? HOVER : {}),
								radius = rr(6),
							},
							) {
								nendo.text(
									labels[t],
									{
										font = FONT_BODY,
										size = 12,
										color = active ? TEXT : TEXT_DIM,
									},
								)
							}
						}
						if ui.prefs.recent_chats {
							for name, i in ui.prefs.folders {
								active := name == ui.chat_folder
								if nendo.box(nendo.id("FolderPill", u32(i)))(
								{
									width = nendo.fit(min = tap_size() ? tap_min() : 0),
									height = nendo.fit(min = tap_size() ? tap_min() : 0),
									padding = {left = 8, right = 8, top = 5, bottom = 5},
									gap = 4,
									align = {y = .Center},
									color = active ? SELECTED : (hovered() ? HOVER : {}),
									radius = rr(6),
								},
								) {
									folder_icon(ui, name, 12)
									nendo.text(
										name,
										{
											font = FONT_BODY,
											size = 12,
											color = active ? TEXT : TEXT_DIM,
										},
									)
								}
							}
						}
					}
					scrollbar(nendo.id("ChatFilters"))
					if nendo.box(nendo.id("ChatViewBtn"))(
					{
						width = nendo.fixed(tap_size() ? tap_min() : 32),
						height = nendo.fixed(tap_size() ? tap_min() : 32),
						padding = {left = 6, right = 6, top = 5, bottom = 5},
						align = {x = .Center, y = .Center},
						color = hovered() ? HOVER : ROW_BG,
						radius = rr(6),
					},
					) {
						nendo.text(
							ui.prefs.recent_chats ? "\uf017" : ICON_FOLDER,
							{font = FONT_ICON, size = 16, color = ACCENT},
						)
						if hovered() {
							tooltip(
								ui.prefs.recent_chats ? tr("Group chats by folder") : tr("Sort chats by recent activity"),
							)
						}
					}
				}
			}
		}

		if page == .Contacts && logged_in && !rail_narrow(ui) {
			empty := contacts_empty(len(ui.contacts), len(contact_rows), len(ui.sidebar_filter))
			if empty != .None {
				nendo.text(
					empty == .No_Matches ? tr("No matching contacts") : tr("No contacts yet"),
					{font = FONT_BODY, size = 13, color = TEXT_DIM},
				)
			}
			if empty == .No_Matches {
				if nendo.box(nendo.id("ContactsClearRow"))({padding = {left = 4}}) {
					micro_button("ContactsClearSearch", tr("Clear search"))
				}
			}
			if empty == .No_Contacts {
				nendo.text(
					tr(
						"Add someone from their profile or paste their npub above. You can also import a contacts CSV or JSON export.",
					),
					{font = FONT_BODY, size = 13, color = TEXT_DIM},
				)
				login_big_button("ContactsImportBtn", tr("Import contacts"), true, .Enabled)
			}
			if contact_query_hex(ui) != "" {
				login_big_button("ContactsAddNpub", tr("Add contact"), true, .Enabled)
			}
			if nendo.box(nendo.id("ContactList"))(
			{
				width = nendo.grow(),
				height = nendo.grow(min = single_pane() ? CONTACT_ROW_H : 0),
				direction = .Column,
				clip = {y = true, scroll = true},
			},
			) {
				contact_rail_rows(ui, contact_rows)
			}
			scrollbar(nendo.id("ContactList"))
			if len(ui.contacts) > 0 {
				micro_button("ContactsManage", tr("Manage contacts"))
				if ui.contact_tools_open {
					if nendo.box(nendo.id("ContactsTools"))({direction = .Column, gap = 8}) {
						micro_button("ContactsImportBtn", tr("Import contacts"))
						if nendo.box(nendo.id("ContactsExportButtons"))({gap = 8}) {
							micro_button("ContactsCsvBtn", tr("Export CSV"))
							micro_button("ContactsJsonBtn", tr("Export JSON"))
						}
					}
				}
			}
		}

		if page == .Chats && logged_in && !rail_narrow(ui) {
			if !ui.add_account_open {devices_banner(ui)}
			if nendo.box(nendo.id("ChatList"))(
			{
				width = nendo.grow(),
				height = pinned ? nendo.grow(min = chat_row_height()) : nendo.fit(),
				direction = .Column,
				gap = INBOX_GAP,
				clip = {y = pinned, scroll = true},
			},
			) {
				chat_rail(ui, inbox, chat_total)
			}
			if pinned {scrollbar(nendo.id("ChatList"))}
		}

	}
	if page_scroll {scrollbar(nendo.id("RailContent"))}
}

@(private = "file")
CONTACT_ROW_H :: f32(50)

@(private = "file")
contact_rail_rows :: proc(ui: ^Ui_State, contacts: []Contact_Order) {
	HEADER_H :: f32(22)
	GAP :: u16(6)
	HEADED_H :: HEADER_H + f32(GAP) + CONTACT_ROW_H
	headings := make([]u8, len(contacts), context.temp_allocator)
	offsets := make([]f32, len(contacts) + 1, context.temp_allocator)
	last_letter: u8
	for order, i in contacts {
		letter: u8 = '#'
		if !order.unnamed && len(order.key) > 0 && 'a' <= order.key[0] && order.key[0] <= 'z' {
			letter = order.key[0] - 'a' + 'A'
		}
		height := CONTACT_ROW_H
		if letter != last_letter {
			headings[i] = letter
			last_letter = letter
			height = HEADED_H
		}
		offsets[i + 1] = offsets[i] + height
	}
	window := nendo.virtual_rows(
		nendo.id("ContactRows"),
		offsets,
		GAP,
		2 * (CONTACT_ROW_H + f32(GAP)),
	)
	for i in window.first ..< window.end {
		index := contacts[i].idx
		if headings[i] == 0 {
			contact_rail_row(ui, index)
			continue
		}
		if nendo.box(nendo.id("ContactEntry", u32(index)))(
		{width = nendo.grow(), height = nendo.fixed(HEADED_H), direction = .Column, gap = GAP},
		) {
			if nendo.box(nendo.id("ContactLetter", u32(index)))(
			{height = nendo.fixed(HEADER_H), padding = {left = 10, top = 6, bottom = 2}},
			) {
				nendo.text(
					fmt.tprintf("%c", headings[i]),
					{font = FONT_MONO, size = 11, color = TEXT_LO, spacing = 2},
				)
			}
			contact_rail_row(ui, index)
		}
	}
}

@(private = "file")
contact_rail_row :: proc(ui: ^Ui_State, index: int) {
	contact := ui.contacts[index]
	id := u32(index)
	selected := ui.selected_contact == index
	if nendo.box(nendo.id("ContactRow", id))(
	{
		width = nendo.grow(),
		height = nendo.fixed(CONTACT_ROW_H),
		padding = nendo.pad(10),
		gap = 10,
		align = {y = .Center},
		color = selected ? SELECTED : (hovered() ? HOVER : {}),
		radius = rr(12),
	},
	) {
		if selected {
			if nendo.box(nendo.id("ContactRowBar", id))(
			{width = nendo.fixed(3), height = nendo.fixed(18), color = ACCENT, radius = rr(2)},
			) {}
		}
		photo := contact_picture(contact)
		avatar(
			"ContactAvatar",
			id,
			photo == nil ? contact.npub : contact.id_hex,
			contact.name,
			30,
			photo,
		)
		name_clip := nendo.id("ContactNameClip", id)
		if nendo.box(name_clip)({width = nendo.grow(), clip = {x = true}}) {
			name_w := nendo.element(name_clip).rect.width
			if name_w <= 0 {
				name_w = max(1, rail_width(ui) - 80)
			}
			nendo.text(
				text_ellipsis(contact_label(ui, contact), name_w, FONT_TITLE, 14),
				{font = FONT_TITLE, size = 14, color = TEXT, wrap = .None},
			)
		}
		if selected && len(contact.npub) > 0 && !single_pane() {
			if nendo.box(nendo.id("ContactRowGap", id))({width = nendo.grow()}) {}
			nendo.text(npub_tail(contact.npub), {font = FONT_MONO, size = 10, color = TEXT_LO})
		}
	}
}
