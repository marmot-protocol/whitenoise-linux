package main

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:time"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"

// Subscription opening window and each cursor-based pagination step.
TL_PAGE :: 100

load_timeline :: proc(client: ^marmot.Client, ui: ^Ui_State, search: string = "") {
	if client == nil || ui.selected < 0 {
		return
	}
	if !timeline_scope(ui, search) || thread.is_done(timeline_job.worker) {
		timeline_start(client, ui, search)
		return
	}
	// Local hides, completed sends, media retries, and profile changes only
	// need to re-project the retained snapshot. Wire changes arrive via next.
	if timeline_page != nil {
		timeline_apply(client, ui, timeline_page)
	}
}

@(private)
timeline_apply :: proc(client: ^marmot.Client, ui: ^Ui_State, page: ^marmot.Timeline_Page) {
	timing_start := time.tick_now()
	defer local_timing_end(.timeline_apply, timing_start)
	page := page
	combined: marmot.Timeline_Page
	if page == timeline_page && len(timeline_history) > 0 {
		records := make([dynamic]marmot.Timeline_Message_Record, context.temp_allocator)
		for i := len(timeline_history) - 1;
		    i >= 0;
		    i -= 1 {older := timeline_history[i]; append(&records, ..older.messages[:older.messages_len])}
		append(&records, ..page.messages[:page.messages_len])
		combined = {
			messages     = raw_data(records[:]),
			messages_len = uint(len(records)),
		}
		page = &combined
	}
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	ui.tl_has_more = page.has_more_before
	ui.tl_has_after = page.has_more_after
	agent_collect(client, ui, page)

	// Message textures are owned by the media_textures session cache
	// now (shared across reloads), so rows never free them.
	// Resolve kind-1009 edits, mirroring chatmodel.rs aggregate_edits:
	// only edits whose authenticated sender authored the target count,
	// ordered by (received_at, id), newest wins as the displayed text.
	author_of := make(map[string]string, context.temp_allocator)
	for i in 0 ..< page.messages_len {
		record := &page.messages[i]
		if (record.kind == 9 || record.kind == 1111) && record.message_id_hex != nil {
			author_of[string(record.message_id_hex)] =
				record.sender != nil ? string(record.sender) : ""
		}
	}
	edits := make(map[string][dynamic]Edit_Rec, context.temp_allocator)
	defer {
		for _, versions in edits {
			delete(versions)
		}
	}
	for i in 0 ..< page.messages_len {
		record := &page.messages[i]
		if record.kind != 1009 ||
		   record.plaintext == nil ||
		   len(strings.trim_space(string(record.plaintext))) == 0 {
			continue
		}
		target := first_event_ref(record)
		author, known := author_of[target]
		if !known || record.sender == nil || author != string(record.sender) {
			continue
		}
		versions := edits[target]
		append(
			&versions,
			Edit_Rec {
				at = record.received_at,
				id = record.message_id_hex != nil ? string(record.message_id_hex) : "",
				record = record,
			},
		)
		edits[target] = versions
	}
	for _, &versions in edits {
		slice.sort_by(versions[:], proc(a, b: Edit_Rec) -> bool {
			return a.at == b.at ? a.id < b.id : a.at < b.at
		})
	}

	// Row indices and block ids move with the reload, so a live update
	// invalidates a selection: drop it unless a drag is in progress.
	if !sel_dragging {
		sel_clear(ui)
	}

	// Ids present before this reload. marmot stores an outgoing message
	// locally before the relay ack, so its record shows up while the
	// send worker is still in flight; the build loop below hides that
	// copy so the grayed pending row stays alone until the ack (slint
	// keeps the overlay until ack too).
	old_times := make(map[string]time.Tick, context.temp_allocator)
	for old in ui.messages {
		old_times[old.id] = old.visible_since
	}
	inflight := make(map[string]int, context.temp_allocator)
	for p in ui.pending {
		if !p.failed && len(p.atts) == 0 && p.group_id == ui.chats[ui.selected].group_id {
			inflight[p.body] += 1
		}
	}
	// NIP-88 votes and thread replies fold into other rows: collected
	// during the walk, applied once every row is built (a vote can sit
	// either side of its poll in the page). Values borrow the page.
	votes := make(map[string]map[string]Poll_Vote, context.temp_allocator) // poll id → sender → latest
	thread_counts := make(map[string]int, context.temp_allocator)

	previous := make([]Msg_Ui, len(ui.messages), context.temp_allocator)
	copy(previous, ui.messages[:])
	previous_ids := make(map[string]int, context.temp_allocator)
	group_id := ui.chats[ui.selected].group_id
	if ui.messages_group == group_id && ui.messages_account == ui.account_ref {
		for msg, i in previous {previous_ids[msg.id] = i}
	}
	delete(ui.messages_group)
	delete(ui.messages_account)
	ui.messages_group = strings.clone(group_id)
	ui.messages_account = strings.clone(ui.account_ref)
	defer append(&retired_messages, ..previous)
	clear(&ui.messages)
	xdc_collect_begin()
	defer xdc_collect_end()
	issue_comments := make(map[string]bool, context.temp_allocator)
	for row in ui.issues {for comment in row.comments {issue_comments[comment.id] = true}}
	for i in 0 ..< page.messages_len {
		record := &page.messages[i]
		if ui.issues_open &&
		   record.kind != 1009 &&
		   !issue_comments[string(record.message_id_hex)] {continue}
		// Edit and delete records act on other rows; they never render
		// as their own message.
		if record.kind == 1009 ||
		   record.kind == 5 ||
		   (issue_chat_hidden(record.kind, record.tags[:record.tags_len]) &&
				   !issue_comments[string(record.message_id_hex)]) {
			continue
		}
		if record.kind == AGENT_ACTIVITY || record.kind == AGENT_OPERATION {
			continue
		}
		stream_body: string
		if record.kind == AGENT_STREAM_START {
			visible: bool
			stream_body, visible = agent_body(record)
			if !visible {
				continue
			}
		}

		// A kind-1018 vote folds into its poll's tally; never a row.
		// Latest per sender wins here, per NIP-88.
		if record.kind == KIND_POLL_VOTE {
			poll_vote_collect(&votes, record)
			continue
		}

		id_str := record.message_id_hex != nil ? string(record.message_id_hex) : ""
		sender := record.sender != nil ? string(record.sender) : "?"
		mine := record.direction != nil && string(record.direction) == "sent"

		// Also discard our persisted tombstones from before local hiding.
		if ui.hidden[id_str] || (mine && record.deleted) {
			continue
		}

		// Webxdc state updates ride text messages; they feed the
		// running app and never render as rows.
		if session, payload, is_xdc := xdc_decode(
			string(record.plaintext != nil ? record.plaintext : ""),
		); is_xdc {
			xdc_collect(session, payload)
			continue
		}

		// System rows use the same mention chips as message bodies.
		// Member additions also keep the subject for the wave button.
		if record.kind == 1210 && record.group_system != nil {
			sys := record.group_system
			kind := sys.system_type != nil ? string(sys.system_type) : ""
			subject := sys.subject_account_id_hex != nil ? string(sys.subject_account_id_hex) : ""
			is_add := kind == "member_added" && len(subject) > 0
			msg := Msg_Ui {
				id       = strings.clone(id_str),
				body     = strings.clone(system_text(client, sys)),
				sys_text = strings.clone(system_text(client, sys, .Mentions)),
				at       = format_when(record.timeline_at),
				at_full  = format_full(record.timeline_at),
				day      = format_day(record.timeline_at),
				system   = true,
			}
			if is_add {
				msg.sys_added_hex = strings.clone(subject)
			}
			append(&ui.messages, msg)
			continue
		}

		// A shared theme rides its own kind: the body is a toml pack,
		// which renders as an offer card rather than as text. An
		// unparseable one is dropped, not shown half-read.
		if record.kind == THEME_EVENT_KIND {
			toml := string(record.plaintext != nil ? record.plaintext : "")
			name := theme_offer_name(toml)
			if len(name) == 0 {
				continue
			}
			info := profile_info(client, sender)
			label := info.name
			if len(label) == 0 {
				label = mine ? "you" : short_hex(sender)
			}
			append(
				&ui.messages,
				Msg_Ui {
					id = strings.clone(id_str),
					sender = strings.clone(label),
					sender_id = strings.clone(sender),
					pic_url = strings.clone(info.pic_url),
					theme_name = strings.clone(name),
					theme_toml = strings.clone(toml),
					theme_swatch = theme_swatches(name, toml),
					at = format_when(record.timeline_at),
					at_full = format_full(record.timeline_at),
					day = format_day(record.timeline_at),
					mine = mine,
				},
			)
			continue
		}

		// Sender label + picture from the kind-0 cache; hex fallback
		// (or "you") when the profile is unknown.
		info := profile_info(client, sender)
		label := info.name
		if len(label) == 0 {
			label = mine ? "you" : short_hex(sender)
		}

		if old, found := previous_ids[id_str];
		   found &&
		   len(edits[id_str]) == 0 &&
		   message_matches(previous[old], record, label, info.pic_url) {
			msg := previous[old]
			msg.thread_replies = 0
			if old != len(ui.messages) {msg.row_height = 0}
			append(&ui.messages, msg)
			previous[old] = {} // ownership moved into the new snapshot
			continue
		}

		// Other participants' deletions retain their placeholder row.
		if record.deleted {
			append(
				&ui.messages,
				Msg_Ui {
					id = strings.clone(id_str),
					sender = strings.clone(label),
					sender_id = strings.clone(sender),
					pic_url = strings.clone(info.pic_url),
					at = format_when(record.timeline_at),
					at_full = format_full(record.timeline_at),
					day = format_day(record.timeline_at),
					mine = mine,
					deleted = true,
					thread_of = strings.clone(first_event_ref(record)),
				},
			)
			continue
		}

		// An edited message renders the newest edit's content under the
		// original id and row position.
		content := record
		versions, has_edits := edits[id_str]
		if has_edits && len(versions) > 0 {
			content = versions[len(versions) - 1].record
		}
		body := content.plaintext != nil ? string(content.plaintext) : ""
		if record.kind == AGENT_STREAM_START {
			body = stream_body
		}

		// The local copy of an in-flight optimistic send: skip it, the
		// pending row is its visual until the ack lands.
		if mine && !(id_str in old_times) && inflight[body] > 0 {
			inflight[body] -= 1
			continue
		}

		msg := Msg_Ui {
			id        = strings.clone(id_str),
			sticker   = sticker_from_record(record),
			sender    = strings.clone(label),
			sender_id = strings.clone(sender),
			pic_url   = strings.clone(info.pic_url),
			body      = strings.clone(body),
			at        = format_when(record.timeline_at),
			at_full   = format_full(record.timeline_at),
			day       = format_day(record.timeline_at),
			mine      = mine,
			edited    = record.edit != nil || (has_edits && len(versions) > 0),
			effect    = record_effect(record),
		}
		// A kind-1068 poll renders its question as the body plus the
		// option bars parsed here; a kind-1111 thread message leaves
		// the main timeline for its root's thread panel.
		if record.kind == KIND_POLL {
			poll_parse(client, &msg, record)
		}
		// A kind-1111 thread message, or a poll created inside a
		// thread, references its root as the first e tag and renders
		// only in that thread's view.
		if record.kind == KIND_THREAD || record.kind == KIND_POLL {
			if root := first_event_ref(record); len(root) > 0 {
				msg.thread_of = strings.clone(root)
				thread_counts[msg.thread_of] += 1
			}
		}
		// A burst plays the first time its message is seen, not on every
		// reload (effects.odin keeps the seen set).
		burst_arrive(msg.id, msg.effect, mine)
		if has_edits {
			original := record.plaintext != nil ? string(record.plaintext) : ""
			append(
				&msg.history,
				Edit_Version{at = format_when(record.timeline_at), text = strings.clone(original)},
			)
			for v in versions {
				append(
					&msg.history,
					Edit_Version {
						at = format_when(v.record.timeline_at),
						text = strings.clone(
							v.record.plaintext != nil ? string(v.record.plaintext) : "",
						),
					},
				)
			}
		}
		// Edit records and poll questions arrive without parsed content
		// tokens; run the text through marmot's markdown parser so they
		// render like any other body.
		cover, secret := hidden_message(body)
		msg.secrets = secret_layers(client, secret)
		if old, found := previous_ids[id_str]; found && previous[old].body == body {
			for &layer, j in msg.secrets {
				if j < len(previous[old].secrets) {layer.open = previous[old].secrets[j].open}
			}
		}
		if secret != "" ||
		   ((msg.edited || record.kind == KIND_POLL || record.kind == KIND_THREAD) &&
				   content.content_tokens.blocks_len == 0 &&
				   len(body) > 0) {
			doc: ^marmot.Markdown_Document
			if marmot.parse_markdown(
				   client,
				   strings.clone_to_cstring(cover, context.temp_allocator),
				   &doc,
			   ) ==
			   .OK {
				convert_blocks(
					&msg.blocks,
					doc.blocks,
					doc.blocks_len,
					false,
					([^]u8)(doc.blank_lines_before)[:doc.blank_lines_before_len],
				)
				marmot.markdown_document_free(doc)
			}
			if secret != "" && len(msg.blocks) == 0 {
				append(&msg.blocks, Md_Block_Ui{kind = .Para, text = strings.clone(cover)})
			}
		} else if record.kind != AGENT_STREAM_START {
			convert_blocks(
				&msg.blocks,
				content.content_tokens.blocks,
				content.content_tokens.blocks_len,
				false,
				([^]u8)(
					content.content_tokens.blank_lines_before,
				)[:content.content_tokens.blank_lines_before_len],
			)
		}
		for j in 0 ..< record.reactions.by_emoji_len {
			entry := &record.reactions.by_emoji[j]
			mine_reaction := false
			for k in 0 ..< record.reactions.user_reactions_len {
				user := &record.reactions.user_reactions[k]
				if user.sender != nil &&
				   string(user.sender) == ui.account_ref &&
				   string(user.emoji) == string(entry.emoji) {
					mine_reaction = true
					break
				}
			}
			// Resolve reactor names for the chip's hover tooltip.
			names := make([dynamic]string, context.temp_allocator)
			for s in 0 ..< entry.senders_len {
				if entry.senders[s] != nil {
					append(&names, profile_label(client, string(entry.senders[s])))
				}
			}
			append(
				&msg.reactions,
				Reaction_Ui {
					label = fmt.aprintf("%s %d", string(entry.emoji), entry.count),
					emoji = strings.clone(string(entry.emoji)),
					count = fmt.aprintf("%d", entry.count),
					mine = mine_reaction,
					who = strings.join(names[:], ", "),
				},
			)
		}

		group := strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator)
		if !issue_comments[id_str] ||
		   issue_tag(record.tags[:record.tags_len], "e") !=
			   issue_tag(record.tags[:record.tags_len], "E") {
			if record.reply_to_message_id_hex != nil {
				msg.reply_id = strings.clone(string(record.reply_to_message_id_hex))
			}
			if record.reply_preview != nil {
				preview := record.reply_preview
				msg.reply_from = strings.clone(
					preview.sender != nil ? profile_label(client, string(preview.sender)) : "?",
				)
				msg.reply_text = strings.clone(
					chat_preview(preview.plaintext != nil ? string(preview.plaintext) : ""),
				)
				msg.reply_image = reply_image_load(client, account, group, preview)
			} else if record.reply_to_message_id_hex != nil {
				// Parent outside the loaded window (or deleted): keep the
				// reply frame with a plain note instead of dropping it.
				msg.reply_text = strings.clone("Original message unavailable")
			}

		}

		for j in 0 ..< record.media_len {
			media_attach(&msg, client, account, group, &record.media[j])
		}
		append(&ui.messages, msg)
	}

	for &msg in ui.messages {
		msg.visible_since = old_times[msg.id]
	}
	// Incoming messages follow the tail only while the reader is already there.
	// Opening a chat and sending explicitly still reveal the newest message.
	follow := true
	if !ui.timeline_loading && clay.GetCurrentContext() != nil {
		data := clay.GetScrollContainerData(clay.ID("Timeline"))
		if data.found {
			follow =
				data.scrollPosition.y <=
				-max(data.contentDimensions.height - data.scrollContainerDimensions.height, 0) + 1
		}
	}
	ui.scroll_pending ||=
		follow && len(ui.messages) > 0 && !(ui.messages[len(ui.messages) - 1].id in old_times)

	// Fold the collected votes and thread reply counts onto their rows.
	for &m in ui.messages {
		if len(m.poll_opts) > 0 {
			poll_tally(&m, votes[m.id], ui.account_ref)
		}
		if n, ok := thread_counts[m.id]; ok {
			m.thread_replies = n
		}
	}

	apply_pending_reacts(ui)
	messages_rebind(ui)
}

