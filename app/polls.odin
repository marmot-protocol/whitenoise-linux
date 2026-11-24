// Native MDK polls. The timeline owns the authenticated tally and local
// selection; the UI owns copied display data until its next snapshot.
package main

import "core:fmt"
import "core:strings"

import "nendo"
import rl "sdlrl"

import marmot "../marmot"

@(private = "file")
Pending_Poll :: struct {
	ticket: int,
	id:     string,
}

@(private = "file")
poll_pending: [dynamic]Pending_Poll

@(private = "file")
poll_voting :: proc(id: string) -> bool {
	for pending in poll_pending {
		if pending.id == id {
			return true
		}
	}
	return false
}

// Called by drain_ops for every completed ticket. Keeping this outside
// Msg_Ui preserves the pending marker across unrelated timeline snapshots.
@(private)
poll_complete :: proc(ticket: int) {
	for pending, i in poll_pending {
		if pending.ticket == ticket {
			delete(pending.id)
			ordered_remove(&poll_pending, i)
			return
		}
	}
}

// Copy the projection before its timeline page is freed. The tally is not
// reconstructed from the visible page, which may omit older poll responses.
poll_project :: proc(client: ^marmot.Client, msg: ^Msg_Ui, poll: ^marmot.Poll_Projection) {
	msg.poll_multi = poll.poll_type == .Multiple_Choice
	msg.poll_total = poll.participants
	msg.poll_open = poll.open
	reserve(&msg.poll_opts, int(poll.options_len))
	for option in poll.options[:poll.options_len] {
		opt := Poll_Opt_Ui {
			id    = strings.clone(string(option.id)),
			label = strings.clone(string(option.label)),
			count = option.votes,
		}
		for selected in poll.local_selection[:poll.local_selection_len] {
			if string(selected) == opt.id {
				opt.mine = true
				break
			}
		}
		doc: ^marmot.Markdown_Document
		if marmot.parse_markdown(client, option.label, &doc) == .OK {
			convert_blocks(
				&opt.blocks,
				doc.blocks,
				doc.blocks_len,
				false,
				([^]u8)(doc.blank_lines_before)[:doc.blank_lines_before_len],
			)
			marmot.markdown_document_free(doc)
		}
		append(&msg.poll_opts, opt)
	}
}

// The option bars under a poll's question, drawn by message_row.
// Clicks are routed by handle_chat to poll_vote.
poll_block :: proc(index: u32, msg: Msg_Ui) {
	width := att_w(360)
	if nendo.box(nendo.id("MsgPoll", index))(
	{direction = .Column, gap = 8, width = nendo.fixed(width)},
	) {
		for opt, j in msg.poll_opts {
			slot := index * 64 + u32(j)
			count := fmt.tprintf("%d", opt.count)
			count_w := max(f32(20), rl.MeasureTextLine(FONT_BODY, 13, count, 0).x)
			if nendo.box(nendo.id("PollOptRow", slot))(
			{
				width = nendo.grow(),
				direction = .Column,
				gap = 8,
				padding = nendo.pad(12),
				color = opt.mine ? SELECTED : (hovered() && msg.poll_open ? HOVER : ROW_BG),
				radius = rr(8),
				border = {color = opt.mine ? ACCENT : ELEVATED_BORDER, width = bw()},
			},
			) {
				if nendo.box(nendo.id("PollOptTop", slot))(
				{width = nendo.grow(), gap = 10, align = {y = .Center}},
				) {
					if nendo.box(nendo.id("PollOptChoice", slot))(
					{
						width = nendo.fixed(18),
						height = nendo.fixed(18),
						align = {x = .Center, y = .Center},
						border = {color = opt.mine ? ACCENT : TEXT_DIM, width = bw()},
						color = opt.mine ? ACCENT : {},
						radius = rr(msg.poll_multi ? 3 : 9),
					},
					) {
						if opt.mine {
							nendo.text(
								ICON_CHECK,
								{font = FONT_ICON, size = 11, color = ON_ACCENT},
							)
						}
					}
					// Label drawn by the message markdown renderer; the
					// grow column pushes the count to the right edge.
					// Id window: [1024, 3072) inside the row's 4096 block
					// (body is below, reply preview at +3072), 32 per option.
					if nendo.box(nendo.id("PollOptLabel", slot))(
					{width = nendo.grow(), direction = .Column, gap = 2},
					) {
						if len(opt.blocks) > 0 {
							md_blocks(
								opt.blocks[:],
								index * 4096 + 1024 + u32(j) * 32,
								wrap_w = max(f32(1), width - 24 - 18 - 20 - count_w),
							)
						} else {
							nendo.text(opt.label, {font = FONT_BODY, size = BODY_FS, color = TEXT})
						}
					}
					nendo.text(
						count,
						{font = FONT_BODY, size = 13, color = TEXT_DIM, wrap = .None},
					)
				}
				frac := msg.poll_total > 0 ? f32(opt.count) / f32(msg.poll_total) : 0
				if nendo.box(nendo.id("PollOptBarBg", slot))(
				{width = nendo.grow(), height = nendo.fixed(4), color = PLATE, radius = rr(2)},
				) {
					if frac > 0 {
						if nendo.box(nendo.id("PollOptBar", slot))(
						{
							width = nendo.percent(frac),
							height = nendo.grow(),
							color = ACCENT,
							radius = rr(2),
						},
						) {}
					}
				}
			}
		}
		if nendo.box(nendo.id("MsgPollFoot", index))({gap = 8, padding = {top = 4}}) {
			total :=
				msg.poll_total == 1 ? tr("1 vote") : fmt.tprintf(tr("%d votes"), msg.poll_total)
			if msg.poll_multi {
				total =
					msg.poll_total == 1 ? tr("1 voter") : fmt.tprintf(tr("%d voters"), msg.poll_total)
			}
			nendo.text(total, {font = FONT_BODY, size = 12, color = TEXT_DIM})
			if poll_voting(msg.id) {
				nendo.text(tr("Saving vote…"), {font = FONT_BODY, size = 12, color = ACCENT})
			}
			if !msg.poll_open {
				nendo.text(
					tr("Voting has ended."),
					{font = FONT_BODY, size = 12, color = TEXT_DIM},
				)
			}
		}
	}
}

