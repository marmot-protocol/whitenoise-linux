package main

import "core:fmt"
import "core:strings"

import "nendo"
import rl "sdlrl"

@(private)
CHAT_WIDTH_MAX :: f32(720)

// A square header control: the phone header's Back and overflow buttons.
@(private = "file")
header_icon :: proc(id_str: string, glyph: string, label: string) {
	if nendo.box(nendo.id(id_str))(
	{
		width = nendo.fixed(44),
		height = nendo.fixed(44),
		align = {x = .Center, y = .Center},
		color = hovered() ? HOVER : {},
		radius = rr(8),
	},
	) {
		if hovered() {tooltip(label)}
		nendo.text(glyph, {font = FONT_TITLE, size = 20, color = TEXT})
	}
}

// The phone header's overflow menu. Rows carry the desktop chips' ids,
// so handle_chat runs them through the same handlers.
@(private = "file")
chat_head_menu :: proc(ui: ^Ui_State, chat: Chat_Row_Ui) {
	if nendo.box(nendo.id("ChatHeadMenu"))(
	{
		width = nendo.fixed(fit_w(240)),
		direction = .Column,
		padding = nendo.pad(4),
		gap = 1,
		floating = {
			attach_to = .Element,
			parent = nendo.id("ChatHeadMore").id,
			attach = {element = .Right_Top, parent = .Right_Bottom},
			offset = {0, 4},
			z = 12,
		},
		color = CARD,
		radius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		ctx_item("FilesBtn", ICON_FOLDER, tr("Files"))
		unread := mi_unread_count(ui)
		ctx_item(
			"BellBtn",
			ICON_BELL,
			unread > 0 ? fmt.tprintf("%s (%d)", tr("Mentions"), unread) : tr("Mentions"),
		)
		ctx_item("GroupSettingsBtn", ICON_SETTINGS, tr("Settings"))
		if !chat_is_dm(chat) {ctx_item("MembersBtn", ICON_PEOPLE, tr("Members"))}
	}
}

chat_pane :: proc(ui: ^Ui_State, chat: Chat_Row_Ui, messages: []Msg_Ui) {
	active := ui.page == .Chats
	// A phone header is one row: Back, the title, Search and an overflow
	// menu for the remaining chips.
	phone := single_pane()

	if nendo.box(nendo.id("ChatPane"))(
	{width = nendo.grow(), height = nendo.grow(), direction = .Column},
	) {
		if active &&
		   open_now(nendo.id("CtxMenu"), ui.ctx_open) &&
		   ui.ctx_msg >= 0 &&
		   ui.ctx_msg < len(ui.messages) {
			context_menu(ui)
		}
		if open_now(nendo.id("HistModal"), ui.hist_open) &&
		   ui.hist_msg >= 0 &&
		   ui.hist_msg < len(ui.messages) {
			edit_history_modal(ui)
		}
		if open_now(nendo.id("RawModal"), ui.raw_open) {
			raw_event_modal(ui)
		}
		if open_now(nendo.id("EncModal"), ui.enc_open) {
			encryption_modal(ui, chat)
		}
		if ui.fwd_kind != .Theme {
			if open_now(nendo.id("FwdModal"), ui.fwd_open) &&
			   (ui.fwd_kind == .Add_Member || forward_source(ui) >= 0) {
				forward_modal(ui)
			}
		}
		if open_now(nendo.id("OvModal"), ui.ov_open) {
			openverse_modal(ui)
		}
		if open_now(nendo.id("LocationModal"), ui.location_open) {
			geo_picker(ui)
		}
		// No close animation here: preview_close frees the decoded
		// views, so nothing may draw the modal after it.
		if open_now(nendo.id("PvModal"), preview_shown) && preview_shown {
			preview_modal(ui)
		}
		// Header.
		if nendo.box(nendo.id("ChatHeader"))(
		{
			width = nendo.grow(),
			padding = phone ? nendo.pad(4) : nendo.pad(14),
			gap = phone ? 2 : 6,
			align = {y = .Center},
			color = RAIL_BG,
		},
		) {
			if phone {header_icon("ChatBack", "\u2039", tr("Back"))}
			// Avatar and title open conversation details.
			if nendo.box(nendo.id("ChatHeadInfo"))(
			{
				width = nendo.grow(),
				height = nendo.fit(min = tap_size() ? tap_min() : 28),
				padding = {left = 4, right = 8, top = 2, bottom = 2},
				gap = 6,
				align = {y = .Center},
				color = hovered() ? HOVER : {},
				radius = rr(8),
			},
			) {
				if page_w(ui) >= 420 {
					peephole_avatar(
						"ChatHeadAvatar",
						0,
						chat.avatar_key,
						chat.title,
						34,
						chat_pic(chat),
						nendo.pointer_over(nendo.id("ChatHeadAvatar", 0)) ? .Open : .Closed,
					)
				}
				// Keep unbroken titles from widening the pane beyond the window.
				if nendo.box(nendo.id("ChatHeadTitleClip"))(
				{width = nendo.grow(), direction = .Column, gap = 2, clip = {x = true}},
				) {
					nendo.text(
						chat.title,
						{font = FONT_TITLE, size = 16, color = CARD_TEXT, wrap = .None},
					)
					if !chat_is_dm(chat) && len(ui.members) > 0 {
						nendo.text(
							fmt.tprintf(
								tr(len(ui.members) == 1 ? N_("%d member") : N_("%d members")),
								len(ui.members),
							),
							{font = FONT_BODY, size = 11, color = CARD_DIM, wrap = .None},
						)
					}
				}
				if hovered() {
					tooltip(chat_is_dm(chat) ? tr("Chat details") : tr("Group settings"))
					cursor_raise(.Pointer)
				}
			}
			// Right-pinned chrome; the bell opens the mentions inbox.
			// Keep MLS internals out of normal mode and compact headers.
			if ui.prefs.dev_mode && page_w(ui) >= 580 {
				if nendo.box(nendo.id("MlsBadge"))(
				{
					padding = {left = 8, right = 8, top = 3, bottom = 3},
					gap = 5,
					align = {y = .Center},
					color = hovered() ? ACCENT_DIM : ACCENT,
					radius = rr(6),
				},
				) {
					nendo.text(ICON_LOCK, {font = FONT_ICON, size = 10, color = ON_ACCENT})
					crop_circle("MlsCircle", 0, chat.group_id, 18)
					nendo.text(
						fmt.tprintf("mls:0x%s", chat.group_id[:min(len(chat.group_id), 6)]),
						{font = FONT_MONO, size = 11, color = ON_ACCENT},
					)
					if hovered() {
						tooltip(tr("End-to-end encrypted"))
						cursor_raise(.Pointer)
					}
				}
			}
			if phone {
				header_icon("SearchBtn", ICON_SEARCH, tr("Search"))
				header_icon("ChatHeadMore", "\u00b7\u00b7\u00b7", tr("Chat options"))
			} else if nendo.box(nendo.id("ChatHeadActions"))({gap = 6, align = {y = .Center}}) {
				header_chip("FilesBtn", ICON_FOLDER, ui.group_files_open, tr("Files"))
				header_chip("SearchBtn", ICON_SEARCH, ui.search_open, tr("Search"))
				bell_chip(ui)
				header_chip(
					"GroupSettingsBtn",
					ICON_SETTINGS,
					ui.show_members && ui.info_tab == .Settings,
					tr("Settings"),
				)
				if !chat_is_dm(chat) {
					header_chip(
						"MembersBtn",
						ICON_PEOPLE,
						ui.show_members && ui.info_tab == .Members,
						tr("Members"),
					)
				}
			}
			// The chrome floats over the timeline; only the bottom-most
			// bar casts, so the shadows don't stack.
			if len(ui.thread_stack) == 0 {
				cast_shade(nendo.id("ChatHeader"), .Down, 14, 0.35)
			}
		}
		if phone && ui.chat_head_menu {chat_head_menu(ui, chat)}
		// A nested if: nendo.box's deferred close runs for its enclosing scope,
		// so it must not sit behind a short-circuited condition.
		if ui.search_open {if nendo.box(nendo.id("SearchBar"))({width = nendo.grow(), direction = .Column, padding = {left = 8, right = 8, top = 6, bottom = 6}, gap = 4}) {
				if nendo.box(nendo.id("SearchBox"))(
				{
					width = nendo.grow(),
					height = nendo.fixed(tap_size() ? tap_min() : 32),
					padding = {left = 10, right = 10},
					align = {y = .Center},
					color = ROW_BG,
					radius = rr(8),
					border = {color = ui.focus == .Search ? ACCENT : FIELD_BORDER, width = bw()},
				},
				) {
					field_text(
						ui,
						"SearchBox",
						&ui.search_input,
						tr("Search messages"),
						ui.focus == .Search,
					)
					if len(ui.search_input) > 0 {
						header_icon("SearchClear", ICON_CLOSE, tr("Clear search"))
					}
				}
				if timeline_job != nil && len(timeline_job.search) > 0 {
					nendo.text(
						fmt.tprintf(
							tr(len(ui.messages) == 1 ? N_("%d result") : N_("%d results")),
							len(ui.messages),
						),
						{font = FONT_BODY, size = 12, color = TEXT_DIM},
					)
				} else {
					nendo.text(
						tr("Press Enter to search."),
						{font = FONT_BODY, size = 12, color = TEXT_DIM},
					)
				}
			}}
		// Declared after the header so the bell it attaches to exists.
		if active && open_now(nendo.id("MiModal"), ui.mi_open) {
			mention_inbox(ui)
		}
		// Thread route: breadcrumb bar under the header while open.
		if len(ui.thread_stack) > 0 {
			thread_bar(ui)
		}

		// Pending-invite banner: this chat awaits a decision.
		if chat.pending {
			if nendo.box(nendo.id("InviteBanner"))(
			{
				width = nendo.grow(),
				direction = single_pane() ? .Column : .Row,
				padding = nendo.pad(12),
				gap = 10,
				align = {y = .Center},

				// Not ROW_BG: secondary buttons share that fill and vanished.
				color = CARD,
			},
			) {
				nendo.text(
					chat_is_dm(chat) ? tr("You were invited to this chat.") : tr("You were invited to this group."),
					{font = FONT_BODY, size = 14, color = TEXT},
				)
				if nendo.box(nendo.id("InviteActions"))(
				{
					width = single_pane() ? nendo.grow() : nendo.fit(),
					gap = 10,
					align = {y = .Center},
				},
				) {
					login_button("InviteDecline", tr("Decline"))
					login_button("InviteAccept", tr("Accept"), primary = true)
				}
			}
		}

		if nendo.box(nendo.id("ChatBody"))(
		{width = nendo.grow(), height = nendo.grow(), direction = .Row, align = {x = .Center}},
		) {
			// Group info takes the whole conversation area, like the
			// thread route; page_view_key plays the swap transition.
			if ui.group_files_open {
				group_files_panel(ui)
			} else if ui.show_members {
				members_panel(ui)
			} else if nendo.box(nendo.id("ChatColumn"))(
			{
				width = ui.prefs.centered_chat ? nendo.grow(max = CHAT_WIDTH_MAX) : nendo.grow(),
				height = nendo.grow(),
				direction = .Column,
			},
			) {
				profile := device_current(ui)
				if profile != nil {
					history_import_progress(profile, chat.group_id)
				}
				// Timeline: a real scroll container, top-anchored.
				// Loads jump to the newest message.
				// The thread route's push/pop transition: content slides
				// home from a small offset.
				cur := thread_cur(ui)
				if nendo.box(nendo.id("Timeline"))(
				{
					width = nendo.grow(),
					height = nendo.grow(),
					direction = .Column,
					padding = {left = u16(thread_slide()), top = 8, bottom = 8},
					gap = TIMELINE_GAP,
					clip = {y = true, scroll = true},
					// The theme's decor scene: nendo emits the Custom
					// command before the children, so it paints behind
					// the messages.
					custom = decor_payload(),
				},
				) {
					// Dividers are left-aligned like the day markers:
					// x=center children drop in this nendo build (quirks).
					// Pending invite: the timeline is preview context under
					// the accept/decline banner.
					if chat.pending {
						if nendo.box(nendo.id("RequestDivider"))(
						{padding = {left = 16, right = 16, top = 8, bottom = 2}},
						) {
							nendo.text(
								tr("• CHAT REQUEST •"),
								{font = FONT_MONO, size = 10, color = ACCENT_DIM, spacing = 2},
							)
						}
					}
					if ui.timeline_loading {
						if nendo.box(nendo.id("TimelineLoading"))(
						{padding = nendo.pad(16), gap = 10, direction = .Column},
						) {
							nendo.text(
								tr("Loading messages…"),
								{font = FONT_BODY, size = 14, color = TEXT_DIM},
							)
							if nendo.box(nendo.id("TimelineLoadingTrack"))(
							{
								width = nendo.fixed(180),
								height = nendo.fixed(4),
								color = PLATE,
								radius = rr(2),
							},
							) {
								phase :=
									!motion_on() ? f32(0.5) : f32(rl.GetTime() - f64(int(rl.GetTime())))
								if motion_on() {anim_moving += 1}
								if nendo.box(nendo.id("TimelineLoadingOffset"))(
								{width = nendo.fixed(phase * 132)},
								) {}
								if nendo.box(nendo.id("TimelineLoadingBar"))(
								{
									width = nendo.fixed(48),
									height = nendo.fixed(4),
									color = ACCENT,
									radius = rr(2),
								},
								) {}
							}
						}
					} else if ui.timeline_error != "" {
						if nendo.box(nendo.id("TimelineLoadError"))({padding = nendo.pad(16)}) {
							nendo.text(
								ui.timeline_error,
								{font = FONT_BODY, size = 14, color = TEXT},
							)
						}
					} else if len(messages) == 0 {
						has_pending := false
						for p in ui.pending {
							if p.thread == cur && pending_in_workspace(ui, p, chat.group_id) {
								has_pending = true
								break
							}
						}
						if !has_pending {empty_timeline(ui)}
					}
					// The thread route filters the one timeline: the main
					// view shows unthreaded rows, a thread view shows its
					// pinned root and the rows tagged to it.
					if len(cur) > 0 {
						thread_root_plate(ui)
					}
					timeline_rows(ui, messages, cur, profile)
					// Keep pending sends at the tail until the timeline catches up.
					for p, i in ui.pending {
						if p.thread == cur && pending_in_workspace(ui, p, chat.group_id) {
							pending_row(u32(i), ui, p)
						}
					}
				}

				scrollbar(nendo.id("Timeline"))
				jump_latest_button()

				if !chat.pending || !single_pane() {chat_composer(ui)}
			}
		}
		chat_drop_overlay(ui)
	}
}

@(private = "file")
timeline_rows :: proc(
	ui: ^Ui_State,
	messages: []Msg_Ui,
	thread: string,
	profile: ^Device_Profile,
) {
	ui.timeline_metric = {body_wrap_w(), UI_SCALE, R_SCALE, chip_h()}
	rows := make([dynamic]Timeline_Entry, 0, len(messages), context.temp_allocator)
	run: Msg_Run
	blocked_at, last_import := -1, -1
	for &msg, i in messages {
		if msg.thread_of != thread {continue}
		row := Timeline_Entry {
			index = i,
		}
		if ui.unread_mark_id != "" && msg.id == ui.unread_mark_id {row.shape.parts += {.Unread}}
		if i == 0 || msg.day != messages[i - 1].day {row.shape.parts += {.Day}}
		if row.shape.parts != {} {run, blocked_at = {}, -1}

		// A collapsed run contributes its disclosure row, but not its messages.
		blocked := msg_blocked(ui, msg)
		if !blocked {
			if blocked_at >= 0 {run = {}}
			blocked_at = -1
		} else {
			if blocked_at < 0 {
				blocked_at, run = i, {}
				row.shape.blocked = blocked_run_len(ui, i)
			}
			if !ui.blocked_open[messages[blocked_at].id] {
				msg.row_height = 0
				if timeline_has_markers(row.shape) {append(&rows, row)}
				continue
			}
		}
		if (msg.origin.kind != .None || last_import >= 0) &&
		   !msg.system &&
		   !msg.deleted &&
		   !blocked &&
		   !ui.hidden[msg.id] {
			if last_import >= 0 {
				origin := &messages[last_import].origin
				if origin.kind != msg.origin.kind || origin.slot != msg.origin.slot {
					row.shape.parts += {.Import}
					row.import_from, run = last_import, {}
				}
			}
			last_import = msg.origin.kind == .None ? -1 : i
		}
		row.shape.parts += {.Body}
		row.shape.head = msg_run_step(&run, msg, ui.timeline_metric.x)
		append(&rows, row)
	}
	if len(rows) == 0 {return}
	ui.timeline_entries = rows[:]
	if nendo.box(nendo.id("TimelineRows"))(
	{width = nendo.grow(), direction = .Column, gap = TIMELINE_GAP},
	) {
		view := nendo.scroll(nendo.id("Timeline"))
		if !view.found {
			for &row in rows {timeline_draw_entry(&row, ui, messages, profile)}
			return
		}
		offsets := make([]f32, len(rows) + 1, context.temp_allocator)
		for first := 0; first < len(rows); {
			end := first
			for end < len(rows) {
				row := &rows[end]
				msg := &messages[row.index]
				height := timeline_cached_height(ui, msg, row.shape)
				if height <= 0 {break}
				offsets[end - first + 1] = offsets[end - first] + height
				end += 1
			}
			if end > first {
				// The Timeline owns scrolling. Each fit column ends with one measured run.
				id := u32(rows[first].index)
				if nendo.box(nendo.id("TimelineSpan", id))(
				{width = nendo.grow(), direction = .Column},
				) {
					window := nendo.virtual_rows(
						nendo.id("TimelineWindow", id),
						offsets[:end - first + 1],
						gap = TIMELINE_GAP,
						overscan = view.viewport.height,
					)
					for &row in rows[first + window.first:first + window.end] {
						timeline_draw_entry(&row, ui, messages, profile)
					}
				}
			}
			if end < len(rows) {
				timeline_draw_entry(&rows[end], ui, messages, profile)
				end += 1
			}
			first = end
		}
	}
}

@(private = "file")
timeline_draw_entry :: proc(
	row: ^Timeline_Entry,
	ui: ^Ui_State,
	messages: []Msg_Ui,
	profile: ^Device_Profile,
) {
	row.mounted = true
	msg := &messages[row.index]
	index := u32(row.index)
	if !timeline_has_markers(row.shape) {
		timeline_draw_body(index, msg^, row.shape.head)
		return
	}
	if nendo.box(nendo.id("TimelineEntry", index))(
	{width = nendo.grow(), direction = .Column, gap = TIMELINE_GAP},
	) {
		if .Unread in row.shape.parts {
			if nendo.box(nendo.id("UnreadMarker"))(
			{
				width = nendo.grow(),
				gap = 12,
				align = {y = .Center},
				padding = {left = 16, right = 16, top = 6, bottom = 2},
			},
			) {
				rule := nendo.Box {
					width  = nendo.grow(),
					height = nendo.fixed(1),
					color  = ACCENT_DIM,
				}
				if nendo.box(nendo.id("UnreadLineL"))(rule) {}
				nendo.text(
					tr("• NEW MESSAGES •"),
					{font = FONT_MONO, size = 10, color = ACCENT, spacing = 2},
				)
				if nendo.box(nendo.id("UnreadLineR"))(rule) {}
			}
		}
		if .Day in row.shape.parts {
			if nendo.box(nendo.id("DayMarker", index))(
			{direction = .Column, padding = {left = 16, right = 16, top = 10, bottom = 4}},
			) {
				nendo.text(
					msg.day,
					{font = FONT_BODY, size = 12, color = TEXT_DIM, spacing = 1, wrap = .None},
				)
			}
		}
		if row.shape.blocked >
		   0 {blocked_run_row(index, row.shape.blocked, ui.blocked_open[msg.id])}
		if .Import in row.shape.parts {
			history_import_divider(msg.id, messages[row.import_from].origin, profile)
		}
		if .Body in row.shape.parts {timeline_draw_body(index, msg^, row.shape.head)}
	}
}

@(private = "file")
timeline_draw_body :: proc(index: u32, msg: Msg_Ui, head: Msg_Head) {
	if msg.system {system_row(index, msg)} else {message_row(index, msg, head)}
}

@(private = "file")
history_import_progress :: proc(profile: ^Device_Profile, group: string) {
	item := profile.view.history_by_group[group]
	if item == nil || item.state.tag != .RECEIVING {return}
	retrying := item.state.body.receiving.retrying
	if nendo.box(nendo.id(retrying ? "HistoryImportRetrying" : "HistoryImportReceiving"))(
	{width = nendo.grow(), padding = nendo.pad(12), gap = 8, align = {y = .Center}, color = CARD},
	) {
		device_emblem(ICON_DOWNLOAD, retrying ? WARNING : ACCENT)
		if nendo.box(nendo.id_local("HistoryActivity"))(
		{width = nendo.grow(), direction = .Column, gap = 6},
		) {
			nendo.text(
				retrying ? tr("Still trying to bring earlier messages from your other device…") : tr("Bringing earlier messages from your other device…"),
				{font = FONT_BODY, size = 12, color = TEXT},
			)
			busy_bar("HistoryImportBusy")
		}
	}
}

@(private = "file")
history_import_divider :: proc(
	message_id: string,
	origin: Message_Origin,
	profile: ^Device_Profile,
) {
	// One line, so a roster rename cannot move the rows below this marker.
	if nendo.box(nendo.id("HistoryImportDivider", nendo.id(message_id).id))(
	{
		width = nendo.grow(),
		height = nendo.fixed(28),
		padding = {left = 16, right = 16},
		gap = 8,
		align = {y = .Center},
		clip = {x = true, y = true},
	},
	) {
		label: string
		switch origin.kind {
		case .None:
			return
		case .Backup:
			label = tr("Messages above were restored from a backup")
		case .Device:
			name := origin.label
			if profile != nil && .Roster in profile.known {
				name = profile.view.roster_labels[origin.slot]
			}
			if name == "" {name = tr("another device")}
			label = fmt.tprintf(tr("Messages above were imported from %s"), name)
		}
		nendo.text(ICON_DOWNLOAD, {font = FONT_ICON, size = 11, color = ACCENT_DIM})
		nendo.text(label, {font = FONT_BODY, size = 12, color = TEXT_DIM, wrap = .None})
	}
}

// The peer of the selected 1:1 chat when you blocked them, "" otherwise.
// That DM keeps its history but loses its composer (blocked_bar).
@(private)
blocked_peer :: proc(ui: ^Ui_State) -> string {
	peer := chat_peer(ui)
	if peer == "" || !ui.blocked[peer] {return ""}
	return peer
}

@(private = "file")
blocked_bar :: proc() {
	if nendo.box(nendo.id("BlockedBar"))(
	{
		width = nendo.grow(),
		padding = nendo.pad(16),
		gap = 10,
		direction = single_pane() ? .Column : .Row,
		align = {y = .Center},
		color = ROW_BG,
	},
	) {
		nendo.text(
			tr("You can't send messages to someone you blocked."),
			{font = FONT_BODY, size = 14, color = TEXT},
		)
		login_button("BlockedUnblock", tr("Unblock"))
	}
}

// The info page's content column width. The page itself fills the chat
// area; only its content keeps a readable measure.
panel_target :: proc(ui: ^Ui_State) -> f32 {
	return f32(clamp(ui.prefs.panel_w, PANEL_W_MIN, PANEL_W_MAX))
}

@(private)
compose_tool :: proc(color: nendo.Color) -> nendo.Box {
	size := nendo.fit(min = tap_size() ? tap_min() : 0)
	return {
		width = size,
		height = size,
		padding = nendo.pad(4),
		align = {x = .Center, y = .Center},
		color = color,
		radius = rr(6),
	}
}

// The previous layout gives the draft's height, capped so the timeline stays visible.
@(private = "file")
compose_draft_height :: proc(chrome: f32) -> f32 {
	if single_pane() && f32(rl.GetScreenHeight()) / UI_ZOOM < 400 {return 20}
	limit := min(240, f32(rl.GetScreenHeight()) / UI_ZOOM * 0.35) - chrome
	return clamp(nendo.element(nendo.id("ComposeText")).rect.height, 20, max(20, limit))
}

@(private = "file")
compose_view: struct {
	head, length: int,
	size:         nendo.Dimensions,
	row:          u32,
}

// Follow edits and caret moves, but leave manual scrolling alone.
@(private)
compose_scroll :: proc(ui: ^Ui_State) {
	buf := &ui.compose
	focus := Focus.Compose
	if ui.focus == .ContactNote {
		buf = &ui.contact_edit.note
		focus = .ContactNote
	} else if ui.page == .Profile && ui.profile.editing {
		buf = &ui.about_input
		focus = .About
	} else if ui.show_members && ui.desc_editing {
		buf = &ui.desc_input
		focus = .Desc
	} else if ui.page == .Chats && ui.poll_open {
		buf = &ui.poll_question
		focus = .PollQ
	}
	data := nendo.scroll(nendo.id("ComposeClip"))
	if ui.focus != focus || !data.found {
		compose_view.head = -1
		return
	}
	_, _, head := field_sel(ui, buf)
	size := data.viewport
	if compose_view.head == head &&
	   compose_view.length == len(buf) &&
	   compose_view.size == size {return}
	compose_view.head, compose_view.length, compose_view.size = head, len(buf), size
	row := nendo.element(nendo.id("ComposeLine", compose_view.row)).rect
	clip := nendo.element(nendo.id("ComposeClip")).rect
	delta := min(row.y - clip.y, 0) + max(row.y + row.height - clip.y - clip.height, 0)
	data.position.y = clamp(data.position.y - delta, min(size.height - data.content.height, 0), 0)
	if delta != 0 {anim_moving += 1}
}

// The group info view is two separate pages: Settings (what the group is
// and how it behaves) and Members (who is in it). Each has its own chip
// in the chat header; the header's title also opens Settings.
Info_Tab :: enum u8 {
	Settings,
	Members,
}

// Readable measure for the page's single column.
@(private = "file")
INFO_COL_MAX :: f32(600)

members_panel :: proc(ui: ^Ui_State) {
	if nendo.box(nendo.id("MembersPanel"))(
	{width = nendo.grow(), height = nendo.grow(), direction = .Column, color = RAIL_BG},
	) {
		col_w := min(info_width(ui), INFO_COL_MAX)
		info_top_bar(ui, col_w)
		if nendo.box(nendo.id("MembersScroll"))(
		{
			width = nendo.grow(),
			height = nendo.grow(),
			direction = .Column,
			padding = {left = 14, right = 14, top = 4, bottom = 24},
			align = {x = .Center},
			clip = {y = true, scroll = true},
		},
		) {
			if nendo.box(nendo.id("InfoColumn"))(
			{width = nendo.fixed(col_w), direction = .Column, gap = 14},
			) {
				switch ui.info_tab {
				case .Settings:
					info_settings_page(ui, col_w)
				case .Members:
					if selected_chat_is_dm(ui) {
						info_settings_page(ui, col_w)
					} else {
						info_members_page(ui, col_w)
					}
				}
			}
		}
		scrollbar(nendo.id("MembersScroll"))
	}
}

// The page's title over the card column, with close at its right edge.
@(private = "file")
info_top_bar :: proc(ui: ^Ui_State, col_w: f32) {
	if nendo.box(nendo.id("MembersHead"))(
	{
		width = nendo.grow(),
		padding = {left = 14, right = 14, top = 16, bottom = 12},
		align = {x = .Center},
	},
	) {
		if nendo.box(nendo.id("MembersHeadRow"))(
		{width = nendo.fixed(col_w), gap = 10, align = {y = .Center}},
		) {
			dm := selected_chat_is_dm(ui)
			members := !dm && ui.info_tab == .Members
			nendo.text(
				dm ? tr("Chat details") : members ? tr("Members") : tr("Group settings"),
				{font = FONT_TITLE, size = 20, color = TEXT},
			)
			if members {
				nendo.text(
					fmt.tprintf("%d", len(ui.members)),
					{font = FONT_MONO, size = 13, color = TEXT_LO},
				)
			}
			if nendo.box(nendo.id("MembersHeadGap"))({width = nendo.grow()}) {}
			if nendo.box(nendo.id("MembersClose"))(
			{
				width = nendo.fixed(tap_size() ? tap_min() : 30),
				height = nendo.fixed(tap_size() ? tap_min() : 30),
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : {},
				radius = rr(8),
			},
			) {
				nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 12, color = TEXT_DIM})
				if hovered() {
					tooltip(tr("Close"))
					cursor_raise(.Pointer)
				}
			}
		}
	}
}

