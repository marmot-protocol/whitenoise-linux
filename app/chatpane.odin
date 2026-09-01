package main

import "core:c"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:text/edit"
import "core:unicode/utf8"
import "core:sync"
import "core:thread"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

chat_pane :: proc(ui: ^Ui_State) {
	chat := ui.chats[ui.selected]

	if clay.UI(clay.ID("ChatPane"))(
	{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}},
	) {
		if open_now(clay.ID("CtxMenu"), ui.ctx_open) && ui.ctx_msg >= 0 && ui.ctx_msg < len(ui.messages) {
			context_menu(ui)
		}
		if open_now(clay.ID("HistModal"), ui.hist_open) && ui.hist_msg >= 0 && ui.hist_msg < len(ui.messages) {
			edit_history_modal(ui)
		}
		if open_now(clay.ID("RawModal"), ui.raw_open) {
			raw_event_modal(ui)
		}
		if open_now(clay.ID("EncModal"), ui.enc_open) {
			encryption_modal(ui, chat)
		}
		if open_now(clay.ID("FwdModal"), ui.fwd_open && ui.fwd_kind == .Message) && ui.fwd_msg >= 0 && ui.fwd_msg < len(ui.messages) {
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
		if open_now(clay.ID("PickerPanel"), ui.picker_open) {
			emoji_picker(ui)
		}
		// Header.
		if clay.UI(clay.ID("ChatHeader"))(
		{layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(14), childGap = 10, childAlignment = {y = .Center}}, backgroundColor = RAIL_BG},
		) {
			avatar("ChatHeadAvatar", 0, chat.group_id, chat.title, 34, chat_pic(chat))
			clay.Text(chat.title, {fontId = FONT_TITLE, fontSize = 16, textColor = TEXT})
			if clay.UI(clay.ID("MlsBadge"))(
			{layout = {padding = {left = 8, right = 8, top = 3, bottom = 3}, childGap = 5, childAlignment = {y = .Center}}, backgroundColor = hovered() ? ACCENT_DIM : ACCENT, cornerRadius = rr(6)},
			) {
				clay.Text(ICON_LOCK, {fontId = FONT_ICON, fontSize = 10, textColor = ON_ACCENT})
				clay.Text(fmt.tprintf("mls:0x%s", chat.group_id[:min(len(chat.group_id), 6)]), {fontId = FONT_MONO, fontSize = 11, textColor = ON_ACCENT})
			}
			// Search box before the grow spacer: fixed siblings after a
			// grow sibling drop in this clay build.
			if ui.search_open {
				if clay.UI(clay.ID("SearchBox"))(
				{
					layout = {sizing = {width = clay.SizingFixed(240), height = clay.SizingFixed(32)}, padding = {left = 10, right = 10}, childAlignment = {y = .Center}},
					backgroundColor = ROW_BG,
					cornerRadius = rr(8),
					border = {color = FIELD_BORDER, width = bw()},
				},
				) {
					field_text(ui, "SearchBox", &ui.search_input, "Search messages", ui.focus == .Search)
				}
			}
			// Right-pinned chrome; the bell opens the mentions inbox.
			if clay.UI(clay.ID("ChatHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			header_chip("SearchBtn", ICON_SEARCH, ui.search_open, "Search this chat")
			bell_chip(ui)
			header_chip("MembersBtn", ICON_PEOPLE, ui.show_members, "Group members")
			// The chrome floats over the timeline; only the bottom-most
			// bar casts, so the shadows don't stack.
			if len(ui.thread_stack) == 0 {
				cast_shade(clay.ID("ChatHeader"), .Down, 14, 0.35)
			}
		}
		// Declared after the header so the bell it attaches to exists.
		if open_now(clay.ID("MiModal"), ui.mi_open) {
			mention_inbox(ui)
		}
		// Thread route: breadcrumb bar under the header while open.
		if len(ui.thread_stack) > 0 {
			thread_bar(ui)
		}

		// Pending-invite banner: this chat awaits a decision.
		if chat.pending {
			if clay.UI(clay.ID("InviteBanner"))(
			{layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(12), childGap = 10, childAlignment = {y = .Center}}, backgroundColor = ROW_BG},
			) {
				clay.Text(tr("You were invited to this group."), {fontId = FONT_BODY, fontSize = 14, textColor = TEXT})
				login_button("InviteAccept", "Accept")
				login_button("InviteDecline", "Decline")
			}
		}

		if clay.UI(clay.ID("ChatBody"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .LeftToRight}}) {
			// Group info takes the whole conversation area, like the
			// thread route; page_view_key plays the swap transition.
			if ui.show_members {
				members_panel(ui)
			} else if clay.UI(clay.ID("ChatColumn"))(
			{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}},
			) {
				// Timeline: a real scroll container, top-anchored like the
				// slint pane; loads jump to the newest message.
				// Centred conversation pads to a ~720 reading measure.
				side_pad := u16(0)
				if ui.prefs.centered_chat {
					pane_w := f32(rl.GetScreenWidth()) / UI_ZOOM - rail_width(ui) - 40
					if pane_w > 720 {
						side_pad = u16((pane_w - 720) / 2)
					}
				}
				// The thread route's push/pop transition: content slides
				// home from a small offset.
				cur := thread_cur(ui)
				if clay.UI(clay.ID("Timeline"))(
				{
					layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = {left = side_pad + u16(thread_slide()), right = side_pad, top = 8 + u16(max(overscroll, 0)), bottom = 8 + u16(max(-overscroll, 0))}, childGap = 2},
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
						if clay.UI(clay.ID("RequestDivider"))({layout = {padding = {left = 16, right = 16, top = 8, bottom = 2}}}) {
							clay.Text("• CHAT REQUEST •", {fontId = FONT_MONO, fontSize = 10, textColor = ACCENT_DIM, letterSpacing = 2})
						}
					}
					if len(ui.messages) == 0 && len(ui.pending) == 0 {
						empty_timeline(ui)
					}
					// The thread route filters the one timeline: the main
					// view shows unthreaded rows, a thread view shows its
					// pinned root and the rows tagged to it.
					if len(cur) > 0 {
						thread_root_plate(ui)
					}
					for msg, i in ui.messages {
						if msg.thread_of != cur {
							continue
						}
						if len(ui.unread_mark_id) > 0 && msg.id == ui.unread_mark_id {
							// Center label between two rule lines, like the
							// slint unread divider.
							if clay.UI(clay.ID("UnreadMarker"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 12, childAlignment = {y = .Center}, padding = {left = 16, right = 16, top = 6, bottom = 2}}}) {
								if clay.UI(clay.ID("UnreadLineL"))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(1)}}, backgroundColor = ACCENT_DIM}) {}
								clay.Text("• NEW MESSAGES •", {fontId = FONT_MONO, fontSize = 10, textColor = ACCENT, letterSpacing = 2})
								if clay.UI(clay.ID("UnreadLineR"))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(1)}}, backgroundColor = ACCENT_DIM}) {}
							}
						}
						if i == 0 || msg.day != ui.messages[i - 1].day {
							if clay.UI(clay.ID("DayMarker", u32(i)))(
							{layout = {layoutDirection = .TopToBottom, padding = {left = 16, right = 16, top = 10, bottom = 4}}},
							) {
								clay.Text(msg.day, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM, letterSpacing = 1})
							}
						}
						if msg.system {
							system_row(u32(i), msg)
						} else {
							message_row(u32(i), msg)
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

				// Reply banner.
				if len(ui.replying) > 0 {
					if clay.UI(clay.ID("ReplyBanner"))(
					{layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 16, right = 16, top = 6, bottom = 6}, childGap = 8}, backgroundColor = RAIL_BG},
					) {
						clay.Text(fmt.tprintf("Replying to: %s", ui.reply_hint), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
						action_chip("ReplyCancel", 0, "Cancel")
					}
				}

				// Composer: one floating pill on the pane bg, like the
				// slint input bar. Enter sends; no Send button.
				if clay.UI(clay.ID("Composer"))(
				{layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(16), childGap = 8, layoutDirection = .TopToBottom}},
				) {
					burst_pane_layer() // own send's effect rises from here
					// Staged attachment chips, the slint staged_files row:
					// picked files waiting for Send, removable per chip.
					if len(ui.staged) > 0 {
						if clay.UI(clay.ID("StagedRow"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}}) {
							for f, i in ui.staged {
								if clay.UI(clay.ID("StagedChip", u32(i)))(
								{layout = {padding = clay.PaddingAll(6), childGap = 6, childAlignment = {y = .Center}}, backgroundColor = ROW_BG, cornerRadius = rr(10), border = {color = FIELD_BORDER, width = bw()}},
								) {
									if f.tex != nil {
										ratio := f.tex.height > 0 ? f32(f.tex.width) / f32(f.tex.height) : 1
										if clay.UI(clay.ID("StagedThumb", u32(i)))(
										{layout = {sizing = {height = clay.SizingFixed(40)}}, aspectRatio = {ratio}, image = {imageData = f.tex}, cornerRadius = rr(6)},
										) {}
									} else {
										clay.Text(ICON_CLIP, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_LO})
									}
									name := f.name
									if len(name) > 28 {
										name = fmt.tprintf("%s…", name[:rune_snap(name, 28)])
									}
									clay.Text(name, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT})
									if clay.UI(clay.ID("StagedX", u32(i)))(
									{layout = {padding = clay.PaddingAll(4)}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)},
									) {
										clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 10, textColor = TEXT_DIM})
									}
								}
							}
						}
					}
					if voice.stream != nil {
						voice_bar()
					} else if clay.UI(clay.ID("ComposeBox"))(
					{
						// Height is sprung rather than fit: a wrapped line
						// opens the pill instead of snapping it. The target
						// comes from the text column's own box, which is
						// still fit-sized, so there is no feedback loop.
						layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(compose_height())}, padding = {left = 16, right = 16, top = 8, bottom = 8}, childGap = 10, childAlignment = {y = .Center}},
						backgroundColor = ROW_BG,
						cornerRadius = rr(22),
						border = {color = ui.focus == .Compose ? ACCENT : FIELD_BORDER, width = bw()},
					},
					) {
						if clay.Hovered() {
							cursor_raise(.Text)
						}
						// Focus lights the pill rather than only recoloring
						// its border.
						glow(clay.ID("ComposeBox"), ACCENT, anim_to(clay.ID("ComposeBox").id ~ GLOW_SALT, ui.focus == .Compose ? 1 : 0, HOVER_RATE) * 0.7, 18)
						// The @-mention popover floats above the box.
						if open_now(clay.ID("MentionPop"), ui.mention_active) {
							mention_popover(ui)
						}
						if clay.UI(clay.ID("AttachBtn"))(
						{layout = {padding = clay.PaddingAll(4)}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)},
						) {
							clay.Text(ICON_CLIP, {fontId = FONT_ICON, fontSize = 14, textColor = TEXT_LO})
						}
						// One row per physical line ('\n' from Shift+Enter or
						// paste); each splits at the selection so the caret
						// sits at its head and the selected span highlights.
						// Emoji render as Twemoji tiles like message bodies.
						// The clip is what makes the growth read as the pill
						// opening: a line appears as the box makes room for
						// it, instead of hanging outside the rounded edge.
						if clay.UI(clay.ID("ComposeClip"))(
						{layout = {sizing = {height = clay.SizingFixed(compose_height() - COMPOSE_PAD)}, childAlignment = {y = .Center}}, clip = {vertical = true}},
						) {
						if clay.UI(clay.ID("ComposeText"))({layout = {layoutDirection = .TopToBottom, childGap = 2}}) {
							if len(ui.compose) == 0 && len(rl.Preedit()) == 0 {
								if clay.UI(clay.ID("ComposeLine", 0))({layout = {childGap = 1, childAlignment = {y = .Center}}}) {
									clay.Text(tr("Send a message..."), {fontId = FONT_BODY, fontSize = BODY_FS, textColor = TEXT_LO})
									if ui.focus == .Compose {
										caret()
									}
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
								}
							}
						}
						}
						if clay.UI(clay.ID("ComposeGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
						if clay.UI(clay.ID("EmojiBtn"))(
						{layout = {padding = clay.PaddingAll(4)}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)},
						) {
							clay.Text(ICON_SMILE, {fontId = FONT_ICON, fontSize = 14, textColor = TEXT_LO})
						}
						// Effect picker: arms a burst for the next send.
						if clay.UI(clay.ID("FxBtn"))(
						{layout = {padding = clay.PaddingAll(4)}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)},
						) {
							if open_now(clay.ID("FxPanel"), ui.fx_open) {
								effect_picker(ui)
							}
							if hovered() {
								tooltip("Send with an effect")
							}
							if tex := emoji_tex(effect_emoji(ui.fx_armed)); ui.fx_armed != 0 && tex != nil {
								if clay.UI(clay.ID("FxBtnArmed"))(
								{layout = {sizing = {width = clay.SizingFixed(16)}}, aspectRatio = {1}, image = {imageData = tex}},
								) {}
							} else {
								clay.Text(ICON_STAR, {fontId = FONT_ICON, fontSize = 14, textColor = ui.fx_armed != 0 ? ACCENT : TEXT_LO})
							}
						}
						if clay.UI(clay.ID("PollBtn"))(
						{layout = {padding = clay.PaddingAll(4)}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)},
						) {
							if hovered() {
								tooltip("Create a poll")
							}
							clay.Text(ICON_POLL, {fontId = FONT_ICON, fontSize = 14, textColor = TEXT_LO})
						}
						if clay.UI(clay.ID("MicBtn"))(
						{layout = {padding = clay.PaddingAll(4)}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)},
						) {
							clay.Text(ICON_MIC, {fontId = FONT_ICON, fontSize = 14, textColor = TEXT_LO})
						}
					}
				}
			}
		}
	}
}

