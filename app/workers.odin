package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import rl "sdlrl"

import marmot "../marmot"

@(private)
Live_Change :: struct {
	group, account: string,
	superseded: bool,
}

Live :: struct {
	mutex:          sync.Mutex,
	account:        string,
	dirty:          bool, // chat list changed
	dirty_groups:   [dynamic]Live_Change, // group ids with changed rows
	sub:            ^marmot.Chat_List_Subscription,
	worker:         ^thread.Thread,
	events_sub:     ^marmot.Events_Subscription,
	events_worker:  ^thread.Thread,
}

live_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	live := (^Live)(t.data)
	for {
		row: ^marmot.Chat_List_Row
		status := marmot.chat_list_subscription_next(live.sub, 0, &row)
		if status == .CLOSED {
			return
		}
		if status != .OK {
			continue
		}

		fmt.eprintfln("live: chat-list event for %s", string(row.group_id_hex))
		sync.lock(&live.mutex)
		live.dirty = true
		append(&live.dirty_groups, Live_Change{
			group = strings.clone(string(row.group_id_hex)),
			account = strings.clone(live.account),
		})
		sync.unlock(&live.mutex)
		marmot.chat_list_row_free(row)
		frame_wake()
	}
}

// The chat-list stream only fires when a row changes (a new message
// moves last_id and the preview). A reaction, edit, or deletion in the
// open chat changes neither, so it never woke the UI: the timeline
// stayed stale until a chat switch reloaded it by hand. The firehose
// covers those, scoped to the account and group in each event.
events_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	live := (^Live)(t.data)
	for {
		event: ^marmot.Runtime_Event
		status := marmot.events_subscription_next(live.events_sub, 0, &event)
		if status == .CLOSED {
			return
		}
		if status != .OK {
			continue
		}
		defer marmot.event_free(event)
		group: cstring
		switch event.tag {
		case .Message_Received:
			group = event.body.message.group
		case .Group_Joined, .Group_State_Updated, .Projection_Updated,
		     .Group_Event, .Welcome_Delivery_Pending, .Epoch_Stall_Escalated,
		     .Group_Change_Superseded:
			group = event.body.group.group
		case .Account_Error, .Agent_Stream_Activity:
			continue
		}
		if group == nil {
			continue
		}
		sync.lock(&live.mutex)
		append(&live.dirty_groups, Live_Change{
			group = strings.clone(string(group)),
			account = strings.clone(string(event.body.group.account)),
			superseded = event.tag == .Group_Change_Superseded,
		})
		sync.unlock(&live.mutex)
		frame_wake()
	}
}

start_live :: proc(live: ^Live, client: ^marmot.Client, account_ref: string) {
	if live.worker != nil || client == nil || len(account_ref) == 0 {
		return
	}
	account := strings.clone_to_cstring(account_ref, context.temp_allocator)
	if marmot.subscribe_chat_list(client, account, false, &live.sub) != .OK {
		fmt.eprintfln("live: subscribe failed: %s", marmot.last_error())
		return
	}
	live.worker = thread.create(live_worker)
	live.account = strings.clone(account_ref)
	live.worker.data = live
	thread.start(live.worker)

	if marmot.subscribe_events(client, &live.events_sub) != .OK {
		// The chat-list stream still covers new messages; reactions
		// and edits fall back to the chat-switch reload.
		fmt.eprintfln("live: events subscribe failed: %s", marmot.last_error())
		return
	}
	live.events_worker = thread.create(events_worker)
	live.events_worker.data = live
	thread.start(live.events_worker)
}

// The subscription is the fast path, and this is the safety net: a
// stream that never wakes (a dropped relay socket, a subscription that
// silently stops) would otherwise leave the rail and the open timeline
// stale until the user switched chats by hand. The poll just marks the
// list dirty; drain_live refreshes it and restarts a closed timeline stream.
LIVE_POLL_SECS :: 3.0

@(private = "file")
live_polled: f64 = -1

live_tick :: proc(live: ^Live, ui: ^Ui_State, client: ^marmot.Client) {
	if client == nil || len(ui.account_ref) == 0 {
		return
	}
	now := rl.GetTime()
	if live_polled >= 0 && now - live_polled < LIVE_POLL_SECS {
		return
	}
	live_polled = now
	sync.lock(&live.mutex)
	live.dirty = true // no dirty group: drain_live decides from the data
	sync.unlock(&live.mutex)
}

// Prune messages past their group's disappearing timer. Expiry lives
// in MDK's sqlite, so this survives restarts; MDK defers on unread
// messages and clock skew, making a quiet minute-scale poll enough.
RETENTION_SWEEP_SECS :: 60.0

@(private = "file")
retention_last: f64 = -1

retention_tick :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if client == nil || len(ui.account_ref) == 0 {
		return
	}
	now := rl.GetTime()
	if retention_last >= 0 && now - retention_last < RETENTION_SWEEP_SECS {
		return
	}
	retention_last = now

	report: ^marmot.Retention_Sweep_Report
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	now_ms := u64(time.now()._nsec) / 1_000_000
	if marmot.sweep_expired_retention(client, account, now_ms, &report) != .OK {
		fmt.eprintfln("retention sweep failed: %s", marmot.last_error())
		return
	}
	defer marmot.retention_sweep_report_free(report)

	// Refresh only what a prune actually touched: rail previews always,
	// the open timeline only when its own group lost rows.
	open_group := ui.selected >= 0 ? ui.chats[ui.selected].group_id : ""
	pruned_any, pruned_open := false, false
	for i in 0 ..< report.groups_len {
		outcome := &report.groups[i]
		if outcome.status != .PRUNED {
			continue
		}
		pruned_any = true
		pruned_open |= string(outcome.group_id_hex) == open_group
	}
	if pruned_any {
		refresh_after_action(ui, client)
		if pruned_open {
			load_timeline(client, ui)
		}
	}
}