// One rounded plate of the info page, holding one setting or one list.
@(private = "file")
info_card :: proc() -> nendo.Box {
	return {
		width = nendo.grow(),
		direction = .Column,
		padding = nendo.pad(16),
		gap = 12,
		color = CARD,
		radius = rr(12),
		border = {color = CARD_BORDER, width = bw()},
	}
}

// A text box with its primary action beside it.
@(private = "file")
info_field :: proc(
	ui: ^Ui_State,
	id_str: string,
	buf: ^[dynamic]u8,
	hint: string,
	focus: Focus,
	button_id: string,
	button_label: string,
) {
	if nendo.box(nendo.id_local("FieldRow"))(
	{
		width = nendo.grow(),
		direction = single_pane() ? .Column : .Row,
		gap = 8,
		align = {y = .Center},
	},
	) {
		if nendo.box(nendo.id(id_str))(
		{
			width = nendo.grow(),
			height = nendo.fixed(tap_size() ? tap_min() : 36),
			padding = {left = 12, right = 12},
			align = {y = .Center},
			color = ROW_BG,
			radius = rr(9),
			border = {color = ui.focus == focus ? ACCENT : FIELD_BORDER, width = bw()},
		},
		) {
			field_text(ui, id_str, buf, hint, ui.focus == focus)
		}
		folder_action(
			button_id,
			button_label,
			button_id != "InviteBtn" || len(strings.trim_space(string(buf[:]))) > 0,
		)
	}
}

