package main

import "core:fmt"
import "core:strings"

import marmot "../marmot"
import "nendo"
import rl "sdlrl"

@(private)
reaction_chip_id :: proc(message: u32, emoji: string) -> nendo.Id {
	return nendo.id("MsgReactionChip", nendo.id(emoji, message).id)
}

@(private = "file")
REACTION_SENDER_GAP :: 6

@(private = "file")
reaction_sender :: proc(sender: string, width: f32, ink: nendo.Color, size: u16) {
	name := strings.trim_space(mention_label(sender))
	if end := strings.index_any(name, "\r\n"); end >= 0 {name = name[:end]}
	photo := person_picture(sender, profile_info(g_client, sender).pic_url)
	SIDE :: 14
	avatar("ReactionSenderAvatar", nendo.open_id(), sender, name, SIDE, photo)
	nendo.text(
		text_ellipsis(name, width - SIDE - REACTION_SENDER_GAP, FONT_BODY, size),
		{font = FONT_BODY, size = size, color = ink, wrap = .None},
	)
}

@(private)
reaction_peek :: proc(id: nendo.Id, strip: nendo.Id, senders: []string) {
	anchor := nendo.element(id)
	if !anchor.found {return}
	view := nendo.element(nendo.id("Timeline")).rect
	if g_ui.timeline_focus.id.id == id.id &&
	   !timeline_button_visible(id, reaction_clip(view, strip)) {return}
	PEEK_NAMES :: 3
	LINE_H :: 18
	shown := min(PEEK_NAMES, len(senders))
	more := len(senders) - shown
	width := min(f32(174), view.width - 16)
	height := f32(shown + int(more > 0)) * LINE_H + 12
	r := anchor.rect
	y := r.y - height - 6
	if y < view.y + 8 {y = r.y + r.height + 6}
	x := clamp(r.x + (r.width - width) / 2, view.x + 8, view.x + view.width - width - 8)
	top := clamp(y, 8, max(8, f32(rl.GetScreenHeight()) / UI_ZOOM - height - 8))
	if nendo.box(nendo.id_local("ReactionPeek"))(
	{
		width = nendo.fixed(width),
		direction = .Column,
		padding = {left = 10, right = 10, top = 6, bottom = 6},
		floating = {attach_to = .Root, z = 18, offset = {x, top}, pointer = .Passthrough},
		color = TOOLTIP,
		radius = rr(6),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		for sender, i in senders[:shown] {
			if nendo.box(nendo.id_local("ReactionPeekLine", u32(i)))(
			{height = nendo.fixed(LINE_H), align = {y = .Center}, gap = REACTION_SENDER_GAP},
			) {
				reaction_sender(sender, width - 20, POPOVER_TEXT, 12)
			}
		}
		if more > 0 {
			nendo.text(
				fmt.tprintf(tr("+%d more"), more),
				{
					font = FONT_BODY,
					size = 11,
					line_height = LINE_H,
					color = TEXT_DIM,
					wrap = .None,
				},
			)
		}
	}
}

@(private)
has_reaction_senders :: proc(reactions: []Reaction_Ui) -> bool {
	for chip in reactions {
		if len(chip.senders) > 0 {return true}
	}
	return false
}

@(private = "file")
timeline_message_pointer :: proc(ui: ^Ui_State, messages: []Msg_Ui) -> u32 {
	for msg in messages {
		if message_menu_allowed(ui, msg) {
			id := message_more_id(msg.id)
			// Only the full-size button is shown on touch rows. The smaller
			// desktop overlay must leave swipes and long presses alone.
			if nendo.pointer_over(id) &&
			   (!rl.TouchActive() ||
					   nendo.element(id).rect.height >= tap_min() - 0.5) {return id.id}
		}
	}
	return 0
}

@(private)
reaction_modal_open :: proc(ui: ^Ui_State, message: string, return_to: Timeline_Control) {
	fan_cancel()
	if ui.mention_active {
		ui.mention_dismissed = ui.mention_at_b
		ui.mention_active = false
	}
	if ui.shortcode_active {
		ui.shortcode_dismissed = ui.shortcode_at_b
		ui.shortcode_active = false
	}
	if slash_open(ui) {ui.slash.dismissed = true}
	// Outgoing popovers must not capture clicks over the modal.
	for name in ([]string{"CtxMenu", "MentionPop", "ShortcodePop", "FxPanel"}) {
		delete_key(&opens, nendo.id(name).id)
	}
	scroll_residual = {}
	ui.reaction_details_id = message
	ui.reaction_return = return_to
	ui.timeline_focus = {}
	kb_focus = "ReactionDetailsClose"
}

@(private = "file")
pending_retry_at :: proc(ui: ^Ui_State) -> ^Pending_Send {
	group, thread_id := ui.chats[ui.selected].group_id, thread_cur(ui)
	for &p in ui.pending {
		if p.failed &&
		   p.thread == thread_id &&
		   pending_in_workspace(ui, p, group) &&
		   nendo.pointer_over(pending_retry_id(p.ticket)) &&
		   pending_send_allowed(ui, p) {
			return &p
		}
	}
	return nil
}

@(private)
timeline_pointer :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	pressed := mouse_pressed()
	if !pressed && ui.timeline_press == 0 {return false}
	available :=
		ui.page == .Chats &&
		ui.selected >= 0 &&
		ui.selected < len(ui.chats) &&
		ui.row_menu < 0 &&
		ui.member_menu < 0 &&
		!ui.ctx_open &&
		!ui.mi_open &&
		!ui.show_members &&
		!ui.add_account_open &&
		!ui.new_chat_open &&
		!ui.compose_more &&
		!ui.fx_open &&
		!ui.chat_head_menu &&
		!settings_modal(ui) &&
		!modal_open(ui) &&
		!ui.picker_open &&
		!ui.folder_menu_open
	released := rl.IsMouseButtonReleased(.LEFT) || forced_release
	if pressed {
		ui.timeline_press = 0
		if !available {return false}
		position := nendo.pointer().position
		press_at, release_at := position, position
		if released && !forced_press && !forced_release && !test_pointer_on {
			press, release := rl.GetLeftClickPoints()
			press_at = transmute(nendo.Vector2)press / UI_ZOOM
			release_at = transmute(nendo.Vector2)release / UI_ZOOM
		}
		if press_at != position {nendo.set_pointer(press_at, .Down)}
		if p := pending_retry_at(ui); p != nil {
			ui.timeline_press = pending_retry_id(p.ticket).id
		} else {
			ui.timeline_press = timeline_message_pointer(ui, ui.messages[:])
			// A worker may replace the rows before the displayed layout is hit-tested.
			if ui.timeline_press ==
			   0 {ui.timeline_press = timeline_message_pointer(ui, retired_messages[:])}
		}
		if press_at != position || release_at != position {nendo.set_pointer(release_at, .Up)}
	}
	if ui.timeline_press == 0 {return false}
	if released {
		press_id := ui.timeline_press
		ui.timeline_press = 0
		if available && mouse_released() && nendo.pointer_over({id = press_id}) {
			if p := pending_retry_at(ui); p != nil && pending_retry_id(p.ticket).id == press_id {
				retry_pending(ui, client, p)
				return true
			}
			for msg in ui.messages {
				if message_menu_allowed(ui, msg) && message_more_id(msg.id).id == press_id {
					open_msg_menu(ui, msg.id, .Button)
					break
				}
			}
		}
	} else if !rl.IsMouseButtonDown(.LEFT) && !pressed {
		ui.timeline_press = 0
		return false
	}
	return true
}