// The info page's content column width. The page itself fills the chat
// area; only its content keeps a readable measure.
panel_target :: proc(ui: ^Ui_State) -> f32 {
	return f32(clamp(ui.prefs.panel_w, PANEL_W_MIN, PANEL_W_MAX))
}

// One "Members  8" style section head, the slint Section label + note.
@(private = "file")
COMPOSE_H_MIN :: f32(44)
COMPOSE_PAD :: f32(16) // the pill's top + bottom padding

// Height of the composer pill, from last frame's text column. The pill
// and its clip both ask for it; no easing, the chat box does not
// animate.
compose_height :: proc() -> f32 {
	target := COMPOSE_H_MIN
	if box := clay.GetElementData(clay.ID("ComposeText")); box.found {
		target = max(COMPOSE_H_MIN, box.boundingBox.height + COMPOSE_PAD)
	}
	return target
}

section_head :: proc(id_str: string, label: string, note: string) {
	if clay.UI(clay.ID(id_str))(
	{layout = {sizing = {width = clay.SizingGrow()}, childGap = 8, childAlignment = {y = .Center}, padding = {top = 8, bottom = 2}}},
	) {
		clay.Text(tr(label), {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT_DIM, letterSpacing = 1})
		if len(note) > 0 {
			clay.Text(note, {fontId = FONT_MONO, fontSize = 11, textColor = TEXT_LO})
		}
	}
}