// Apply pending live updates on the UI thread, preserving selection
// by group id across the chat-list reload.
drain_live :: proc(live: ^Live, ui: ^Ui_State, client: ^marmot.Client) {
	sync.lock(&live.mutex)
	dirty := live.dirty
	live.dirty = false
	for group in live.dirty_groups {
		if group.account == ui.account_ref { dirty = true }
	}
	had_events := len(live.dirty_groups) > 0
	for group in live.dirty_groups {
		if group.superseded && group.account == ui.account_ref && ui.selected >= 0 && group.group == ui.chats[ui.selected].group_id {
			ui.client_status = strings.clone(tr("Another group change took precedence. Review your group settings."))
		}
		delete(group.group)
		delete(group.account)
	}
	clear(&live.dirty_groups)
	sync.unlock(&live.mutex)

	if !dirty {
		return
	}
	issues_refresh()
	if had_events {
		search_revision += 1
		sync_at = rl.GetTime() // the status bar shows SYNCING for a beat
	}

	selected_group: string
	if ui.selected >= 0 { selected_group = ui.chats[ui.selected].group_id }
	// Unread counts before the reload, to spot the chats that gained
	// messages for desktop notifications.
	old_unread := make(map[string]u64, context.temp_allocator)
	for chat in ui.chats {
		old_unread[chat.group_id] = chat.unread
	}
	load_chat_list(client, ui.account_ref, ui)
	ui.selected = -1
	for chat, i in ui.chats {
		if chat.group_id == selected_group {
			ui.selected = i
			break
		}
	}
	focused := rl.IsWindowFocused()
	for chat in ui.chats {
		gate := Notify_Gate{
			enabled = ui.prefs.notify_desktop,
			focused = focused,
			viewing = chat.group_id == selected_group,
			muted   = chat.muted,
			from_me = chat.last_mine,
			fresh   = chat.unread > old_unread[chat.group_id],
			kind    = chat.last_kind,
			msg_id  = chat.last_id,
			seen_id = notify_seen_id(chat.group_id),
		}
		if should_notify(gate) {
			do_notify(ui, chat.title, chat.preview)
		}
		notify_mark(chat.group_id, chat.last_id)
	}
	// Timeline subscriptions deliver changes independently of rail updates.
	if ui.selected >= 0 && (timeline_job == nil || thread.is_done(timeline_job.worker)) {
		load_timeline(client, ui, string(ui.search_input[:]))
	}
	// The rail can receive its unread update after the timeline snapshot.
	if ui.selected >= 0 && focused && !ui.timeline_loading && !ui.tl_has_after && ui.chats[ui.selected].unread > 0 {
		mark_chat_read(ui, client, ui.selected)
	}
}

// Optimistic-send plumbing, the slint PendingState overlay for the
// send path: Enter appends a grayed "sending…" row and clears the
// composer immediately, a worker thread runs the blocking marmot
// call, and the frame loop drains completions (ack replaces the row
// with the confirmed record via reload; failure turns it danger with
// tap-to-retry).
//
//   Enter ──► ui.pending + worker ──► sends_done ──► drain_sends
//                (grayed row)          (mutex)     (drop row + reload,
//                                                   or mark failed)
Pending_Send :: struct {
	visible_since: time.Tick, // compose action until first presented optimistic row
	sending_since: time.Tick, // start of the current send attempt
	ticket:   int, // matches a Send_Done back to its row
	group_id: string,
	sender:   string, // own display label, mirrors confirmed rows
	body:     string, // composed text; file name for a non-image upload
	reply_to: string, // message id, "" = plain send
	issue:    Issue_Reply,
	thread:   string, // thread root id, "" = main timeline
	atts:     [dynamic]Pending_Att, // upload payloads, owned until drained
	failed:   bool,
	queued:   bool, // waiting for the auto-retry timer (offline.odin)
	dismissed: bool, // hidden during an active send; freed when its worker completes
	attempts: int, // failed tries so far, capped by MAX_SEND_ATTEMPTS
}

// One attachment moved out of Staged_File at send time. The worker's
// upload request points straight at `data`, so the row can only be
// freed after the worker reports completion (including deletion of
// a failed or queued send).
Pending_Att :: struct {
	name:       string,
	media_type: string, // static literal from media_type_for, never freed
	dim:        string, // "WxH", "" for non-images
	data:       []u8,
	tex:        ^rl.Texture2D, // thumbnail for the pending row, nil for non-images
}

Job_Att :: struct {
	name:       cstring,
	media_type: cstring,
	dim:        cstring, // nil for non-images
	data:       [^]u8, // borrowed from the Pending_Att
	data_len:   uint,
}

Send_Job :: struct {
	ticket:  int,
	client:  ^marmot.Client,
	account: cstring,
	group:   cstring,
	text:    cstring,
	reply:   cstring, // nil = plain send
	thread:  cstring, // nil = main timeline; else the kind-1111 root
	issue:   Issue_Reply, // borrowed from Pending_Send until completion
	caption: cstring, // nil, or the body to ride along with atts (aliases text)
	atts:    []Job_Att, // non-empty = upload_media instead of a text send
}

Send_Done :: struct {
	ticket: int,
	status: marmot.Status, // classifies a failure as queued vs failed
	err:    string, // "" = ok
	ids:    [dynamic]string, // hide a dismissed send even if publishing succeeds
	refresh_requested: bool,
}

