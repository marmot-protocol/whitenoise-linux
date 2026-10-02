package main

import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

chat_pane :: proc(ui: ^Ui_State) {
	chat := ui.chats[ui.selected]

	if clay.UI(clay.ID("ChatPane"))(
	{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}},
	) {
		if open_now(clay.ID("CtxMenu"), ui.ctx_open) &&
		   ui.ctx_msg >= 0 &&
		   ui.ctx_msg < len(ui.messages) {
			context_menu(ui)
		}
		if open_now(clay.ID("HistModal"), ui.hist_open) &&
		   ui.hist_msg >= 0 &&
		   ui.hist_msg < len(ui.messages) {
			edit_history_modal(ui)
		}
		if open_now(clay.ID("RawModal"), ui.raw_open) {
			raw_event_modal(ui)
		}
		if open_now(clay.ID("EncModal"), ui.enc_open) {
			encryption_modal(ui, chat)
		}
		if open_now(clay.ID("FwdModal"), ui.fwd_open && ui.fwd_kind == .Message) &&
		   forward_source(ui) >= 0 {
			forward_modal(ui)
		}
		if open_now(clay.ID("OvModal"), ui.ov_open) {
			openverse_modal(ui)
		}
		if open_now(clay.ID("PollModal"), ui.poll_open) {
			poll_modal(ui)
		}
		// No close animation here: preview_close frees the decoded
		// views, so nothing may draw the modal after it.
		if open_now(clay.ID("PvModal"), preview_shown) && preview_shown {
			preview_modal(ui)
		}
		// Header.
		if clay.UI(clay.ID("ChatHeader"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				padding = clay.PaddingAll(14),
				childGap = 6,
				childAlignment = {y = .Center},
			},
			backgroundColor = RAIL_BG,
		},
		) {
			// Avatar and title open group settings; the Members chip opens members.
			if clay.UI(clay.ID("ChatHeadInfo"))(
			{
				layout = {
					padding = {left = 4, right = 8, top = 2, bottom = 2},
					childGap = 6,
					childAlignment = {y = .Center},
				},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(8),
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
						clay.PointerOver(clay.ID("ChatHeadAvatar", 0)) ? .Open : .Closed,
					)
				}
				// Keep unbroken titles from widening the pane beyond the window.
				if clay.UI(clay.ID("ChatHeadTitleClip"))({clip = {horizontal = true}}) {
					clay.Text(
						chat.title,
						{fontId = FONT_TITLE, fontSize = 16, textColor = TEXT, wrapMode = .None},
					)
				}
				if hovered() {
					tooltip(tr("Group settings"))
					cursor_raise(.Pointer)
				}
			}
			// The badge is provenance, not a control, and it is the
			// widest thing in the row: dropped when the row has to
			// choose between it and the header actions. The same string is
			// on the chat's encryption panel.
			if page_w(ui) >= HEAD_BADGE_W + 160 {
				if clay.UI(clay.ID("MlsBadge"))(
				{
					layout = {
						padding = {left = 8, right = 8, top = 3, bottom = 3},
						childGap = 5,
						childAlignment = {y = .Center},
					},
					backgroundColor = hovered() ? ACCENT_DIM : ACCENT,
					cornerRadius = rr(6),
				},
				) {
					clay.Text(
						ICON_LOCK,
						{fontId = FONT_ICON, fontSize = 10, textColor = ON_ACCENT},
					)
					crop_circle("MlsCircle", 0, chat.group_id, 18)
					clay.Text(
						fmt.tprintf("mls:0x%s", chat.group_id[:min(len(chat.group_id), 6)]),
						{fontId = FONT_MONO, fontSize = 11, textColor = ON_ACCENT},
					)
				}
			}
			// Right-pinned chrome; the bell opens the mentions inbox.
			if clay.UI(clay.ID("ChatHeadGap"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			if ui.issue_setting ==
			   .Enabled {header_chip("IssuesBtn", ICON_COMMENTS, ui.issues_open, tr("Issues"))}
			header_chip("FilesBtn", ICON_FOLDER, ui.group_files_open, tr("Files"))
			header_chip("SearchBtn", ICON_SEARCH, ui.search_open, tr("Search"))
			bell_chip(ui)
			header_chip(
				"GroupSettingsBtn",
				ICON_SETTINGS,
				ui.show_members && ui.info_tab == .Settings,
				tr("Settings"),
			)
			header_chip(
				"MembersBtn",
				ICON_PEOPLE,
				ui.show_members && ui.info_tab == .Members,
				tr("Members"),
			)
			// The chrome floats over the timeline; only the bottom-most
			// bar casts, so the shadows don't stack.
			if len(ui.thread_stack) == 0 {
				cast_shade(clay.ID("ChatHeader"), .Down, 14, 0.35)
			}
		}
		if ui.search_open {
			if clay.UI(clay.ID("SearchBox"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(32)},
					padding = {left = 10, right = 10},
					childAlignment = {y = .Center},
				},
				backgroundColor = ROW_BG,
				cornerRadius = rr(8),
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
			}
		}
		// Declared after the header so the bell it attaches to exists.
		if open_now(clay.ID("MiModal"), ui.mi_open) {
			mention_inbox(ui)
		}
		// Thread route: breadcrumb bar under the header while open.
		if len(ui.thread_stack) > 0 && !ui.issues_open {
			thread_bar(ui)
		}

		// Pending-invite banner: this chat awaits a decision.
		if chat.pending {
			if clay.UI(clay.ID("InviteBanner"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					padding = clay.PaddingAll(12),
					childGap = 10,
					childAlignment = {y = .Center},
				},
				backgroundColor = ROW_BG,
			},
			) {
				clay.Text(
					tr("You were invited to this group."),
					{fontId = FONT_BODY, fontSize = 14, textColor = TEXT},
				)
				login_button("InviteAccept", tr("Accept"))
				login_button("InviteDecline", tr("Decline"))
			}
		}

		if clay.UI(clay.ID("ChatBody"))(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				layoutDirection = .LeftToRight,
			},
		},
		) {
			// Group info takes the whole conversation area, like the
			// thread route; page_view_key plays the swap transition.
			if ui.group_files_open {
				group_files_panel(ui)
			} else if ui.show_members {
				members_panel(ui)
			} else if ui.issues_open && ui.issue_setting == .Enabled {
				issues_panel(ui)
			} else if clay.UI(clay.ID("ChatColumn"))(
			{
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingGrow()},
					layoutDirection = .TopToBottom,
				},
			},
			) {
				// Timeline: a real scroll container, top-anchored.
				// Loads jump to the newest message.
				// Centred conversation pads to a ~720 reading measure.
				side_pad := u16(0)
				if ui.prefs.centered_chat {
					if pane := page_w(ui); pane > 720 {
						side_pad = u16((pane - 720) / 2)
					}
				}
				// The thread route's push/pop transition: content slides
				// home from a small offset.
				cur := thread_cur(ui)
				if clay.UI(clay.ID("Timeline"))(
				{
					layout = {
						sizing = {clay.SizingGrow(), clay.SizingGrow()},
						layoutDirection = .TopToBottom,
						padding = {
							left = side_pad + u16(thread_slide()),
							right = side_pad,
							top = 8,
							bottom = 8,
						},
						childGap = 2,
					},
					clip = {vertical = true, childOffset = clay.GetScrollOffset()},
					// The theme's decor scene: clay emits the Custom
					// command before the children, so it paints behind
					// the messages.
					custom = {customData = decor_payload()},
				},
				) {
					// Dividers are left-aligned like the day markers:
					// x=center children drop in this clay build (quirks).
					// Pending invite: the timeline is preview context under
					// the accept/decline banner.
					if chat.pending {
						if clay.UI(clay.ID("RequestDivider"))(
						{layout = {padding = {left = 16, right = 16, top = 8, bottom = 2}}},
						) {
							clay.Text(
								tr("• CHAT REQUEST •"),
								{
									fontId = FONT_MONO,
									fontSize = 10,
									textColor = ACCENT_DIM,
									letterSpacing = 2,
								},
							)
						}
					}
					if ui.timeline_loading {
						if clay.UI(clay.ID("TimelineLoading"))(
						{
							layout = {
								padding = clay.PaddingAll(16),
								childGap = 10,
								layoutDirection = .TopToBottom,
							},
						},
						) {
							clay.Text(
								tr("Loading messages…"),
								{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
							)
							if clay.UI(clay.ID("TimelineLoadingTrack"))(
							{
								layout = {sizing = {clay.SizingFixed(180), clay.SizingFixed(4)}},
								backgroundColor = PLATE,
								cornerRadius = rr(2),
							},
							) {
								phase :=
									ui.prefs.reduce_motion ? f32(0.5) : f32(rl.GetTime() - f64(int(rl.GetTime())))
								if !ui.prefs.reduce_motion {anim_moving += 1}
								if clay.UI(clay.ID("TimelineLoadingOffset"))(
								{layout = {sizing = {width = clay.SizingFixed(phase * 132)}}},
								) {}
								if clay.UI(clay.ID("TimelineLoadingBar"))(
								{
									layout = {
										sizing = {clay.SizingFixed(48), clay.SizingFixed(4)},
									},
									backgroundColor = ACCENT,
									cornerRadius = rr(2),
								},
								) {}
							}
						}
					} else if ui.timeline_error != "" {
						if clay.UI(clay.ID("TimelineLoadError"))(
						{layout = {padding = clay.PaddingAll(16)}},
						) {
							clay.Text(
								ui.timeline_error,
								{fontId = FONT_BODY, fontSize = 14, textColor = TEXT},
							)
						}
					} else if len(ui.messages) == 0 && len(ui.pending) == 0 {
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
					for msg, i in ui.messages {
						if msg.thread_of != cur {
							continue
						}
						if len(ui.unread_mark_id) > 0 && msg.id == ui.unread_mark_id {
							run = {}
							blocked_at = -1
							// Center label between two rule lines.
							if clay.UI(clay.ID("UnreadMarker"))(
							{
								layout = {
									sizing = {width = clay.SizingGrow()},
									childGap = 12,
									childAlignment = {y = .Center},
									padding = {left = 16, right = 16, top = 6, bottom = 2},
								},
							},
							) {
								if clay.UI(clay.ID("UnreadLineL"))(
								{
									layout = {
										sizing = {
											width = clay.SizingGrow(),
											height = clay.SizingFixed(1),
										},
									},
									backgroundColor = ACCENT_DIM,
								},
								) {}
								clay.Text(
									tr("• NEW MESSAGES •"),
									{
										fontId = FONT_MONO,
										fontSize = 10,
										textColor = ACCENT,
										letterSpacing = 2,
									},
								)
								if clay.UI(clay.ID("UnreadLineR"))(
								{
									layout = {
										sizing = {
											width = clay.SizingGrow(),
											height = clay.SizingFixed(1),
										},
									},
									backgroundColor = ACCENT_DIM,
								},
								) {}
							}
						}
						if i == 0 || msg.day != ui.messages[i - 1].day {
							run = {}
							blocked_at = -1
							if clay.UI(clay.ID("DayMarker", u32(i)))(
							{
								layout = {
									layoutDirection = .TopToBottom,
									padding = {left = 16, right = 16, top = 10, bottom = 4},
								},
							},
							) {
								clay.Text(
									msg.day,
									{
										fontId = FONT_BODY,
										fontSize = 12,
										textColor = TEXT_DIM,
										letterSpacing = 1,
										wrapMode = .None,
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
							if !ui.blocked_open[ui.messages[blocked_at].id] {continue}
						}
						head := msg_run_step(&run, msg, wrap_w)
						if timeline_skip(ui, msg) {
							if clay.UI(clay.ID(msg.system ? "SysRow" : "MsgRow", u32(i)))(
							{
								layout = {
									sizing = {
										width = clay.SizingGrow(),
										height = clay.SizingFixed(msg.row_height),
									},
								},
							},
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

				scrollbar(clay.ID("Timeline"))
				jump_latest_button()

				chat_composer(ui)
			}
		}
	}
}

// The peer of the selected 1:1 chat when you blocked them, "" otherwise.
// That DM keeps its history but loses its composer (blocked_bar).
@(private)
blocked_peer :: proc(ui: ^Ui_State) -> string {
	if ui.selected < 0 {return ""}
	peer, is_dm := ui.dm_peer[ui.chats[ui.selected].group_id]
	if !is_dm || !ui.blocked[peer] {return ""}
	return peer
}

@(private = "file")
blocked_bar :: proc() {
	if clay.UI(clay.ID("BlockedBar"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = clay.PaddingAll(16),
			childGap = 10,
			childAlignment = {y = .Center},
		},
		backgroundColor = ROW_BG,
	},
	) {
		clay.Text(
			tr("You can't send messages to someone you blocked."),
			{fontId = FONT_BODY, fontSize = 14, textColor = TEXT},
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
COMPOSE_H_MIN :: f32(20) + COMPOSE_CHROME_H

// Height of the input surface from last frame's text column. The surface
// and its clip use the same height so growing drafts never animate apart.
compose_height :: proc() -> f32 {
	target := COMPOSE_H_MIN
	if box := clay.GetElementData(clay.ID("ComposeText")); box.found {
		target = max(COMPOSE_H_MIN, box.boundingBox.height + COMPOSE_CHROME_H)
	}
	return min(target, max(COMPOSE_H_MIN, min(240, f32(rl.GetScreenHeight()) / UI_ZOOM * 0.35)))
}

@(private = "file")
compose_view: struct {
	head, length: int,
	size:         clay.Dimensions,
	row:          u32,
}

// Follow edits and caret moves, but leave manual scrolling alone.
@(private)
compose_scroll :: proc(ui: ^Ui_State) {
	buf := &ui.compose
	focus := Focus.Compose
	if ui.issues_open && ui.issue_new && !ui.show_members {
		buf = &ui.issue_body
		focus = .Issue_Body
	}
	data := clay.GetScrollContainerData(clay.ID("ComposeClip"))
	if ui.focus != focus || !data.found {
		compose_view.head = -1
		return
	}
	_, _, head := field_sel(ui, buf)
	size := data.scrollContainerDimensions
	if compose_view.head == head &&
	   compose_view.length == len(buf) &&
	   compose_view.size == size {return}
	compose_view.head, compose_view.length, compose_view.size = head, len(buf), size
	row := clay.GetElementData(clay.ID("ComposeLine", compose_view.row)).boundingBox
	clip := clay.GetElementData(clay.ID("ComposeClip")).boundingBox
	delta := min(row.y - clip.y, 0) + max(row.y + row.height - clip.y - clip.height, 0)
	data.scrollPosition.y = clamp(
		data.scrollPosition.y - delta,
		min(size.height - data.contentDimensions.height, 0),
		0,
	)
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
	if clay.UI(clay.ID("MembersPanel"))(
	{
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
		backgroundColor = RAIL_BG,
	},
	) {
		col_w := min(info_width(ui), INFO_COL_MAX)
		info_top_bar(ui, col_w)
		if clay.UI(clay.ID("MembersScroll"))(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				padding = {left = 14, right = 14, top = 4, bottom = 24},
				childAlignment = {x = .Center},
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			if clay.UI(clay.ID("InfoColumn"))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(col_w)},
					layoutDirection = .TopToBottom,
					childGap = 14,
				},
			},
			) {
				switch ui.info_tab {
				case .Settings:
					info_settings_page(ui, col_w)
				case .Members:
					info_members_page(ui)
				}
			}
		}
		scrollbar(clay.ID("MembersScroll"))
	}
}

// The page's title over the card column, with close at its right edge.
@(private = "file")
info_top_bar :: proc(ui: ^Ui_State, col_w: f32) {
	if clay.UI(clay.ID("MembersHead"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {left = 14, right = 14, top = 16, bottom = 12},
			childAlignment = {x = .Center},
		},
	},
	) {
		if clay.UI(clay.ID("MembersHeadRow"))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(col_w)},
				childGap = 10,
				childAlignment = {y = .Center},
			},
		},
		) {
			members := ui.info_tab == .Members
			clay.Text(
				members ? tr("Members") : tr("Group settings"),
				{fontId = FONT_TITLE, fontSize = 20, textColor = TEXT},
			)
			if members {
				clay.Text(
					fmt.tprintf("%d", len(ui.members)),
					{fontId = FONT_MONO, fontSize = 13, textColor = TEXT_LO},
				)
			}
			if clay.UI(clay.ID("MembersHeadGap"))(
			{layout = {sizing = {width = clay.SizingGrow()}}},
			) {}
			if clay.UI(clay.ID("MembersClose"))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(30), height = clay.SizingFixed(30)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(8),
			},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
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
info_card :: proc() -> clay.ElementDeclaration {
	return {
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(16),
			childGap = 12,
		},
		backgroundColor = CARD,
		cornerRadius = rr(12),
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
	if clay.UI(clay.ID_LOCAL("FieldRow"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			childGap = 8,
			childAlignment = {y = .Center},
		},
	},
	) {
		if clay.UI(clay.ID(id_str))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(36)},
				padding = {left = 12, right = 12},
				childAlignment = {y = .Center},
			},
			backgroundColor = ROW_BG,
			cornerRadius = rr(9),
			border = {color = ui.focus == focus ? ACCENT : FIELD_BORDER, width = bw()},
		},
		) {
			field_text(ui, id_str, buf, hint, ui.focus == focus)
		}
		folder_action(button_id, button_label, true)
	}
}

