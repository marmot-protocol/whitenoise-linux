// NIP-88 polls over Marmot custom events.
//
//   create        vote                  render
//   kind 1068 ──▶ kind 1018 ──▶ load_timeline tally ──▶ option bars
//   content=Q     ["e", poll]           (latest vote per sender wins)
//   ["option",    ["response", id]…
//    id, label]…
//
// The poll is a normal timeline row whose body is the question;
// poll_parse fills Msg_Ui.poll_*, poll_tally folds the collected
// votes, poll_block draws the options, handlers route clicks to
// poll_vote. Votes are fire-and-forget: the tally updates when the
// ack's reload lands, no optimistic ghost.
package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

// One sender's latest kind-1018 response, borrowed from the timeline
// page for the duration of load_timeline.
Poll_Vote :: struct {
	at:   u64,
	opts: []string, // response tag values, wire order
}

// Fold one vote record into the per-poll map; latest timestamp wins.
poll_vote_collect :: proc(votes: ^map[string]map[string]Poll_Vote, record: ^marmot.Timeline_Message_Record) {
	poll_id := first_event_ref(record)
	if len(poll_id) == 0 || record.sender == nil {
		return
	}
	sender := string(record.sender)

	opts := make([dynamic]string, context.temp_allocator)
	for t in 0 ..< record.tags_len {
		tag := &record.tags[t]
		if tag.values_len >= 2 && string(tag.values[0]) == "response" {
			append(&opts, string(tag.values[1]))
		}
	}

	per, ok := votes[poll_id]
	if !ok {
		per = make(map[string]Poll_Vote, context.temp_allocator)
	}
	if prev, seen := per[sender]; !seen || record.timeline_at > prev.at {
		per[sender] = Poll_Vote{at = record.timeline_at, opts = opts[:]}
	}
	votes[poll_id] = per
}

// Fill Msg_Ui.poll_* from a kind-1068 record's tags. Option labels run
// through marmot's markdown parser, the same pass message bodies get,
// so poll_block can draw them with md_blocks.
poll_parse :: proc(client: ^marmot.Client, msg: ^Msg_Ui, record: ^marmot.Timeline_Message_Record) {
	for t in 0 ..< record.tags_len {
		tag := &record.tags[t]
		if tag.values_len >= 3 && string(tag.values[0]) == "option" {
			opt := Poll_Opt_Ui{
				id    = strings.clone(string(tag.values[1])),
				label = strings.clone(string(tag.values[2])),
			}
			doc: ^marmot.Markdown_Document
			if marmot.parse_markdown(client, strings.clone_to_cstring(opt.label, context.temp_allocator), &doc) == .OK {
				convert_blocks(&opt.blocks, doc.blocks, doc.blocks_len, false)
				marmot.markdown_document_free(doc)
			}
			append(&msg.poll_opts, opt)
		} else if tag.values_len >= 2 && string(tag.values[0]) == "polltype" {
			msg.poll_multi = string(tag.values[1]) == "multiplechoice"
		} else if tag.values_len >= 2 && string(tag.values[0]) == "endsAt" {
			msg.poll_ends, _ = strconv.parse_u64(string(tag.values[1]))
		}
	}
}

// Count the collected votes onto the option rows. NIP-88: one vote per
// sender (poll_vote_collect kept the latest), single choice takes the
// first response tag, multiple choice the first occurrence of each id;
// votes after endsAt don't count.
poll_tally :: proc(msg: ^Msg_Ui, per: map[string]Poll_Vote, self: string) {
	for sender, v in per {
		if msg.poll_ends != 0 && v.at > msg.poll_ends {
			continue
		}
		counted := false
		seen := make(map[string]bool, context.temp_allocator)
		for opt_id in v.opts {
			if seen[opt_id] {
				continue
			}
			seen[opt_id] = true
			for &opt in msg.poll_opts {
				if opt.id != opt_id {
					continue
				}
				opt.count += 1
				if sender == self {
					opt.mine = true
				}
				counted = true
				break
			}
			if !msg.poll_multi {
				break
			}
		}
		if counted {
			msg.poll_total += 1
		}
	}
}

poll_closed :: proc(msg: Msg_Ui) -> bool {
	return msg.poll_ends != 0 && u64(time.time_to_unix(time.now())) > msg.poll_ends
}

