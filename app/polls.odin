// Native MDK polls. The timeline owns the authenticated tally and local
// selection; the UI owns copied display data until its next snapshot.
package main

import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
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
	if clay.UI(clay.ID("MsgPoll", index))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			childGap = 8,
			sizing = {width = clay.SizingFixed(width)},
		},
	},
	) {
		for opt, j in msg.poll_opts {
			slot := index * 64 + u32(j)
			count := fmt.tprintf("%d", opt.count)
			count_w := max(f32(20), rl.MeasureTextLine(FONT_BODY, 13, count, 0).x)
			if clay.UI(clay.ID("PollOptRow", slot))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					childGap = 8,
					padding = clay.PaddingAll(12),
				},
				backgroundColor = opt.mine ? SELECTED : (hovered() && msg.poll_open ? HOVER : ROW_BG),
				cornerRadius = rr(8),
				border = {color = opt.mine ? ACCENT : ELEVATED_BORDER, width = bw()},
			},
			) {
				if clay.UI(clay.ID("PollOptTop", slot))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						childGap = 10,
						childAlignment = {y = .Center},
					},
				},
				) {
					if clay.UI(clay.ID("PollOptChoice", slot))(
					{
						layout = {
							sizing = {clay.SizingFixed(18), clay.SizingFixed(18)},
							childAlignment = {x = .Center, y = .Center},
						},
						border = {color = opt.mine ? ACCENT : TEXT_DIM, width = bw()},
						backgroundColor = opt.mine ? ACCENT : {},
						cornerRadius = rr(msg.poll_multi ? 3 : 9),
					},
					) {
						if opt.mine {
							clay.Text(
								ICON_CHECK,
								{fontId = FONT_ICON, fontSize = 11, textColor = ON_ACCENT},
							)
						}
					}
					// Label drawn by the message markdown renderer; the
					// grow column pushes the count to the right edge.
					// Id window: [1024, 3072) inside the row's 4096 block
					// (body is below, reply preview at +3072), 32 per option.
					if clay.UI(clay.ID("PollOptLabel", slot))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							layoutDirection = .TopToBottom,
							childGap = 2,
						},
					},
					) {
						if len(opt.blocks) > 0 {
							md_blocks(
								opt.blocks[:],
								index * 4096 + 1024 + u32(j) * 32,
								wrap_w = max(f32(1), width - 24 - 18 - 20 - count_w),
							)
						} else {
							clay.Text(
								opt.label,
								{fontId = FONT_BODY, fontSize = BODY_FS, textColor = TEXT},
							)
						}
					}
					clay.Text(
						count,
						{
							fontId = FONT_BODY,
							fontSize = 13,
							textColor = TEXT_DIM,
							wrapMode = .None,
						},
					)
				}
				frac := msg.poll_total > 0 ? f32(opt.count) / f32(msg.poll_total) : 0
				if clay.UI(clay.ID("PollOptBarBg", slot))(
				{
					layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(4)}},
					backgroundColor = PLATE,
					cornerRadius = rr(2),
				},
				) {
					if frac > 0 {
						if clay.UI(clay.ID("PollOptBar", slot))(
						{
							layout = {
								sizing = {
									width = clay.SizingPercent(frac),
									height = clay.SizingGrow(),
								},
							},
							backgroundColor = ACCENT,
							cornerRadius = rr(2),
						},
						) {}
					}
				}
			}
		}
		if clay.UI(clay.ID("MsgPollFoot", index))({layout = {childGap = 8, padding = {top = 4}}}) {
			total :=
				msg.poll_total == 1 ? tr("1 vote") : fmt.tprintf(tr("%d votes"), msg.poll_total)
			if msg.poll_multi {
				total =
					msg.poll_total == 1 ? tr("1 voter") : fmt.tprintf(tr("%d voters"), msg.poll_total)
			}
			clay.Text(total, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
			if poll_voting(msg.id) {
				clay.Text(
					tr("Saving vote…"),
					{fontId = FONT_BODY, fontSize = 12, textColor = ACCENT},
				)
			}
			if !msg.poll_open {
				clay.Text(
					tr("Voting has ended."),
					{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
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

// The create-poll modal: question, fixed option rows (blanks are
// skipped), choice-mode toggle.
poll_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("PollModal"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {
				width = clay.SizingFixed(modal_w(clay.ID("PollModal"), 460)),
				height = clay.SizingFit({max = modal_h(680)}),
			},
			padding = clay.PaddingAll(16),
			childGap = 10,
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		floating = {
			attachTo = .Root,
			zIndex = 11,
			offset = {0, rise(clay.ID("PollModal"))},
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
		backgroundColor = CARD,
		cornerRadius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		clay.Text(tr("Create poll"), {fontId = FONT_TITLE, fontSize = 18, textColor = TEXT})
		poll_question_box(ui)
		for i in 0 ..< len(ui.poll_inputs) {
			if clay.UI(clay.ID("PollInputRow", u32(i)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					childGap = 8,
					childAlignment = {y = .Center},
				},
			},
			) {
				input_box(
					ui,
					fmt.tprintf("PollOptBox%d", i),
					&ui.poll_inputs[i],
					tr("Add an option..."),
					ui.focus == .PollOpt && ui.poll_focus == i,
					width = 0,
				)
				if len(ui.poll_inputs) > POLL_OPTS_MIN {
					if clay.UI(clay.ID("PollRemoveOpt", u32(i)))(
					{
						layout = {
							sizing = {clay.SizingFixed(44), clay.SizingFixed(44)},
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = hovered() ? HOVER : ROW_BG,
						cornerRadius = rr(8),
					},
					) {
						clay.Text(
							ICON_CLOSE,
							{fontId = FONT_ICON, fontSize = 14, textColor = TEXT_DIM},
						)
					}
					if clay.PointerOver(clay.ID("PollRemoveOpt", u32(i))) {
						tooltip(tr("Remove option"))
					}
				}
			}
		}
		if len(ui.poll_inputs) < POLL_OPTS_CAP {
			micro_button("PollAddOpt", tr("Add option"))
		}
		ready := poll_ready(ui)
		if !ready {
			clay.Text(
				tr("Add a question and at least two options."),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
			)
		}
		if clay.UI(clay.ID("PollBtnRow"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = single_pane() ? .TopToBottom : .LeftToRight,
				childGap = 8,
				childAlignment = {y = .Center},
			},
		},
		) {
			if clay.UI(clay.ID("PollChoiceRow"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(44)},
					childGap = 8,
					childAlignment = {y = .Center},
				},
			},
			) {
				toggle("PollMulti", ui.poll_multi_in)
				clay.Text(
					tr("Multiple choice"),
					{fontId = FONT_BODY, fontSize = 12, textColor = TEXT},
				)
			}
			if clay.UI(clay.ID("PollBtnGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("PollActions"))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					childGap = 8,
					childAlignment = {y = .Center},
				},
			},
			) {
				login_button("PollCancel", tr("Cancel"))
				login_big_button("PollCreate", tr("Create"), true, ready ? .Enabled : .Disabled)
			}
		}
	}
	scrollbar(clay.ID("PollModal"), 12)
}

@(private = "file")
poll_ready :: proc(ui: ^Ui_State) -> bool {
	if len(strings.trim_space(string(ui.poll_question[:]))) == 0 {
		return false
	}
	count := 0
	for option in ui.poll_inputs {
		if len(strings.trim_space(string(option[:]))) > 0 {
			count += 1
		}
	}
	return count >= POLL_OPTS_MIN
}

// Keep the modal's question separate from the composer's IDs and wrap
// cache, but use the same grapheme rendering, selection, and IME spans.
@(private = "file")
poll_q_lines :: proc(ui: ^Ui_State) -> []Wrap_Line {
	box := clay.GetElementData(clay.ID("PollQBox"))
	width := box.found ? box.boundingBox.width - 20 : modal_w(clay.ID("PollModal"), 460) - 52
	return wrapped_lines(string(ui.poll_question[:]), max(width - CARET_W, 1), BODY_FS, .Compose)
}

@(private = "file")
poll_question_box :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("PollQBox"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFit({min = 80})},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(10),
		},
		backgroundColor = ROW_BG,
		border = ui.focus == .PollQ ? focus_border(true) : clay.BorderElementConfig{color = FIELD_BORDER, width = bw()},
		cornerRadius = rr(8),
	},
	) {
		if len(ui.poll_question) == 0 && len(rl.Preedit()) == 0 {
			if clay.UI(clay.ID("PollQPlaceholder"))({layout = {childAlignment = {y = .Center}}}) {
				if ui.focus == .PollQ {
					caret()
				}
				clay.Text(
					tr("Ask a question..."),
					{fontId = FONT_BODY, fontSize = BODY_FS, textColor = TEXT_DIM},
				)
			}
		} else {
			text := string(ui.poll_question[:])
			lo, hi, head := field_sel(ui, &ui.poll_question)
			if ui.focus != .PollQ {
				head = -1
			}
			for line, i in poll_q_lines(ui) {
				h := head
				if i > 0 && head == line.start && text[line.start - 1] != '\n' {
					h = -1
				}
				compose_line(0x10000 + u32(i), text, line.start, line.end, lo, hi, h)
			}
		}
	}
}