members_panel :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("MembersPanel"))(
	{
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
		backgroundColor = RAIL_BG,
	},
	) {
		if clay.UI(clay.ID("MembersBody"))(
		{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}},
		) {
			// Close sits over the hero, top-right, like the slint panel.
			if clay.UI(clay.ID("MembersHead"))({layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 14, right = 10, top = 10}, childAlignment = {y = .Center}}}) {
				if clay.UI(clay.ID("MembersHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
				if clay.UI(clay.ID("MembersClose"))(
				{layout = {sizing = {width = clay.SizingFixed(26), height = clay.SizingFixed(26)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(7)},
				) {
					clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
				}
			}

			// Everything but the head and the leave row scrolls. A wide
			// pane splits into a settings column and a people column,
			// capped at a readable width and centered; a narrow one
			// stacks the same two blocks.
			if clay.UI(clay.ID("MembersScroll"))(
			{
				layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = {left = 14, right = 14, bottom = 12}, childGap = 6, childAlignment = {x = .Center}},
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
			},
			) {
				content := info_width(ui)
				if content >= INFO_WIDE_MIN {
					row_w := min(content, INFO_COLS_MAX)
					if clay.UI(clay.ID("InfoCols"))({layout = {sizing = {width = clay.SizingFixed(row_w)}, childGap = INFO_COL_GAP}}) {
						if clay.UI(clay.ID("InfoSettings"))({layout = {sizing = {width = clay.SizingFixed(INFO_SETTINGS_W)}, layoutDirection = .TopToBottom, childGap = 6}}) {
							info_settings_col(ui)
						}
						if clay.UI(clay.ID("InfoPeople"))({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 6}}) {
							info_people_col(ui, row_w - INFO_SETTINGS_W - INFO_COL_GAP)
						}
					}
				} else {
					if clay.UI(clay.ID("InfoStack"))({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 6}}) {
						info_settings_col(ui)
						info_people_col(ui, content)
					}
				}
			}
			scrollbar(clay.ID("MembersScroll"))

			// Pinned under the scroll, the slint GroupLeaveRow.
			if clay.UI(clay.ID("LeaveBtn"))(
			{
				layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(46)}, padding = {left = 20, right = 20}, childGap = 10, childAlignment = {y = .Center}},
				backgroundColor = hovered() ? HOVER : {},
				border = {color = FIELD_BORDER, width = {top = BORDER_W}},
			},
			) {
				clay.Text(ICON_BAN, {fontId = FONT_ICON, fontSize = 13, textColor = DANGER})
				clay.Text(tr("Leave group"), {fontId = FONT_TITLE, fontSize = 13, textColor = DANGER})
			}
		}
	}
}