// Overlay the in-flight reactions onto the rows just built. An add
// that the reload already confirmed just loses its ghost; an unreact
// still on the wire fades the chip it is about to remove.
apply_pending_reacts :: proc(ui: ^Ui_State) {
	for p in ui.react_pending {
		for &msg in ui.messages {
			if msg.id != p.msg_id {
				continue
			}
			hit := false
			for &chip in msg.reactions {
				if chip.emoji != p.emoji {
					continue
				}
				hit = true
				chip.ghost = !p.remove || chip.mine
			}
			if !hit && !p.remove {
				append(
					&msg.reactions,
					Reaction_Ui {
						label = fmt.aprintf("%s 1", p.emoji),
						emoji = strings.clone(p.emoji),
						count = strings.clone("1"),
						mine = true,
						ghost = true,
					},
				)
			}
			break
		}
	}
}

@(private)
System_Names :: enum {
	Labels,
	Mentions,
}

// Keep known participants even when the authenticated event has no actor.
// Mentions use the existing inline renderer; previews keep labels.
system_text :: proc(
	client: ^marmot.Client,
	ev: ^marmot.Group_System_Event,
	names: System_Names = .Labels,
) -> string {
	actor := ev.actor_display_name != nil ? string(ev.actor_display_name) : ""
	subject := ev.subject_display_name != nil ? string(ev.subject_display_name) : ""
	if len(actor) == 0 &&
	   ev.actor_account_id_hex != nil &&
	   len(string(ev.actor_account_id_hex)) > 0 {
		actor = profile_label(client, string(ev.actor_account_id_hex))
	}
	if len(subject) == 0 &&
	   ev.subject_account_id_hex != nil &&
	   len(string(ev.subject_account_id_hex)) > 0 {
		subject = profile_label(client, string(ev.subject_account_id_hex))
	}
	if names == .Mentions {
		if ev.actor_account_id_hex != nil {
			if npub := hex_npub(string(ev.actor_account_id_hex)); len(npub) > 0 {
				defer delete(npub)
				actor = fmt.tprintf("nostr:%s", npub)
			}
		}
		if ev.subject_account_id_hex != nil {
			if npub := hex_npub(string(ev.subject_account_id_hex)); len(npub) > 0 {
				defer delete(npub)
				subject = fmt.tprintf("nostr:%s", npub)
			}
		}
	}
	kind := ev.system_type != nil ? string(ev.system_type) : ""
	name := ev.name != nil ? string(ev.name) : ""

	switch {
	case kind == "member_added" && len(actor) > 0 && len(subject) > 0:
		return fmt.tprintf(tr("%s added %s"), actor, subject)
	case kind == "member_added" && len(subject) > 0:
		return fmt.tprintf(tr("%s was added to the group"), subject)
	case kind == "member_removed" && len(actor) > 0 && len(subject) > 0:
		return fmt.tprintf(tr("%s removed %s"), actor, subject)
	case kind == "member_removed" && len(subject) > 0:
		return fmt.tprintf(tr("%s was removed from the group"), subject)
	case kind == "member_left" && len(subject) > 0:
		return fmt.tprintf(tr("%s left the group"), subject)
	case kind == "member_left" && len(actor) > 0:
		return fmt.tprintf(tr("%s left the group"), actor)
	case kind == "admin_added" && len(actor) > 0 && len(subject) > 0:
		return fmt.tprintf(tr("%s made %s an admin"), actor, subject)
	case kind == "admin_added" && len(subject) > 0:
		return fmt.tprintf(tr("%s was made an admin"), subject)
	case kind == "admin_removed" && len(actor) > 0 && len(subject) > 0:
		return fmt.tprintf(tr("%s dismissed %s as admin"), actor, subject)
	case kind == "admin_removed" && len(subject) > 0:
		return fmt.tprintf(tr("%s is no longer an admin"), subject)
	case kind == "group_renamed" && len(actor) > 0 && len(name) > 0:
		return fmt.tprintf(tr("%s renamed the group to %s"), actor, name)
	case kind == "group_renamed" && len(name) > 0:
		return fmt.tprintf(tr("The group was renamed to %s"), name)
	case kind == "group_avatar_changed" && len(actor) > 0:
		return fmt.tprintf(tr("%s changed the group photo"), actor)
	case kind == "disappearing_timer_changed" && len(actor) > 0:
		return fmt.tprintf(tr("%s changed the disappearing message timer"), actor)
	case kind == "group_disbanded" && len(actor) > 0:
		return fmt.tprintf(tr("%s disbanded the group"), actor)
	}
	return ev.text != nil ? string(ev.text) : ""
}