// Build the full replacement selection. Multiple choice toggles an option;
// single choice replaces the previous selection.
poll_selection :: proc(msg: ^Msg_Ui, opt: int) -> []string {
	selected := make([dynamic]string, 0, len(msg.poll_opts), context.temp_allocator)
	for option, i in msg.poll_opts {
		picked := msg.poll_multi ? (i == opt ? !option.mine : option.mine) : i == opt
		if picked {append(&selected, option.id)}
	}
	return selected[:]
}

poll_vote :: proc(ui: ^Ui_State, client: ^marmot.Client, msg: ^Msg_Ui, opt: int) {
	if !msg.poll_open {return}
	if poll_voting(msg.id) {
		return
	}
	selected := poll_selection(msg, opt)
	// Native polls require at least one selection; keep the final vote.
	if len(selected) == 0 {return}
	// Paint the replacement selection before the worker returns. drain_ops
	// reloads the authoritative tally on success and on failure.
	was_voter := false
	for &option, i in msg.poll_opts {
		was_voter = was_voter || option.mine
		picked := msg.poll_multi ? (i == opt ? !option.mine : option.mine) : i == opt
		if picked != option.mine {
			if picked {
				option.count += 1
			} else if option.count > 0 {
				option.count -= 1
			}
			option.mine = picked
		}
	}
	if !was_voter {
		msg.poll_total += 1
	}
	spawn_poll(ui, client, .Poll_Vote, msg.id, "", selected)
	append(&poll_pending, Pending_Poll{ticket = op_ticket, id = strings.clone(msg.id)})
	play_sound(.Send)
}

@(private)
Poll_Error :: enum {
	None,
	Question,
	Options,
}

@(private)
poll_input_error :: proc(ui: ^Ui_State) -> Poll_Error {
	if len(strings.trim_space(string(ui.poll_question[:]))) == 0 {
		return .Question
	}
	count := 0
	for input in ui.poll_inputs {
		if len(strings.trim_space(string(input[:]))) == 0 {continue}
		count += 1
		if count >= POLL_OPTS_MIN {return .None}
	}
	return .Options
}

@(private = "file")
POLL_DAYS :: [?]u64{1, 3, 7, 0}