// The scroll area's usable width, from last frame's box capped by the
// window (an inflated stale box during a shrink must not feed back).
@(private = "file")
info_width :: proc(ui: ^Ui_State) -> f32 {
	w := panel_target(ui)
	if box, ok := element_box(nendo.id("MembersScroll")); ok {
		avail := page_w(ui)
		w = min(box.width, avail)
	}
	return max(1, min(w, page_w(ui)) - 28) // the scroll's own side padding
}

@(private)
conversation_exit_kind :: proc(ui: ^Ui_State) -> Confirm_Kind {
	if ui.selected < 0 || len(ui.members) == 0 {return .None}
	chat := ui.chats[ui.selected]
	if chat.pending || conversation_deleting(ui.account_ref, chat.group_id) {return .None}
	if len(ui.members) == 1 && ui.members[0].is_self {
		return .Delete_Group
	}
	return chat_is_dm(chat) ? .Leave_Chat : .Leave_Group
}

// Settings: the group's face, then its controls and destructive action.
@(private = "file")
info_settings_page :: proc(ui: ^Ui_State, col_w: f32) {
	admin := self_is_admin(ui)
	dm := selected_chat_is_dm(ui)
	notes := ui.selected >= 0 && ui.chats[ui.selected].group_id == ui.prefs.notes_group
	if nendo.box(nendo.id("InfoHeroCard"))(info_card()) {
		group_hero(ui)
		if notes {
			nendo.text(
				tr("These settings and messages are only yours."),
				{font = FONT_BODY, size = 12, color = TEXT_DIM},
			)
		}
	}

	activation_card(ui, info_card())
	if admin && !dm {
		if nendo.box(nendo.id("InfoNameCard"))(info_card()) {
			row_labels(
				notes ? tr("Notes name") : tr("Group name"),
				notes ? tr("Only you see this name.") : tr("Everyone in the group sees the new name."),
			)
			info_field(
				ui,
				"RenameBox",
				&ui.rename_input,
				tr("New name"),
				.Rename,
				"RenameBtn",
				tr("Rename"),
			)
		}
	}

	// Group timer, an MLS setting shared by every member; MDK
	// stamps each new message and prunes after expiry.
	if nendo.box(nendo.id("InfoTimerCard"))(info_card()) {
		row_labels(
			tr("Disappearing messages"),
			notes ? tr("Your existing and new notes are deleted after this time.") : tr("Messages already in the chat, and new ones, are deleted for everyone after this time."),
		)
		// Members see the current timer without controls to change it.
		if !admin {
			nendo.text(
				retention_text(ui.group_retention),
				{font = FONT_TITLE, size = 12, color = TEXT_DIM},
			)
		} else {
			retention_choices("RetentionRow", DETAIL_RETENTION_KEYS, ui.group_retention)
		}
	}

	info_relays_card(ui, col_w - 32, dm ? tr("Chat relays") : tr("Group relays"))

	if nendo.box(nendo.id("InfoExportCard"))(info_card()) {
		if nendo.box(nendo.id("ExportRow"))(
		{
			width = nendo.grow(),
			direction = single_pane() ? .Column : .Row,
			gap = 8,
			align = {y = .Center},
		},
		) {
			row_labels(tr("Export chat"), tr("Save a copy of this conversation to a file."))
			if nendo.box(nendo.id("ExportButtons"))({gap = 8}) {
				micro_button("ExportHtmlBtn", "HTML")
				micro_button("ExportMdBtn", "Markdown")
			}
		}
	}

	shared_media_grid(ui, col_w - 32) // the card's side padding

	kind := conversation_exit_kind(ui)
	if kind == .None {return}
	deleting := kind == .Delete_Group
	// The one destructive action sits last, apart from the settings.
	if nendo.box(nendo.id(deleting ? "DeleteConversationBtn" : "LeaveBtn"))(
	{
		width = nendo.grow(),
		padding = nendo.pad(16),
		gap = 14,
		align = {y = .Center},
		color = hovered() ? HOVER : CARD,
		radius = rr(12),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		nendo.text(deleting ? ICON_TRASH : ICON_BAN, {font = FONT_ICON, size = 15, color = DANGER})
		if deleting {
			row_labels(tr("Delete group"), tr("Remove the conversation from this device."), DANGER)
		} else {
			row_labels(
				dm ? tr("Leave chat") : tr("Leave group"),
				tr("You will stop receiving its messages."),
				DANGER,
			)
		}
		if hovered() {cursor_raise(.Pointer)}
	}
}

@(private = "file")
info_relays_card :: proc(ui: ^Ui_State, width: f32, title: string) {
	if nendo.box(nendo.id("InfoRelaysCard"))(info_card()) {
		row_labels(
			title,
			tr(
				"These relays carry encrypted messages for this conversation. This list does not show connection status.",
			),
		)
		switch ui.group_relays_status {
		case .Loading:
			nendo.text(tr("Loading relays…"), {font = FONT_BODY, size = 12, color = TEXT_DIM})
			busy_bar("InfoRelaysBusy")
		case .Failed:
			nendo.text(
				tr("Couldn't load relays. Please try again."),
				{font = FONT_BODY, size = 12, color = TEXT_DIM},
			)
			micro_button("InfoRelaysRetry", tr("Retry"))
		case .Ready:
			if len(ui.group_relays) == 0 {
				nendo.text(
					tr("No relays configured."),
					{font = FONT_BODY, size = 12, color = TEXT_DIM},
				)
			}
			inset :: 8
			gap :: 8
			icon_w :: 16
			address_w := max(1, width - 2 * inset - gap - icon_w)
			seed := group_relay_seed(ui)
			for url in ui.group_relays {
				if nendo.box(nendo.id(url, seed))(
				{
					width = nendo.grow(),
					height = nendo.fit(min = tap_size() ? tap_min() : 0),
					padding = nendo.pad(inset),
					gap = gap,
					align = {y = .Center},
					color = hovered() ? HOVER : ROW_BG,
					radius = rr(8),
				},
				) {
					if nendo.box(nendo.id_local("RelayAddress"))(
					{width = nendo.grow(), direction = .Column},
					) {
						for line in wrapped_lines(url, address_w, 12, .Plain) {
							nendo.text(
								url[line.start:line.end],
								{font = FONT_BODY, size = 12, color = TEXT, wrap = .None},
							)
						}
					}
					if nendo.box(nendo.id_local("RelayCopyIcon"))(
					{width = nendo.fixed(icon_w), align = {x = .Center}},
					) {
						nendo.text(ICON_COPY, {font = FONT_ICON, size = 12, color = TEXT_DIM})
					}
					if hovered() {
						tooltip(tr("Copy"))
						cursor_raise(.Pointer)
					}
				}
			}
		}
	}
}

@(private = "file")
MEMBER_HEIGHT :: 48
@(private = "file")
MEMBER_GAP :: 6
@(private = "file")
MEMBER_NICK_HEIGHT :: 28
@(private = "file")
MEMBER_CARD_PAD :: 8

// Only admins can invite, so the member list decides whether you see the
// invite box. False while the list is still loading.
@(private)
self_is_admin :: proc(ui: ^Ui_State) -> bool {
	for member in ui.members {
		if member.is_self {
			return member.is_admin
		}
	}
	return false
}

// Members: inviting someone (admins only), then everyone in the group.
@(private = "file")
info_members_page :: proc(ui: ^Ui_State, col_w: f32) {
	if selected_chat_is_dm(ui) {return}
	if self_is_admin(ui) {
		if nendo.box(nendo.id("InfoInviteCard"))(info_card()) {
			row_labels(tr("Add member"), "")
			info_field(
				ui,
				"InviteBox",
				&ui.invite_input,
				tr("Public key or verified address"),
				.Invite,
				"InviteBtn",
				ui.nip05_ticket != 0 ? tr("Looking up...") : strings.contains(string(ui.invite_input[:]), "@") ? tr("Look up") : tr("Invite"),
			)
		}
	}

	// Rows carry their own inset and hover fill, so the list card hugs them.
	list_card := info_card()
	list_card.padding = nendo.pad(MEMBER_CARD_PAD)
	if nendo.box(nendo.id("InfoMembersCard"))(list_card) {
		if members_job != nil && len(ui.members) == 0 {
			nendo.text(tr("Loading…"), {font = FONT_BODY, size = 13, color = TEXT_DIM})
		}
		if nendo.box(nendo.id("MembersList"))(
		{width = nendo.grow(), direction = .Column, gap = MEMBER_GAP},
		) {
			member_rows(ui, max(1, col_w - 2 * MEMBER_CARD_PAD))
		}
	}
}

@(private = "file")
member_rows :: proc(ui: ^Ui_State, width: f32) {
	count := len(ui.members)
	nick := ui.member_nick
	if nick < 0 || nick >= count {
		member_run(ui.members[:], 0, count)
		return
	}

	// Keep the focused field mounted and size its prompt before windowing the rows below it.
	member_run(ui.members[:], 0, nick)
	member_row(&ui.members[nick], u32(nick))
	PROMPT_SIZE :: u16(12)
	prompt := fmt.tprintf(tr("Nickname for %s"), ui.members[nick].name)
	if nendo.box(nendo.id("MemberNickPrompt"))({width = nendo.grow(), direction = .Column}) {
		for line in wrapped_lines(prompt, width, PROMPT_SIZE, .Plain) {
			text := prompt[line.start:line.end]
			if strings.trim_space(text) == "" {
				if nendo.box(nendo.id_local("Blank", line.index))(
				{height = nendo.fixed(f32(PROMPT_SIZE) * rl.TextScale)},
				) {}
				continue
			}
			nendo.text(
				text,
				{font = FONT_BODY, size = PROMPT_SIZE, color = TEXT_DIM, wrap = .None},
			)
		}
	}
	if nendo.box(nendo.id("MemberNickBox"))(
	{
		width = nendo.grow(),
		height = nendo.fixed(tap_size() ? tap_min() : MEMBER_NICK_HEIGHT),
		padding = {left = 8, right = 8},
		align = {y = .Center},
		color = ROW_BG,
		radius = rr(6),
		border = nendo.Border{color = ACCENT, width = bw()},
	},
	) {
		field_text(
			ui,
			"MemberNickBox",
			&ui.nick_input,
			tr("Nickname"),
			ui.focus == .Nick,
			12,
			TEXT_LO,
		)
	}
	if nendo.box(nendo.id("MemberNickActions", u32(nick)))({gap = 8}) {
		folder_action("MemberNickSave", tr("Save"), true)
		micro_button("MemberNickCancel", tr("Cancel"))
	}
	member_run(ui.members[:], nick + 1, count)
}

@(private = "file")
member_run :: proc(members: []Member_Ui, start, end: int) {
	if start == end {
		return
	}
	window := nendo.virtual_rows(
		nendo.id("MemberRows", u32(start)),
		end - start,
		MEMBER_HEIGHT,
		gap = MEMBER_GAP,
	)
	for i in start + window.first ..< start + window.end {
		member_row(&members[i], u32(i))
	}
}

@(private = "file")
member_row :: proc(member: ^Member_Ui, index: u32) {
	if nendo.box(nendo.id("MemberRow", index))(
	{
		width = nendo.grow(),
		height = nendo.fixed(MEMBER_HEIGHT),
		padding = {left = 8, right = 6},
		gap = 10,
		align = {y = .Center},
		color = hovered() ? HOVER : {},
		radius = rr(8),
	},
	) {
		avatar(
			"MemberAvatar",
			index,
			member.id_hex,
			member.name,
			36,
			person_picture(member.id_hex, member.pic_url),
		)

		if nendo.box(nendo.id("MemberCol", index))(
		{width = nendo.grow(), direction = .Column, gap = 1, clip = {x = true}},
		) {
			if nendo.box(nendo.id("MemberName", index))(
			{width = nendo.grow(), gap = 6, align = {y = .Center}},
			) {
				nendo.text(member.name, {font = FONT_TITLE, size = 13, color = TEXT})
				if member.is_self {
					if nendo.box(nendo.id("MemberYou", index))(
					{
						padding = {left = 6, right = 6, top = 1, bottom = 1},
						color = SELECTED,
						radius = rr(5),
					},
					) {
						nendo.text(
							tr("YOU"),
							{font = FONT_MONO, size = 9, color = ACCENT, spacing = 1},
						)
					}
				}
			}
			// Admin marker rides the subline, so the name stays quiet.
			nendo.text(
				member.is_admin ? tr("Admin") : npub_tail(member.npub),
				{
					font = member.is_admin ? FONT_TITLE : FONT_MONO,
					size = 10,
					color = member.is_admin ? ACCENT : TEXT_LO,
				},
			)
		}
		// A non-admin self row has no action to offer.
		if !member.is_self || member.is_admin {
			if nendo.box(nendo.id("MemberMenuBtn", index))(
			{
				width = nendo.fixed(tap_size() ? tap_min() : 26),
				height = nendo.fixed(tap_size() ? tap_min() : 26),
				align = {x = .Center, y = .Center},
				color = hovered() ? SELECTED : {},
				radius = rr(6),
			},
			) {
				nendo.text("...", {font = FONT_TITLE, size = 13, color = TEXT_DIM})
			}
		}
	}
}

// Timer chip presets, in seconds; 0 disables.
@(private)
RETENTION_SECS := [5]u64{0, 3600, 86400, 604800, 2419200}
@(private)
DETAIL_RETENTION_KEYS :: [len(RETENTION_SECS)]string {
	"RetChip0",
	"RetChip1",
	"RetChip2",
	"RetChip3",
	"RetChip4",
}
@(private)
NC_RETENTION_KEYS := [len(RETENTION_SECS)]string {
	"NCRetention0",
	"NCRetention1",
	"NCRetention2",
	"NCRetention3",
	"NCRetention4",
}

@(private)
retention_choices :: proc(
	row: string,
	keys: [len(RETENTION_SECS)]string,
	current: u64,
	focus := "",
) {
	labels := [len(RETENTION_SECS)]string{tr("Off"), "1h", "1d", "1w", "4w"}
	if nendo.box(nendo.id(row))(
	{
		width = nendo.grow(),
		padding = nendo.pad(3),
		gap = 2,
		clip = {x = true, scroll = true},
		color = ROW_BG,
		radius = rr(10),
		border = {color = FIELD_BORDER, width = bw()},
	},
	) {
		for key, i in keys {
			active := current == RETENTION_SECS[i]
			if nendo.box(nendo.id(key))(
			{
				width = nendo.fit(min = tap_size() ? tap_min() : 0),
				height = nendo.fit(min = tap_size() ? tap_min() : 0),
				padding = {left = 14, right = 14, top = 6, bottom = 6},
				align = {x = .Center, y = .Center},
				color = active ? ACCENT : (hovered() ? HOVER : {}),
				border = key == focus ? kb_ring(active ? ON_ACCENT : ACCENT) : {},
				radius = rr(7),
			},
			) {
				nendo.text(
					labels[i],
					{font = FONT_TITLE, size = 12, color = active ? ON_ACCENT : TEXT_DIM},
				)
				if hovered() && !active {cursor_raise(.Pointer)}
			}
		}
	}
	scrollbar(nendo.id(row))
}

@(private)
reveal_retention_choice :: proc(row: string, choice: nendo.Id) {
	container := nendo.id(row)
	scroll := nendo.scroll(container)
	button := nendo.element(choice)
	if !scroll.found || !button.found {return}
	view := nendo.element(container).rect
	box := button.rect
	if box.x < view.x {
		scroll.position.x += view.x - box.x
	} else if box.x + box.width > view.x + view.width {
		scroll.position.x -= box.x + box.width - view.x - view.width
	}
}

@(private)
retention_text :: proc(secs: u64) -> string {
	if secs == 0 {return tr("Off")}
	units := [?]struct {
		secs:             u64,
		singular, plural: string,
	} {
		{86400, N_("%d day"), N_("%d days")},
		{3600, N_("%d hour"), N_("%d hours")},
		{60, N_("%d minute"), N_("%d minutes")},
		{1, N_("%d second"), N_("%d seconds")},
	}
	remaining := secs
	parts: [len(units)]string
	count := 0
	for unit in units {
		n := remaining / unit.secs
		if n == 0 {continue}
		parts[count] = fmt.tprintf(tr(n == 1 ? unit.singular : unit.plural), n)
		count += 1
		remaining %= unit.secs
	}
	return strings.join(parts[:count], ", ", context.temp_allocator)
}

SHARED_MEDIA_CAP :: 60
SHARED_MEDIA_COLS :: 3

// SHARED MEDIA section of the info panel: the open conversation's
// loaded images as square thumbnails, newest first. A click opens the
// lightbox slideshow on that image (via img_hover, like timeline
// tiles). Square cells stretch the texture; nendo has no cover-crop.
@(private = "file")
shared_media_grid :: proc(ui: ^Ui_State, col_w: f32) {
	Thumb :: struct {
		msg_id: string,
		att:    int,
		tex:    ^rl.Texture2D,
	}
	thumbs := make([dynamic]Thumb, context.temp_allocator)
	total := 0
	for i := len(ui.messages) - 1; i >= 0; i -= 1 {
		for slot, att in ui.messages[i].attachments {
			if slot.kind != .Image && slot.kind != .Sticker {continue}
			tex := slot.view.(^rl.Texture2D) or_continue
			total += 1
			if len(thumbs) < SHARED_MEDIA_CAP {
				append(&thumbs, Thumb{ui.messages[i].id, att, tex})
			}
		}
	}
	if total == 0 {
		return
	}

	if nendo.box(nendo.id("InfoMediaCard"))(info_card()) {
		row_labels(tr("Shared media"), "")
		cell := (col_w - 12) / SHARED_MEDIA_COLS // minus the two 6px gaps
		if nendo.box(nendo.id("SharedMedia"))({direction = .Column, gap = 6}) {
			for row := 0; row * SHARED_MEDIA_COLS < len(thumbs); row += 1 {
				if nendo.box(nendo.id("SharedMediaRow", u32(row)))({gap = 6}) {
					for t, c in thumbs[row * SHARED_MEDIA_COLS:min((row + 1) * SHARED_MEDIA_COLS, len(thumbs))] {
						if nendo.box(
							nendo.id("SharedMediaCell", u32(row * SHARED_MEDIA_COLS + c)),
						)(
							{
								width = nendo.fixed(cell),
								height = nendo.fixed(cell),
								image = t.tex,
								radius = rr(6),
							},
						) {
							if hovered() {
								img_hover = {
									msg_id = t.msg_id,
									att    = t.att,
								}
							}
						}
					}
				}
			}
		}
		if total > len(thumbs) {
			nendo.text(
				fmt.tprintf(tr("+%d more"), total - len(thumbs)),
				{font = FONT_BODY, size = 11, color = TEXT_DIM},
			)
		}
	}
}

// The text row of an input box: placeholder, or the value with the
// selection highlighted and the caret at the selection head. Also the
// element (id_str, 1) that field_mouse hit-tests against.
field_text :: proc(
	ui: ^Ui_State,
	id_str: string,
	buf: ^[dynamic]u8,
	placeholder: string,
	focused: bool,
	font_size: u16 = 13,
	ph_color: nendo.Color = {},
) {
	if focused && rl.HasTouch() {touch_field = nendo.id(id_str)}
	// Clip inside the parent's padding; keep the selection head in view.
	view := nendo.element(nendo.id(id_str, 3))
	offset: f32
	if focused && len(buf) > 0 && view.found {
		_, _, head := field_sel(ui, buf)
		x := rl.MeasureTextLine(FONT_BODY, font_size, string(buf[:head]), 0).x
		offset = max(0, x + CARET_W - view.rect.width)
	}
	if nendo.box(nendo.id(id_str, 3))(
	{width = nendo.grow(), align = {y = .Center}, clip = {x = true, offset = {-offset, 0}}},
	) {
		if nendo.box(nendo.id(id_str, 1))({align = {y = .Center}}) {
			if nendo.hovered() {
				cursor_raise(.Text)
			}
			caret_h := f32(font_size) + 1
			if len(buf) == 0 {
				// Caret first: typing starts at the left edge, not after the hint.
				if focused {
					caret(caret_h)
				}
				ph := ph_color
				if ph.a == 0 {
					ph = TEXT_DIM
				}
				nendo.text(
					placeholder,
					{font = FONT_BODY, size = font_size, color = ph, wrap = .None},
				)
			} else {
				text := string(buf[:])
				lo, hi, head := field_sel(ui, buf)
				if lo > 0 {
					nendo.text(
						text[:lo],
						{font = FONT_BODY, size = font_size, color = TEXT, wrap = .None},
					)
				}
				if focused && head == lo {
					caret(caret_h)
				}
				if hi > lo {
					if nendo.box(nendo.id(id_str, 2))({color = ACCENT}) {
						nendo.text(
							text[lo:hi],
							{font = FONT_BODY, size = font_size, color = ON_ACCENT, wrap = .None},
						)
					}
					if focused && head == hi {
						caret(caret_h)
					}
				}
				if hi < len(text) {
					nendo.text(
						text[hi:],
						{font = FONT_BODY, size = font_size, color = TEXT, wrap = .None},
					)
				}
			}
		}
	}
}

// Labeled single-line input box; active border while focused.
// width 0 grows to fill the row.
input_box :: proc(
	ui: ^Ui_State,
	id_str: string,
	buf: ^[dynamic]u8,
	placeholder: string,
	active: bool,
	width: f32 = 420,
) {
	if nendo.box(nendo.id(id_str))(
	{
		width = width > 0 && !single_pane() ? nendo.fixed(width) : nendo.grow(),
		height = nendo.fixed(tap_size() ? tap_min() : 38),
		padding = {left = 12, right = 12},
		align = {y = .Center},
		color = ROW_BG,
		radius = rr(8),
		// A resting border keeps the box visible on ROW_BG cards.
		border = active ? focus_border(true) : {color = FIELD_BORDER, width = bw()},
	},
	) {
		field_text(ui, id_str, buf, placeholder, active, 14)
	}
}

// Empty timeline: a centred plate, not a sentence stranded in the
// top-left under the session divider. Grows into whatever height the
// dividers above it leave, so it holds the middle of the pane.
// An applied search that matched nothing says so and offers the way
// back, instead of claiming the chat itself is empty.
empty_timeline :: proc(ui: ^Ui_State) {
	notes := ui.selected >= 0 && ui.chats[ui.selected].group_id == ui.prefs.notes_group
	searched := timeline_job != nil && len(timeline_job.search) > 0
	title, hint := tr("No messages yet"), tr("Send the first message to start the conversation.")
	if notes {
		title, hint =
			tr("Your own notepad"),
			tr("Anything you write here stays between you and this device's key.")
	}
	if searched {
		title, hint = tr("No matching messages"), tr("Try a different search.")
	}
	if nendo.box(nendo.id("EmptyTL"))(
	{
		width = nendo.grow(),
		height = nendo.grow(),
		direction = .Column,
		align = {x = .Center, y = .Center},
		gap = 12,
	},
	) {
		// Ringed glyph, the same circle language as an avatar.
		if nendo.box(nendo.id("EmptyTLRing"))(
		{
			width = nendo.fixed(64),
			height = nendo.fixed(64),
			align = {x = .Center, y = .Center},
			color = PLATE,
			radius = rr(32),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			nendo.text(
				searched ? ICON_SEARCH : notes ? ICON_PENCIL : ICON_CHATS,
				{font = FONT_ICON, size = 24, color = ACCENT_DIM},
			)
		}
		nendo.text(title, {font = FONT_TITLE, size = 18, color = TEXT})
		nendo.text(hint, {font = FONT_BODY, size = 13, color = TEXT_DIM})
		if searched {
			micro_button("TimelineClearSearch", tr("Clear search"))
		}
	}
}

@(private)
Nc_Page :: enum {
	Contacts,
	Group,
}

@(private)
Nc_Created :: struct {
	id:              string,
	skipped:         int,
	photo_requested: bool,
}

@(private)
Nc_Member :: struct {
	hex, label, pic_url: string,
}

@(private)
NC_CONTACT_H :: f32(64)

@(private)
nc_pending_label :: proc(ui: ^Ui_State) -> string {
	for job in account_jobs {
		if job.account == ui.account_ref && job.form != nil {
			return account_pending_label(job.kind)
		}
	}
	if ui.nip05_ticket != 0 {return tr("Looking up...")}
	return ""
}

// Both shortcut rows use the same generous hit target as the contact list.
@(private = "file")
nc_action_row :: proc(id, icon, title, detail: string) {
	if nendo.box(nendo.id(id))(
	{
		width = nendo.grow(),
		padding = nendo.pad(12),
		gap = 14,
		align = {y = .Center},
		color = hovered() ? HOVER : ROW_BG,
		radius = rr(12),
	},
	) {
		if nendo.box(nendo.id(id, 1))(
		{
			width = nendo.fixed(40),
			height = nendo.fixed(40),
			align = {x = .Center, y = .Center},
			color = HOVER,
			radius = rr(20),
		},
		) {nendo.text(icon, {font = FONT_ICON, size = 16, color = ACCENT})}
		if nendo.box(nendo.id(id, 2))({width = nendo.grow(), direction = .Column, gap = 4}) {
			nendo.text(title, {font = FONT_TITLE, size = 15, color = TEXT})
			nendo.text(detail, {font = FONT_BODY, size = 12, color = TEXT_DIM})
		}
		nendo.text(ICON_RIGHT, {font = FONT_ICON, size = 12, color = TEXT_LO})
	}
}

@(private)
nc_contact_matches :: proc(
	ui: ^Ui_State,
	query: string,
	excluded: map[string]bool = nil,
) -> []Contact_Order {
	filter := strings.to_lower(strings.trim_space(query), context.temp_allocator)
	rows := contact_order(ui, ui.nc_contacts[:])
	// Short queries search names, not the shared npub prefix or single hex digits.
	key_query := len(filter) >= 4
	count := 0
	for row in rows {
		contact := ui.nc_contacts[row.idx]
		if excluded[contact.id_hex] {continue}
		if filter != "" &&
		   !strings.contains(row.key, filter) &&
		   (!key_query ||
				   (!strings.contains(contact.npub, filter) &&
						   !strings.contains(contact.id_hex, filter))) {continue}
		rows[count] = row
		count += 1
	}
	return rows[:count]
}

@(private)
nc_pasted_members :: proc(ui: ^Ui_State, text: string) -> []string {
	if !strings.contains(text, ",") {
		hex := nc_address_hex(ui, text)
		if hex == "" {return nil}
		keys := make([]string, 1, context.temp_allocator)
		keys[0] = hex
		return keys
	}
	keys := strings.split(text, ",", context.temp_allocator)
	for &key in keys {
		key = nc_address_hex(ui, key)
		if key == "" {return nil}
	}
	return keys
}

// Pubkey hex of a pasted npub, nprofile, hex key or marmot://profile link;
// "" for anything else and for your own key.
@(private)
nc_address_hex :: proc(ui: ^Ui_State, text: string) -> string {
	ref := strings.trim_space(text)
	if link := marmot_link_ref(ref); link != "" {ref = link}
	hx := deeplink_hex(ref)
	if strings.equal_fold(hx, ui.account_ref) {return ""}
	return hx
}

@(private)
nc_member_rows :: proc(ui: ^Ui_State) -> (rows: []Contact_Order, people: []int) {
	excluded := make(map[string]bool, len(ui.nc_members), context.temp_allocator)
	for member in ui.nc_members {excluded[member.hex] = true}
	rows = nc_contact_matches(ui, string(ui.nc_member[:]), excluded)
	people = people_rows(ui, rows, excluded)
	return
}

@(private)
NC_MEMBER_H :: f32(48)

@(private = "file")
nc_member_options :: proc(ui: ^Ui_State, query: string) {
	rows, people := nc_member_rows(ui)
	count := len(rows) + len(people)
	lines := count
	if ui.people.status != .Idle && ui.people.status != .Done {lines += 1}
	if lines == 0 && (query == "" || strings.contains(query, "@")) {return}
	ui.nc_contact_sel = clamp(ui.nc_contact_sel, 0, max(0, count - 1))
	height := f32(clamp(lines, 1, 3)) * NC_MEMBER_H
	if nendo.box(nendo.id("NCMemberOptions"))(
	{
		width = nendo.grow(),
		height = nendo.fixed(height),
		direction = .Column,
		color = CARD,
		border = {color = CARD_BORDER, width = bw()},
		radius = rr(8),
		align = {y = lines == 0 ? .Center : .Top},
		clip = {y = true, scroll = true},
	},
	) {
		if lines == 0 {
			if nendo.box(nendo.id("NCMemberEmpty"))({padding = {left = 12, right = 12}}) {
				nendo.text(tr("No matches"), {font = FONT_BODY, size = 13, color = TEXT_DIM})
			}
		} else {
			window := nendo.virtual_rows(nendo.id("NCMemberRows"), lines, NC_MEMBER_H)
			for i in window.first ..< window.end {
				lit := i == ui.nc_contact_sel
				if i == count {
					people_status_row(ui, nendo.fixed(NC_MEMBER_H))
				} else if i < len(rows) {
					contact := ui.nc_contacts[rows[i].idx]
					label := contact_label(ui, contact)
					nc_member_option(
						"NCMemberOption",
						u32(rows[i].idx),
						contact.id_hex,
						label,
						npub_tail(contact.npub),
						contact.pic_url,
						lit,
					)
				} else {
					at := people[i - len(rows)]
					hit := ui.people.hits[at]
					nc_member_option(
						"NCMemberPerson",
						u32(at),
						hit.id_hex,
						people_label(ui, hit),
						people_sublabel(hit),
						hit.pic_url,
						lit,
					)
				}
			}
		}
	}
	scrollbar(nendo.id("NCMemberOptions"), 16)
}

@(private = "file")
nc_selected_members :: proc(ui: ^Ui_State) {
	if len(ui.nc_members) == 0 {return}
	row_h := tap_size() ? tap_min() : 30
	if nendo.box(nendo.id("NCSelectedMembers"))({width = nendo.grow(), direction = .Column}) {
		for member, i in ui.nc_members {
			if nendo.box(nendo.id("NCMemberPicked", u32(i)))(
			{width = nendo.grow(), height = nendo.fixed(row_h), align = {y = .Center}, gap = 8},
			) {
				pic_url := profile_info(g_client, member.hex).pic_url
				if pic_url == "" {pic_url = member.pic_url}
				avatar(
					"NCMemberPickedAvatar",
					u32(i),
					member.hex,
					member.label,
					22,
					person_picture(member.hex, pic_url),
				)
				if nendo.box(nendo.id_local("Name"))({width = nendo.grow(), clip = {x = true}}) {
					nendo.text(
						member.label,
						{font = FONT_BODY, size = 14, color = TEXT, wrap = .None},
					)
				}
				if nendo.box(nendo.id("NCMemberRemove", u32(i)))(
				{
					width = nendo.fixed(row_h),
					height = nendo.fixed(row_h),
					align = {x = .Center, y = .Center},
					color = hovered() ? HOVER : {},
					border = ui.focus == .NC_Remove && ui.nc_remove_focus == i ? kb_ring(ACCENT) : {},
					radius = rr(7),
				},
				) {
					nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 12, color = TEXT_DIM})
					if hovered() {tooltip(tr("Remove")); cursor_raise(.Pointer)}
				}
			}
		}
	}
}