// Layout metrics for the full-pane info page.
INFO_COLS_MAX :: 1080 // readable cap for the two-column row
INFO_WIDE_MIN :: 720 // below this the page stays one column
INFO_SETTINGS_W :: 360
INFO_COL_GAP :: 32

// The scroll area's usable width, from last frame's box capped by the
// window (an inflated stale box during a shrink must not feed back).
@(private = "file")
info_width :: proc(ui: ^Ui_State) -> f32 {
	w := panel_target(ui)
	if box, ok := element_box(clay.ID("MembersScroll")); ok {
		avail := f32(rl.GetScreenWidth()) / UI_ZOOM - rail_width(ui) - 40
		w = min(box.width, avail)
	}
	return w - 28 // the scroll's own side padding
}

// Identity and group settings: hero, rename, timer, invite, export.
@(private = "file")
info_settings_col :: proc(ui: ^Ui_State) {
	group_hero(ui)

	eyebrow("GROUP NAME")
	if clay.UI(clay.ID("RenameBox"))(
	{
		layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(34)}, padding = {left = 10, right = 10}, childAlignment = {y = .Center}},
		backgroundColor = ROW_BG,
		cornerRadius = rr(8),
		border = ui.focus == .Rename ? clay.BorderElementConfig{color = ACCENT, width = bw()} : {},
	},
	) {
		field_text(ui, "RenameBox", &ui.rename_input, "New name", ui.focus == .Rename)
	}
	login_button("RenameBtn", "Rename")

	// Group timer, an MLS setting shared by every member; MDK
	// stamps each new message and prunes after expiry.
	eyebrow("DISAPPEARING MESSAGES")
	if clay.UI(clay.ID("RetentionRow"))({layout = {childGap = 8}}) {
		labels := [len(RETENTION_SECS)]string{N_("Off"), "1h", "1d", "1w", "4w"}
		for secs, i in RETENTION_SECS {
			active := ui.group_retention == secs
			micro_button(fmt.tprintf("RetChip%d", i), labels[i], active ? ACCENT : {})
		}
	}

	eyebrow("ADD MEMBER")
	if clay.UI(clay.ID("InviteBox"))(
	{
		layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(34)}, padding = {left = 10, right = 10}, childAlignment = {y = .Center}},
		backgroundColor = ROW_BG,
		cornerRadius = rr(8),
		border = {color = FIELD_BORDER, width = bw()},
	},
	) {
		field_text(ui, "InviteBox", &ui.invite_input, "npub or hex", ui.focus == .Invite)
	}
	login_button("InviteBtn", "Invite")

	eyebrow("EXPORT CHAT")
	if clay.UI(clay.ID("ExportRow"))({layout = {childGap = 8}}) {
		micro_button("ExportHtmlBtn", "HTML")
		micro_button("ExportMdBtn", "Markdown")
	}
}