// The scroll area's usable width, from last frame's box capped by the
// window (an inflated stale box during a shrink must not feed back).
@(private = "file")
info_width :: proc(ui: ^Ui_State) -> f32 {
	w := panel_target(ui)
	if box, ok := element_box(clay.ID("MembersScroll")); ok {
		avail := page_w(ui)
		w = min(box.width, avail)
	}
	return w - 28 // the scroll's own side padding
}

// Settings: the group's face, one card per setting, then leaving.
@(private = "file")
info_settings_page :: proc(ui: ^Ui_State, col_w: f32) {
	admin := self_is_admin(ui)
	if clay.UI(clay.ID("InfoHeroCard"))(info_card()) {
		group_hero(ui)
	}

	if admin {
		if clay.UI(clay.ID("InfoNameCard"))(info_card()) {
			row_labels(tr("Group name"), tr("Everyone in the group sees the new name."))
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
	if clay.UI(clay.ID("InfoTimerCard"))(info_card()) {
		row_labels(
			tr("Disappearing messages"),
			tr("New messages are deleted for everyone after this time."),
		)
		labels := [len(RETENTION_SECS)]string{N_("Off"), "1h", "1d", "1w", "4w"}
		// Members see the current timer without controls to change it.
		if !admin {
			clay.Text(
				retention_text(ui.group_retention),
				{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT_DIM},
			)
		} else {
			if clay.UI(clay.ID("RetentionRow"))(
			{
				layout = {padding = clay.PaddingAll(3), childGap = 2},
				backgroundColor = ROW_BG,
				cornerRadius = rr(10),
				border = {color = FIELD_BORDER, width = bw()},
			},
			) {
				for secs, i in RETENTION_SECS {
					active := ui.group_retention == secs
					if clay.UI(clay.ID(fmt.tprintf("RetChip%d", i)))(
					{
						layout = {padding = {left = 14, right = 14, top = 6, bottom = 6}},
						backgroundColor = active ? ACCENT : (hovered() ? HOVER : {}),
						cornerRadius = rr(7),
					},
					) {
						clay.Text(
							tr(labels[i]),
							{
								fontId = FONT_TITLE,
								fontSize = 12,
								textColor = active ? ON_ACCENT : TEXT_DIM,
							},
						)
						if hovered() && !active {cursor_raise(.Pointer)}
					}
				}
			}
		}
	}

	if admin {
		if clay.UI(clay.ID("InfoIssuesCard"))(info_card()) {
			issues_settings(ui)
		}
	}

	if clay.UI(clay.ID("InfoExportCard"))(info_card()) {
		if clay.UI(clay.ID("ExportRow"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 8,
				childAlignment = {y = .Center},
			},
		},
		) {
			row_labels(tr("Export chat"), tr("Save a copy of this conversation to a file."))
			micro_button("ExportHtmlBtn", "HTML")
			micro_button("ExportMdBtn", "Markdown")
		}
	}

	shared_media_grid(ui, col_w - 32) // the card's side padding

	// The one destructive action sits last, apart from the settings.
	if clay.UI(clay.ID("LeaveBtn"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = clay.PaddingAll(16),
			childGap = 14,
			childAlignment = {y = .Center},
		},
		backgroundColor = hovered() ? HOVER : CARD,
		cornerRadius = rr(12),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		clay.Text(ICON_BAN, {fontId = FONT_ICON, fontSize = 15, textColor = DANGER})
		row_labels(tr("Leave group"), tr("You will stop receiving its messages."), DANGER)
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
	if self_is_admin(ui) {
		if clay.UI(clay.ID("InfoInviteCard"))(info_card()) {
			row_labels(tr("Add member"), "")
			info_field(
				ui,
				"InviteBox",
				&ui.invite_input,
				tr("npub, hex, name@domain, or .bit"),
				.Invite,
				"InviteBtn",
				ui.nip05_ticket != 0 ? tr("Looking up...") : strings.contains(string(ui.invite_input[:]), "@") ? tr("Look up") : tr("Invite"),
			)
		}
	}

	// Rows carry their own inset and hover fill, so the list card hugs them.
	list_card := info_card()
	list_card.layout.padding = clay.PaddingAll(8)
	if clay.UI(clay.ID("InfoMembersCard"))(list_card) {
		if members_job != nil && len(ui.members) == 0 {
			clay.Text(tr("Loading…"), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM})
		}
		if clay.UI(clay.ID("MembersList"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				childGap = MEMBER_GAP,
			},
		},
		) {
			member_rows(ui)
		}
	}
}