// px above the top of loaded history at which scrolling up fetches the
// next page (handle_chat).
TL_FETCH_MARGIN :: f32(300)

// Raw-event JSON for the View raw modal (dev mode). marmot-c has no
// accessor for the outer signed wire event, so this pretty-prints the
// retained timeline record's projection of the
// inner app event (id, kind, tags, sender, timestamps, ...).
raw_event_json :: proc(client: ^marmot.Client, ui: ^Ui_State, msg_id: string) -> string {
	if ui.selected < 0 {
		return ""
	}
	page := timeline_page
	if page == nil {return ""}

	for i in 0 ..< page.messages_len {
		record := &page.messages[i]
		if record.message_id_hex == nil || string(record.message_id_hex) != msg_id {
			continue
		}
		return record_json(record)
	}
	return fmt.aprintf("No record with id %s in this chat's window.", msg_id)
}

// Pretty-print one record's projection of the inner app event.
// Shared by the View raw modal and the HTML transcript export.
record_json :: proc(
	record: ^marmot.Timeline_Message_Record,
	allocator := context.allocator,
) -> string {
	str :: proc(c: cstring) -> string {
		return c != nil ? string(c) : ""
	}
	tags := make([dynamic][]string, context.temp_allocator)
	for j in 0 ..< record.tags_len {
		tag := &record.tags[j]
		values := make([]string, tag.values_len, context.temp_allocator)
		for k in 0 ..< tag.values_len {
			values[k] = str(tag.values[k])
		}
		append(&tags, values)
	}
	// Spaces, not tabs: the mono font has no tab glyph.
	data, err := json.marshal(struct {
			message_id_hex, source_message_id_hex:      string,
			kind:                                       u64,
			direction, group_id_hex, sender, plaintext: string,
			tags:                                       [][]string,
			timeline_at, received_at:                   u64,
			reply_to_message_id_hex:                    string,
			media_json:                                 string,
			deleted:                                    bool,
			deleted_by_message_id_hex:                  string,
			invalidation_status:                        string,
		} {
			message_id_hex = str(record.message_id_hex),
			source_message_id_hex = str(record.source_message_id_hex),
			kind = record.kind,
			direction = str(record.direction),
			group_id_hex = str(record.group_id_hex),
			sender = str(record.sender),
			plaintext = str(record.plaintext),
			tags = tags[:],
			timeline_at = record.timeline_at,
			received_at = record.received_at,
			reply_to_message_id_hex = str(record.reply_to_message_id_hex),
			media_json = str(record.media_json),
			deleted = record.deleted,
			deleted_by_message_id_hex = str(record.deleted_by_message_id_hex),
			invalidation_status = str(record.invalidation_status),
		}, json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil {
		return strings.clone("Couldn't serialize the event. Please try again.", allocator)
	}
	return strings.clone(string(data), allocator)
}

// Archived chats: same call as the rail with include_archived, kept
// to only the archived rows.
load_archived :: proc(client: ^marmot.Client, ui: ^Ui_State) {
	timing_start := time.tick_now()
	defer local_timing_end(.archived_load, timing_start)
	rows: ^marmot.Presented_Chat_List
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	if marmot.presented_chat_list(client, account, true, &rows) != .OK {
		return
	}
	defer marmot.presented_chat_list_free(rows)

	fresh := make([dynamic]Chat_Row_Ui, 0, int(rows.rows_len))
	for i in 0 ..< rows.rows_len {
		row := &rows.rows[i]
		if !row.row.archived {
			continue
		}
		append(&fresh, row_to_ui(client, row, ui.account_ref))
	}
	chats_replace(&ui.archived, fresh)
}

// Named contacts first, then unresolved ids, each case-insensitive; key is
// the lowercased name (also the filter haystack), idx the ui.contacts
// position. Temp-allocated, rebuilt per frame.
Contact_Order :: struct {
	key:     string,
	idx:     int,
	unnamed: bool,
}

// Local nickname when set, else the published/directory name.
contact_label :: proc(ui: ^Ui_State, c: Contact_Ui) -> string {
	if nick, ok := ui.nicknames[c.id_hex]; ok && len(nick) > 0 {
		return nick
	}
	return c.name
}

contact_order :: proc(ui: ^Ui_State) -> []Contact_Order {
	rows := make([]Contact_Order, len(ui.contacts), context.temp_allocator)
	for contact, i in ui.contacts {
		label := contact_label(ui, contact)
		rows[i] = {
			strings.to_lower(label, context.temp_allocator),
			i,
			label == "" || label == short_hex(contact.id_hex),
		}
	}
	slice.sort_by(rows, proc(a, b: Contact_Order) -> bool {
		if a.unnamed != b.unnamed {return !a.unnamed}
		return a.key < b.key
	})
	return rows
}

// "npub136lfe...gfasl4" tail for tight row corners.
npub_tail :: proc(npub: string) -> string {
	if len(npub) <= 24 {
		return npub
	}
	return fmt.tprintf("%s...%s", npub[:10], npub[len(npub) - 6:])
}

load_contacts :: proc(client: ^marmot.Client, ui: ^Ui_State) {
	timing_start := time.tick_now()
	defer local_timing_end(.contacts_load, timing_start)
	clear(&ui.contacts)
	clear(&ui.dm_peer)
	indices := make(map[string]int, allocator = context.temp_allocator)
	load_follows(client, ui, &indices)
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)

	for chat in ui.chats {
		members: ^marmot.Group_Member_Record_List
		group := strings.clone_to_cstring(chat.group_id, context.temp_allocator)
		if marmot.group_members(client, account, group, &members) != .OK {
			continue
		}
		defer marmot.app_group_member_record_list_free(members)

		contact_groups(ui, chat, members.items[:members.len], indices)
	}
}