@(private)
poll_fields :: proc(ui: ^Ui_State, width: f32) {
	if ui.poll_error != .None {
		nendo.text(
			ui.poll_error == .Question ? tr("Add a question for your poll.") : tr("Add at least two options."),
			{font = FONT_BODY, size = 12, color = DANGER},
		)
	}
	id := nendo.id("PollFields")
	view_h := f32(rl.GetScreenHeight()) / UI_ZOOM
	// Keep room for the header and question even when the options scroll.
	limit := max(44, min(300, view_h - 132, view_h * 0.65))
	stack := width < 460
	chip_h := tap_size() ? tap_min() : 26
	settings_h := stack ? 2 * chip_h + 8 : chip_h
	option_h := tap_size() ? tap_min() : 38
	gap :: 6
	minimum := min(
		limit,
		POLL_OPTS_MIN * option_h + chip_h + settings_h + (POLL_OPTS_MIN + 1) * gap,
	)
	if nendo.box(id)(
	{
		width = nendo.grow(),
		height = nendo.fit(min = minimum, max = limit),
		direction = .Column,
		gap = gap,
		clip = {y = true, scroll = true},
	},
	) {
		for &input, i in ui.poll_inputs {
			if nendo.box(nendo.id("PollInputRow", u32(i)))(
			{width = nendo.grow(), gap = 6, align = {y = .Center}},
			) {
				input_box(
					ui,
					fmt.tprintf("PollOptBox%d", i),
					&input,
					fmt.tprintf(tr("Option %d"), i + 1),
					ui.poll_ticket == 0 && ui.focus == .PollOpt && ui.poll_focus == i,
					width = 0,
				)
				if len(ui.poll_inputs) > POLL_OPTS_MIN {
					if nendo.box(nendo.id("PollRemoveOpt", u32(i)))(
						compose_tool(hovered() ? HOVER : ROW_BG),
					) {
						nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 14, color = TEXT_DIM})
						if hovered() {tooltip(tr("Remove option"))}
					}
				}
			}
		}
		if len(ui.poll_inputs) < POLL_OPTS_CAP {
			poll_chip(nendo.id("PollAddOpt"), tr("Add option"), false)
		}
		if nendo.box(nendo.id("PollSettings"))(
		{height = nendo.fixed(settings_h), direction = stack ? .Column : .Row, gap = 8},
		) {
			if nendo.box(nendo.id("PollChoiceRow"))({gap = 4}) {
				poll_chip(nendo.id("PollSingle"), tr("Single choice"), !ui.poll_multi_in)
				poll_chip(nendo.id("PollMulti"), tr("Multiple choice"), ui.poll_multi_in)
			}
			if nendo.box(nendo.id("PollDurationRow"))({gap = 4}) {
				for days, i in POLL_DAYS {
					chip := nendo.id("PollDays", u32(i))
					label := days == 0 ? "∞" : fmt.tprintf(tr("%dd"), days)
					poll_chip(chip, label, days == ui.poll_days)
					if days == 0 && nendo.pointer_over(chip) {tooltip(tr("Never"))}
				}
			}
		}
	}
	scrollbar(id)
}

@(private = "file")
poll_chip :: proc(id: nendo.Id, label: string, selected: bool) {
	if nendo.box(id)(
	{
		width = nendo.fit(min = tap_size() ? tap_min() : 28),
		height = nendo.fixed(tap_size() ? tap_min() : 26),
		padding = {left = 8, right = 8},
		align = {x = .Center, y = .Center},
		color = selected ? SELECTED : (hovered() ? HOVER : ROW_BG),
		radius = rr(6),
	},
	) {
		nendo.text(label, {font = FONT_BODY, size = 12, color = selected ? ACCENT : TEXT_DIM})
	}
}

poll_close :: proc(ui: ^Ui_State) {
	if !ui.poll_open {return}
	ui.poll_open = false
	ui.poll_ticket = 0
	if ui.focus == .PollQ || ui.focus == .PollOpt {
		ui.focus = .Compose
		touch_field = {}
		compose_keyboard = false
	}
}

poll_reset :: proc(ui: ^Ui_State) {
	ui.ed_target = nil
	clear(&ui.poll_question)
	for &b in ui.poll_inputs {delete(b)}
	clear(&ui.poll_inputs)
	// Appending an option must not move buffers the editor points into.
	reserve(&ui.poll_inputs, POLL_OPTS_CAP)
	for _ in 0 ..< POLL_OPTS_MIN {append(&ui.poll_inputs, [dynamic]u8{})}
	ui.poll_multi_in = false
	ui.poll_days = 7
	ui.poll_error = .None
	ui.poll_focus = 0
	ui.poll_reveal = false
	ui.poll_open = true
	ui.focus = .PollQ
	compose_keyboard = true
	if rl.HasTouch() {touch_field = nendo.id("ComposeClip")}
}