// The people column: the member list and shared media.
@(private = "file")
info_people_col :: proc(ui: ^Ui_State, col_w: f32) {
	section_head("MembersSection", "Members", fmt.tprintf("%d", len(ui.members)))
	for member, i in ui.members {
		if clay.UI(clay.ID("MemberRow", u32(i)))(
		{
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(48)}, padding = {left = 6, right = 2}, childGap = 10, childAlignment = {y = .Center}},
			backgroundColor = hovered() ? HOVER : {},
			cornerRadius = rr(8),
		},
		) {
			avatar("MemberAvatar", u32(i), member.id_hex, member.name, 36, url_pic(member.pic_url))
			if clay.UI(clay.ID("MemberCol", u32(i)))({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 1}}) {
				if clay.UI(clay.ID("MemberName", u32(i)))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 6, childAlignment = {y = .Center}}}) {
					clay.Text(member.name, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
					if member.is_self {
						if clay.UI(clay.ID("MemberYou", u32(i)))(
						{layout = {padding = {left = 6, right = 6, top = 1, bottom = 1}}, backgroundColor = SELECTED, cornerRadius = rr(5)},
						) {
							clay.Text(tr("YOU"), {fontId = FONT_MONO, fontSize = 9, textColor = ACCENT, letterSpacing = 1})
						}
					}
				}
				// Admin marker rides the subline, so the name stays quiet.
				clay.Text(
					member.is_admin ? tr("Admin") : npub_tail(member.npub),
					{fontId = member.is_admin ? FONT_TITLE : FONT_MONO, fontSize = 10, textColor = member.is_admin ? ACCENT : TEXT_LO},
				)
			}
			// A non-admin self row has no action to offer.
			if !member.is_self || member.is_admin {
				if clay.UI(clay.ID("MemberMenuBtn", u32(i)))(
				{layout = {sizing = {width = clay.SizingFixed(26), height = clay.SizingFixed(26)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = hovered() ? SELECTED : {}, cornerRadius = rr(6)},
				) {
					clay.Text("...", {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT_DIM})
				}
			}
		}
		// The nickname editor takes the row's place below it.
		if ui.member_nick == i {
			if clay.UI(clay.ID("MemberNickBox", u32(i)))(
			{
				layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(28)}, padding = {left = 8, right = 8}, childAlignment = {y = .Center}},
				backgroundColor = ROW_BG,
				cornerRadius = rr(6),
				border = clay.BorderElementConfig{color = ACCENT, width = bw()},
			},
			) {
				field_text(ui, "MemberNickBox", &ui.nick_input, "Nickname", ui.focus == .Nick, 12, TEXT_LO)
			}
		}
	}

	shared_media_grid(ui, col_w)
}

