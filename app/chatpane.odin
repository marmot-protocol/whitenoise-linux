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
	preview := ui.chat_preview_w > 0
	// A phone header is one row: Back, the title, Search and an overflow
	// menu for the remaining chips.
	phone := single_pane()

	if nendo.box(nendo.id("ChatPane"))(
	{width = nendo.grow(), height = preview ? nendo.fit() : nendo.grow(), direction = .Column},
	) {
		if open_now(nendo.id("CtxMenu"), ui.ctx_open) &&
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
		if !preview && ui.fwd_kind != .Theme {
			if open_now(nendo.id("FwdModal"), ui.fwd_open) &&
			   (ui.fwd_kind == .Add_Member || forward_source(ui) >= 0) {
				forward_modal(ui)
			}
		}
		if open_now(nendo.id("OvModal"), ui.ov_open) {
			openverse_modal(ui)
		}
		if open_now(nendo.id("PollModal"), ui.poll_open) {
			poll_modal(ui)
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
			if phone && !preview {header_icon("ChatBack", "\u2039", tr("Back"))}
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
					title := chat.title
					if preview {
						width := nendo.element(nendo.id("ChatHeadTitleClip")).rect.width
						if width > 0 {title = text_ellipsis(title, width, FONT_TITLE, 16)}
					}
					nendo.text(title, {font = FONT_TITLE, size = 16, color = TEXT, wrap = .None})
					if !chat_is_dm(chat) && len(ui.members) > 0 {
						nendo.text(
							fmt.tprintf(
								tr(len(ui.members) == 1 ? N_("%d member") : N_("%d members")),
								len(ui.members),
							),
							{font = FONT_BODY, size = 11, color = TEXT_LO, wrap = .None},
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
			if len(ui.thread_stack) == 0 && !preview {
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
		if open_now(nendo.id("MiModal"), ui.mi_open) {
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
		{
			width = nendo.grow(),
			height = preview ? nendo.fit() : nendo.grow(),
			direction = .Row,
			align = {x = .Center},
		},
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
				height = preview ? nendo.fit() : nendo.grow(),
				direction = .Column,
			},
			) {
				// Timeline: a real scroll container, top-anchored.
				// Loads jump to the newest message.
				// The thread route's push/pop transition: content slides
				// home from a small offset.
				cur := thread_cur(ui)
				if nendo.box(nendo.id("Timeline"))(
				{
					width = nendo.grow(),
					height = preview ? nendo.fit(min = 260) : nendo.grow(),
					direction = .Column,
					padding = {left = u16(thread_slide()), top = 8, bottom = 8},
					gap = 2,
					clip = {y = !preview, scroll = true},
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
									ui.prefs.reduce_motion ? f32(0.5) : f32(rl.GetTime() - f64(int(rl.GetTime())))
								if !ui.prefs.reduce_motion {anim_moving += 1}
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
					} else if len(messages) == 0 && len(ui.pending) == 0 {
						empty_timeline(ui)
					}
					// The thread route filters the one timeline: the main
					// view shows unthreaded rows, a thread view shows its
					// pinned root and the rows tagged to it.
					if len(cur) > 0 {
						thread_root_plate(ui)
					}
					ui.timeline_metric = {body_wrap_w(), UI_SCALE, R_SCALE, chip_h()}
					run: Msg_Run
					wrap_w := body_wrap_w()
					blocked_at := -1 // first row of the blocked run in progress
					for msg, i in messages {
						if msg.thread_of != cur {
							continue
						}
						if len(ui.unread_mark_id) > 0 && msg.id == ui.unread_mark_id {
							run = {}
							blocked_at = -1
							// Center label between two rule lines.
							if nendo.box(nendo.id("UnreadMarker"))(
							{
								width = nendo.grow(),
								gap = 12,
								align = {y = .Center},
								padding = {left = 16, right = 16, top = 6, bottom = 2},
							},
							) {
								if nendo.box(nendo.id("UnreadLineL"))(
								{
									width = nendo.grow(),
									height = nendo.fixed(1),
									color = ACCENT_DIM,
								},
								) {}
								nendo.text(
									tr("• NEW MESSAGES •"),
									{font = FONT_MONO, size = 10, color = ACCENT, spacing = 2},
								)
								if nendo.box(nendo.id("UnreadLineR"))(
								{
									width = nendo.grow(),
									height = nendo.fixed(1),
									color = ACCENT_DIM,
								},
								) {}
							}
						}
						if i == 0 || msg.day != messages[i - 1].day {
							run = {}
							blocked_at = -1
							if nendo.box(nendo.id("DayMarker", u32(i)))(
							{
								direction = .Column,
								padding = {left = 16, right = 16, top = 10, bottom = 4},
							},
							) {
								nendo.text(
									msg.day,
									{
										font = FONT_BODY,
										size = 12,
										color = TEXT_DIM,
										spacing = 1,
										wrap = .None,
									},
								)
							}
						}
						// Grouping restarts on both sides of a blocked run, so a
						// collapsed run never glues its neighbours together.
						if !msg_blocked(ui, msg) {
							if blocked_at >= 0 {run = {}}
							blocked_at = -1
						} else {
							if blocked_at < 0 {
								blocked_at = i
								run = {}
								blocked_run_row(
									u32(i),
									blocked_run_len(ui, i),
									ui.blocked_open[msg.id],
								)
							}
							if !ui.blocked_open[messages[blocked_at].id] {continue}
						}
						head := msg_run_step(&run, msg, wrap_w)
						if timeline_skip(ui, msg) {
							if nendo.box(nendo.id(msg.system ? "SysRow" : "MsgRow", u32(i)))(
							{width = nendo.grow(), height = nendo.fixed(msg.row_height)},
							) {}
						} else if msg.system {
							system_row(u32(i), msg)
						} else {
							message_row(u32(i), msg, head)
						}
					}
					// Optimistic rows at the tail: unacked sends grayed,
					// failed ones danger with tap-to-retry.
					for p, i in ui.pending {
						if p.group_id == chat.group_id && p.thread == cur {
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

@(private = "file")
COMPOSE_TOOLS_H :: f32(28)
COMPOSE_CHROME_H :: f32(16 + 8) + COMPOSE_TOOLS_H // padding, gap, toolbar

@(private)
compose_chrome_height :: proc() -> f32 {
	return COMPOSE_CHROME_H + (tap_size() ? 16 : 0)
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

// Height of the input surface from last frame's text column. The surface
// and its clip use the same height so growing drafts never animate apart.
compose_height :: proc() -> f32 {
	minimum := f32(20) + compose_chrome_height()
	target := minimum
	if box := nendo.element(nendo.id("ComposeText")); box.found {
		target = max(minimum, box.rect.height + compose_chrome_height())
	}
	if single_pane() && f32(rl.GetScreenHeight()) / UI_ZOOM < 400 {return minimum}
	return min(target, max(minimum, min(240, f32(rl.GetScreenHeight()) / UI_ZOOM * 0.35)))
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
	if ui.page == .Profile && ui.profile.editing {
		buf = &ui.about_input
		focus = .About
	} else if ui.show_members && ui.desc_editing {
		buf = &ui.desc_input
		focus = .Desc
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
						info_members_page(ui)
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

// Settings: the group's face, one card per setting, then leaving.
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
		labels := [len(RETENTION_SECS)]string{N_("Off"), "1h", "1d", "1w", "4w"}
		// Members see the current timer without controls to change it.
		if !admin {
			nendo.text(
				retention_text(ui.group_retention),
				{font = FONT_TITLE, size = 12, color = TEXT_DIM},
			)
		} else {
			if nendo.box(nendo.id("RetentionRow"))(
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
				for secs, i in RETENTION_SECS {
					active := ui.group_retention == secs
					if nendo.box(nendo.id(fmt.tprintf("RetChip%d", i)))(
					{
						width = nendo.fit(min = tap_size() ? tap_min() : 0),
						height = nendo.fit(min = tap_size() ? tap_min() : 0),
						padding = {left = 14, right = 14, top = 6, bottom = 6},
						align = {x = .Center, y = .Center},
						color = active ? ACCENT : (hovered() ? HOVER : {}),
						radius = rr(7),
					},
					) {
						nendo.text(
							tr(labels[i]),
							{font = FONT_TITLE, size = 12, color = active ? ON_ACCENT : TEXT_DIM},
						)
						if hovered() && !active {cursor_raise(.Pointer)}
					}
				}
			}
			scrollbar(nendo.id("RetentionRow"))
		}
	}

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

	// The one destructive action sits last, apart from the settings.
	if nendo.box(nendo.id("LeaveBtn"))(
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
		nendo.text(ICON_BAN, {font = FONT_ICON, size = 15, color = DANGER})
		row_labels(
			dm ? tr("Leave chat") : tr("Leave group"),
			tr("You will stop receiving its messages."),
			DANGER,
		)
		if hovered() {cursor_raise(.Pointer)}
	}
}

@(private = "file")
MEMBER_HEIGHT :: 48
@(private = "file")
MEMBER_GAP :: 6
@(private = "file")
MEMBER_NICK_HEIGHT :: 28

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
info_members_page :: proc(ui: ^Ui_State) {
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
	list_card.padding = nendo.pad(8)
	if nendo.box(nendo.id("InfoMembersCard"))(list_card) {
		if members_job != nil && len(ui.members) == 0 {
			nendo.text(tr("Loading…"), {font = FONT_BODY, size = 13, color = TEXT_DIM})
		}
		if nendo.box(nendo.id("MembersList"))(
		{width = nendo.grow(), direction = .Column, gap = MEMBER_GAP},
		) {
			member_rows(ui)
		}
	}
}

// The member list. Rows keep their geometry off screen, but only rows
// near the viewport build names and queue avatars.
@(private = "file")
member_rows :: proc(ui: ^Ui_State) {
	nick_height := tap_size() ? tap_min() : MEMBER_NICK_HEIGHT
	data := nendo.scroll(nendo.id("MembersScroll"))
	view := nendo.element(nendo.id("MembersScroll"))
	first := nendo.element(nendo.id("MemberRow", 0))
	y := first.rect.y
	if data.found {
		y += data.position.y - ui.members_scroll_y
		ui.members_scroll_y = data.position.y
	}
	for member, i in ui.members {
		visible :=
			!data.found ||
			!first.found ||
			ui.member_nick == i ||
			y + MEMBER_HEIGHT >= view.rect.y - 2 * (MEMBER_HEIGHT + MEMBER_GAP) &&
				y <= view.rect.y + view.rect.height + 2 * (MEMBER_HEIGHT + MEMBER_GAP)
		y += f32(
			MEMBER_HEIGHT +
			MEMBER_GAP +
			(ui.member_nick == i ? nick_height + MEMBER_GAP + (tap_size() ? tap_min() : 28) + 30 : 0),
		)
		if nendo.box(nendo.id("MemberRow", u32(i)))(
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
			if !visible {continue}
			avatar("MemberAvatar", u32(i), member.id_hex, member.name, 36, url_pic(member.pic_url))
			if nendo.box(nendo.id("MemberCol", u32(i)))(
			{width = nendo.grow(), direction = .Column, gap = 1, clip = {x = true}},
			) {
				if nendo.box(nendo.id("MemberName", u32(i)))(
				{width = nendo.grow(), gap = 6, align = {y = .Center}},
				) {
					nendo.text(member.name, {font = FONT_TITLE, size = 13, color = TEXT})
					if member.is_self {
						if nendo.box(nendo.id("MemberYou", u32(i)))(
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
				if nendo.box(nendo.id("MemberMenuBtn", u32(i)))(
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
		// The nickname editor takes the row's place below it.
		if ui.member_nick == i {
			nendo.text(
				fmt.tprintf(tr("Nickname for %s"), member.name),
				{font = FONT_BODY, size = 12, color = TEXT_DIM},
			)
			// Only one editor is open. Keep index zero for the box so its
			// text child's index one cannot collide with a member index.
			if nendo.box(nendo.id("MemberNickBox"))(
			{
				width = nendo.grow(),
				height = nendo.fixed(f32(nick_height)),
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
			if nendo.box(nendo.id("MemberNickActions", u32(i)))({gap = 8}) {
				folder_action("MemberNickSave", tr("Save"), true)
				micro_button("MemberNickCancel", tr("Cancel"))
			}
		}
	}
}

// Timer chip presets, in seconds; 0 disables. Handlers index the same
// array, so chip N here is chip N there.
RETENTION_SECS :: [5]u64{0, 3600, 86400, 604800, 2419200}

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
NC_CONTACT_H :: f32(64)

@(private)
nc_pending_label :: proc(ui: ^Ui_State) -> string {
	for job in account_jobs {
		if job.account == ui.account_ref && job.kind == .Create_Chat && job.form {
			return tr("Creating your chat")
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
nc_contact_matches :: proc(ui: ^Ui_State, query: string) -> []Contact_Order {
	filter := strings.to_lower(strings.trim_space(query), context.temp_allocator)
	rows := contact_order(ui, ui.nc_contacts[:])
	// Short queries search names, not the shared npub prefix or single hex digits.
	key_query := len(filter) >= 4
	count := 0
	for row in rows {
		contact := ui.nc_contacts[row.idx]
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
nc_member_ref :: proc(ui: ^Ui_State) -> string {
	if ui.nc_member_choice > 0 && ui.nc_member_choice <= len(ui.nc_contacts) {
		contact := ui.nc_contacts[ui.nc_member_choice - 1]
		if string(ui.nc_member[:]) == contact_label(ui, contact) {return contact.id_hex}
	}
	member := strings.trim_space(string(ui.nc_member[:]))
	if member == "" {return member}
	if strings.contains(member, ",") {
		out := strings.builder_make(context.temp_allocator)
		for key in strings.split(member, ",", context.temp_allocator) {
			ref := strings.trim_space(key)
			if link := marmot_link_ref(ref); link != "" {ref = link}
			hx := deeplink_hex(ref)
			if hx == "" || strings.equal_fold(hx, ui.account_ref) {return ""}
			if len(out.buf) > 0 {strings.write_byte(&out, '\n')}
			strings.write_string(&out, hx)
		}
		return strings.to_string(out)
	}
	if strings.contains(member, "@") {return member}
	if ref := marmot_link_ref(member); ref != "" {member = ref}
	return deeplink_hex(member)
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
Nc_Member_Menu :: enum {
	Hidden,
	Contacts,
	No_Matches,
}

// An empty field or an address Create group accepts is not a failed search.
@(private)
nc_member_menu :: proc(query: string, matches: int, accepted: bool) -> Nc_Member_Menu {
	if matches > 0 {return .Contacts}
	if strings.trim_space(query) == "" || accepted {return .Hidden}
	return .No_Matches
}

@(private)
NC_MEMBER_H :: f32(48)

@(private = "file")
nc_member_options :: proc(ui: ^Ui_State) {
	if ui.nc_page != .Group ||
	   ui.focus != .NC_Member ||
	   ui.nc_member_choice != 0 ||
	   nc_pending_label(ui) != "" {return}
	field := nendo.element(nendo.id("NCMember"))
	if !field.found {return}
	rows := nc_contact_matches(ui, string(ui.nc_member[:]))
	count := len(rows)
	if nc_member_menu(string(ui.nc_member[:]), count, nc_member_ref(ui) != "") == .Hidden {return}
	ui.nc_contact_sel = clamp(ui.nc_contact_sel, 0, max(0, count - 1))
	below := nendo.element(nendo.id("NCCreate")).rect.y - field.rect.y - field.rect.height - 4
	header := nendo.element(nendo.id("NCHeader")).rect
	above := field.rect.y - header.y - header.height - 4
	up := below < NC_MEMBER_H * 2 && above > below
	height := min(
		f32(max(1, count)) * NC_MEMBER_H,
		NC_MEMBER_H * 5,
		max(NC_MEMBER_H, up ? above : below),
	)
	if nendo.box(nendo.id("NCMemberOptions"))(
	{
		width = nendo.fixed(field.rect.width),
		height = nendo.fixed(height),
		direction = .Column,
		color = CARD,
		border = {color = CARD_BORDER, width = bw()},
		radius = rr(8),
		clip = {y = true, scroll = true},
		floating = {
			attach_to = .Element,
			parent = nendo.id("NCMember").id,
			z = 15,
			offset = {0, up ? -4 : 4},
			attach = {
				element = up ? .Left_Bottom : .Left_Top,
				parent = up ? .Left_Top : .Left_Bottom,
			},
		},
	},
	) {
		data := nendo.scroll(nendo.id("NCMemberOptions"))
		if data.found {data.position.y = clamp(data.position.y, -max(0, f32(count) * NC_MEMBER_H - height), 0)}
		first := data.found ? clamp(int(-data.position.y / NC_MEMBER_H), 0, count) : 0
		last := min(first + 7, count)
		if nendo.box(nendo.id("NCMemberBefore"))(
		{height = nendo.fixed(f32(first) * NC_MEMBER_H)},
		) {}
		if count == 0 {
			nendo.text(tr("No matching contacts"), {font = FONT_BODY, size = 13, color = TEXT_DIM})
		}
		for row, i in rows[first:last] {
			contact := ui.nc_contacts[row.idx]
			if nendo.box(nendo.id("NCMemberOption", u32(row.idx)))(
			{
				width = nendo.grow(),
				height = nendo.fixed(NC_MEMBER_H),
				padding = {left = 10, right = 10},
				gap = 10,
				align = {y = .Center},
				color = first + i == ui.nc_contact_sel ? SELECTED : hovered() ? HOVER : {},
				clip = {x = true},
			},
			) {
				avatar(
					"NCMemberAvatar",
					u32(row.idx),
					contact.id_hex,
					contact_label(ui, contact),
					28,
					url_pic(contact.pic_url),
				)
				row_labels(contact_label(ui, contact), npub_tail(contact.npub))
				if hovered() {cursor_raise(.Pointer)}
			}
		}
		if nendo.box(nendo.id("NCMemberAfter"))(
		{height = nendo.fixed(f32(count - last) * NC_MEMBER_H)},
		) {}
	}
	scrollbar(nendo.id("NCMemberOptions"), 16)
}

@(private = "file")
nc_contact_list :: proc(ui: ^Ui_State) {
	rows := nc_contact_matches(ui, string(ui.nc_search[:]))
	count := len(rows)
	ui.nc_contact_sel = clamp(ui.nc_contact_sel, 0, max(0, count - 1))
	if nendo.box(nendo.id("NCContactsCaption"))(
	{width = nendo.grow(), padding = {top = 14, bottom = 4}, gap = 8},
	) {
		eyebrow(tr("CONTACTS"))
		nendo.text(fmt.tprintf("%d", count), {font = FONT_BODY, size = 11, color = TEXT_LO})
	}
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
						url_pic(profile_cached(address).pic_url),
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
					invalid_key ? tr("This key has a typo.") : loading ? tr("Loading your contacts") : searching ? tr("No matching contacts") : tr("No contacts yet"),
					{font = FONT_TITLE, size = 16, color = TEXT},
				)
				if invalid_key || !loading {
					nendo.text(
						invalid_key ? tr("Check each character against the original and try again.") : searching ? tr("To start a chat with someone new, paste their public key.") : tr("People you follow show up here. To start a chat now, paste someone's public key in the field above."),
						{font = FONT_BODY, size = 13, color = TEXT_DIM},
					)
				}
				if loading {busy_bar("NCContactsBusy")}
			}
		} else {
			ROW_H :: NC_CONTACT_H
			data := nendo.scroll(nendo.id("NCContacts"))
			height := data.found ? data.viewport.height : f32(rl.GetScreenHeight()) / UI_ZOOM
			offset :=
				data.found ? clamp(-data.position.y, 0, max(0, f32(count) * ROW_H - height)) : 0
			if data.found {data.position.y = -offset}
			first := clamp(int(offset / ROW_H) - 2, 0, count)
			last := clamp(int((offset + height) / ROW_H) + 3, first, count)
			if first >
			   0 {if nendo.box(nendo.id("NCContactsTop"))({height = nendo.fixed(f32(first) * ROW_H)}) {}}
			for row, visible in rows[first:last] {
				contact := ui.nc_contacts[row.idx]
				if nendo.box(nendo.id("NCContact", u32(row.idx)))(
				{
					width = nendo.grow(),
					height = nendo.fixed(ROW_H),
					padding = {left = 12, right = 12},
					gap = 14,
					align = {y = .Center},
					color = hovered() || ui.focus == .NC_Search && ui.nc_contact_sel == first + visible ? HOVER : nendo.Color{},
					radius = rr(10),
				},
				) {
					avatar(
						"NCContactAvatar",
						u32(row.idx),
						contact.id_hex,
						contact_label(ui, contact),
						40,
						url_pic(contact.pic_url),
					)
					if nendo.box(nendo.id("NCContactText", u32(row.idx)))(
					{width = nendo.grow(), direction = .Column, gap = 4, clip = {x = true}},
					) {
						nendo.text(
							contact_label(ui, contact),
							{font = FONT_TITLE, size = 15, color = TEXT, wrap = .None},
						)
						nendo.text(
							existing_dm(ui, contact.id_hex) >= 0 ? tr("Open chat") : npub_tail(contact.npub),
							{font = FONT_MONO, size = 11, color = TEXT_DIM, wrap = .None},
						)
					}
					nendo.text(ICON_CHATS, {font = FONT_ICON, size = 14, color = TEXT_LO})
				}
			}
			if last <
			   count {if nendo.box(nendo.id("NCContactsBottom"))({height = nendo.fixed(f32(count - last) * ROW_H)}) {}}
		}
	}
	scrollbar(nendo.id("NCContacts"))
}

new_chat_pane :: proc(ui: ^Ui_State) {
	defer scrollbar(nendo.id("NewChatPane"))
	pending := nc_pending_label(ui)
	group := ui.nc_page == .Group
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
				header_chip(group ? "NCBack" : "NCCancel", "\uf060", false, tr("Back"))
				if nendo.box(nendo.id("NCTitle"))(
				{width = nendo.grow(), direction = .Column, gap = 6},
				) {
					nendo.text(
						group ? tr("New group") : tr("New chat"),
						{font = FONT_TITLE, size = 26, color = TEXT},
					)
					nendo.text(
						group ? tr("Give your group a name and a photo.") : no_contacts ? tr("Paste someone's public key to start a chat.") : tr("Choose someone to talk to."),
						{font = FONT_BODY, size = 14, color = TEXT_DIM},
					)
				}
			}
			if ui.nc_page == .Contacts {
				input_box(
					ui,
					"NCSearch",
					&ui.nc_search,
					tr("Search contacts or paste a public key..."),
					ui.focus == .NC_Search,
					0,
				)
				nc_action_row(
					"NCGroup",
					ICON_PEOPLE,
					tr("New group"),
					tr("Start a group and invite people."),
				)
				if rl.WhipAvailable() {
					nc_action_row(
						"NCTerminal",
						"\ue795",
						tr("New terminal"),
						tr("Choose a project folder to open a terminal."),
					)
				}
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
					nendo.text(tr("Members"), {font = FONT_TITLE, size = 14, color = TEXT})
					input_box(
						ui,
						"NCMember",
						&ui.nc_member,
						tr("Search contacts or paste public keys..."),
						ui.focus == .NC_Member,
						0,
					)
					hint := tr("Choose a contact or paste public keys separated by commas.")
					if ui.nc_member_choice > 0 {
						hint = fmt.tprintf(
							tr("%s will be added to the group."),
							contact_label(ui, ui.nc_contacts[ui.nc_member_choice - 1]),
						)
					} else if address := nc_address_hex(ui, string(ui.nc_member[:]));
					   address != "" {
						hint = fmt.tprintf(
							tr("%s will be added to the group."),
							sender_label(address),
						)
					} else if members := nc_member_ref(ui); strings.contains(members, "\n") {
						hint = fmt.tprintf(
							tr("%d people will be added to the group."),
							len(strings.split(members, "\n", context.temp_allocator)),
						)
					}
					nendo.text(hint, {font = FONT_BODY, size = 13, color = TEXT_DIM})
				}
				scrollbar(nendo.id("NCForm"))
			}
			if pending != "" {
				nendo.text(pending, {font = FONT_BODY, size = 13, color = ACCENT})
				busy_bar("NCBusy")
			}
			if ui.nc_page != .Contacts {
				label :=
					pending != "" ? pending : ui.nc_member_choice == 0 && strings.contains(string(ui.nc_member[:]), "@") ? tr("Look up") : tr("Create group")
				// A NIP-05 lookup only fills in the member, so it needs no name yet.
				member := nc_member_ref(ui)
				nip05 := strings.contains(member, "@")
				named := strings.trim_space(string(ui.nc_name[:])) != ""
				ready := pending == "" && member != "" && (named || nip05)
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
			nc_member_options(ui)
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
				for line, i in compose_lines(text) {
					h := head
					if head == line[0] && line[0] > 0 && text[line[0] - 1] != '\n' {h = -1}
					compose_line(u32(i), text, line[0], line[1], lo, hi, h)
					if h >= line[0] && h <= line[1] {compose_view.row = u32(i)}
				}
			}
		}
		scrollbar(nendo.id("ComposeClip"))
	}
}

@(private = "file")
compose_more_menu :: proc(ui: ^Ui_State) {
	if nendo.box(nendo.id("ComposeMoreMenu"))(
	{
		width = nendo.fixed(fit_w(240)),
		direction = .Column,
		padding = nendo.pad(4),
		floating = {
			attach_to = .Element,
			parent = nendo.id("ComposeTools").id,
			attach = {element = .Left_Bottom, parent = .Left_Top},
			offset = {0, -6},
			z = 12,
		},
		color = CARD,
		radius = rr(10),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		if ui.editing == "" {
			ctx_item("PollBtn", ICON_POLL, tr("Create a poll"))
			ctx_item("LocationBtn", ICON_LOCATION, tr("Send location"))
			sent := gm_sent_today(ui)
			ctx_item(
				"GmBtn",
				"",
				sent ? tr("You said GM here today") : tr("Say GM (once a day)"),
				sent ? ACCENT_DIM : nendo.Color{},
			)
		}
		ctx_item("FxBtn", ICON_FX, tr("Send with an effect"))
		if ui.prefs.stt_enabled {ctx_item("DictateBtn", ICON_MIC, tr("Dictate"))}
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
	submit_available := !ui.search_open && (ui.stt.file == nil || ui.stt.message != "")

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
	} else if len(ui.replying) > 0 {
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

	// A filled input surface anchored to the conversation. Enter sends;
	// the existing toolbar stays separate from the growing draft.
	if nendo.box(nendo.id("Composer"))(
	{
		width = nendo.grow(),
		padding = nendo.pad(
			single_pane() ? (f32(rl.GetScreenHeight()) / UI_ZOOM < 500 ? 4 : 8) : 16,
		),
		gap = 8,
		direction = .Column,
	},
	) {
		burst_pane_layer() // own send's effect rises from here
		// A capped scrollable list keeps every removal control reachable
		// without letting attachments widen or consume the chat pane.
		if len(ui.staged) > 0 {
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
		if ui.chat_preview_w == 0 && voice_active() {
			voice_bar()
		} else if nendo.box(nendo.id("ComposeBox"))(
		{
			// The draft owns the full width; controls stay on their own row.
			width = nendo.grow(),
			height = nendo.fixed(compose_height()),
			padding = {left = 16, right = 16, top = 8, bottom = 8},
			gap = 8,
			direction = .Column,
			color = PLATE,
			radius = rr(8),
			border = {color = ui.focus == .Compose ? ACCENT_DIM : FIELD_BORDER, width = bw()},
		},
		) {
			if nendo.hovered() {
				cursor_raise(.Text)
			}
			// The @-mention and :shortcode: popovers float above the box.
			if open_now(nendo.id("MentionPop"), ui.mention_active) {
				mention_popover(ui)
			}
			if open_now(nendo.id("ShortcodePop"), ui.shortcode_active) {
				shortcode_popover(ui)
			}
			// One row per physical line ('\n' from Shift+Enter or
			// paste); each splits at the selection so the caret
			// sits at its head and the selected span highlights.
			// Emoji render as tiles like message bodies.
			// Long drafts scroll inside the capped text viewport.
			if nendo.box(nendo.id("ComposeClip"))(
			{
				width = nendo.grow(),
				height = nendo.fixed(compose_height() - compose_chrome_height()),
				clip = {x = true, y = true, scroll = true},
			},
			) {
				if nendo.box(nendo.id("ComposeText"))(
				{width = nendo.grow(), direction = .Column, gap = 2},
				) {
					if len(ui.compose) == 0 && (ui.chat_preview_w > 0 || len(rl.Preedit()) == 0) {
						compose_view.row = 0
						if nendo.box(nendo.id("ComposeLine", 0))(
						{gap = 1, align = {y = .Center}},
						) {
							// Caret first: typing starts at the left edge.
							if ui.focus == .Compose {
								caret()
							}
							nendo.text(
								len(ui.thread_stack) > 0 ? tr("Reply in thread…") : tr("Send a message..."),
								{font = FONT_BODY, size = BODY_FS, color = TEXT_LO},
							)
						}
					} else {
						text := string(ui.compose[:])
						lo, hi, head := field_sel(ui, &ui.compose)
						if ui.focus != .Compose {
							head = -1
						}
						for r, i in compose_lines(text) {
							h := head
							// A caret on a wrap boundary belongs to
							// the upper visual line.
							if head == r[0] && r[0] > 0 && text[r[0] - 1] != '\n' {
								h = -1
							}
							compose_line(u32(i), text, r[0], r[1], lo, hi, h)
							if h >= r[0] && h <= r[1] {compose_view.row = u32(i)}
						}
					}
				}
			}
			scrollbar(nendo.id("ComposeClip"))
			if nendo.box(nendo.id("ComposeTools"))(
			{
				width = nendo.grow(),
				height = nendo.fixed(tap_size() ? tap_min() : COMPOSE_TOOLS_H),
				gap = single_pane() ? 2 : 10,
				align = {y = .Center},
			},
			) {
				if nendo.box(nendo.id("ComposeToolScroll"))(
				{
					width = nendo.grow(),
					height = nendo.grow(),
					gap = single_pane() ? 2 : 10,
					align = {y = .Center},
					clip = {x = !single_pane(), scroll = true},
				},
				) {
					if nendo.box(nendo.id("AttachBtn"))(compose_tool(hovered() ? HOVER : {})) {
						nendo.text(ICON_CLIP, {font = FONT_ICON, size = 14, color = TEXT_LO})
						if hovered() {tooltip(tr("Attach a file"))}
					}
					if nendo.box(nendo.id("ComposeGap"))({width = nendo.grow()}) {}
					if nendo.box(nendo.id("EmojiBtn"))(compose_tool(hovered() ? HOVER : {})) {
						nendo.text(ICON_SMILE, {font = FONT_ICON, size = 14, color = TEXT_LO})
						if hovered() {tooltip(tr("Emoji"))}
					}
					if single_pane() {
						if nendo.box(nendo.id("ComposeMoreBtn"))(
							compose_tool(ui.compose_more ? SELECTED : (hovered() ? HOVER : {})),
						) {
							nendo.text("+", {font = FONT_TITLE, size = 22, color = TEXT_DIM})
						}
					} else {
						// Effect picker: arms a burst for the next send.
						if nendo.box(nendo.id("FxBtn"))(compose_tool(hovered() ? HOVER : {})) {
							if open_now(nendo.id("FxPanel"), ui.fx_open) {
								effect_picker(ui)
							}
							if hovered() {
								tooltip(tr("Send with an effect"))
							}
							if tex := emoji_tex(effect_emoji(ui.fx_armed));
							   ui.fx_armed != 0 && tex != nil {
								if nendo.box(nendo.id("FxBtnArmed"))(
								{width = nendo.fixed(16), aspect = 1, image = tex},
								) {}
							} else {
								nendo.text(
									ICON_STAR,
									{
										font = FONT_ICON,
										size = 14,
										color = ui.fx_armed != 0 ? ACCENT : TEXT_LO,
									},
								)
							}
						}
						if nendo.box(nendo.id("PollBtn"))(compose_tool(hovered() ? HOVER : {})) {
							if hovered() {
								tooltip(tr("Create a poll"))
							}
							nendo.text(ICON_POLL, {font = FONT_ICON, size = 14, color = TEXT_LO})
						}
						if ui.editing == "" {
							if nendo.box(nendo.id("LocationBtn"))(
								compose_tool(hovered() ? HOVER : {}),
							) {
								if hovered() {tooltip(tr("Send location"))}
								nendo.text(
									ICON_LOCATION,
									{font = FONT_ICON, size = 14, color = TEXT_LO},
								)
							}
						}
						// Once a day per chat; lit and inert after it went out.
						if ui.editing == "" {
							sent := gm_sent_today(ui)
							if nendo.box(nendo.id("GmBtn"))(
								compose_tool(hovered() && !sent ? HOVER : {}),
							) {
								if hovered() {
									tooltip(
										sent ? tr("You said GM here today") : tr("Say GM (once a day)"),
									)
								}
								nendo.text(
									"GM",
									{
										font = FONT_TITLE,
										size = 12,
										color = sent ? ACCENT_DIM : TEXT_LO,
									},
								)
							}
						}
						if ui.prefs.stt_enabled {
							micro_button(
								"DictateBtn",
								tr("Dictate"),
								ui.stt.file != nil ? TEXT_LO : {},
							)
						}
					}
					if nendo.box(nendo.id("MicBtn"))(compose_tool(hovered() ? HOVER : {})) {
						nendo.text(ICON_MIC, {font = FONT_ICON, size = 14, color = TEXT_LO})
						if hovered() {tooltip(tr("Voice message"))}
					}
				}
				if !single_pane() {scrollbar(nendo.id("ComposeToolScroll"))}
				if tap_size() && submit_available {
					ready :=
						stage_files_ready(ui) &&
						(strings.trim_space(string(ui.compose[:])) != "" ||
								(len(ui.staged) > 0 && ui.editing == ""))
					if nendo.box(nendo.id("SendBtn"))(
					{
						width = nendo.fit(min = 44),
						height = nendo.fixed(44),
						padding = {left = 12, right = 12},
						align = {x = .Center, y = .Center},
						color = ready ? (hovered() ? ACCENT_DIM : ACCENT) : ROW_BG,
						radius = rr(8),
					},
					) {
						nendo.text(
							ui.editing != "" ? tr("Save") : tr("Send"),
							{font = FONT_TITLE, size = 12, color = ready ? ON_ACCENT : TEXT_LO},
						)
					}
				}
			}
			if single_pane() {
				if ui.compose_more {compose_more_menu(ui)}
				if open_now(nendo.id("FxPanel"), ui.fx_open) {effect_picker(ui)}
			}
		}
		if !tap_size() && submit_available && (ui.chat_preview_w > 0 || !voice_active()) {
			if nendo.box(nendo.id("ComposeSubmitRow"))(
			{width = nendo.grow(), gap = 8, align = {y = .Center}},
			) {
				if nendo.box(nendo.id("ComposeSubmitHint"))({width = nendo.grow()}) {
					nendo.text(
						ui.editing != "" ? tr("Enter to save. Shift+Enter for a new line.") : tr("Enter to send. Shift+Enter for a new line."),
						{font = FONT_BODY, size = 11, color = TEXT_LO},
					)
				}
				folder_action("SendBtn", ui.editing != "" ? tr("Save") : tr("Send"), true)
			}
		}
	}
}