// One group-member suggestion: a contact, or a person the directory found.
@(private = "file")
nc_member_option :: proc(id: string, index: u32, hex, label, sub, pic_url: string, lit: bool) {
	if nendo.box(nendo.id(id, index))(
	{
		width = nendo.grow(),
		height = nendo.fixed(NC_MEMBER_H),
		padding = {left = 10, right = 10},
		gap = 10,
		align = {y = .Center},
		color = lit ? SELECTED : hovered() ? HOVER : {},
		clip = {x = true},
	},
	) {
		avatar(fmt.tprintf("%sAvatar", id), index, hex, label, 28, person_picture(hex, pic_url))
		row_labels(label, sub)
		if hovered() {cursor_raise(.Pointer)}
	}
}

// One New chat row: a contact, or a person the directory search found.
@(private = "file")
nc_person_row :: proc(id: string, index: u32, hex, label, sub, pic_url: string, lit: bool) {
	if nendo.box(nendo.id(id, index))(
	{
		width = nendo.grow(),
		height = nendo.fixed(NC_CONTACT_H),
		padding = {left = 12, right = 12},
		gap = 14,
		align = {y = .Center},
		color = hovered() || lit ? HOVER : nendo.Color{},
		radius = rr(10),
	},
	) {
		avatar(fmt.tprintf("%sAvatar", id), index, hex, label, 40, person_picture(hex, pic_url))
		if nendo.box(nendo.id_local("Text"))(
		{width = nendo.grow(), direction = .Column, gap = 4, clip = {x = true}},
		) {
			nendo.text(label, {font = FONT_TITLE, size = 15, color = TEXT, wrap = .None})
			nendo.text(sub, {font = FONT_MONO, size = 11, color = TEXT_DIM, wrap = .None})
		}
		nendo.text(ICON_CHATS, {font = FONT_ICON, size = 14, color = TEXT_LO})
	}
}