// Timer chip presets, in seconds; 0 disables. Handlers index the same
// array, so chip N here is chip N there.
RETENTION_SECS :: [5]u64{0, 3600, 86400, 604800, 2419200}

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

	section_head("SharedMediaSection", "Shared media", "")
	cell := (col_w - 12) / SHARED_MEDIA_COLS // minus the two 6px gaps
	if clay.UI(clay.ID("SharedMedia"))({layout = {layoutDirection = .TopToBottom, childGap = 6}}) {
		for row := 0; row * SHARED_MEDIA_COLS < len(thumbs); row += 1 {
			if clay.UI(clay.ID("SharedMediaRow", u32(row)))({layout = {childGap = 6}}) {
				for t, c in thumbs[row * SHARED_MEDIA_COLS:min((row + 1) * SHARED_MEDIA_COLS, len(thumbs))] {
					if clay.UI(clay.ID("SharedMediaCell", u32(row * SHARED_MEDIA_COLS + c)))(
					{layout = {sizing = {width = clay.SizingFixed(cell), height = clay.SizingFixed(cell)}}, image = {imageData = t.tex}, cornerRadius = rr(6)},
					) {
						if hovered() {
							img_hover = {msg_id = t.msg_id, att = t.att}
						}
					}
				}
			}
		}
	}
	if total > len(thumbs) {
		clay.Text(fmt.tprintf("+%d more", total - len(thumbs)), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
	}
}

// Snapshot the selected chat's enriched member rows.
load_members :: proc(client: ^marmot.Client, ui: ^Ui_State) {
	if ui.selected < 0 {
		return
	}
	details: ^marmot.Group_Details
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	group := strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator)
	if marmot.group_details(client, account, group, &details) != .OK {
		ui.client_status = fmt.aprintf("members failed: %s", marmot.last_error())
		return
	}
	defer marmot.group_details_free(details)

	delete(ui.group_desc)
	ui.group_desc = strings.clone(details.group.description != nil ? string(details.group.description) : "")
	ui.group_retention = details.group.disappearing_message_secs

	clear(&ui.members)
	ui.member_nick = -1 // fresh rows invalidate the editor index
	for i in 0 ..< details.members_len {
		member := &details.members[i]
		// Local nickname wins over the published name, like contacts.
		name: string
		if nick, ok := ui.nicknames[string(member.member_id_hex)]; ok && len(nick) > 0 && !member.is_self {
			name = nick
		} else if member.display_name != nil && len(string(member.display_name)) > 0 {
			name = string(member.display_name)
		} else if member.is_self {
			name = "you"
		} else {
			name = short_hex(string(member.member_id_hex))
		}
		append(&ui.members, Member_Ui{
			pic_url  = strings.clone(profile_info(client, string(member.member_id_hex)).pic_url),
			id_hex   = strings.clone(string(member.member_id_hex)),
			npub     = strings.clone(hex_npub(string(member.member_id_hex))),
			name     = strings.clone(name),
			is_admin = member.is_admin,
			is_self  = member.is_self,
		})
	}
}