// MDK assigns option IDs and authors the event. The worker resolves the thread tags.
@(private = "file")
poll_create :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if new_send_paused(ui) || thread_send_paused(ui) {return}
	ui.poll_error = poll_input_error(ui)
	if ui.poll_error != .None {return}
	question := strings.trim_space(string(ui.poll_question[:]))
	options: [POLL_OPTS_CAP]string
	count := 0
	for input in ui.poll_inputs {
		label := strings.trim_space(string(input[:]))
		if label == "" {continue}
		options[count] = label
		count += 1
	}
	spawn_poll(
		ui,
		client,
		.Poll_Create,
		thread_cur(ui),
		question,
		options[:count],
		ui.poll_multi_in ? .Multiple_Choice : .Single_Choice,
		ends_at = ui.poll_days == 0 ? 0 : now_unix() + ui.poll_days * 86_400,
	)
	ui.poll_ticket = op_ticket
}

@(private)
handle_poll :: proc(ui: ^Ui_State, client: ^marmot.Client) -> bool {
	if ui.poll_ticket != 0 {return false}
	if rl.IsKeyPressed(.ESCAPE) {
		poll_close(ui)
		return true
	}
	if ui.focus == .Compose {ui.focus = .PollQ}
	compose_mouse(ui, &ui.poll_question, .PollQ)
	if ui.focus == .PollQ {
		edit_text(ui, &ui.poll_question, true)
	} else if ui.focus == .PollOpt {
		if ui.poll_reveal {
			id := nendo.id(fmt.tprintf("PollOptBox%d", ui.poll_focus))
			if nendo.element(id).found {
				scroll_into_view(nendo.id("PollFields"), id)
				ui.poll_reveal = false
				anim_moving += 1
			}
		}
		edit_text(ui, &ui.poll_inputs[ui.poll_focus])
	}
	if ui.poll_error != .None {ui.poll_error = poll_input_error(ui)}

	if step := tab_step(); step != 0 && (ui.focus == .PollQ || ui.focus == .PollOpt) {
		count := 1 + len(ui.poll_inputs)
		at := ui.focus == .PollOpt ? 1 + ui.poll_focus : 0
		at = (at + step + count) % count
		ui.focus = at == 0 ? .PollQ : .PollOpt
		ui.poll_focus = max(at - 1, 0)
		ui.poll_reveal = at != 0
		return true
	}
	if rl.IsKeyPressed(.ENTER) && (ui.focus == .PollQ || ui.focus == .PollOpt) {
		if ui.focus == .PollQ {
			if shift_down() || rl.HasTouch() {
				ed_insert(ui, &ui.poll_question, "\n")
			} else {
				poll_create(ui, client)
			}
		} else if ui.poll_focus < len(ui.poll_inputs) - 1 {
			ui.poll_focus += 1
			ui.poll_reveal = true
		} else if len(ui.poll_inputs) < POLL_OPTS_CAP && len(ui.poll_inputs[ui.poll_focus]) > 0 {
			append(&ui.poll_inputs, [dynamic]u8{})
			ui.poll_focus += 1
			ui.poll_reveal = true
		}
		return true
	}
	for &input, i in ui.poll_inputs {
		if field_mouse(ui, &input, fmt.tprintf("PollOptBox%d", i)) {
			ui.focus, ui.poll_focus = .PollOpt, i
			return true
		}
	}
	if !mouse_released() {return false}
	if len(ui.poll_inputs) > POLL_OPTS_MIN {
		for _, i in ui.poll_inputs {
			if !clicked_indexed("PollRemoveOpt", u32(i)) {continue}
			// Removing a row moves the remaining buffers.
			if ui.ed_target != &ui.poll_question {ui.ed_target = nil}
			delete(ui.poll_inputs[i])
			ordered_remove(&ui.poll_inputs, i)
			if ui.poll_focus > i {ui.poll_focus -= 1}
			ui.poll_focus = min(ui.poll_focus, len(ui.poll_inputs) - 1)
			return true
		}
	}
	if clicked("PollAddOpt") && len(ui.poll_inputs) < POLL_OPTS_CAP {
		append(&ui.poll_inputs, [dynamic]u8{})
		ui.focus, ui.poll_focus = .PollOpt, len(ui.poll_inputs) - 1
		if rl.HasTouch() {touch_field = nendo.id(fmt.tprintf("PollOptBox%d", ui.poll_focus))}
		ui.poll_reveal = true
		return true
	}
	if clicked("PollSingle") || clicked("PollMulti") {
		ui.poll_multi_in = clicked("PollMulti")
		return true
	}
	for days, i in POLL_DAYS {
		if clicked_indexed("PollDays", u32(i)) {
			ui.poll_days = days
			return true
		}
	}
	if composer_clicked("SendBtn") {
		poll_create(ui, client)
		return true
	}
	if clicked("PollCancel") {
		poll_close(ui)
		return true
	}
	return false
}