// Shared membership enriches saved contacts without creating new ones.
// Keep every 1:1 peer mapped, including people outside the contact list.
@(private)
contact_groups :: proc(
	ui: ^Ui_State,
	chat: Chat_Row_Ui,
	members: []marmot.Group_Member_Record,
	indices: map[string]int,
) {
	for member in members {
		if member.local || member.member_id_hex == nil {
			continue
		}
		id := string(member.member_id_hex)
		if len(members) == 2 {
			ui.dm_peer[strings.clone(chat.group_id)] = strings.clone(id)
		}
		if index, ok := indices[id]; ok {
			append(
				&ui.contacts[index].groups,
				Common_Group {
					strings.clone(chat.group_id),
					strings.clone(chat.title),
					len(members),
				},
			)
		}
	}
}

// Only the account's explicitly saved NIP-02 follows are contacts.
@(private = "file")
load_follows :: proc(client: ^marmot.Client, ui: ^Ui_State, indices: ^map[string]int) {
	follows: ^marmot.String_List
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	if marmot.account_follows(client, account, &follows) != .OK || follows == nil {
		return
	}
	defer marmot.string_list_free(follows)

	for i in 0 ..< follows.len {
		if follows.items[i] == nil {
			continue
		}
		id := string(follows.items[i])
		if id == ui.account_ref {
			continue // following yourself is not a contact
		}
		if _, exists := indices[id]; exists {
			continue
		}
		indices[strings.clone(id, context.temp_allocator)] = len(ui.contacts)

		name := short_hex(id)
		resolved: cstring
		if marmot.display_name(client, follows.items[i], &resolved) == .OK && resolved != nil {
			name = string(resolved)
		}
		npub_str: string
		npub_c: cstring
		if marmot.npub(client, follows.items[i], &npub_c) == .OK && npub_c != nil {
			npub_str = strings.clone(string(npub_c))
			marmot.string_free(npub_c)
		}
		append(
			&ui.contacts,
			Contact_Ui {
				id_hex = strings.clone(id),
				name = strings.clone(name),
				pic_url = strings.clone(profile_info(client, id).pic_url),
				npub = npub_str,
			},
		)
		marmot.string_free(resolved)
	}
}