login_button :: proc(id_str: string, label: string) {
	if clay.UI(clay.ID(id_str))(
	{
		layout = {padding = {left = 18, right = 18, top = 10, bottom = 10}},
		backgroundColor = hovered() ? ACCENT : ROW_BG,
		cornerRadius = rr(8),
		border = bevel_border(),
	},
	) {
		clay.Text(tr(label), {fontId = FONT_BODY, fontSize = 16, textColor = hovered() ? BG : TEXT})
	}
}

// The text row of an input box: placeholder, or the value with the
// selection highlighted and the caret at the selection head. Also the
// element (id_str, 1) that field_mouse hit-tests against.
field_text :: proc(ui: ^Ui_State, id_str: string, buf: ^[dynamic]u8, placeholder: string, focused: bool, font_size: u16 = 13, ph_color: clay.Color = {}) {
	if clay.UI(clay.ID(id_str, 1))({layout = {childAlignment = {y = .Center}}}) {
		if clay.Hovered() {
			cursor_raise(.Text)
		}
		caret_h := f32(font_size) + 1
		if len(buf) == 0 {
			ph := ph_color
			if ph.a == 0 {
				ph = TEXT_DIM
			}
			clay.Text(placeholder, {fontId = FONT_BODY, fontSize = font_size, textColor = ph})
			if focused {
				caret(caret_h)
			}
		} else {
			text := string(buf[:])
			lo, hi, head := field_sel(ui, buf)
			if lo > 0 {
				clay.Text(text[:lo], {fontId = FONT_BODY, fontSize = font_size, textColor = TEXT})
			}
			if focused && head == lo {
				caret(caret_h)
			}
			if hi > lo {
				if clay.UI(clay.ID(id_str, 2))({backgroundColor = ACCENT}) {
					clay.Text(text[lo:hi], {fontId = FONT_BODY, fontSize = font_size, textColor = ON_ACCENT})
				}
				if focused && head == hi {
					caret(caret_h)
				}
			}
			if hi < len(text) {
				clay.Text(text[hi:], {fontId = FONT_BODY, fontSize = font_size, textColor = TEXT})
			}
		}
	}
}

// Labeled single-line input box; active border while focused.
// width 0 grows to fill the row.
input_box :: proc(ui: ^Ui_State, id_str: string, buf: ^[dynamic]u8, placeholder: string, active: bool, width: f32 = 420) {
	if clay.UI(clay.ID(id_str))(
	{
		layout = {sizing = {width = width > 0 ? clay.SizingFixed(width) : clay.SizingGrow(), height = clay.SizingFixed(38)}, padding = {left = 12, right = 12}, childAlignment = {y = .Center}},
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
			layout = {sizing = {width = clay.SizingFixed(64), height = clay.SizingFixed(64)}, childAlignment = {x = .Center, y = .Center}},
			backgroundColor = PLATE,
			cornerRadius = rr(32),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			clay.Text(notes ? ICON_PENCIL : ICON_CHATS, {fontId = FONT_ICON, fontSize = 24, textColor = ACCENT_DIM})
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
	{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, childAlignment = {x = .Center, y = .Center}, childGap = 12}},
	) {
		clay.Text(tr("New chat"), {fontId = FONT_TITLE, fontSize = 24, textColor = TEXT})
		clay.Text(tr("Add a contact for a direct chat, or leave it empty for a group of your own."), {fontId = FONT_BODY, fontSize = 14, textColor = TEXT_DIM})
		input_box(ui, "NCMember", &ui.nc_member, "npub or hex (optional)", ui.focus == .NC_Member)
		input_box(ui, "NCName", &ui.nc_name, "Group name", ui.focus == .NC_Name)
		if clay.UI(clay.ID("NCButtons"))({layout = {childGap = 12}}) {
			login_button("NCCreate", "Create")
			login_button("NCCancel", "Cancel")
		}
	}
}