// Directory search progress: a sweep while it runs, then a retry when a
// radius gave up or the search failed. Nothing once it has finished.
@(private = "file")
people_status_row :: proc(ui: ^Ui_State, height: nendo.Size) {
	status := ui.people.status
	if status == .Idle || status == .Done {return}
	if nendo.box(nendo.id("PeopleStatus"))(
	{
		width = nendo.grow(),
		height = height,
		padding = {left = 12, right = 12, top = 4, bottom = 4},
		gap = 10,
		align = {y = .Center},
	},
	) {
		text := tr("Searching the network...")
		if status == .Incomplete {text = tr("Some network results may be missing.")}
		if status == .Failed {text = tr("Couldn't search the network. Please try again.")}
		nendo.text(
			text,
			{
				font = FONT_BODY,
				size = 12,
				color = status == .Failed ? DANGER : TEXT_DIM,
				wrap = .None,
			},
		)
		if status == .Searching {
			busy_bar("PeopleBusy")
		} else {
			micro_button("PeopleRetry", tr("Try again"))
		}
	}
}

@(private = "file")
nc_contact_list :: proc(ui: ^Ui_State) {
	rows := nc_contact_matches(ui, string(ui.nc_search[:]))
	people := people_rows(ui, rows)
	count := len(rows) + len(people)
	ui.nc_contact_sel = clamp(ui.nc_contact_sel, 0, max(0, count - 1))
	if nendo.box(nendo.id("NCContactsCaption"))(
	{width = nendo.grow(), padding = {top = 14, bottom = 4}, gap = 8},
	) {
		// Network hits are people, not contacts yet.
		eyebrow(len(people) > 0 ? tr("PEOPLE") : tr("CONTACTS"))
		nendo.text(fmt.tprintf("%d", count), {font = FONT_BODY, size = 11, color = TEXT_LO})
	}
	people_status_row(ui, nendo.fit())
	if nendo.box(nendo.id("NCContacts"))(
	{
		width = nendo.grow(),
		height = nendo.grow(),
		direction = .Column,
		clip = {y = true, scroll = true},
	},
	) {
		if count == 0 {
			loading := false
			for job in account_jobs {if job.account == ui.account_ref && job.kind == .Read_Contacts {loading = true; break}}
			address := nc_address_hex(ui, string(ui.nc_search[:]))
			if address != "" {
				npub := hex_npub(address)
				defer delete(npub)
				if nendo.box(nendo.id("NCStartAddress"))(
				{
					width = nendo.grow(),
					height = nendo.fit(min = 64),
					padding = nendo.pad(12),
					gap = 12,
					align = {y = .Center},
					color = hovered() ? HOVER : ROW_BG,
					radius = rr(10),
				},
				) {
					avatar(
						"NCAddressAvatar",
						0,
						address,
						sender_label(address),
						40,
						person_picture(address, profile_cached(address).pic_url),
					)
					if nendo.box(nendo.id("NCAddressText"))(
					{width = nendo.grow(), direction = .Column, gap = 4, clip = {x = true}},
					) {
						nendo.text(
							sender_label(address),
							{font = FONT_TITLE, size = 15, color = TEXT, wrap = .None},
						)
						nendo.text(
							existing_dm(ui, address) >= 0 ? tr("Open chat") : tr("Start chat"),
							{font = FONT_BODY, size = 13, color = TEXT_DIM},
						)
						nendo.text(npub_tail(npub), {font = FONT_MONO, size = 11, color = TEXT_LO})
					}
				}
			} else if ui.people.status == .Searching {
				// The status row above the list already says the network is
				// being searched. Keep this a separate branch: nendo.box closes
				// its element when the `if` ends, so it must never sit behind `&&`.
			} else if nendo.box(nendo.id("NCEmptyContacts"))(
			{
				width = nendo.grow(),
				direction = .Column,
				gap = 8,
				padding = {top = 12, bottom = 12},
			},
			) {
				query := strings.trim_space(string(ui.nc_search[:]))
				searching := len(query) > 0
				invalid_key :=
					strings.has_prefix(strings.to_lower(query, context.temp_allocator), "npub1") &&
					deeplink_hex(query) == ""
				nendo.text(
					invalid_key ? tr("This key has a typo.") : loading ? tr("Loading your contacts") : searching ? tr("No matches") : tr("No contacts yet"),
					{font = FONT_TITLE, size = 16, color = TEXT},
				)
				if invalid_key || !loading {
					nendo.text(
						invalid_key ? tr("Check each character against the original and try again.") : searching ? tr("Check the spelling, or paste their public key.") : tr("People you follow show up here. To start a chat now, search for someone by name or paste their public key above."),
						{font = FONT_BODY, size = 13, color = TEXT_DIM},
					)
				}
				if loading {busy_bar("NCContactsBusy")}
			}
		} else {
			window := nendo.virtual_rows(nendo.id("NCContactRows"), count, NC_CONTACT_H)
			for i in window.first ..< window.end {
				lit := ui.focus == .NC_Search && ui.nc_contact_sel == i
				if i < len(rows) {
					contact := ui.nc_contacts[rows[i].idx]
					nc_person_row(
						"NCContact",
						u32(rows[i].idx),
						contact.id_hex,
						contact_label(ui, contact),
						existing_dm(ui, contact.id_hex) >= 0 ? tr("Open chat") : npub_tail(contact.npub),
						contact.pic_url,
						lit,
					)
					continue
				}
				at := people[i - len(rows)]
				hit := ui.people.hits[at]
				nc_person_row(
					"NCPerson",
					u32(at),
					hit.id_hex,
					people_label(ui, hit),
					existing_dm(ui, hit.id_hex) >= 0 ? tr("Open chat") : people_sublabel(hit),
					hit.pic_url,
					lit,
				)
			}
		}
	}
	scrollbar(nendo.id("NCContacts"))
}