// The member list. Rows keep their geometry off screen, but only rows
// near the viewport build names and queue avatars.
@(private = "file")
member_rows :: proc(ui: ^Ui_State) {
	data := clay.GetScrollContainerData(clay.ID("MembersScroll"))
	view := clay.GetElementData(clay.ID("MembersScroll"))
	first := clay.GetElementData(clay.ID("MemberRow", 0))
	y := first.boundingBox.y
	if data.found {
		y += data.scrollPosition.y - ui.members_scroll_y
		ui.members_scroll_y = data.scrollPosition.y
	}
	for member, i in ui.members {
		visible :=
			!data.found ||
			!first.found ||
			ui.member_nick == i ||
			y + MEMBER_HEIGHT >= view.boundingBox.y - 2 * (MEMBER_HEIGHT + MEMBER_GAP) &&
				y <=
					view.boundingBox.y + view.boundingBox.height + 2 * (MEMBER_HEIGHT + MEMBER_GAP)
		y +=
			MEMBER_HEIGHT +
			MEMBER_GAP +
			(ui.member_nick == i ? MEMBER_NICK_HEIGHT + MEMBER_GAP : 0)
		if clay.UI(clay.ID("MemberRow", u32(i)))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(MEMBER_HEIGHT)},
				padding = {left = 8, right = 6},
				childGap = 10,
				childAlignment = {y = .Center},
			},
			backgroundColor = hovered() ? HOVER : {},
			cornerRadius = rr(8),
		},
		) {
			if !visible {continue}
			avatar("MemberAvatar", u32(i), member.id_hex, member.name, 36, url_pic(member.pic_url))
			if clay.UI(clay.ID("MemberCol", u32(i)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					childGap = 1,
				},
			},
			) {
				if clay.UI(clay.ID("MemberName", u32(i)))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						childGap = 6,
						childAlignment = {y = .Center},
					},
				},
				) {
					clay.Text(member.name, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
					if member.is_self {
						if clay.UI(clay.ID("MemberYou", u32(i)))(
						{
							layout = {padding = {left = 6, right = 6, top = 1, bottom = 1}},
							backgroundColor = SELECTED,
							cornerRadius = rr(5),
						},
						) {
							clay.Text(
								tr("YOU"),
								{
									fontId = FONT_MONO,
									fontSize = 9,
									textColor = ACCENT,
									letterSpacing = 1,
								},
							)
						}
					}
				}
				// Admin marker rides the subline, so the name stays quiet.
				clay.Text(
					member.is_admin ? tr("Admin") : npub_tail(member.npub),
					{
						fontId = member.is_admin ? FONT_TITLE : FONT_MONO,
						fontSize = 10,
						textColor = member.is_admin ? ACCENT : TEXT_LO,
					},
				)
			}
			// A non-admin self row has no action to offer.
			if !member.is_self || member.is_admin {
				if clay.UI(clay.ID("MemberMenuBtn", u32(i)))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(26), height = clay.SizingFixed(26)},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = hovered() ? SELECTED : {},
					cornerRadius = rr(6),
				},
				) {
					clay.Text("...", {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT_DIM})
				}
			}
		}
		// The nickname editor takes the row's place below it.
		if ui.member_nick == i {
			if clay.UI(clay.ID("MemberNickBox", u32(i)))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow(),
						height = clay.SizingFixed(MEMBER_NICK_HEIGHT),
					},
					padding = {left = 8, right = 8},
					childAlignment = {y = .Center},
				},
				backgroundColor = ROW_BG,
				cornerRadius = rr(6),
				border = clay.BorderElementConfig{color = ACCENT, width = bw()},
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
		}
	}
}