@(private = "file")
poll_q_mouse :: proc(ui: ^Ui_State) -> bool {
	over := clay.PointerOver(clay.ID("PollQBox"))
	pressed := over && (rl.HasTouch() ? mouse_released() : mouse_pressed())
	dragging := !rl.HasTouch() && text_drag == &ui.poll_question && rl.IsMouseButtonDown(.LEFT)
	if !pressed && !dragging {
		return false
	}
	point := rl.GetMousePosition()
	point.x /= UI_ZOOM
	point.y /= UI_ZOOM
	text := string(ui.poll_question[:])
	hit := len(text)
	for line, i in poll_q_lines(ui) {
		row := clay.GetElementData(clay.ID("ComposeLine", 0x10000 + u32(i)))
		if row.found && point.y < row.boundingBox.y + row.boundingBox.height {
			hit =
				line.start +
				hit_compose_line(text[line.start:line.end], point.x - row.boundingBox.x)
			break
		}
	}
	ui.focus = .PollQ
	if rl.HasTouch() {
		touch_field = clay.ID("PollQBox")
	}
	ed_begin(ui, &ui.poll_question)
	if pressed && !shift_down() {
		ui.ed.selection = {hit, hit}
	} else {
		ui.ed.selection[0] = hit
	}
	ed_end(ui, &ui.poll_question)
	if !rl.HasTouch() {
		text_drag = &ui.poll_question
		text_drag_box = clay.ID("PollQBox")
	}
	caret_wake()
	return true
}

