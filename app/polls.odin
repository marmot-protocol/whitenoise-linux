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

// The create-poll modal: question, fixed option rows (blanks are
// skipped), choice-mode toggle.
poll_modal :: proc(ui: ^Ui_State) {
	if nendo.box(nendo.id("PollModal"))(
	{
		direction = .Column,
		width = nendo.fixed(modal_w(nendo.id("PollModal"), 460)),
		height = nendo.fit(max = modal_h(680)),
		padding = nendo.pad(16),
		gap = 10,
		clip = {y = true, scroll = true},
		floating = {
			attach_to = .Root,
			z = 11,
			offset = {0, rise(nendo.id("PollModal"))},
			attach = {element = .Center_Center, parent = .Center_Center},
		},
		color = CARD,
		radius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		nendo.text(tr("Create poll"), {font = FONT_TITLE, size = 18, color = TEXT})
		poll_question_box(ui)
		for i in 0 ..< len(ui.poll_inputs) {
			if nendo.box(nendo.id("PollInputRow", u32(i)))(
			{width = nendo.grow(), gap = 8, align = {y = .Center}},
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
					if nendo.box(nendo.id("PollRemoveOpt", u32(i)))(
					{
						width = nendo.fixed(44),
						height = nendo.fixed(44),
						align = {x = .Center, y = .Center},
						color = hovered() ? HOVER : ROW_BG,
						radius = rr(8),
					},
					) {
						nendo.text(ICON_CLOSE, {font = FONT_ICON, size = 14, color = TEXT_DIM})
					}
					if nendo.pointer_over(nendo.id("PollRemoveOpt", u32(i))) {
						tooltip(tr("Remove option"))
					}
				}
			}
		}
		if len(ui.poll_inputs) < POLL_OPTS_CAP {
			micro_button("PollAddOpt", tr("Add option"))
		}
		if ui.poll_error != .None {
			nendo.text(
				ui.poll_error == .Question ? tr("Add a question for your poll.") : tr("Add at least two options."),
				{font = FONT_BODY, size = 12, color = DANGER},
			)
		}
		if nendo.box(nendo.id("PollBtnRow"))(
		{
			width = nendo.grow(),
			direction = single_pane() ? .Column : .Row,
			gap = 8,
			align = {y = .Center},
		},
		) {
			if nendo.box(nendo.id("PollChoiceRow"))(
			{width = nendo.grow(), height = nendo.fixed(44), gap = 8, align = {y = .Center}},
			) {
				toggle("PollMulti", ui.poll_multi_in)
				nendo.text(tr("Multiple choice"), {font = FONT_BODY, size = 12, color = TEXT})
			}
			if nendo.box(nendo.id("PollBtnGap"))({width = nendo.grow()}) {}
			if nendo.box(nendo.id("PollActions"))(
			{width = nendo.grow(), gap = 8, align = {y = .Center}},
			) {
				login_button("PollCancel", tr("Cancel"))
				login_big_button("PollCreate", tr("Create"), true)
			}
		}
	}
	scrollbar(nendo.id("PollModal"), 12)
}

// Keep the modal's question separate from the composer's IDs and wrap
// cache, but use the same grapheme rendering, selection, and IME spans.
@(private = "file")
poll_q_lines :: proc(ui: ^Ui_State) -> []Wrap_Line {
	box := nendo.element(nendo.id("PollQBox"))
	width := box.found ? box.rect.width - 20 : modal_w(nendo.id("PollModal"), 460) - 52
	return wrapped_lines(string(ui.poll_question[:]), max(width - CARET_W, 1), BODY_FS, .Compose)
}

@(private = "file")
poll_question_box :: proc(ui: ^Ui_State) {
	if nendo.box(nendo.id("PollQBox"))(
	{
		width = nendo.grow(),
		height = nendo.fit(min = 80),
		direction = .Column,
		padding = nendo.pad(10),
		color = ROW_BG,
		border = ui.focus == .PollQ ? focus_border(true) : nendo.Border{color = FIELD_BORDER, width = bw()},
		radius = rr(8),
	},
	) {
		if len(ui.poll_question) == 0 && len(rl.Preedit()) == 0 {
			if nendo.box(nendo.id("PollQPlaceholder"))({align = {y = .Center}}) {
				if ui.focus == .PollQ {
					caret()
				}
				nendo.text(
					tr("Ask a question..."),
					{font = FONT_BODY, size = BODY_FS, color = TEXT_DIM},
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
	over := nendo.pointer_over(nendo.id("PollQBox"))
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
		row := nendo.element(nendo.id("ComposeLine", 0x10000 + u32(i)))
		if row.found && point.y < row.rect.y + row.rect.height {
			hit = line.start + hit_compose_line(text[line.start:line.end], point.x - row.rect.x)
			break
		}
	}
	ui.focus = .PollQ
	if rl.HasTouch() {
		touch_field = nendo.id("PollQBox")
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
		text_drag_box = nendo.id("PollQBox")
	}
	caret_wake()
	return true
}

poll_close :: proc(ui: ^Ui_State) {
	ui.poll_open = false
	ui.poll_error = .None
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
	ui.poll_error = .None
	ui.poll_focus = 0
	ui.focus = .PollQ
}

// MDK assigns option ids, validates the poll and authors its event. Only
// conversation/thread context tags are supplied by the application.
poll_create :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	ui.poll_error = poll_input_error(ui)
	if ui.poll_error != .None {return}
	question := strings.trim_space(string(ui.poll_question[:]))
	options := make([dynamic]string, 0, len(ui.poll_inputs), context.temp_allocator)
	for i in 0 ..< len(ui.poll_inputs) {
		label := strings.trim_space(string(ui.poll_inputs[i][:]))
		if len(label) == 0 {
			continue
		}
		append(&options, label)
	}
	tags := make([dynamic][]string, context.temp_allocator)

	// A poll created inside a thread carries the root e tag and lives
	// in that thread's view.
	if cur := thread_cur(ui); len(cur) > 0 {
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
	if ui.poll_error != .None {
		ui.poll_error = poll_input_error(ui)
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
			if !nendo.pointer_over(nendo.id("PollRemoveOpt", u32(i))) {
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
	if nendo.pointer_over(nendo.id("PollAddOpt")) && len(ui.poll_inputs) < POLL_OPTS_CAP {
		append(&ui.poll_inputs, [dynamic]u8{})
		ui.focus = .PollOpt
		ui.poll_focus = len(ui.poll_inputs) - 1
		return
	}
	if nendo.pointer_over(nendo.id("PollChoiceRow")) {
		ui.poll_multi_in = !ui.poll_multi_in
		return
	}
	if nendo.pointer_over(nendo.id("PollCreate")) {
		poll_create(ui, client)
		return
	}
	if nendo.pointer_over(nendo.id("PollCancel")) {
		poll_close(ui)
		return
	}
	if !nendo.pointer_over(nendo.id("PollModal")) {
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