// The option bars under a poll's question, drawn by message_row.
// Clicks are routed by handle_chat to poll_vote.
poll_block :: proc(index: u32, msg: Msg_Ui) {
	if clay.UI(clay.ID("MsgPoll", index))(
	{layout = {layoutDirection = .TopToBottom, childGap = 4, sizing = {width = clay.SizingGrow({max = 300})}}},
	) {
		for opt, j in msg.poll_opts {
			slot := index * 64 + u32(j)
			if clay.UI(clay.ID("PollOptRow", slot))(
			{
				layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 4, padding = clay.PaddingAll(8)},
				backgroundColor = hovered() && !poll_closed(msg) ? HOVER : ROW_BG,
				cornerRadius = rr(8),
				border = opt.mine ? clay.BorderElementConfig{color = ACCENT, width = bw()} : {},
			},
			) {
				if clay.UI(clay.ID("PollOptTop", slot))(
				{layout = {sizing = {width = clay.SizingGrow()}, childGap = 6, childAlignment = {y = .Center}}},
				) {
					// Label drawn by the message markdown renderer; the
					// grow column pushes the count to the right edge.
					// Id window: [1024, 3072) inside the row's 4096 block
					// (body is below, reply preview at +3072), 32 per option.
					if clay.UI(clay.ID("PollOptLabel", slot))(
					{layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 2}},
					) {
						if len(opt.blocks) > 0 {
							md_blocks(opt.blocks[:], index * 4096 + 1024 + u32(j) * 32)
						} else {
							clay.Text(opt.label, {fontId = FONT_BODY, fontSize = 13, textColor = TEXT})
						}
					}
					clay.Text(fmt.tprintf("%d", opt.count), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO})
				}
				frac := msg.poll_total > 0 ? f32(opt.count) / f32(msg.poll_total) : 0
				if clay.UI(clay.ID("PollOptBarBg", slot))(
				{layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(4)}}, backgroundColor = PLATE, cornerRadius = rr(2)},
				) {
					if frac > 0 {
						if clay.UI(clay.ID("PollOptBar", slot))(
						{layout = {sizing = {width = clay.SizingPercent(frac), height = clay.SizingGrow()}}, backgroundColor = ACCENT, cornerRadius = rr(2)},
						) {}
					}
				}
			}
		}
		if clay.UI(clay.ID("MsgPollFoot", index))({layout = {childGap = 6}}) {
			clay.Text(fmt.tprintf(tr("%d votes"), msg.poll_total), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
			if poll_closed(msg) {
				clay.Text(tr("Voting has ended."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
			}
		}
	}
}

// Send this sender's full response set, replacing any earlier vote:
// single choice replaces with the clicked option, multiple choice
// toggles it within the currently voted set.
poll_vote :: proc(ui: ^Ui_State, client: ^marmot.Client, msg: ^Msg_Ui, opt: int) {
	if poll_closed(msg^) {
		return
	}
	tags := make([dynamic][]string, context.temp_allocator)
	ref := make([]string, 2, context.temp_allocator)
	ref[0] = "e"
	ref[1] = msg.id
	append(&tags, ref)

	for o, j in msg.poll_opts {
		picked := msg.poll_multi ? (j == opt ? !o.mine : o.mine) : j == opt
		if !picked {
			continue
		}
		row := make([]string, 2, context.temp_allocator)
		row[0] = "response"
		row[1] = o.id
		append(&tags, row)
	}

	spawn_custom(ui, client, KIND_POLL_VOTE, tags[:], "")
	play_sound(.Send)
}

// The create-poll modal: question, fixed option rows (blanks are
// skipped), choice-mode toggle.
poll_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("PollModal"))(
	{
		layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(modal_w(clay.ID("PollModal"), 460))}, padding = clay.PaddingAll(16), childGap = 10},
		floating = {attachTo = .Root, zIndex = 11, offset = {0, rise(clay.ID("PollModal"))}, attachment = {element = .CenterCenter, parent = .CenterCenter}},
		backgroundColor = CARD,
		cornerRadius = rr(12),
		border = {color = ELEVATED_BORDER, width = bw()},
	},
	) {
		clay.Text(tr("Create poll"), {fontId = FONT_TITLE, fontSize = 18, textColor = TEXT})
		input_box(ui, "PollQBox", &ui.poll_question, tr("Ask a question..."), ui.focus == .PollQ)
		for i in 0 ..< len(ui.poll_inputs) {
			input_box(ui, fmt.tprintf("PollOptBox%d", i), &ui.poll_inputs[i], tr("Add an option..."), ui.focus == .PollOpt && ui.poll_focus == i)
		}
		if len(ui.poll_inputs) < POLL_OPTS_CAP {
			micro_button("PollAddOpt", "Add option")
		}
		if clay.UI(clay.ID("PollBtnRow"))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 8, childAlignment = {y = .Center}}}) {
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

// Publish the kind-1068 event and close; needs a question and at
// least two non-blank options.
poll_create :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	question := strings.trim_space(string(ui.poll_question[:]))
	tags := make([dynamic][]string, context.temp_allocator)
	n := 0
	for i in 0 ..< len(ui.poll_inputs) {
		label := strings.trim_space(string(ui.poll_inputs[i][:]))
		if len(label) == 0 {
			continue
		}
		row := make([]string, 3, context.temp_allocator)
		row[0] = "option"
		row[1] = fmt.tprintf("%d", n)
		row[2] = label
		append(&tags, row)
		n += 1
	}
	if len(question) == 0 || n < POLL_OPTS_MIN {
		return
	}
	row := make([]string, 2, context.temp_allocator)
	row[0] = "polltype"
	row[1] = ui.poll_multi_in ? "multiplechoice" : "singlechoice"
	append(&tags, row)

	// A poll created inside a thread carries the root e tag and lives
	// in that thread's view.
	if cur := thread_cur(ui); len(cur) > 0 {
		ref := make([]string, 2, context.temp_allocator)
		ref[0] = "e"
		ref[1] = cur
		append(&tags, ref)
	}

	spawn_custom(ui, client, KIND_POLL, tags[:], question)
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