new_chat_pane :: proc(ui: ^Ui_State) {
	defer scrollbar(nendo.id("NewChatPane"))
	pending := nc_pending_label(ui)
	group := ui.nc_page == .Group
	retry_open := ui.nc_created.id != ""
	no_contacts := len(ui.nc_contacts) == 0
	for job in account_jobs {if job.account == ui.account_ref && job.kind == .Read_Contacts {no_contacts = false; break}}
	if nendo.box(nendo.id("NewChatPane"))(
	{
		width = nendo.grow(),
		height = nendo.grow(),
		padding = nendo.pad(single_pane() ? 12 : 24),
		direction = .Column,
		align = {x = .Center},
		clip = {y = true, scroll = true},
	},
	) {
		if nendo.box(nendo.id("NCContent"))(
		{
			width = nendo.grow(max = 640),
			height = nendo.grow(min = single_pane() ? 340 : 0),
			direction = .Column,
			gap = 12,
		},
		) {
			if nendo.box(nendo.id("NCHeader"))(
			{
				width = nendo.grow(),
				align = {y = .Center},
				gap = 12,
				padding = {top = 8, bottom = 8},
			},
			) {
				header_chip(
					group && pending == "" && !retry_open ? "NCBack" : "NCCancel",
					"\uf060",
					false,
					tr("Back"),
				)
				if nendo.box(nendo.id("NCTitle"))(
				{width = nendo.grow(), direction = .Column, gap = 6},
				) {
					nendo.text(
						group ? tr("New group") : tr("New chat"),
						{font = FONT_TITLE, size = 26, color = TEXT},
					)
					if !retry_open {
						nendo.text(
							group ? tr("Give your group a name and a photo.") : no_contacts ? tr("Search for someone or paste their public key to start a chat.") : tr("Choose someone to talk to."),
							{font = FONT_BODY, size = 14, color = TEXT_DIM},
						)
					}
				}
			}
			if retry_open {
				if pending == "" {login_big_button("NCRetryOpen", tr("Retry"), true)}
			} else if !group {
				input_box(
					ui,
					"NCSearch",
					&ui.nc_search,
					tr("Search by name or Nostr address, or paste a public key..."),
					ui.focus == .NC_Search,
					0,
				)
				nc_action_row(
					"NCGroup",
					ICON_PEOPLE,
					tr("New group"),
					tr("Start a group and invite people."),
				)
				nc_contact_list(ui)
			} else {
				if nendo.box(nendo.id("NCForm"))(
				{
					width = nendo.grow(),
					height = nendo.grow(min = 44),
					direction = .Column,
					gap = 10,
					clip = {y = true, scroll = true},
				},
				) {
					if nendo.box(nendo.id("NCPicture"))(
					{
						width = nendo.grow(),
						padding = {bottom = 8},
						align = {y = .Center},
						gap = 16,
					},
					) {
						// Previewed from the trimmed name the group is created with.
						name := strings.trim_space(string(ui.nc_name[:]))
						if len(ui.nc_pic.data) > 0 || len(name) > 0 {
							avatar("NCPic", 0, "", name, 64, nc_pic_tex(ui))
						} else if nendo.box(nendo.id("NCPicPlaceholder"))(
						{
							width = nendo.fixed(64),
							height = nendo.fixed(64),
							align = {x = .Center, y = .Center},
							color = HOVER,
							radius = rr(32),
						},
						) {nendo.text(ICON_PEOPLE, {font = FONT_ICON, size = 24, color = ACCENT})}
						if nendo.box(nendo.id("NCPicActions"))({direction = .Column, gap = 8}) {
							micro_button("NCPicFile", tr("Choose image"))
							micro_button("NCPicEmoji", tr("Create from emoji"))
							if len(ui.nc_pic.data) > 0 {micro_button("NCPicRemove", tr("Remove"))}
						}
					}
					nendo.text(tr("Group name"), {font = FONT_TITLE, size = 14, color = TEXT})
					input_box(ui, "NCName", &ui.nc_name, tr("Group name"), ui.focus == .NC_Name, 0)
					if nendo.box(nendo.id("NCMemberHeading"))({gap = 8, align = {y = .Center}}) {
						nendo.text(tr("Members"), {font = FONT_TITLE, size = 14, color = TEXT})
						if len(ui.nc_members) > 0 {
							nendo.text(
								fmt.tprintf("%d", len(ui.nc_members)),
								{font = FONT_BODY, size = 12, color = TEXT_DIM},
							)
						}
					}
					query := strings.trim_space(string(ui.nc_member[:]))
					pasted := len(nc_pasted_members(ui, query)) > 0
					lookup := strings.contains(query, "@") && !strings.contains(query, ",")
					if nendo.box(nendo.id("NCMemberSearch"))(
					{width = nendo.grow(), align = {y = .Center}, gap = 8},
					) {
						input_box(
							ui,
							"NCMember",
							&ui.nc_member,
							tr("Search by name or paste public keys..."),
							ui.focus == .NC_Member,
							0,
						)
						if pending == "" && (pasted || lookup) {
							micro_button("NCMemberAdd", pasted ? tr("Add") : tr("Look up"))
						}
					}
					if ui.focus == .NC_Member && pending == "" && !pasted {
						nc_member_options(ui, query)
					}
					nc_selected_members(ui)
					nendo.text(tr("Description"), {font = FONT_TITLE, size = 14, color = TEXT})
					input_box(
						ui,
						"NCDescription",
						&ui.nc_description,
						tr("Description"),
						ui.focus == .NC_Description,
						0,
					)
					nendo.text(
						tr("Disappearing messages"),
						{font = FONT_TITLE, size = 14, color = TEXT},
					)
					focus :=
						ui.focus == .NC_Retention ? NC_RETENTION_KEYS[ui.nc_retention_focus] : ""
					retention_choices("NCRetention", NC_RETENTION_KEYS, ui.nc_retention, focus)
				}
				scrollbar(nendo.id("NCForm"))
			}
			if pending != "" {
				nendo.text(pending, {font = FONT_BODY, size = 13, color = ACCENT})
				busy_bar("NCBusy")
			}
			if group && !retry_open {
				label := pending != "" ? pending : tr("Create group")
				named := strings.trim_space(string(ui.nc_name[:])) != ""
				ready := pending == "" && named && len(ui.nc_members) > 0
				login_big_button("NCCreate", label, true, ready ? .Enabled : .Disabled)
			}
			if nendo.box(nendo.id("NCPrivacy"))(
			{
				width = nendo.grow(),
				align = {x = .Center, y = .Center},
				gap = 8,
				padding = {top = 4},
			},
			) {
				nendo.text(ICON_LOCK, {font = FONT_ICON, size = 11, color = TEXT_LO})
				nendo.text(
					tr("End-to-end encrypted"),
					{font = FONT_BODY, size = 12, color = TEXT_DIM},
				)
			}
		}
	}
}