@(private = "file")
sent_ids :: proc(ids: ^[dynamic]string, summary: ^marmot.Send_Summary) {
	if summary == nil {
		return
	}
	for id in summary.message_ids[:summary.message_ids_len] {
		append(ids, strings.clone(string(id)))
	}
}

sends_mutex: sync.Mutex
sends_done: [dynamic]Send_Done
send_threads: [dynamic]^thread.Thread
send_ticket: int

// Publish uploaded references into a thread: one kind-1111 event
// carrying the root e tag plus one imeta tag per attachment (built by
// marmot, the same shape its own kind-9 media messages use, so the
// timeline resolves them into downloadable media on every client).
@(private = "file")
send_thread :: proc(job: ^Send_Job, result: ^marmot.Media_Upload_Result, ids: ^[dynamic]string) -> marmot.Status {
	e_vals := [2]cstring{"e", job.thread}
	rows := make([dynamic]marmot.Message_Tag)
	defer delete(rows)
	if job.issue.root == "" {
		append(&rows, marmot.Message_Tag{values = raw_data(e_vals[:]), values_len = 2})
	} else {
		for tag in issue_reply_tags(job.issue) {
			values := make([]cstring, len(tag), context.temp_allocator)
			for value, i in tag { values[i] = strings.clone_to_cstring(value, context.temp_allocator) }
			append(&rows, marmot.Message_Tag{raw_data(values), uint(len(values))})
		}
	}

	built := make([dynamic]^marmot.Message_Tag)
	defer {
		for tag in built {
			marmot.message_tag_free(tag)
		}
		delete(built)
	}
	for i in 0 ..< (result != nil ? result.attachments_len : 0) {
		tag: ^marmot.Message_Tag
		if s := marmot.build_media_imeta_tag(job.client, job.account, job.group, &result.attachments[i].reference, &tag); s != .OK {
			return s
		}
		append(&built, tag)
		append(&rows, tag^)
	}

	summary: ^marmot.Send_Summary
	status := marmot.send_custom_event(job.client, job.account, job.group, KIND_THREAD, raw_data(rows[:]), uint(len(rows)), job.text, &summary)
	if status == .OK {
		sent_ids(ids, summary)
		marmot.send_summary_free(summary)
	}
	return status
}

send_worker :: proc(t: ^thread.Thread) {
	timing_start := time.tick_now()
	defer local_timing_end(.send_worker, timing_start)
	context.allocator = reload_allocator()
	defer frame_wake()
	job := (^Send_Job)(t.data)
	status := marmot.Status.OK
	ids: [dynamic]string
	if job.issue.root != "" { status = issue_send_allowed(job.client, job.account, job.group) }
	if status == .OK && len(job.atts) > 0 {
		// One upload_media round trip: encrypt, push to Blossom, and
		// (main timeline) publish the kind-9 message in the same call.
		// A thread upload keeps send=false and publishes the references
		// itself as a kind-1111 event, since upload_media carries no
		// tags to place it in the thread.
		requests := make([]marmot.Media_Upload_Attachment_Request, len(job.atts))
		for a, i in job.atts {
			requests[i] = {
				file_name     = a.name,
				media_type    = a.media_type,
				plaintext     = a.data,
				plaintext_len = a.data_len,
				dim           = a.dim,
			}
		}
		request := marmot.Media_Upload_Request {
			attachments     = raw_data(requests),
			attachments_len = uint(len(requests)),
			caption         = job.caption,
			send            = job.thread == nil,
		}
		result: ^marmot.Media_Upload_Result
		status = marmot.upload_media(job.client, job.account, job.group, &request, &result)
		if status == .OK {
			if job.thread != nil {
				status = send_thread(job, result, &ids)
			} else {
				sent_ids(&ids, result.sent)
			}
			marmot.media_upload_result_free(result)
		}
		delete(requests)
	} else if status == .OK {
		summary: ^marmot.Send_Summary
		if job.thread != nil {
			status = send_thread(job, nil, &ids)
		} else if job.reply != nil {
			status = marmot.reply_to_message(job.client, job.account, job.group, job.reply, job.text, &summary)
		} else {
			status = marmot.send_text(job.client, job.account, job.group, job.text, &summary)
		}
		if status == .OK {
			sent_ids(&ids, summary)
			marmot.send_summary_free(summary)
		}
	}

	err: string
	if status != .OK {
		err = marmot.last_error()
		if err == "" { err = fmt.aprintf("%v", status) }
	}
	fmt.eprintfln("send: ticket=%d done status=%v err=%s", job.ticket, status, err)
	sync.lock(&sends_mutex)
	append(&sends_done, Send_Done{ticket = job.ticket, status = status, err = err, ids = ids})
	sync.unlock(&sends_mutex)

	delete(job.account)
	delete(job.group)
	delete(job.text)
	if job.reply != nil {
		delete(job.reply)
	}
	if job.thread != nil {
		delete(job.thread)
	}
	for a in job.atts {
		delete(a.name)
		delete(a.media_type)
		if a.dim != nil {
			delete(a.dim)
		}
		// a.data belongs to the Pending_Att; drain_sends frees it.
	}
	delete(job.atts)
	free(job)
}

