package main

import "nendo"
import rl "sdlrl"

@(private)
reaction_button_id :: proc(message: string) -> nendo.Id {
	return nendo.id("ReactionDetailsButton", nendo.id(message).id)
}

@(private)
reaction_details_button :: proc(message: string) {
	id := reaction_button_id(message)
	focused := g_ui.reaction_focus == id.id
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

@(private)
reaction_pointer :: proc(ui: ^Ui_State) -> bool {
	pressed := mouse_pressed()
	if !pressed && ui.reaction_press == 0 {return false}
	available :=
		ui.page == .Chats &&
		ui.selected >= 0 &&
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
		ui.reaction_press = 0
		if !available {return false}
		position := nendo.pointer().position
		press_at, release_at := position, position
		if released && !forced_press && !forced_release && !test_pointer_on {
			press, release := rl.GetLeftClickPoints()
			press_at = transmute(nendo.Vector2)press / UI_ZOOM
			release_at = transmute(nendo.Vector2)release / UI_ZOOM
		}
		if press_at != position {nendo.set_pointer(press_at, .Down)}
		ui.reaction_press = reaction_pointer_id(ui.messages[:])
		// A worker may replace the rows before the displayed layout is hit-tested.
		if ui.reaction_press == 0 {ui.reaction_press = reaction_pointer_id(retired_messages[:])}
		if press_at != position || release_at != position {nendo.set_pointer(release_at, .Up)}
	}
	if ui.reaction_press == 0 {return false}
	if released {
		if available && mouse_released() && nendo.pointer_over({id = ui.reaction_press}) {
			for msg in ui.messages {
				if len(msg.reactions) == 0 || len(msg.reactions[0].senders) == 0 {continue}
				if reaction_button_id(msg.id).id == ui.reaction_press {
					reaction_modal_open(ui, msg.id)
					break
				}
			}
		}
		ui.reaction_press = 0
	} else if !rl.IsMouseButtonDown(.LEFT) && !pressed {
		ui.reaction_press = 0
		return false
	}
	return true
}

@(private = "file")
reaction_button_visible :: proc(id: nendo.Id, view: nendo.Rect) -> bool {
	button := nendo.element(id)
	return(
		button.found &&
		button.rect.y >= view.y - 0.5 &&
		button.rect.y + button.rect.height <= view.y + view.height + 0.5 \
	)
}

@(private)
handle_reaction_keys :: proc(ui: ^Ui_State) -> bool {
	if ui.show_members || web_modal.open {return false}
	focused := ui.reaction_focus != 0
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
		ui.reaction_focus = 0
		return true
	}
	step := tab_step()
	activate := focused && (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE))
	if !focused && step == 0 {return false}

	view := nendo.element(nendo.id("Timeline")).rect
	if focused && !reaction_button_visible({id = ui.reaction_focus}, view) {
		ui.reaction_focus = 0
		// A key polled before the button disappeared must not send a draft.
		if activate {return true}
		focused = false
	}
	if step == 0 && !activate {return focused}

	first, next: u32
	found_focus := false
	for i in 0 ..< len(ui.messages) {
		index := step < 0 ? len(ui.messages) - i - 1 : i
		msg := &ui.messages[index]
		if len(msg.reactions) == 0 || len(msg.reactions[0].senders) == 0 {continue}
		id := reaction_button_id(msg.id)
		if !reaction_button_visible(id, view) {continue}
		if first == 0 {first = id.id}
		if id.id == ui.reaction_focus {
			if step == 0 {
				reaction_modal_open(ui, msg.id)
				kb_focus = "ReactionDetailsClose"
				return true
			}
			found_focus = true
		} else if found_focus {
			next = id.id
			break
		}
	}
	ui.reaction_focus = step == 0 ? 0 : (found_focus ? next : first)
	return focused || ui.reaction_focus != 0
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