@(private = "file")
reaction_clip :: proc(view: nendo.Rect, strip: nendo.Id) -> nendo.Rect {
	row := nendo.element(strip).rect
	left := max(view.x, row.x)
	return {left, view.y, min(view.x + view.width, row.x + row.width) - left, view.height}
}

@(private = "file")
timeline_button_visible :: proc(id: nendo.Id, view: nendo.Rect) -> bool {
	button := nendo.element(id)
	return(
		button.found &&
		button.rect.x >= view.x - 0.5 &&
		button.rect.x + button.rect.width <= view.x + view.width + 0.5 &&
		button.rect.y >= view.y - 0.5 &&
		button.rect.y + button.rect.height <= view.y + view.height + 0.5 \
	)
}

@(private)
timeline_keys :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	if ui.show_members || web_modal.open {return false}
	focus := ui.timeline_focus
	focused := focus.id.id != 0
	if !focused &&
	   (ui.focus == .Filter ||
			   ui.poll_open ||
			   ui.timestamp.open ||
			   ui.compose_more ||
			   ui.fx_open ||
			   ui.chat_head_menu ||
			   ui.mention_active ||
			   ui.shortcode_active ||
			   slash_open(ui) ||
			   voice_active()) {
		return false
	}
	if focused && rl.IsKeyPressed(.ESCAPE) {
		ui.timeline_focus = {}
		ui.timeline_retry_back = {}
		return true
	}
	step := tab_step()
	menu_key := focused && shift_down() && rl.IsKeyPressed(.F10)
	activate := focused && (menu_key || rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE))
	if !focused && step == 0 {return false}

	timeline := nendo.id("Timeline")
	view := nendo.element(timeline).rect
	focus_view := focus.strip.id != 0 ? reaction_clip(view, focus.strip) : view
	if focused && focus.id != timeline && !timeline_button_visible(focus.id, focus_view) {
		ui.timeline_retry_back = {}
		// A refresh or scroll can remove the focused control without a keypress.
		focus = {
			id = timeline,
		}
		ui.timeline_focus = focus
	}
	if focus.id == timeline && step == 0 {return true}
	if step == 0 && !activate {return focused}

	first, next, visible_message: Timeline_Control
	found_focus, focus_is_retry, first_is_retry, next_is_retry := false, false, false, false
	// Retry follows the visible message controls and remains tabbable offscreen.
	group, thread_id := ui.chats[ui.selected].group_id, thread_cur(ui)
	count := len(ui.messages) + len(ui.pending)
	for i in 0 ..< count {
		index := step < 0 ? count - i - 1 : i
		is_retry := index >= len(ui.messages)
		msg: ^Msg_Ui
		retry: ^Pending_Send
		seed: u32
		strip: nendo.Id
		clip: nendo.Rect
		slots := 1
		if is_retry {
			retry = &ui.pending[index - len(ui.messages)]
			if !retry.failed ||
			   retry.thread != thread_id ||
			   !pending_in_workspace(ui, retry^, group) ||
			   !pending_send_allowed(ui, retry^) {continue}
		} else {
			msg = &ui.messages[index]
			slots += len(msg.reactions)
			if slots > 1 {
				seed = nendo.id(msg.id).id
				strip = nendo.id("MsgReactions", seed)
				clip = reaction_clip(view, strip)
			}
		}
		for j in 0 ..< slots {
			slot := step < 0 ? slots - j - 1 : j
			id: nendo.Id
			candidate := Timeline_Control{}
			if is_retry {
				id = pending_retry_id(retry.ticket)
				button := nendo.element(id)
				if !button.found ||
				   button.rect.x < view.x - 0.5 ||
				   button.rect.x + button.rect.width > view.x + view.width + 0.5 {continue}
			} else if slot == 0 {
				if !message_menu_allowed(ui, msg^) {continue}
				id = message_more_id(msg.id)
				if !timeline_button_visible(id, view) {continue}
			} else {
				chip := &msg.reactions[slot - 1]
				if len(chip.senders) == 0 {continue}
				id = reaction_chip_id(seed, chip.emoji)
				box := nendo.element(id)
				if !box.found ||
				   box.rect.width > clip.width + 0.5 ||
				   box.rect.y < view.y - 0.5 ||
				   box.rect.y + box.rect.height > view.y + view.height + 0.5 {continue}
				candidate.strip = strip
			}
			candidate.id = id
			if !is_retry && visible_message.id.id == 0 {visible_message = candidate}
			if first.id.id == 0 {first, first_is_retry = candidate, is_retry}
			if id.id == focus.id.id {
				if step == 0 {
					if is_retry {
						if menu_key {return true}
						ui.timeline_focus = {}
						ui.timeline_retry_back = {}
						retry_pending(ui, client, retry)
					} else if slot == 0 || menu_key {
						if message_menu_allowed(ui, msg^) {open_msg_menu(ui, msg.id, .Keyboard)}
					} else {
						reaction_modal_open(ui, msg.id, focus)
					}
					return true
				}
				found_focus, focus_is_retry = true, is_retry
			} else if found_focus {
				next, next_is_retry = candidate, is_retry
				break
			}
		}
		if next.id.id != 0 {break}
	}
	target := step == 0 ? Timeline_Control{} : (found_focus ? next : first)
	retry_target := target.id.id != 0 && (found_focus ? next_is_retry : first_is_retry)
	if scroll := nendo.scroll(timeline); scroll.found {
		// Remember where the previous control was before Retry scrolls the timeline.
		if retry_target && found_focus && !focus_is_retry {
			ui.timeline_retry_back = {focus, scroll.position.y}
		} else if retry_target && !found_focus && step < 0 {
			ui.timeline_retry_back = {visible_message, scroll.position.y}
		} else if !retry_target &&
		   step < 0 &&
		   focus_is_retry &&
		   ui.timeline_retry_back.focus.id.id != 0 {
			target = ui.timeline_retry_back.focus
			scroll.position.y = ui.timeline_retry_back.y
		}
	}
	if !retry_target {ui.timeline_retry_back = {}}
	ui.timeline_focus = target
	if retry_target {scroll_into_view(timeline, target.id)}
	if strip := nendo.scroll(target.strip); strip.found {
		view := reaction_clip(view, target.strip)
		box := nendo.element(target.id).rect
		strip.position.x +=
			max(0, view.x - box.x) - max(0, box.x + box.width - view.x - view.width)
	}
	return activate || focused || target.id.id != 0
}