spawn_send :: proc(ui: ^Ui_State, client: ^marmot.Client, p: ^Pending_Send) {
	p.sending_since = time.tick_now()
	job := new(Send_Job)
	job.ticket = p.ticket
	job.client = client
	job.account = strings.clone_to_cstring(ui.account_ref)
	job.group = strings.clone_to_cstring(p.group_id)
	job.text = strings.clone_to_cstring(p.body)
	job.reply = len(p.reply_to) > 0 ? strings.clone_to_cstring(p.reply_to) : nil
	job.issue = p.issue
	job.thread = len(p.thread) > 0 ? strings.clone_to_cstring(p.thread) : nil
	if len(p.atts) > 0 {
		// upload_media publishes the kind-9 itself, so the typed body
		// only survives as its caption. Staged files carry no typed
		// body (their name is the row label), and the thread path
		// sends job.text as the kind-1111 content already.
		emoji_only := job.thread == nil && len(p.body) > 0
		for a in p.atts {
			emoji_only &= strings.has_prefix(a.name, EMOJI_ATT_PREFIX)
		}
		if emoji_only {
			job.caption = job.text
		}
		job.atts = make([]Job_Att, len(p.atts))
		for a, i in p.atts {
			job.atts[i] = {
				name       = strings.clone_to_cstring(a.name),
				media_type = strings.clone_to_cstring(a.media_type),
				dim        = len(a.dim) > 0 ? strings.clone_to_cstring(a.dim) : nil,
				data       = raw_data(a.data),
				data_len   = uint(len(a.data)),
			}
		}
	}

	fmt.eprintfln("send: ticket=%d spawned", job.ticket)
	t := thread.create(send_worker)
	t.data = job
	append(&send_threads, t)
	thread.start(t)
}

// Append the grayed row and kick the worker; the composer clears
// right after in the caller.
queue_send :: proc(ui: ^Ui_State, client: ^marmot.Client, body: string) {
	started := time.tick_now()
	info := profile_info(client, ui.account_ref)
	send_ticket += 1
	append(&ui.pending, Pending_Send{
		visible_since = started,
		ticket   = send_ticket,
		group_id = strings.clone(ui.chats[ui.selected].group_id),
		sender   = strings.clone(len(info.name) > 0 ? info.name : "you"),
		body     = strings.clone(body),
		// A reply can't carry a thread tag, so the open thread wins.
		reply_to = strings.clone(len(thread_cur(ui)) > 0 && ui.compose_issue == "" ? "" : ui.replying),
		thread   = strings.clone(thread_cur(ui)),
		issue    = issue_reply(ui),
	})
	attach_body_emoji(&ui.pending[len(ui.pending) - 1], body)
	spawn_send(ui, client, &ui.pending[len(ui.pending) - 1])
}

// Ship the image behind every :shortcode: this device defines, so the
// group renders it instead of the literal text. A reply is left alone:
// upload_media has no reply tag, so attaching would drop the reply.
@(private = "file")
attach_body_emoji :: proc(p: ^Pending_Send, body: string) {
	if len(p.reply_to) > 0 {
		return
	}
	for code in emoji_codes_in(body) {
		name := emoji_file_for(code)
		data, err := os.read_entire_file(fmt.tprintf("%s/%s", emoji_dir(), name), context.allocator)
		if err != nil {
			continue
		}
		append(&p.atts, Pending_Att{
			name       = fmt.aprintf("%s%s", EMOJI_ATT_PREFIX, name),
			media_type = media_type_for(name),
			data       = data,
		})
	}
}

free_pending :: proc(p: ^Pending_Send) {
	delete(p.group_id)
	delete(p.sender)
	delete(p.body)
	delete(p.reply_to)
	delete(p.thread)
	issue_reply_free(p.issue)
	for &a in p.atts {
		delete(a.name)
		delete(a.dim)
		delete(a.data)
		if a.tex != nil {
			rl.UnloadTexture(a.tex^)
			free(a.tex)
		}
	}
	delete(p.atts)
}

// Move the staged chips into pending sends and kick upload workers:
// all images become ONE pending (the kind-9 album grid), every other
// file its own pending, mirroring the slint flush. Chips clear
// immediately; a failed upload turns its row danger for retry.
queue_staged :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if len(ui.staged) == 0 {
		return
	}
	started := time.tick_now()
	info := profile_info(client, ui.account_ref)
	sender := len(info.name) > 0 ? info.name : "you"
	group := ui.chats[ui.selected].group_id

	album := Pending_Send{visible_since = started}
	for &f in ui.staged {
		att := Pending_Att {
			name       = f.name, // ownership moves out of Staged_File
			media_type = f.media_type,
			data       = f.data,
			tex        = f.tex,
		}
		if f.tex != nil {
			att.dim = fmt.aprintf("%dx%d", f.tex.width, f.tex.height)
			append(&album.atts, att)
		} else {
			send_ticket += 1
			p := Pending_Send {
				visible_since = started,
				ticket   = send_ticket,
				group_id = strings.clone(group),
				sender   = strings.clone(sender),
				body     = strings.clone(f.name),
				thread   = strings.clone(thread_cur(ui)),
		issue    = issue_reply(ui),
			}
			append(&p.atts, att)
			append(&ui.pending, p)
			spawn_send(ui, client, &ui.pending[len(ui.pending) - 1])
		}
	}
	if len(album.atts) > 0 {
		send_ticket += 1
		album.ticket = send_ticket
		album.group_id = strings.clone(group)
		album.sender = strings.clone(sender)
		album.body = strings.clone("")
		album.thread = strings.clone(thread_cur(ui))
		album.issue = issue_reply(ui)
		append(&ui.pending, album)
		spawn_send(ui, client, &ui.pending[len(ui.pending) - 1])
	}
	clear(&ui.staged) // fields moved into the pendings above
}

