// Native MDK polls. The timeline owns the authenticated tally and local
// selection; the UI owns copied display data until its next snapshot.
package main

import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

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
	if clay.UI(clay.ID("MsgPoll", index))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			childGap = 4,
			sizing = {width = clay.SizingGrow({max = 300})},
		},
	},
	) {
		for opt, j in msg.poll_opts {
			slot := index * 64 + u32(j)
			if clay.UI(clay.ID("PollOptRow", slot))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					childGap = 4,
					padding = clay.PaddingAll(8),
				},
				backgroundColor = hovered() && msg.poll_open ? HOVER : ROW_BG,
				cornerRadius = rr(8),
				border = opt.mine ? clay.BorderElementConfig{color = ACCENT, width = bw()} : {},
			},
			) {
				if clay.UI(clay.ID("PollOptTop", slot))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						childGap = 6,
						childAlignment = {y = .Center},
					},
				},
				) {
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
							md_blocks(opt.blocks[:], index * 4096 + 1024 + u32(j) * 32)
						} else {
							clay.Text(
								opt.label,
								{fontId = FONT_BODY, fontSize = 13, textColor = TEXT},
							)
						}
					}
					clay.Text(
						fmt.tprintf("%d", opt.count),
						{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
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
		if clay.UI(clay.ID("MsgPollFoot", index))({layout = {childGap = 6}}) {
			clay.Text(
				fmt.tprintf(tr("%d votes"), msg.poll_total),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
			)
			if !msg.poll_open {
				clay.Text(
					tr("Voting has ended."),
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
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
	selected := poll_selection(msg, opt)
	// Native polls require at least one selection; keep the final vote.
	if len(selected) == 0 {return}
	spawn_poll(ui, client, .Poll_Vote, msg.id, "", selected)
	play_sound(.Send)
}

// The create-poll modal: question, fixed option rows (blanks are
// skipped), choice-mode toggle.
poll_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("PollModal"))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(modal_w(clay.ID("PollModal"), 460))},
			padding = clay.PaddingAll(16),
			childGap = 10,
		},
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
		input_box(ui, "PollQBox", &ui.poll_question, tr("Ask a question..."), ui.focus == .PollQ)
		for i in 0 ..< len(ui.poll_inputs) {
			input_box(
				ui,
				fmt.tprintf("PollOptBox%d", i),
				&ui.poll_inputs[i],
				tr("Add an option..."),
				ui.focus == .PollOpt && ui.poll_focus == i,
			)
		}
		if len(ui.poll_inputs) < POLL_OPTS_CAP {
			micro_button("PollAddOpt", "Add option")
		}
		if clay.UI(clay.ID("PollBtnRow"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 8,
				childAlignment = {y = .Center},
			},
		},
		) {
			if ui.poll_multi_in {
				micro_button("PollMulti", "Multiple choice")
			} else {
				micro_button("PollMulti", "Single choice")
			}
			if clay.UI(clay.ID("PollBtnGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			login_button("PollCancel", "Cancel")
			login_button("PollCreate", "Create")
		}
	}
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
		edit_text(ui, &ui.poll_question)
	} else if ui.focus == .PollOpt {
		edit_text(ui, &ui.poll_inputs[ui.poll_focus])
	}
	// Enter advances question → options top to bottom, growing a new
	// row past the last one (the shim has no Tab key).
	if rl.IsKeyPressed(.ENTER) {
		if ui.focus == .PollQ {
			ui.focus = .PollOpt
			ui.poll_focus = 0
		} else if ui.poll_focus < len(ui.poll_inputs) - 1 {
			ui.poll_focus += 1
		} else if len(ui.poll_inputs) < POLL_OPTS_CAP && len(ui.poll_inputs[ui.poll_focus]) > 0 {
			append(&ui.poll_inputs, [dynamic]u8{})
			ui.poll_focus += 1
		}
		return
	}
	if field_mouse(ui, &ui.poll_question, "PollQBox") {
		ui.focus = .PollQ
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
	if clay.PointerOver(clay.ID("PollAddOpt")) && len(ui.poll_inputs) < POLL_OPTS_CAP {
		append(&ui.poll_inputs, [dynamic]u8{})
		ui.focus = .PollOpt
		ui.poll_focus = len(ui.poll_inputs) - 1
		return
	}
	if clay.PointerOver(clay.ID("PollMulti")) {
		ui.poll_multi_in = !ui.poll_multi_in
		return
	}
	if clay.PointerOver(clay.ID("PollCreate")) {
		poll_create(ui, client)
		return
	}
	if clay.PointerOver(clay.ID("PollCancel")) || !clay.PointerOver(clay.ID("PollModal")) {
		poll_close(ui)
	}
}