poll_close :: proc(ui: ^Ui_State) {
	ui.poll_open = false
	ui.focus = .Compose
}

// Blank modal: question, two empty option rows. Reserved to the cap so
// the edit state's pointers into the array survive "Add option".
poll_reset :: proc(ui: ^Ui_State) {
	clear(&ui.poll_question)
	for &b in ui.poll_inputs {
		delete(b)
	}
	clear(&ui.poll_inputs)
	reserve(&ui.poll_inputs, POLL_OPTS_CAP)
	for _ in 0 ..< POLL_OPTS_MIN {
		append(&ui.poll_inputs, [dynamic]u8{})
	}
	ui.poll_multi_in = false
	ui.poll_focus = 0
	ui.focus = .PollQ
}

// MDK assigns option ids, validates the poll and authors its event. Only
// conversation/thread context tags are supplied by the application.
poll_create :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	question := strings.trim_space(string(ui.poll_question[:]))
	options := make([dynamic]string, 0, len(ui.poll_inputs), context.temp_allocator)
	for i in 0 ..< len(ui.poll_inputs) {
		label := strings.trim_space(string(ui.poll_inputs[i][:]))
		if len(label) == 0 {
			continue
		}
		append(&options, label)
	}
	if len(question) == 0 || len(options) < POLL_OPTS_MIN {
		return
	}
	tags := make([dynamic][]string, context.temp_allocator)

	// A poll created inside a thread carries the root e tag and lives
	// in that thread's view.
	reply := issue_reply(ui)
	defer issue_reply_free(reply)
	if ui.compose_issue != "" {
		append(&tags, ..issue_reply_tags(reply))
	} else if cur := thread_cur(ui); len(cur) > 0 {
		ref := make([]string, 2, context.temp_allocator)
		ref[0] = "e"
		ref[1] = cur
		append(&tags, ref)
	}

	spawn_poll(
		ui,
		client,
		.Poll_Create,
		"",
		question,
		options[:],
		ui.poll_multi_in ? .Multiple_Choice : .Single_Choice,
		tags[:],
	)
	play_sound(.Send)
	poll_close(ui)
}