// Frame-loop drain: settle acked/failed sends and reap worker threads.
drain_sends :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	for i := len(send_threads) - 1; i >= 0; i -= 1 {
		if thread.is_done(send_threads[i]) {
			thread.join(send_threads[i])
			thread.destroy(send_threads[i])
			unordered_remove(&send_threads, i)
		}
	}

	sync.lock(&sends_mutex)
	done := sends_done
	sends_done = {}
	sync.unlock(&sends_mutex)
	if len(done) == 0 {
		return
	}
	defer delete(done)

	reload, refresh := false, false
	visible := make(map[string]bool, context.temp_allocator)
	if timeline_page != nil {
		for record in timeline_page.messages[:timeline_page.messages_len] {
			visible[string(record.message_id_hex)] = true
		}
	}
	for &d in done {
		// The acknowledgement can beat the timeline update. Keep its preview
		// until the replacement exists, and recover a missed subscription update.
		waiting := false
		if d.err == "" && timeline_scope(ui, "") {
			for p in ui.pending {
				if p.ticket != d.ticket || p.dismissed || p.group_id != string(timeline_job.group) {
					continue
				}
				for id in d.ids {
					waiting ||= !visible[id]
				}
				break
			}
		}
		if waiting {
			if !d.refresh_requested {
				refresh = true
				d.refresh_requested = true
			}
			sync.lock(&sends_mutex)
			append(&sends_done, d)
			sync.unlock(&sends_mutex)
			continue
		}
		defer {
			delete(d.err)
			for id in d.ids {
				delete(id)
			}
			delete(d.ids)
		}
		for &p, i in ui.pending {
			if p.ticket != d.ticket {
				continue
			}
			fmt.eprintfln("send: ticket=%d settled err=%s", d.ticket, d.err)
			if p.dismissed || len(d.err) == 0 {
				if p.dismissed && len(d.ids) > 0 {
					for id in d.ids {
						if !ui.hidden[id] {
							ui.hidden[strings.clone(id)] = true
						}
					}
					save_hidden(ui)
				}
				free_pending(&p)
				ordered_remove(&ui.pending, i)
				reload ||= len(d.err) == 0
			} else {
				// Transport-shaped failures queue for auto-retry until
				// the attempt cap; definitive errors fail outright.
				p.attempts += 1
				if send_retryable(d.status) && p.attempts < MAX_SEND_ATTEMPTS {
					p.queued = true
				} else {
					p.failed = true
					shake() // a send that is not coming back deserves it
					play_sound(.Error)
				}
				ui.client_status = fmt.aprintf("send failed: %s", d.err)
			}
			break
		}
	}
	save_offline(ui)
	if refresh {
		timeline_start(client, ui, "")
	} else if reload {
		load_timeline(client, ui)
	}
}

// ── Reaction / delete worker ────────────────────────────────────────
//
// One relay round trip each, and running it inline froze the frame for
// its whole duration. There is no optimistic row to settle here: the
// burst and fly play immediately in message_op, and the timeline
// reloads when the worker reports back. Threads are reaped by
// drain_sends, which joins whatever is done in send_threads.
Op_Job :: struct {
	ticket:  int,
	client:  ^marmot.Client,
	op:      Msg_Op,
	account: cstring,
	group:   cstring,
	target:  cstring,
	emoji:   cstring, // nil for delete
	kind:    u64, // .Custom only
	tags:    [][]cstring, // .Custom only, owned rows
	content: cstring, // .Custom only
	secs:    u64, // .Retention only
}

Op_Done :: struct {
	ticket: int,
	op:     Msg_Op,
	err:    string, // "" = ok, else the owned marmot error
	account, group, target, content: string, // owned edit recovery data
	history: [dynamic]^marmot.Timeline_Edit_Page,
}

ops_mutex: sync.Mutex
ops_done: [dynamic]Op_Done
op_ticket: int

op_worker :: proc(t: ^thread.Thread) {
	timing_start := time.tick_now()
	defer local_timing_end(.message_op_worker, timing_start)
	context.allocator = reload_allocator()
	defer frame_wake()
	job := (^Op_Job)(t.data)
	summary: ^marmot.Send_Summary
	history: [dynamic]^marmot.Timeline_Edit_Page
	status: marmot.Status
	switch job.op {
	case .History:
		before: u64
		before_id: cstring
		for {
			page: ^marmot.Timeline_Edit_Page
			status = marmot.message_edit_history(job.client, job.account, job.group, job.target, before_id != nil ? 1 : 0, before, before_id, 100, &page)
			if status != .OK { break }
			append(&history, page)
			if !page.has_more || page.len == 0 { break }
			before, before_id = page.versions[0].edited_at, page.versions[0].id
		}
	case .React:
		status = marmot.react_to_message(job.client, job.account, job.group, job.target, job.emoji, &summary)
	case .Unreact:
		status = marmot.unreact_from_message(job.client, job.account, job.group, job.target, &summary)
	case .Delete:
		status = marmot.delete_message(job.client, job.account, job.group, job.target, &summary)
	case .Edit:
		status = marmot.edit_message(job.client, job.account, job.group, job.target, job.content, &summary)
	case .Custom, .Issue:
		rows := make([]marmot.Message_Tag, len(job.tags))
		for row, i in job.tags {
			rows[i] = {values = raw_data(row), values_len = uint(len(row))}
		}
		status = .OK
		if job.op == .Issue { status = issue_send_allowed(job.client, job.account, job.group) }
		if status == .OK { status = marmot.send_custom_event(job.client, job.account, job.group, job.kind, raw_data(rows), uint(len(rows)), job.content, &summary) }
		delete(rows)
	case .Issue_Setting:
		component: ^marmot.Group_App_Component
		status = marmot.group_app_component(job.client, job.account, job.group, ISSUE_COMPONENT, &component)
		if status == .OK && component != nil && issue_setting(component.data[:component.data_len]) == .Unavailable { status = .INVALID_APP_COMPONENT }
		if component != nil { marmot.app_component_free(component) }
		if status == .OK {
			data := [2]u8{1, u8(job.secs)}
			status = marmot.update_app_component(job.client, job.account, job.group, ISSUE_COMPONENT, raw_data(data[:]), 2, &summary)
		}
	case .Retention:
		status = marmot.update_message_retention(job.client, job.account, job.group, job.secs, &summary)
	case .Rename:
		status = marmot.update_group_profile(job.client, job.account, job.group, job.target, nil, &summary)
	case .Invite, .Remove:
		refs := [1]cstring{job.target}
		if job.op == .Invite {
			status = marmot.invite_members(job.client, job.account, job.group, raw_data(refs[:]), 1, &summary)
		} else {
			status = marmot.remove_members(job.client, job.account, job.group, raw_data(refs[:]), 1, &summary)
		}
	case .Promote:
		status = marmot.promote_admin(job.client, job.account, job.group, job.target, &summary)
	case .Demote:
		status = marmot.demote_admin(job.client, job.account, job.group, job.target, &summary)
	}

	err: string
	if status == .OK {
		marmot.send_summary_free(summary)
	} else {
		err = marmot.last_error()
		if err == "" { err = strings.clone("Group action unavailable.") }
	}
	done := Op_Done{ticket = job.ticket, op = job.op, err = err, history = history}
	if job.op == .History || job.op == .Edit || job.op == .Issue || job.op == .Issue_Setting {
		done.account = strings.clone(string(job.account))
		done.group = strings.clone(string(job.group))
		done.target = strings.clone(string(job.target))
		done.content = strings.clone(string(job.content))
	}
	sync.lock(&ops_mutex)
	append(&ops_done, done)
	sync.unlock(&ops_mutex)

	delete(job.account)
	delete(job.group)
	delete(job.target)
	if job.emoji != nil {
		delete(job.emoji)
	}
	for row in job.tags {
		for v in row {
			delete(v)
		}
		delete(row)
	}
	delete(job.tags)
	if job.content != nil {
		delete(job.content)
	}
	free(job)
}