REACTION_LINE_H :: f32(24)

@(private)
reaction_details_modal :: proc(ui: ^Ui_State) {
	chips: []Reaction_Ui
	for msg in ui.messages {
		if msg.id != ui.reaction_details_id {continue}
		chips = msg.reactions[:]
		break
	}
	count := 0
	for chip in chips {
		if len(chip.senders) > 0 {count += 1 + len(chip.senders)}
	}

	width := fit_w(360)
	panel := nendo.id("ReactionDetailsModal")
	if nendo.box(panel)(
	{
		width = nendo.fixed(width),
		direction = .Column,
		padding = nendo.pad(16),
		gap = 10,
		color = CARD,
		radius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
		floating = {
			attach_to = .Root,
			z = 11,
			attach = {element = .Center_Center, parent = .Center_Center},
		},
	},
	) {
		if nendo.box(nendo.id("ReactionDetailsHead"))(
		{width = nendo.grow(), align = {y = .Center}},
		) {
			nendo.text(tr("Reaction details"), {font = FONT_TITLE, size = 18, color = TEXT})
			if nendo.box()({width = nendo.grow()}) {}
			size := tap_size() ? tap_min() : 24
			if nendo.box(nendo.id("ReactionDetailsClose"))(
			{
				width = nendo.fixed(size),
				height = nendo.fixed(size),
				align = {x = .Center, y = .Center},
				color = hovered() ? HOVER : {},
				radius = rr(6),
				border = kb_focus == "ReactionDetailsClose" ? kb_ring(ACCENT) : {},
			},
			) {
				nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 12, color = TEXT_DIM})
				if hovered() {tooltip(tr("Close"))}
			}
		}
		if count == 0 {
			nendo.text(
				tr("No reactions to show."),
				{font = FONT_BODY, size = 13, color = TEXT_DIM},
			)
			return
		}
		list := nendo.id("ReactionDetailsList")
		if nendo.box(list)(
		{
			width = nendo.grow(),
			height = nendo.fixed(min(f32(count) * REACTION_LINE_H, max(1, modal_h(500) - 88))),
			direction = .Column,
			clip = {x = true, y = true, scroll = true},
		},
		) {
			reaction_details_lines(chips, count, width - 60)
		}
		scrollbar(list, 12)
	}
}

