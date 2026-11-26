package main

import marmot "../marmot"
import "nendo"
import rl "sdlrl"

@(private)
reaction_button_id :: proc(message: string) -> nendo.Id {
	return nendo.id("ReactionDetailsButton", nendo.id(message).id)
}

@(private)
reaction_details_button :: proc(message: string) {
	id := reaction_button_id(message)
	focused := g_ui.timeline_focus == id.id
	size := tap_size() ? tap_min() : 24
	if nendo.box(id)(
	{
		width = nendo.fixed(size),
		height = nendo.fixed(size),
		align = {x = .Center, y = .Center},
		color = hovered() ? HOVER : ROW_BG,
		radius = rr(10),
		border = focused ? kb_ring(ACCENT) : {},
	},
	) {
		nendo.text(ICON_PEOPLE, {font = FONT_ICON, size = 12, color = TEXT})
		if !modal_open(g_ui) && (focused || hovered()) {tooltip(tr("Reaction details"), .Above)}
	}
}

@(private = "file")
reaction_pointer_id :: proc(messages: []Msg_Ui) -> u32 {
	for msg in messages {
		if len(msg.reactions) == 0 || len(msg.reactions[0].senders) == 0 {continue}
		id := reaction_button_id(msg.id)
		if nendo.pointer_over(id) {return id.id}
	}
	return 0
}

@(private = "file")
reaction_modal_open :: proc(ui: ^Ui_State, message: string) {
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
	// Closing composer popovers must not capture clicks over the modal.
	for name in ([]string{"MentionPop", "ShortcodePop", "FxPanel"}) {
		delete_key(&opens, nendo.id(name).id)
	}
	scroll_residual = {}
	ui.reaction_details_id = message
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
			ui.timeline_press = reaction_pointer_id(ui.messages[:])
			// A worker may replace the rows before the displayed layout is hit-tested.
			if ui.timeline_press ==
			   0 {ui.timeline_press = reaction_pointer_id(retired_messages[:])}
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
				if len(msg.reactions) == 0 || len(msg.reactions[0].senders) == 0 {continue}
				if reaction_button_id(msg.id).id == press_id {
					reaction_modal_open(ui, msg.id)
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
	focused := ui.timeline_focus != 0
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
		ui.timeline_focus = 0
		ui.timeline_retry_back = {}
		return true
	}
	step := tab_step()
	activate := focused && (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE))
	if !focused && step == 0 {return false}

	timeline := nendo.id("Timeline")
	view := nendo.element(timeline).rect
	if focused && !timeline_button_visible({id = ui.timeline_focus}, view) {
		ui.timeline_focus = 0
		ui.timeline_retry_back = {}
		// A key polled before the button disappeared must not send a draft.
		if activate {return true}
		focused = false
	}
	if step == 0 && !activate {return focused}

	Target :: struct {
		id:    nendo.Id,
		retry: bool,
	}
	first, next: Target
	visible_reaction: u32
	found_focus, focus_is_retry := false, false
	// Pending rows follow reactions in visual order and remain tabbable offscreen.
	group, thread_id := ui.chats[ui.selected].group_id, thread_cur(ui)
	count := len(ui.messages) + len(ui.pending)
	for i in 0 ..< count {
		index := step < 0 ? count - i - 1 : i
		is_retry := index >= len(ui.messages)
		id: nendo.Id
		if !is_retry {
			msg := &ui.messages[index]
			if len(msg.reactions) == 0 || len(msg.reactions[0].senders) == 0 {continue}
			id = reaction_button_id(msg.id)
			if !timeline_button_visible(id, view) {continue}
			if visible_reaction == 0 {visible_reaction = id.id}
		} else {
			p := &ui.pending[index - len(ui.messages)]
			if !p.failed ||
			   p.thread != thread_id ||
			   !pending_in_workspace(ui, p^, group) ||
			   !pending_send_allowed(ui, p^) {continue}
			id = pending_retry_id(p.ticket)
			button := nendo.element(id)
			if !button.found ||
			   button.rect.x < view.x - 0.5 ||
			   button.rect.x + button.rect.width > view.x + view.width + 0.5 {continue}
		}
		candidate := Target{id, is_retry}
		if first.id.id == 0 {first = candidate}
		if id.id == ui.timeline_focus {
			if step == 0 {
				if !is_retry {
					reaction_modal_open(ui, ui.messages[index].id)
					kb_focus = "ReactionDetailsClose"
				} else {
					ui.timeline_focus = 0
					ui.timeline_retry_back = {}
					retry_pending(ui, client, &ui.pending[index - len(ui.messages)])
				}
				return true
			}
			found_focus, focus_is_retry = true, is_retry
		} else if found_focus {
			next = candidate
			break
		}
	}
	target := step == 0 ? Target{} : (found_focus ? next : first)
	if scroll := nendo.scroll(timeline); scroll.found {
		// Reaction controls only participate while visible. Remember the
		// viewport before a Retry can scroll the previous control out of it.
		if target.retry && found_focus && !focus_is_retry {
			ui.timeline_retry_back = {ui.timeline_focus, scroll.position.y}
		} else if target.retry && !found_focus && step < 0 {
			ui.timeline_retry_back = {visible_reaction, scroll.position.y}
		} else if !target.retry &&
		   step < 0 &&
		   focus_is_retry &&
		   ui.timeline_retry_back.focus != 0 {
			ui.timeline_focus = ui.timeline_retry_back.focus
			scroll.position.y = ui.timeline_retry_back.y
			ui.timeline_retry_back = {}
			return true
		}
	}
	if !target.retry {ui.timeline_retry_back = {}}
	ui.timeline_focus = target.id.id
	if target.retry {scroll_into_view(timeline, target.id)}
	return focused || ui.timeline_focus != 0
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
				gap = 6,
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
					name := profile_label(g_client, chip.senders[i - start - 1])
					nendo.text(
						text_ellipsis(name, width, FONT_BODY, 13),
						{font = FONT_BODY, size = 13, color = TEXT},
					)
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