// Fire-and-forget custom event onto the op worker (poll, vote, thread
// message); drain_ops reloads the timeline on the ack.
spawn_custom :: proc(ui: ^Ui_State, client: ^marmot.Client, kind: u64, tags: [][]string, content: string, op: Msg_Op = .Custom) -> int {
	op_ticket += 1
	job := new(Op_Job)
	job.ticket = op_ticket
	job.client = client
	job.op = op
	job.kind = kind
	job.account = strings.clone_to_cstring(ui.account_ref)
	job.group = strings.clone_to_cstring(ui.chats[ui.selected].group_id)
	job.target = strings.clone_to_cstring("")
	job.content = strings.clone_to_cstring(content)
	job.tags = make([][]cstring, len(tags))
	for row, i in tags {
		job.tags[i] = make([]cstring, len(row))
		for v, j in row {
			job.tags[i][j] = strings.clone_to_cstring(v)
		}
	}

	t := thread.create(op_worker)
	t.data = job
	append(&send_threads, t)
	ticket := job.ticket
	thread.start(t)
	return ticket
}

spawn_op :: proc(ui: ^Ui_State, client: ^marmot.Client, op: Msg_Op, message_id, emoji: string, secs: u64 = 0) -> int {
	op_ticket += 1
	job := new(Op_Job)
	job.ticket = op_ticket
	job.client = client
	job.op = op
	job.account = strings.clone_to_cstring(ui.account_ref)
	job.group = strings.clone_to_cstring(ui.chats[ui.selected].group_id)
	job.target = strings.clone_to_cstring(message_id)
	job.emoji = op == .React ? strings.clone_to_cstring(emoji) : nil
	if op == .Edit { job.content = strings.clone_to_cstring(emoji) }
	job.secs = secs

	t := thread.create(op_worker)
	t.data = job
	append(&send_threads, t)
	thread.start(t)
	return job.ticket
}

// Frame-loop drain: one timeline reload for the batch, the failures
// shaken and reported.
drain_ops :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	sync.lock(&ops_mutex)
	done := ops_done
	ops_done = {}
	sync.unlock(&ops_mutex)
	if len(done) == 0 {
		return
	}
	defer delete(done)

	for d in done {
		if d.op == .History {
			if d.ticket == ui.hist_ticket {
				ui.hist_ticket = 0
				if d.err != "" { ui.client_status = strings.clone(tr("Couldn't load edit history. Please try again.")) } else {
					for i := len(d.history) - 1; i >= 0; i -= 1 {
						for v in d.history[i].versions[:d.history[i].len] { append(&ui.hist_versions, Edit_Version{format_when(v.edited_at), strings.clone(string(v.plaintext))}) }
					}
				}
			}
			for page in d.history { marmot.edit_history_free(page) }
			delete(d.history); edit_result_free(d)
			continue
		}
		if d.op == .Issue || d.op == .Issue_Setting { issues_complete(ui, d); continue }
		if d.op == .Edit {
			edit_complete(ui, d)
			continue
		}
		// The ghost goes either way: on the ack the reload carries the
		// confirmed chip, on failure there is nothing to show.
		for p, i in ui.react_pending {
			if p.ticket != d.ticket {
				continue
			}
			delete(p.msg_id)
			delete(p.emoji)
			ordered_remove(&ui.react_pending, i)
			break
		}
		if len(d.err) == 0 {
			// Group ops change more than the timeline: the member list,
			// and for a rename the rail row's title.
			#partial switch d.op {
			case .Rename:
				refresh_after_action(ui, client)
			case .Invite, .Remove, .Promote, .Demote:
				load_members(client, ui)
			}
			continue
		}
		#partial switch d.op {
		case .Retention:
			load_members(client, ui) // undo the optimistic chip flip
		case .Rename:
			refresh_after_action(ui, client) // undo the optimistic title
		}
		ui.client_status = fmt.aprintf("action failed: %s", d.err)
		delete(d.err)
		shake()
		play_sound(.Error)
	}
	load_timeline(client, ui)
}