load_profile :: proc(client: ^marmot.Client, ui: ^Ui_State) {
	if ui.profile.loaded {
		return
	}
	timing_start := time.tick_now()
	defer local_timing_end(.profile_load, timing_start)
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)

	npub: cstring
	if marmot.npub(client, account, &npub) == .OK && npub != nil {
		ui.profile.npub = strings.clone(string(npub))
		marmot.string_free(npub)
	}
	name: cstring
	if marmot.display_name(client, account, &name) == .OK && name != nil {
		ui.profile.name = strings.clone(string(name))
		marmot.string_free(name)
	}

	// Full kind-0 metadata for the viewer rows (handle, nip05, lud16).
	meta: ^marmot.User_Profile_Metadata
	if marmot.user_profile(client, account, &meta) == .OK && meta != nil {
		if meta.name != nil {
			ui.profile.username = strings.clone(string(meta.name))
		}
		if meta.about != nil {
			ui.profile.about = strings.clone(string(meta.about))
		}
		if meta.nip05 != nil {
			ui.profile.nip05 = strings.clone(string(meta.nip05))
		}
		if meta.lud16 != nil {
			ui.profile.lud16 = strings.clone(string(meta.lud16))
		}
		ui.profile.pic_set = meta.picture != nil && len(string(meta.picture)) > 0
		marmot.user_profile_metadata_free(meta)
	}

	// Own deep-link QR, shown inline on the profile page. Kept across
	// soft reloads (npub never changes); account switches zero the
	// struct, so a fresh one is cut then.
	if ui.profile.qr == nil && len(ui.profile.npub) > 0 {
		ui.profile.qr = qr_texture(ui.profile.npub)
	}

	relays: ^marmot.String_List
	if marmot.account_nip65_relays(client, account, &relays) == .OK {
		for i in 0 ..< relays.len {
			append(&ui.profile.nip65, strings.clone(string(relays.items[i])))
		}
		marmot.string_list_free(relays)
	}
	inbox: ^marmot.String_List
	if marmot.account_inbox_relays(client, account, &inbox) == .OK {
		for i in 0 ..< inbox.len {
			append(&ui.profile.inbox, strings.clone(string(inbox.items[i])))
		}
		marmot.string_list_free(inbox)
	}
	ui.profile.loaded = true
}

// Nav clicks, settings chips, profile actions, account switching.