// Apply this frame's typing (chars, backspace, Ctrl+V paste) to buf.
// Key press including OS key-repeat, so held arrows/backspace repeat.

// Uses the chat composer's wrapping, selection, IME, and caret hit testing.
@(private)
multiline_field :: proc(
	ui: ^Ui_State,
	buf: ^[dynamic]u8,
	focus: Focus,
	placeholder: string,
	height: f32,
) {
	mode := focus == .ContactNote ? Wrap_Mode.Plain : .Compose
	if nendo.box(nendo.id("ComposeBox"))(
	{
		width = nendo.grow(),
		padding = nendo.pad(10),
		color = ROW_BG,
		border = ui.focus == focus ? focus_border(true) : nendo.Border{color = FIELD_BORDER, width = bw()},
		radius = rr(8),
	},
	) {
		if nendo.box(nendo.id("ComposeClip"))(
		{
			width = nendo.grow(),
			height = nendo.fixed(height),
			direction = .Column,
			clip = {x = true, y = true, scroll = true},
		},
		) {
			if len(buf) == 0 && len(rl.Preedit()) == 0 {
				compose_view.row = 0
				if nendo.box(nendo.id("ComposeLine", 0))({gap = 1, align = {y = .Center}}) {
					if ui.focus == focus {
						caret()
					}
					nendo.text(placeholder, {font = FONT_BODY, size = BODY_FS, color = TEXT_DIM})
				}
			} else {
				text := string(buf[:])
				lo, hi, head := field_sel(ui, buf)
				if ui.focus != focus {head = -1}
				for line, i in compose_lines(text, mode = mode) {
					h := head
					if head == line[0] && line[0] > 0 && text[line[0] - 1] != '\n' {h = -1}
					compose_line(u32(i), text, line[0], line[1], lo, hi, h, mode)
					if h >= line[0] && h <= line[1] {compose_view.row = u32(i)}
				}
			}
		}
		scrollbar(nendo.id("ComposeClip"))
	}
}