// Timer chip presets, in seconds; 0 disables. Handlers index the same
// array, so chip N here is chip N there.
RETENTION_SECS :: [5]u64{0, 3600, 86400, 604800, 2419200}

@(private = "file")
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
// tiles). Square cells stretch the texture; clay has no cover-crop.
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
		for entry in ui.messages[i].images {
			total += 1
			if len(thumbs) < SHARED_MEDIA_CAP {
				append(&thumbs, Thumb{ui.messages[i].id, entry.att, entry.view})
			}
		}
	}
	if total == 0 {
		return
	}

	if clay.UI(clay.ID("InfoMediaCard"))(info_card()) {
		row_labels(tr("Shared media"), "")
		cell := (col_w - 12) / SHARED_MEDIA_COLS // minus the two 6px gaps
		if clay.UI(clay.ID("SharedMedia"))(
		{layout = {layoutDirection = .TopToBottom, childGap = 6}},
		) {
			for row := 0; row * SHARED_MEDIA_COLS < len(thumbs); row += 1 {
				if clay.UI(clay.ID("SharedMediaRow", u32(row)))({layout = {childGap = 6}}) {
					for t, c in thumbs[row * SHARED_MEDIA_COLS:min((row + 1) * SHARED_MEDIA_COLS, len(thumbs))] {
						if clay.UI(clay.ID("SharedMediaCell", u32(row * SHARED_MEDIA_COLS + c)))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(cell),
									height = clay.SizingFixed(cell),
								},
							},
							image = {imageData = t.tex},
							cornerRadius = rr(6),
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
			clay.Text(
				fmt.tprintf(tr("+%d more"), total - len(thumbs)),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
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
	ph_color: clay.Color = {},
) {
	// Clip inside the parent's padding; keep the selection head in view.
	view := clay.GetElementData(clay.ID(id_str, 3))
	offset: f32
	if focused && len(buf) > 0 && view.found {
		_, _, head := field_sel(ui, buf)
		x := rl.MeasureTextLine(FONT_BODY, font_size, string(buf[:head]), 0).x
		offset = max(0, x + CARET_W - view.boundingBox.width)
	}
	if clay.UI(clay.ID(id_str, 3))(
	{
		layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}},
		clip = {horizontal = true, childOffset = {-offset, 0}},
	},
	) {
		if clay.UI(clay.ID(id_str, 1))({layout = {childAlignment = {y = .Center}}}) {
			if clay.Hovered() {
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
				clay.Text(
					placeholder,
					{fontId = FONT_BODY, fontSize = font_size, textColor = ph, wrapMode = .None},
				)
			} else {
				text := string(buf[:])
				lo, hi, head := field_sel(ui, buf)
				if lo > 0 {
					clay.Text(
						text[:lo],
						{
							fontId = FONT_BODY,
							fontSize = font_size,
							textColor = TEXT,
							wrapMode = .None,
						},
					)
				}
				if focused && head == lo {
					caret(caret_h)
				}
				if hi > lo {
					if clay.UI(clay.ID(id_str, 2))({backgroundColor = ACCENT}) {
						clay.Text(
							text[lo:hi],
							{
								fontId = FONT_BODY,
								fontSize = font_size,
								textColor = ON_ACCENT,
								wrapMode = .None,
							},
						)
					}
					if focused && head == hi {
						caret(caret_h)
					}
				}
				if hi < len(text) {
					clay.Text(
						text[hi:],
						{
							fontId = FONT_BODY,
							fontSize = font_size,
							textColor = TEXT,
							wrapMode = .None,
						},
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
	if clay.UI(clay.ID(id_str))(
	{
		layout = {
			sizing = {
				width = width > 0 ? clay.SizingFixed(width) : clay.SizingGrow(),
				height = clay.SizingFixed(38),
			},
			padding = {left = 12, right = 12},
			childAlignment = {y = .Center},
		},
		backgroundColor = ROW_BG,
		cornerRadius = rr(8),
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
empty_timeline :: proc(ui: ^Ui_State) {
	notes := ui.selected >= 0 && ui.chats[ui.selected].group_id == ui.prefs.notes_group
	if clay.UI(clay.ID("EmptyTL"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childAlignment = {x = .Center, y = .Center},
			childGap = 12,
		},
	},
	) {
		// Ringed glyph, the same circle language as an avatar.
		if clay.UI(clay.ID("EmptyTLRing"))(
		{
			layout = {
				sizing = {width = clay.SizingFixed(64), height = clay.SizingFixed(64)},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = PLATE,
			cornerRadius = rr(32),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			clay.Text(
				notes ? ICON_PENCIL : ICON_CHATS,
				{fontId = FONT_ICON, fontSize = 24, textColor = ACCENT_DIM},
			)
		}
		clay.Text(
			notes ? tr("Your own notepad") : tr("No messages yet"),
			{fontId = FONT_TITLE, fontSize = 18, textColor = TEXT},
		)
		clay.Text(
			notes ? tr("Anything you write here stays between you and this device's key.") : tr("Send the first message to start the conversation."),
			{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
		)
	}
}

new_chat_pane :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("NewChatPane"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childAlignment = {x = .Center, y = .Center},
			childGap = 12,
		},
	},
	) {
		clay.Text(tr("New chat"), {fontId = FONT_TITLE, fontSize = 24, textColor = TEXT})
		clay.Text(
			tr("Add a contact for a direct chat, or leave it empty for a group of your own."),
			{fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM},
		)
		input_box(
			ui,
			"NCMember",
			&ui.nc_member,
			tr("npub, hex, name@domain, or .bit (optional)"),
			ui.focus == .NC_Member,
		)
		input_box(ui, "NCName", &ui.nc_name, tr("Group name"), ui.focus == .NC_Name)
		if clay.UI(clay.ID("NCPicRow"))(
		{layout = {childGap = 12, childAlignment = {y = .Center}}},
		) {
			avatar("NCPic", 0, "", string(ui.nc_name[:]), 48, nc_pic_tex(ui))
			micro_button("NCPicFile", tr("Choose image"))
			micro_button("NCPicEmoji", tr("Create from emoji"))
			if len(ui.nc_pic.data) > 0 {
				micro_button("NCPicRemove", tr("Remove"))
			}
		}
		if clay.UI(clay.ID("NCButtons"))({layout = {childGap = 12}}) {
			login_button(
				"NCCreate",
				ui.nip05_ticket != 0 ? tr("Looking up...") : strings.contains(string(ui.nc_member[:]), "@") ? tr("Look up") : tr("Create"),
			)
			login_button("NCCancel", tr("Cancel"))
		}
	}
}

// Apply this frame's typing (chars, backspace, Ctrl+V paste) to buf.
// Key press including OS key-repeat, so held arrows/backspace repeat.

// Uses the chat composer's wrapping, selection, IME, and caret hit testing.
@(private)
issue_editor :: proc(
	ui: ^Ui_State,
	buf: ^[dynamic]u8,
	focus: Focus,
	placeholder: string,
	height: f32,
) {
	if clay.UI(clay.ID("ComposeBox"))(
	{
		layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(10)},
		backgroundColor = ROW_BG,
		border = ui.focus == focus ? focus_border(true) : clay.BorderElementConfig{color = FIELD_BORDER, width = bw()},
		cornerRadius = rr(8),
	},
	) {
		if clay.UI(clay.ID("ComposeClip"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(height)},
				layoutDirection = .TopToBottom,
			},
			clip = {horizontal = true, vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			if len(buf) == 0 && len(rl.Preedit()) == 0 {
				compose_view.row = 0
				if clay.UI(clay.ID("ComposeLine", 0))(
				{layout = {childGap = 1, childAlignment = {y = .Center}}},
				) {
					if ui.focus == focus {
						caret()
					}
					clay.Text(
						placeholder,
						{fontId = FONT_BODY, fontSize = BODY_FS, textColor = TEXT_DIM},
					)
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
		scrollbar(clay.ID("ComposeClip"))
	}
}

@(private)
chat_composer :: proc(ui: ^Ui_State) {
	if blocked_peer(ui) != "" {
		blocked_bar()
		return
	}

	// Edit banner: the composer holds a sent message, not a new one.
	// It stands in for the reply banner, which returns once the edit ends.
	if len(ui.editing) > 0 {
		if clay.UI(clay.ID("EditBanner"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				padding = {left = 16, right = 16, top = 6, bottom = 6},
				childGap = 8,
				childAlignment = {y = .Center},
			},
			backgroundColor = RAIL_BG,
		},
		) {
			clay.Text(ICON_PENCIL, {fontId = FONT_ICON, fontSize = 12, textColor = ACCENT})
			clay.Text(
				tr("Editing message"),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
			)
			action_chip("EditCancel", 0, tr("Cancel"))
		}
	} else if len(ui.replying) > 0 {
		if clay.UI(clay.ID("ReplyBanner"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				padding = {left = 16, right = 16, top = 6, bottom = 6},
				childGap = 8,
			},
			backgroundColor = RAIL_BG,
		},
		) {
			clay.Text(
				fmt.tprintf(tr("Replying to: %s"), ui.reply_hint),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
			)
			action_chip("ReplyCancel", 0, tr("Cancel"))
		}
	}

	// A filled input surface anchored to the conversation. Enter sends;
	// the existing toolbar stays separate from the growing draft.
	if clay.UI(clay.ID("Composer"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = clay.PaddingAll(16),
			childGap = 8,
			layoutDirection = .TopToBottom,
		},
	},
	) {
		burst_pane_layer() // own send's effect rises from here
		// A capped scrollable list keeps every removal control reachable
		// without letting attachments widen or consume the chat pane.
		if len(ui.staged) > 0 {
			if clay.UI(clay.ID("StagedRow"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow(), height = clay.SizingFit({max = 144})},
					layoutDirection = .TopToBottom,
					childGap = 8,
				},
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
			},
			) {
				for f, i in ui.staged {
					if clay.UI(clay.ID("StagedChip", u32(i)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							padding = clay.PaddingAll(6),
							childGap = 6,
							childAlignment = {y = .Center},
						},
						backgroundColor = ROW_BG,
						cornerRadius = rr(10),
						border = {color = FIELD_BORDER, width = bw()},
					},
					) {
						if f.tex != nil {
							ratio := f.tex.height > 0 ? f32(f.tex.width) / f32(f.tex.height) : 1
							if clay.UI(clay.ID("StagedThumb", u32(i)))(
							{
								layout = {
									sizing = {width = clay.SizingFixed(min(80, 40 * ratio))},
								},
								aspectRatio = {ratio},
								image = {imageData = f.tex},
								cornerRadius = rr(6),
							},
							) {}
						} else {
							clay.Text(
								ICON_CLIP,
								{fontId = FONT_ICON, fontSize = 12, textColor = TEXT_LO},
							)
						}
						name := f.name
						if len(name) > 28 {
							name = fmt.tprintf("%s…", name[:rune_snap(name, 28)])
						}
						if clay.UI(clay.ID("StagedName", u32(i)))(
						{
							layout = {sizing = {width = clay.SizingGrow()}},
							clip = {horizontal = true},
						},
						) {
							clay.Text(
								name,
								{
									fontId = FONT_BODY,
									fontSize = 12,
									textColor = TEXT,
									wrapMode = .None,
								},
							)
						}
						if clay.UI(clay.ID("StagedX", u32(i)))(
						{
							layout = {padding = clay.PaddingAll(4)},
							backgroundColor = hovered() ? HOVER : {},
							cornerRadius = rr(6),
						},
						) {
							clay.Text(
								ICON_CLOSE,
								{fontId = FONT_ICON, fontSize = 10, textColor = TEXT_DIM},
							)
						}
					}
				}
			}
			scrollbar(clay.ID("StagedRow"))
		}
		if voice.stream != nil {
			voice_bar()
		} else if clay.UI(clay.ID("ComposeBox"))(
		{
			// The draft owns the full width; controls stay on their own row.
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(compose_height())},
				padding = {left = 16, right = 16, top = 8, bottom = 8},
				childGap = 8,
				layoutDirection = .TopToBottom,
			},
			backgroundColor = PLATE,
			cornerRadius = rr(8),
			border = {color = ui.focus == .Compose ? ACCENT_DIM : FIELD_BORDER, width = bw()},
		},
		) {
			if clay.Hovered() {
				cursor_raise(.Text)
			}
			// The @-mention and :shortcode: popovers float above the box.
			if open_now(clay.ID("MentionPop"), ui.mention_active) {
				mention_popover(ui)
			}
			if open_now(clay.ID("ShortcodePop"), ui.shortcode_active) {
				shortcode_popover(ui)
			}
			// One row per physical line ('\n' from Shift+Enter or
			// paste); each splits at the selection so the caret
			// sits at its head and the selected span highlights.
			// Emoji render as tiles like message bodies.
			// Long drafts scroll inside the capped text viewport.
			if clay.UI(clay.ID("ComposeClip"))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow(),
						height = clay.SizingFixed(compose_height() - COMPOSE_CHROME_H),
					},
				},
				clip = {horizontal = true, vertical = true, childOffset = clay.GetScrollOffset()},
			},
			) {
				if clay.UI(clay.ID("ComposeText"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						layoutDirection = .TopToBottom,
						childGap = 2,
					},
				},
				) {
					if len(ui.compose) == 0 && len(rl.Preedit()) == 0 {
						compose_view.row = 0
						if clay.UI(clay.ID("ComposeLine", 0))(
						{layout = {childGap = 1, childAlignment = {y = .Center}}},
						) {
							// Caret first: typing starts at the left edge.
							if ui.focus == .Compose {
								caret()
							}
							clay.Text(
								ui.compose_issue != "" ? tr("Write a comment") : tr("Send a message..."),
								{fontId = FONT_BODY, fontSize = BODY_FS, textColor = TEXT_LO},
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
			scrollbar(clay.ID("ComposeClip"))
			if clay.UI(clay.ID("ComposeTools"))(
			{
				layout = {
					sizing = {
						width = clay.SizingGrow(),
						height = clay.SizingFixed(COMPOSE_TOOLS_H),
					},
					childGap = 10,
					childAlignment = {y = .Center},
				},
			},
			) {
				if clay.UI(clay.ID("AttachBtn"))(
				{
					layout = {padding = clay.PaddingAll(4)},
					backgroundColor = hovered() ? HOVER : {},
					cornerRadius = rr(6),
				},
				) {
					clay.Text(ICON_CLIP, {fontId = FONT_ICON, fontSize = 14, textColor = TEXT_LO})
				}
				if clay.UI(clay.ID("ComposeGap"))(
				{layout = {sizing = {width = clay.SizingGrow()}}},
				) {}
				if clay.UI(clay.ID("EmojiBtn"))(
				{
					layout = {padding = clay.PaddingAll(4)},
					backgroundColor = hovered() ? HOVER : {},
					cornerRadius = rr(6),
				},
				) {
					clay.Text(ICON_SMILE, {fontId = FONT_ICON, fontSize = 14, textColor = TEXT_LO})
				}
				// Effect picker: arms a burst for the next send.
				if clay.UI(clay.ID("FxBtn"))(
				{
					layout = {padding = clay.PaddingAll(4)},
					backgroundColor = hovered() ? HOVER : {},
					cornerRadius = rr(6),
				},
				) {
					if open_now(clay.ID("FxPanel"), ui.fx_open) {
						effect_picker(ui)
					}
					if hovered() {
						tooltip(tr("Send with an effect"))
					}
					if tex := emoji_tex(effect_emoji(ui.fx_armed));
					   ui.fx_armed != 0 && tex != nil {
						if clay.UI(clay.ID("FxBtnArmed"))(
						{
							layout = {sizing = {width = clay.SizingFixed(16)}},
							aspectRatio = {1},
							image = {imageData = tex},
						},
						) {}
					} else {
						clay.Text(
							ICON_STAR,
							{
								fontId = FONT_ICON,
								fontSize = 14,
								textColor = ui.fx_armed != 0 ? ACCENT : TEXT_LO,
							},
						)
					}
				}
				if clay.UI(clay.ID("PollBtn"))(
				{
					layout = {padding = clay.PaddingAll(4)},
					backgroundColor = hovered() ? HOVER : {},
					cornerRadius = rr(6),
				},
				) {
					if hovered() {
						tooltip(tr("Create a poll"))
					}
					clay.Text(ICON_POLL, {fontId = FONT_ICON, fontSize = 14, textColor = TEXT_LO})
				}
				// Once a day per chat; lit and inert after it went out.
				if ui.editing == "" && ui.compose_issue == "" {
					sent := gm_sent_today(ui)
					if clay.UI(clay.ID("GmBtn"))(
					{
						layout = {padding = {left = 5, right = 5, top = 3, bottom = 3}},
						backgroundColor = hovered() && !sent ? HOVER : {},
						cornerRadius = rr(6),
					},
					) {
						if hovered() {
							tooltip(
								sent ? tr("You said GM here today") : tr("Say GM (once a day)"),
							)
						}
						clay.Text(
							"GM",
							{
								fontId = FONT_TITLE,
								fontSize = 12,
								textColor = sent ? ACCENT_DIM : TEXT_LO,
							},
						)
					}
				}
				if ui.prefs.stt_enabled {
					micro_button("DictateBtn", tr("Dictate"), ui.stt.file != nil ? TEXT_LO : {})
				}
				if clay.UI(clay.ID("MicBtn"))(
				{
					layout = {padding = clay.PaddingAll(4)},
					backgroundColor = hovered() ? HOVER : {},
					cornerRadius = rr(6),
				},
				) {
					clay.Text(ICON_MIC, {fontId = FONT_ICON, fontSize = 14, textColor = TEXT_LO})
				}
			}
		}
	}
}