// Which hover action a chat row offers (rail rows archive, archive-page
// rows unarchive); also selects the chip's clay ID for click handling.

// ── Contact key-package probe ───────────────────────────────────────
//
// Whether a contact has a published KeyPackage is what decides if a
// chat with them can start at all, and marmot answers it only by
// resolving one: the prewarm call, asked about a single member, caches
// the KeyPackage it finds and counts it. That is a relay round trip,
// so the contact pane asks once per contact and reads the answer here.

Kp_Probe :: enum {
	Unknown, // never asked
	Checking,
	Published,
	Missing,
}

// contact hex → what the probe found; one entry per contact viewed.
kp_probes: map[string]Kp_Probe

@(private = "file")
kp_mutex: sync.Mutex
@(private = "file")
Kp_Answer :: struct {
	hex:   string,
	found: bool,
}
@(private = "file")
kp_done: [dynamic]Kp_Answer

@(private = "file")
Kp_Job :: struct {
	client:  ^marmot.Client,
	account: string,
	hex:     string,
}

// Ask about one contact, once. The answer lands in kp_probes.
probe_key_package :: proc(ui: ^Ui_State, client: ^marmot.Client, hex: string) {
	if client == nil || len(hex) == 0 || kp_probes[hex] != .Unknown {
		return
	}
	kp_probes[strings.clone(hex)] = .Checking

	job := new(Kp_Job)
	job.client = client
	job.account = strings.clone(ui.account_ref)
	job.hex = strings.clone(hex)
	t := thread.create(kp_worker)
	t.data = job
	thread.start(t)
}

@(private = "file")
kp_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer frame_wake()
	job := (^Kp_Job)(t.data)
	summary: ^marmot.Member_Key_Package_Prewarm_Summary
	account := strings.clone_to_cstring(job.account, context.temp_allocator)
	member := strings.clone_to_cstring(job.hex, context.temp_allocator)
	refs := [1]cstring{member}

	found := false
	if marmot.prewarm_group_member_key_packages(job.client, account, raw_data(refs[:]), 1, &summary) == .OK && summary != nil {
		found = summary.reused_members + summary.network_resolved_members > 0
		marmot.member_key_package_prewarm_summary_free(summary)
	}
	free_all(context.temp_allocator)

	sync.lock(&kp_mutex)
	append(&kp_done, Kp_Answer{job.hex, found})
	sync.unlock(&kp_mutex)
	delete(job.account)
	free(job)
}

// Frame-loop drain: adopt finished probes.
drain_kp :: proc() {
	sync.lock(&kp_mutex)
	done := kp_done
	kp_done = {}
	sync.unlock(&kp_mutex)

	for d in done {
		kp_probes[d.hex] = d.found ? .Published : .Missing
		delete(d.hex)
	}
	delete(done)
}

// ── Contact relay lists ─────────────────────────────────────────────
//
// A contact's published NIP-65 and inbox relays, so the detail pane can
// say which of them you also publish to: share one and your events meet
// without a third party relaying them.
//
// marmot splits the read in two. The cached one is a local lookup, so
// it runs inline on selection; when it comes back with nothing (the
// usual case for a contact never fetched before), the worker asks the
// relays and the drain re-reads the cache. Only the selected contact is
// ever on screen, so this is one slot rather than a per-contact map.

Rel_State :: enum {
	Empty, // no contact selected
	Checking,
	Loaded,
}

Contact_Relay :: struct {
	url:    string,
	inbox:  bool, // on their inbox list rather than their NIP-65 list
	mutual: bool, // you publish to it too
}

// The selected contact's relays; refilled on every selection.
rel_hex: string
rel_state: Rel_State
rel_list: [dynamic]Contact_Relay
rel_mutual: int

@(private = "file")
rel_mutex: sync.Mutex
@(private = "file")
rel_fetched: string // hex the worker just refreshed, "" = nothing pending

// Selection entry point: read the cache now, fetch if it is empty.
load_contact_relays :: proc(ui: ^Ui_State, client: ^marmot.Client, hex: string) {
	if client == nil || len(hex) == 0 {
		return
	}
	// "Shared with you" is measured against your own published lists,
	// which load lazily with the Profile page. Idempotent, and every
	// read behind it is local.
	load_profile(client, ui)

	delete(rel_hex)
	rel_hex = strings.clone(hex)
	rel_state = .Checking

	if read_contact_relays(ui, client, hex) {
		rel_state = .Loaded
		return
	}
	job := new(Rel_Job)
	job.client = client
	job.hex = strings.clone(hex)
	t := thread.create(rel_worker)
	t.data = job
	thread.start(t)
}

// Fill rel_list from marmot's cache. False when nothing is cached yet,
// which is what sends the worker to the relays.
@(private = "file")
read_contact_relays :: proc(ui: ^Ui_State, client: ^marmot.Client, hex: string) -> bool {
	lists: ^marmot.Account_Relay_Lists
	id := strings.clone_to_cstring(hex, context.temp_allocator)
	if marmot.user_relay_lists(client, id, &lists) != .OK || lists == nil {
		return false
	}
	defer marmot.account_relay_lists_free(lists)

	for r in rel_list {
		delete(r.url)
	}
	clear(&rel_list)

	mine := make([dynamic]string, context.temp_allocator)
	append(&mine, ..ui.profile.nip65[:])
	append(&mine, ..ui.profile.inbox[:])
	rel_mutual = merge_relays(relay_urls(lists.nip65), relay_urls(lists.inbox), mine[:], &rel_list)
	return len(rel_list) > 0
}