// Full-width stacked login button, the slint sign-in card style.
login_big_button :: proc(id_str: string, label: string, primary: bool) {
	if clay.UI(clay.ID(id_str))(
	{
		layout = {sizing = {width = clay.SizingFixed(560), height = clay.SizingFixed(52)}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = primary ? ACCENT : ROW_BG,
		cornerRadius = rr(10),
		border = primary ? {} : clay.BorderElementConfig{color = FIELD_BORDER, width = bw()},
	},
	) {
		if primary {
			hover_glow(clay.ID(id_str), ACCENT, hovered())
		}
		clay.Text(label, {fontId = FONT_TITLE, fontSize = 16, textColor = primary ? ON_ACCENT : TEXT})
	}
}

// Three dots cycling on the accent: the busy indicator for work that
// blocks a pane rather than a row.
progress_dots :: proc(id_str: string) {
	if clay.UI(clay.ID(id_str))({layout = {childGap = 9, childAlignment = {y = .Center}}}) {
		lit := int(rl.GetTime() * 3) % 3
		for i in 0 ..< 3 {
			if clay.UI(clay.ID(id_str, u32(i + 1)))(
			{layout = {sizing = {width = clay.SizingFixed(10), height = clay.SizingFixed(10)}}, backgroundColor = i == lit ? ACCENT : ROW_BG, cornerRadius = rr(5)},
			) {}
		}
	}
}

// Sign-in card: menu of entry options, or the nsec import form.
login_pane :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("LoginCard"))(
	{
		layout = {sizing = {width = clay.SizingFixed(660)}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(50), childGap = 14, childAlignment = {x = .Center}},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		clay.Text("///", {fontId = FONT_TITLE, fontSize = 34, textColor = ACCENT})
		clay.Text("White Noise", {fontId = FONT_TITLE, fontSize = 28, textColor = TEXT})

		if auth_job != nil {
			// The round trip runs on the sign-in worker; this is the only
			// thing the card offers until drain_auth picks it up.
			minting := len(auth_job.nsec) == 0
			clay.Text(minting ? tr("Generating your key") : tr("Signing you in"), {fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM})
			if clay.UI(clay.ID("LoginGapA"))({layout = {sizing = {height = clay.SizingFixed(10)}}}) {}
			progress_dots("LoginDots")
			if clay.UI(clay.ID("LoginGapB"))({layout = {sizing = {height = clay.SizingFixed(10)}}}) {}
			clay.Text(
				minting ? tr("Publishing your profile to the relays. This takes a few seconds.") : tr("Checking your key with the relays. This takes a few seconds."),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
			)
		} else if !ui.login_import {
			clay.Text(tr("Sign in to your Nostr identity"), {fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM})
			if clay.UI(clay.ID("LoginGapA"))({layout = {sizing = {height = clay.SizingFixed(10)}}}) {}
			login_big_button("LoginImportBtn", "I have an nsec", true)
			login_big_button("LoginCreate", "Generate a new key", false)
			if clay.UI(clay.ID("LoginGapB"))({layout = {sizing = {height = clay.SizingFixed(10)}}}) {}
			clay.Text(tr("Your key never leaves this device."), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO})
			micro_button("LoginBackup", tr("Import backup"))
		} else {
			clay.Text(tr("Import a key"), {fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM})
			if clay.UI(clay.ID("LoginGapA"))({layout = {sizing = {height = clay.SizingFixed(10)}}}) {}
			eyebrow("NSEC")
			if clay.UI(clay.ID("LoginInput"))(
			{
				layout = {sizing = {width = clay.SizingFixed(560), height = clay.SizingFixed(46)}, padding = {left = 14, right = 14}, childAlignment = {y = .Center}},
				backgroundColor = ROW_BG,
				cornerRadius = rr(10),
				border = {color = ACCENT, width = bw()},
			},
			) {
				if len(ui.login_input) == 0 {
					clay.Text("nsec1...", {fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM})
				} else {
					masked := strings.repeat("*", min(len(ui.login_input), 48), context.temp_allocator)
					clay.Text(masked, {fontId = FONT_BODY, fontSize = 15, textColor = TEXT})
				}
			}
			if clay.UI(clay.ID("LoginGapB"))({layout = {sizing = {height = clay.SizingFixed(6)}}}) {}
			if clay.UI(clay.ID("LoginButtons"))({layout = {childGap = 12}}) {
				login_button("LoginBack", "Back")
				login_button("LoginGo", "Continue")
			}
		}

		if len(ui.login_error) > 0 {
			clay.Text(ui.login_error, {fontId = FONT_BODY, fontSize = 14, textColor = DANGER})
		}
		// Floats to the root; the settings page hosts the same modal.
		if open_now(clay.ID("BackupModal"), ui.backup_mode != .None) {
			backup_modal(ui)
		}
	}
}

// Apply this frame's typing (chars, backspace, Ctrl+V paste) to buf.
// Key press including OS key-repeat, so held arrows/backspace repeat.