@(private = "file")
reaction_details_lines :: proc(chips: []Reaction_Ui, count: int, width: f32) {
	rows := nendo.virtual_rows(nendo.id("ReactionDetailsRows"), count, REACTION_LINE_H)
	start := 0
	for chip in chips {
		if start >= rows.end {break}
		if len(chip.senders) == 0 {continue}
		end := start + 1 + len(chip.senders)
		for i in min(end, max(start, rows.first)) ..< min(end, rows.end) {
			header := i == start
			if nendo.box(nendo.id("ReactionDetailsLine", u32(i)))(
			{
				width = nendo.grow(),
				height = nendo.fixed(REACTION_LINE_H),
				align = {y = .Center},
				padding = {left = header ? 8 : 20},
				gap = REACTION_SENDER_GAP,
				color = header ? ROW_BG : {},
				radius = rr(6),
			},
			) {
				if header {
					if tex := emoji_tex(chip.emoji); tex != nil {
						if nendo.box()({width = nendo.fixed(16), aspect = 1, image = tex}) {}
						nendo.text(chip.count, {font = FONT_TITLE, size = 13, color = TEXT})
					} else {
						nendo.text(chip.label, {font = FONT_TITLE, size = 13, color = TEXT})
					}
				} else {
					reaction_sender(chip.senders[i - start - 1], width, TEXT, 13)
				}
			}
		}
		start = end
	}
}

@(private)
reaction_modal_close :: proc(ui: ^Ui_State) {
	if scroll := nendo.scroll(nendo.id("ReactionDetailsList"));
	   scroll.found {scroll.position^ = {}}
	scroll_residual = {}
	ui.reaction_details_id = ""
	ui.timeline_focus, ui.reaction_return = ui.reaction_return, {}
	if kb_focus == "ReactionDetailsClose" {kb_focus = ""}
}

@(private)
handle_reaction_modal :: proc(ui: ^Ui_State) {
	key := control_keys({"ReactionDetailsClose"})
	if rl.IsKeyPressed(.ESCAPE) ||
	   key == .Pressed ||
	   clicked("ReactionDetailsClose") ||
	   (mouse_released() && nendo.pointer_over(nendo.id("ModalVeil"))) {
		reaction_modal_close(ui)
		return
	}
	if scroll := nendo.scroll(nendo.id("ReactionDetailsList")); scroll.found {
		bottom := min(0, scroll.viewport.height - scroll.content.height)
		switch {
		case key_hit(.UP):
			scroll.position.y = min(0, scroll.position.y + REACTION_LINE_H)
		case key_hit(.DOWN):
			scroll.position.y = max(bottom, scroll.position.y - REACTION_LINE_H)
		case key_hit(.HOME):
			scroll.position.y = 0
		case key_hit(.END):
			scroll.position.y = bottom
		}
	}
}