// One published list as Odin strings, borrowed from the C allocation.
@(private = "file")
relay_urls :: proc(list: marmot.Relay_List) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< list.relays_len {
		if list.relays[i] != nil {
			append(&out, string(list.relays[i]))
		}
	}
	return out[:]
}

// Merge a contact's two published lists into one deduped set, marking
// every relay you publish to as well. A relay on both of their lists
// keeps its first sighting, so their NIP-65 entry wins over their inbox
// one. Returns how many are shared.
merge_relays :: proc(nip65, inbox, mine: []string, out: ^[dynamic]Contact_Relay) -> (mutual: int) {
	for list, kind in ([2][]string{nip65, inbox}) {
		for url in list {
			seen := false
			for r in out {
				if r.url == url {
					seen = true
					break
				}
			}
			if seen {
				continue
			}

			shared := slice.contains(mine, url)
			if shared {
				mutual += 1
			}
			append(out, Contact_Relay{strings.clone(url), kind == 1, shared})
		}
	}
	return mutual
}

@(private = "file")
Rel_Job :: struct {
	client: ^marmot.Client,
	hex:    string,
}

@(private = "file")
rel_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer frame_wake()
	job := (^Rel_Job)(t.data)
	lists: ^marmot.Account_Relay_Lists
	id := strings.clone_to_cstring(job.hex, context.temp_allocator)
	// The result is dropped: it lands in marmot's cache, and the drain
	// re-reads it on the UI thread where rel_list lives.
	if marmot.refresh_user_relay_lists(job.client, id, raw_data(DEFAULT_RELAYS), uint(len(DEFAULT_RELAYS)), &lists) == .OK && lists != nil {
		marmot.account_relay_lists_free(lists)
	}
	free_all(context.temp_allocator)

	sync.lock(&rel_mutex)
	delete(rel_fetched)
	rel_fetched = job.hex
	sync.unlock(&rel_mutex)
	free(job)
}

// Frame-loop drain: adopt a finished fetch, unless the selection moved
// on while it was in flight.
drain_relays :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	sync.lock(&rel_mutex)
	hex := rel_fetched
	rel_fetched = ""
	sync.unlock(&rel_mutex)
	if len(hex) == 0 {
		return
	}
	defer delete(hex)

	if hex != rel_hex {
		return
	}
	read_contact_relays(ui, client, hex)
	rel_state = .Loaded
}

// ── Sign-in worker ──────────────────────────────────────────────────
//
// create_identity and login block on relay round trips (and, for a
// fresh identity, a Blossom upload) for seconds, which froze the whole
// window. They run here instead; the login pane shows a progress card
// and the frame loop finishes the job on the UI thread, where texture
// creation belongs.

// Whether the finished job still owes the UI a starter face.
Auth_Seed :: enum {
	None,
	Starter_Face,
}

Auth_Job :: struct {
	client:  ^marmot.Client,
	nsec:    string, // "" = mint a fresh identity
	seed:    Auth_Seed,
	hex:     string, // result: the account just added
	pic_url: string,
	err:     string, // "" = it worked
}

// Non-nil while a sign-in is in flight; the login pane reads it.
auth_job: ^Auth_Job
@(private = "file")
auth_thread: ^thread.Thread

@(private)
auth_stop :: proc() {
	if auth_thread == nil { return }
	thread.join(auth_thread)
	thread.destroy(auth_thread)
	auth_thread = nil
}

@(private)
reload_jobs_busy :: proc() -> bool {
	if auth_thread != nil { return true }
	for worker in send_threads {
		if !thread.is_done(worker) { return true }
	}
	return false
}
@(private = "file")
auth_mutex: sync.Mutex
@(private = "file")
auth_done: bool

@(private = "file")
auth_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer frame_wake()
	job := (^Auth_Job)(t.data)
	// marmot's last_error is thread-local, so the message is built here.
	if len(job.nsec) > 0 {
		job.hex, job.err = import_identity_blocking(job.client, job.nsec)
	} else {
		job.hex, job.pic_url, job.err = create_identity_blocking(job.client)
	}
	free_all(context.temp_allocator)

	sync.lock(&auth_mutex)
	auth_done = true
	sync.unlock(&auth_mutex)
}

// Kick a sign-in. `nsec` empty mints a fresh identity. A second call
// while one is in flight is ignored.
start_auth :: proc(ui: ^Ui_State, client: ^marmot.Client, nsec: string) {
	if auth_job != nil || client == nil {
		return
	}
	ui.login_error = ""

	auth_job = new(Auth_Job)
	auth_job.client = client
	auth_job.nsec = strings.clone(nsec)
	auth_job.seed = len(nsec) > 0 ? .None : .Starter_Face
	auth_thread = thread.create(auth_worker)
	auth_thread.data = auth_job
	thread.start(auth_thread)
}

// Frame-loop tick: adopt a finished sign-in.
drain_auth :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	sync.lock(&auth_mutex)
	done := auth_done
	sync.unlock(&auth_mutex)
	if !done {
		return
	}

	thread.join(auth_thread)
	thread.destroy(auth_thread)
	auth_thread = nil
	auth_done = false

	job := auth_job
	auth_job = nil
	defer {
		delete(job.nsec)
		delete(job.hex)
		delete(job.pic_url)
		delete(job.err)
		free(job)
	}

	if len(job.err) > 0 {
		ui.login_error = strings.clone(job.err)
		return
	}
	finish_auth(ui, client, job.hex, job.pic_url, job.seed)
}