@(private)
chat_composer :: proc(ui: ^Ui_State) {
	if ui.selected >= 0 && ui.chats[ui.selected].archived {
		if nendo.box(nendo.id("ArchivedCompose"))(
		{width = nendo.grow(), padding = nendo.pad(16), color = RAIL_BG},
		) {
			nendo.text(
				tr("This chat is archived. Restore it from Archive to send messages."),
				{font = FONT_BODY, size = 13, color = TEXT_DIM},
			)
		}
		return
	}
	if blocked_peer(ui) != "" {
		blocked_bar()
		return
	}
	placement := ui.editing != "" ? Thread_Placement.Ready : thread_placement_state(ui)
	poll_suspended := ui.poll_open && ui.search_open
	if (poll_suspended && ui.poll_ticket == 0) || (ui.timestamp.open && ui.search_open) {return}
	// Edit banner: the composer holds a sent message, not a new one.
	// It stands in for the reply banner, which returns once the edit ends.
	if len(ui.editing) > 0 {
		if nendo.box(nendo.id("EditBanner"))(
		{
			width = nendo.grow(),
			padding = {left = 16, right = 16, top = 6, bottom = 6},
			gap = 8,
			align = {y = .Center},
			color = RAIL_BG,
		},
		) {
			nendo.text(ICON_PENCIL, {font = FONT_ICON, size = 12, color = ACCENT})
			nendo.text(tr("Editing message"), {font = FONT_BODY, size = 12, color = TEXT_DIM})
			action_chip("EditCancel", 0, tr("Cancel"))
		}
	} else if !ui.poll_open && len(ui.replying) > 0 {
		if nendo.box(nendo.id("ReplyBanner"))(
		{
			width = nendo.grow(),
			padding = {left = 16, right = 8, top = 4, bottom = 4},
			gap = 8,
			align = {y = .Center},
			color = ROW_BG,
			border = {color = ACCENT, width = {left = 3}},
		},
		) {
			from, snippet := tr("Replying"), ui.reply_hint
			for msg in ui.messages {
				if msg.id != ui.replying {continue}
				from, snippet = msg.sender, msg_preview(msg)
				if nick := ui.nicknames[msg.sender_id]; nick != "" {from = nick}
				break
			}
			if nendo.box(nendo.id("ReplyBannerText"))(
			{width = nendo.grow(), direction = .Column, gap = 2, clip = {x = true}},
			) {
				nendo.text(
					text_ellipsis(from, max(1, page_w(ui) - 90), FONT_TITLE, 12),
					{font = FONT_TITLE, size = 12, color = ACCENT, wrap = .None},
				)
				nendo.text(
					text_ellipsis(snippet, max(1, page_w(ui) - 90), FONT_BODY, 12),
					{font = FONT_BODY, size = 12, color = TEXT_DIM, wrap = .None},
				)
			}
			header_icon("ReplyCancel", ICON_CLOSE, tr("Cancel reply"))
		}
	}

	padding := u16(single_pane() ? (f32(rl.GetScreenHeight()) / UI_ZOOM < 500 ? 4 : 8) : 16)
	if nendo.box(nendo.id("Composer"))(
	{width = nendo.grow(), padding = nendo.pad(padding), gap = 8, direction = .Column},
	) {
		burst_pane_layer() // own send's effect rises from here
		if placement != .Ready {
			nendo.text(
				thread_placement_text(placement),
				{font = FONT_BODY, size = 13, color = TEXT_DIM},
			)
			if placement == .Checking {busy_bar("ThreadPlacementBusy")}
			if placement == .Error {action_chip("ThreadPlacementRetry", 0, tr("Try again"))}
		}
		if ui.poll_ticket != 0 {
			nendo.text(tr("Sending..."), {font = FONT_BODY, size = 12, color = TEXT_DIM})
			busy_bar("PollBusy")
			if single_pane() && short_conversation(ui) {return}
		}
		if poll_suspended {return}
		// A capped scrollable list keeps every removal control reachable
		// without letting attachments widen or consume the chat pane.
		if !ui.poll_open && !ui.timestamp.open && len(ui.staged) > 0 {
			if nendo.box(nendo.id("StagedRow"))(
			{
				width = nendo.grow(),
				height = nendo.fit(max = 144),
				direction = .Column,
				gap = 8,
				clip = {y = true, scroll = true},
			},
			) {
				for f, i in ui.staged {
					if nendo.box(nendo.id("StagedChip", u32(i)))(
					{
						width = nendo.grow(),
						padding = nendo.pad(6),
						gap = 6,
						align = {y = .Center},
						color = ROW_BG,
						radius = rr(10),
						border = {color = FIELD_BORDER, width = bw()},
					},
					) {
						if f.tex != nil {
							ratio := f.tex.height > 0 ? f32(f.tex.width) / f32(f.tex.height) : 1
							if nendo.box(nendo.id("StagedThumb", u32(i)))(
							{
								width = nendo.fixed(min(80, 40 * ratio)),
								aspect = ratio,
								image = f.tex,
								radius = rr(6),
							},
							) {}
						} else {
							nendo.text(ICON_CLIP, {font = FONT_ICON, size = 12, color = TEXT_LO})
						}
						name := f.name
						if len(name) > 28 {
							name = fmt.tprintf("%s…", name[:rune_snap(name, 28)])
						}
						if nendo.box(nendo.id("StagedName", u32(i)))(
						{width = nendo.grow(), direction = .Column, gap = 4, clip = {x = true}},
						) {
							nendo.text(
								name,
								{font = FONT_BODY, size = 12, color = TEXT, wrap = .None},
							)
							if f.load != nil {
								nendo.text(
									tr("Preparing attachment…"),
									{font = FONT_BODY, size = 12, color = TEXT_LO},
								)
								busy_bar(fmt.tprintf("StagedBusy%d", i))
							} else {
								nendo.text(
									human_size(i64(len(f.data))),
									{font = FONT_BODY, size = 12, color = TEXT_LO},
								)
							}
						}
						if nendo.box(nendo.id("StagedX", u32(i)))(
							compose_tool(hovered() ? HOVER : {}),
						) {
							nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 10, color = TEXT_DIM})
						}
					}
				}
			}
			scrollbar(nendo.id("StagedRow"))
		}
		if voice_active() {
			voice_bar()
		} else {
			width := page_w(ui)
			if ui.prefs.centered_chat {width = min(width, CHAT_WIDTH_MAX)}
			composer_edit(ui, width - 2 * f32(padding) - 32, placement == .Ready)
		}
	}
}


@(private = "file")
composer_edit :: proc(ui: ^Ui_State, width: f32, can_send: bool) {
	focus := ui.timestamp.open ? Focus.Timestamp : ui.poll_open ? .PollQ : .Compose
	active := ui.focus == focus && ui.poll_ticket == 0
	if nendo.box(nendo.id("ComposeBox"))(
	{
		width = nendo.grow(),
		direction = .Column,
		gap = ui.timestamp.open ? 6 : 8,
		padding = {left = 16, right = 16, top = 8, bottom = 8},
		color = PLATE,
		radius = rr(8),
		border = {color = active ? ACCENT_DIM : FIELD_BORDER, width = bw()},
	},
	) {
		if ui.timestamp.open {timestamp_picker(ui); return}
		plan := composer_plan(ui, composer_config(&ui.prefs), width)
		buf := ui.poll_open ? &ui.poll_question : &ui.compose
		text := string(buf[:])
		inline_width := ui.poll_open ? width - 2 * (plan.size + f32(plan.gap)) : plan.inline_width
		placeholder :=
			ui.poll_open ? tr("Ask a question...") : (len(ui.thread_stack) > 0 ? tr("Reply in thread…") : tr("Send a message..."))
		inline :=
			plan.config.layout == .Automatic &&
			inline_width >= COMPOSER_TEXT_MIN &&
			wrap_break(text, 0, len(text), inline_width - CARET_W, BODY_FS, .Compose) ==
				len(text) &&
			strings.index_byte(text, '\n') < 0
		if ui.page == .Chats && !ui.poll_open {
			if open_now(nendo.id("MentionPop"), ui.mention_active) {mention_popover(ui)}
			if open_now(nendo.id("ShortcodePop"), ui.shortcode_active) {shortcode_popover(ui)}
			if slash_open(ui) {slash_popover(ui)}
			if open_now(nendo.id("FxPanel"), ui.fx_open) {effect_picker(ui)}
		}
		if !inline {
			composer_draft(
				ui,
				buf,
				focus,
				placeholder,
				width,
				compose_draft_height(24 + plan.size),
			)
		}
		if nendo.box(nendo.id("ComposeTools"))(
		{
			width = nendo.grow(),
			height = nendo.fixed(plan.size),
			gap = plan.gap,
			align = {y = .Center},
		},
		) {
			if ui.poll_open {
				if nendo.box(nendo.id("PollCancel"))(
				{
					width = nendo.fixed(plan.size),
					height = nendo.fixed(plan.size),
					align = {x = .Center, y = .Center},
					color = ui.poll_ticket == 0 && hovered() ? HOVER : {},
					radius = rr(6),
				},
				) {
					if ui.poll_ticket == 0 && hovered() {tooltip(tr("Cancel"))}
					nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 14, color = TEXT_DIM})
				}
			} else if can_send {
				composer_tools(ui, plan, .Left)
			}
			if inline {
				composer_draft(ui, buf, focus, placeholder, inline_width, 20)
			} else if nendo.box(nendo.id("ComposeGap"))({width = nendo.grow()}) {}
			if !ui.poll_open && can_send {composer_tools(ui, plan, .Right)}
			if can_send {composer_primary(ui, plan)}
		}
		if ui.poll_open {
			poll_fields(ui, width)
		} else if ui.page == .Chats && ui.compose_more && can_send {
			composer_menu(ui, plan)
		}
	}
}

@(private = "file")
composer_draft :: proc(
	ui: ^Ui_State,
	buf: ^[dynamic]u8,
	focus: Focus,
	placeholder: string,
	width, height: f32,
) {
	text := string(buf[:])
	active := ui.focus == focus && ui.poll_ticket == 0
	if nendo.box(nendo.id("ComposeClip"))(
	{
		width = nendo.grow(),
		height = nendo.fixed(height),
		clip = {x = true, y = true, scroll = true},
	},
	) {
		if nendo.hovered() {cursor_raise(.Text)}
		if nendo.box(nendo.id("ComposeText"))(
		{width = nendo.grow(), direction = .Column, gap = 2},
		) {
			if text == "" && (!active || len(rl.Preedit()) == 0) {
				compose_view.row = 0
				if nendo.box(nendo.id("ComposeLine", 0))({gap = 1, align = {y = .Center}}) {
					if active {caret()}
					nendo.text(
						placeholder,
						{font = FONT_BODY, size = BODY_FS, color = TEXT_LO, wrap = .None},
					)
				}
			} else {
				lo, hi, head := field_sel(ui, buf)
				if !active {head = -1}
				for line, i in compose_lines(text, max(1, width - CARET_W)) {
					h := head
					// At a soft wrap, the caret belongs to the upper line.
					if h == line[0] && line[0] > 0 && text[line[0] - 1] != '\n' {h = -1}
					compose_line(u32(i), text, line[0], line[1], lo, hi, h)
					if h >= line[0] && h <= line[1] {compose_view.row = u32(i)}
				}
			}
		}
	}
	scrollbar(nendo.id("ComposeClip"))
}