// Modal input: typing routes to the focused box, Tab walks the boxes,
// clicks hit the toggle and buttons. Captures everything while open.
handle_poll :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if rl.IsKeyPressed(.ESCAPE) {
		poll_close(ui)
		return
	}
	if ui.focus == .PollQ {
		edit_text(ui, &ui.poll_question, true)
	} else if ui.focus == .PollOpt {
		edit_text(ui, &ui.poll_inputs[ui.poll_focus])
	}
	// Tab walks question → options and wraps; position 0 is the question,
	// 1 + i is option i.
	if step := tab_step(); step != 0 {
		count := 1 + len(ui.poll_inputs)
		at := ui.focus == .PollOpt ? 1 + ui.poll_focus : 0
		at = (at + step + count) %% count
		ui.focus = at == 0 ? .PollQ : .PollOpt
		ui.poll_focus = max(at - 1, 0)
		return
	}
	// Enter inserts a question line; option fields advance top to bottom.
	if rl.IsKeyPressed(.ENTER) {
		if ui.focus == .PollQ {
			ed_insert(ui, &ui.poll_question, "\n")
		} else if ui.poll_focus < len(ui.poll_inputs) - 1 {
			ui.poll_focus += 1
		} else if len(ui.poll_inputs) < POLL_OPTS_CAP && len(ui.poll_inputs[ui.poll_focus]) > 0 {
			append(&ui.poll_inputs, [dynamic]u8{})
			ui.poll_focus += 1
		}
		return
	}
	if poll_q_mouse(ui) {
		return
	}
	for i in 0 ..< len(ui.poll_inputs) {
		if field_mouse(ui, &ui.poll_inputs[i], fmt.tprintf("PollOptBox%d", i)) {
			ui.focus = .PollOpt
			ui.poll_focus = i
			return
		}
	}
	if !mouse_released() {
		return
	}
	if len(ui.poll_inputs) > POLL_OPTS_MIN {
		for i in 0 ..< len(ui.poll_inputs) {
			if !clay.PointerOver(clay.ID("PollRemoveOpt", u32(i))) {
				continue
			}
			// Removing a row moves the remaining buffers. Drop their old
			// edit pointer before moving them so undo cannot target a neighbour.
			if ui.ed_target != &ui.poll_question {
				ui.ed_target = nil
			}
			delete(ui.poll_inputs[i])
			ordered_remove(&ui.poll_inputs, i)
			if ui.poll_focus > i {
				ui.poll_focus -= 1
			}
			ui.poll_focus = min(ui.poll_focus, len(ui.poll_inputs) - 1)
			return
		}
	}
	if clay.PointerOver(clay.ID("PollAddOpt")) && len(ui.poll_inputs) < POLL_OPTS_CAP {
		append(&ui.poll_inputs, [dynamic]u8{})
		ui.focus = .PollOpt
		ui.poll_focus = len(ui.poll_inputs) - 1
		return
	}
	if clay.PointerOver(clay.ID("PollChoiceRow")) {
		ui.poll_multi_in = !ui.poll_multi_in
		return
	}
	if clay.PointerOver(clay.ID("PollCreate")) {
		if poll_ready(ui) {
			poll_create(ui, client)
		}
		return
	}
	if clay.PointerOver(clay.ID("PollCancel")) {
		poll_close(ui)
		return
	}
	if !clay.PointerOver(clay.ID("PollModal")) {
		if len(ui.poll_question) > 0 {
			return
		}
		for option in ui.poll_inputs {
			if len(option) > 0 {
				return
			}
		}
		poll_close(ui)
	}
}
