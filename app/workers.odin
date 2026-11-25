package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "nendo"
import rl "sdlrl"

import marmot "../marmot"

@(private)
WORKER_POLL_INTERVAL :: 100 * time.Millisecond

@(private)
Live_Change :: struct {
	group, account:    string,
	superseded:        bool,
	activation_signal: bool,
}

@(private)
Device_Part :: enum {
	Link,
	Roster,
	Started_Fresh,
	Closed_Chats,
	Leftover_Chats,
	Sign_Ins,
	Warning,
	Overdue,
	History,
	Unlinked,
	Chat_Review,
}

@(private)
Device_Parts :: bit_set[Device_Part]

Live :: struct {
	mutex:            sync.Mutex,
	dirty:            bool, // chat list changed
	dirty_groups:     [dynamic]Live_Change, // group ids with changed rows
	dirty_devices:    map[string]Device_Parts,
	stream:           ^Live_Stream,
	retired:          [dynamic]^Live_Stream,
	events_sub:       ^marmot.Events_Subscription,
	events_worker:    ^thread.Thread,
	events_attempted: bool,
	refresh:          ^Chat_List_Work,
	refresh_dirty:    bool,
}

@(private)
Live_Stream :: struct {
	live:    ^Live,
	client:  ^marmot.Client,
	account: cstring,
	worker:  ^thread.Thread,
	cancel:  bool, // under live.mutex
}

live_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer frame_wake()
	job := (^Live_Stream)(t.data)
	live := job.live
	sub: ^marmot.Chat_List_Subscription
	if marmot.subscribe_chat_list(job.client, job.account, true, &sub) != .OK {
		detail := marmot.last_error()
		fmt.eprintfln("live: subscribe failed: %s", detail)
		delete(detail)
		return
	}
	defer marmot.chat_list_subscription_free(sub)
	for {
		sync.lock(&live.mutex)
		cancel := job.cancel
		sync.unlock(&live.mutex)
		if cancel {return}
		row: ^marmot.Chat_List_Row
		status := marmot.chat_list_subscription_next(sub, 100, &row)
		if status == .TIMEOUT {continue}
		if status != .OK || row == nil {return}
		sync.lock(&live.mutex)
		cancel = job.cancel
		if !cancel {live.dirty = true}
		sync.unlock(&live.mutex)
		marmot.chat_list_row_free(row)
		if !cancel {frame_wake()}
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
		if event != nil && queue_live_event(live, event) {
			frame_wake()
		}
	}
}

@(private)
queue_live_event :: proc(live: ^Live, event: ^marmot.Runtime_Event) -> bool {
	group, account: cstring
	parts: Device_Parts
	activation_signal: bool
	switch event.tag {
	case .Message_Received:
		group, account = event.body.message.group, event.body.message.account
	case .Group_Joined, .Group_State_Updated, .Group_Event, .Group_Change_Superseded:
		group, account = event.body.group.group, event.body.group.account
		activation_signal = true
	case .Projection_Updated, .Welcome_Delivery_Pending, .Epoch_Stall_Escalated:
		group, account = event.body.group.group, event.body.group.account
	case .Linked_Devices_Changed:
		parts = {.Roster, .Started_Fresh}
	case .Key_Package_Refresh_Overdue_Changed:
		parts = {.Overdue}
	case .Unrecognized_Sign_Ins_Changed:
		parts = {.Sign_Ins}
	case .Compromise_Warning_Changed:
		parts = {.Warning}
	case .Device_Link_Changed:
		parts = {.Link}
	case .Device_Unlinked:
		parts = {.Unlinked}
	case .Chat_History_Imports_Changed:
		parts = {.History}
	case .Account_Error, .History_Notices_Changed, .Recovery_Status_Changed:
		return false
	}
	if parts != {} {
		id := string(event.body.account.account)
		if id == "" {return false}
		sync.lock(&live.mutex)
		if change, ok := &live.dirty_devices[id]; ok {
			change^ += parts
		} else {
			live.dirty_devices[strings.clone(id)] = parts
		}
		sync.unlock(&live.mutex)
		return true
	}
	if group == nil {return false}
	sync.lock(&live.mutex)
	append(
		&live.dirty_groups,
		Live_Change {
			group = strings.clone(string(group)),
			account = strings.clone(string(account)),
			superseded = event.tag == .Group_Change_Superseded,
			activation_signal = activation_signal,
		},
	)
	sync.unlock(&live.mutex)
	return true
}

start_live :: proc(live: ^Live, client: ^marmot.Client, account_ref: string) {
	for i := len(live.retired) - 1; i >= 0; i -= 1 {
		if job := live.retired[i]; thread.is_done(job.worker) {
			live_stream_free(job)
			unordered_remove(&live.retired, i)
		}
	}
	if old := live.stream; old != nil {
		if string(old.account) == account_ref {return}
		sync.lock(&live.mutex)
		old.cancel = true
		live.dirty = false
		sync.unlock(&live.mutex)
		append(&live.retired, old)
		live.stream = nil
	}
	if client == nil || account_ref == "" {return}
	job := new(Live_Stream)
	job.live, job.client, job.account = live, client, strings.clone_to_cstring(account_ref)
	job.worker = thread.create(live_worker)
	job.worker.data = job
	live.stream = job
	live.refresh_dirty = true
	thread.start(job.worker)
}

@(private = "file")
live_stream_free :: proc(job: ^Live_Stream) {
	thread.join(job.worker)
	thread.destroy(job.worker)
	delete(job.account)
	free(job)
}

@(private)
live_stop :: proc(live: ^Live) {
	if live.stream != nil {
		sync.lock(&live.mutex); live.stream.cancel = true; sync.unlock(&live.mutex)
		live_stream_free(live.stream)
	}
	for job in live.retired {live_stream_free(job)}
	delete(live.retired)
	live.stream, live.retired = nil, {}
}

@(private)
start_events :: proc(live: ^Live, client: ^marmot.Client) {
	if client == nil || live.events_attempted {return}
	live.events_attempted = true
	if marmot.subscribe_events(client, &live.events_sub) != .OK {
		detail := marmot.last_error()
		fmt.eprintfln("live: events subscribe failed: %s", detail)
		delete(detail)
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
// The sweep can block for a long time (883 ms measured on the first
// frame after boot, a one-group account), so it runs on a worker and
// the first tick after it lands applies the result.
RETENTION_SWEEP_SECS :: 60.0

@(private = "file")
retention_last: f64 = -1

@(private = "file")
Retention_Job :: struct {
	worker:  ^thread.Thread,
	client:  ^marmot.Client,
	account: cstring,
	now_ms:  u64,
	status:  marmot.Status,
	error:   string, // marmot's last_error is per thread
	report:  ^marmot.Retention_Sweep_Report,
}

@(private = "file")
retention_job: Retention_Job

@(private = "file")
retention_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer frame_wake()
	job := (^Retention_Job)(t.data)
	job.status = marmot.sweep_expired_retention(job.client, job.account, job.now_ms, &job.report)
	if job.status != .OK {
		job.report = nil
		job.error = marmot.last_error()
	}
}

// Join the sweep in flight and release it. Shutdown calls this before
// the client is freed.
@(private)
retention_stop :: proc() {
	job := &retention_job
	if job.worker == nil {
		return
	}
	thread.join(job.worker)
	thread.destroy(job.worker)
	if job.report != nil {
		marmot.retention_sweep_report_free(job.report)
	}
	delete(job.account)
	delete(job.error)
	job^ = {}
}

retention_tick :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if client == nil || len(ui.account_ref) == 0 {
		return
	}
	job := &retention_job
	if job.worker != nil {
		if thread.is_done(job.worker) {
			retention_apply(ui, client, job)
			retention_stop()
		}
		return
	}
	now := rl.GetTime()
	if retention_last >= 0 && now - retention_last < RETENTION_SWEEP_SECS {
		return
	}
	retention_last = now

	job^ = {
		client  = client,
		account = strings.clone_to_cstring(ui.account_ref),
		now_ms  = u64(time.now()._nsec) / 1_000_000,
	}
	job.worker = thread.create(retention_worker)
	job.worker.data = job
	thread.start(job.worker)
}

@(private = "file")
retention_apply :: proc(ui: ^Ui_State, client: ^marmot.Client, job: ^Retention_Job) {
	if job.status != .OK {
		fmt.eprintfln("retention sweep failed: %s", job.error)
		return
	}
	// An account switch mid-sweep leaves nothing on screen to refresh.
	report := job.report
	if string(job.account) != ui.account_ref {
		return
	}

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
			if thread_cur(ui) != "" {thread_check_placement(ui)}
		}
	}
}

// Apply pending live updates on the UI thread, preserving selection
// by group id across the chat-list reload.
drain_live :: proc(live: ^Live, ui: ^Ui_State, client: ^marmot.Client) {
	sync.lock(&live.mutex)
	dirty := live.dirty
	live.dirty = false
	groups := live.dirty_groups
	if len(groups) > 0 {live.dirty_groups = {}}
	sync.unlock(&live.mutex)

	refresh_members := false
	for group in groups {
		if group.account == ui.account_ref {dirty = true}
		if group.activation_signal {activation_live(ui, group)}
		refresh_members |=
			group.activation_signal &&
			group.account == ui.account_ref &&
			ui.show_members &&
			ui.selected >= 0 &&
			group.group == ui.chats[ui.selected].group_id &&
			!conversation_deleting(group.account, group.group)
		if group.superseded &&
		   group.account == ui.account_ref &&
		   ui.selected >= 0 &&
		   group.group == ui.chats[ui.selected].group_id {
			set_status(
				ui,
				strings.clone(
					tr("Another group change took precedence. Review your group settings."),
				),
				.Error,
			)
		}
		delete(group.group)
		delete(group.account)
	}
	if refresh_members {load_members(client, ui)}

	live.refresh_dirty ||= dirty || ui.chat_read_dirty
	ui.chat_read_dirty = false
	if len(groups) > 0 {
		clear(&groups)
		sync.lock(&live.mutex)
		if cap(live.dirty_groups) == 0 {
			live.dirty_groups = groups
			groups = {}
		}
		sync.unlock(&live.mutex)
		delete(groups)
		search_revision += 1
		sync_at = rl.GetTime() // the status bar shows SYNCING for a beat
	}

	job := live.refresh
	if job != nil && thread.is_done(job.worker) {
		live.refresh = nil
		live_apply(live, ui, client, job)
		chat_list_free(job)
		free(job)
	}
	// New rules can need facts the last refresh did not ask for.
	needed := folder_async_facts(ui.prefs)
	if (!ui.chat_members_read && folder_rules_need_members(ui.prefs)) ||
	   needed - ui.chat_folder_facts_attempted != {} {live.refresh_dirty = true}
	// Coalesce events while a read is running; never wait for that read on a frame.
	if live.refresh != nil || !live.refresh_dirty || client == nil || ui.account_ref == "" {return}
	include_archived := ui.page == .Archived
	if include_archived {
		for pending in account_jobs {
			if pending.kind == .Read_Archived && pending.account == ui.account_ref {return}
		}
	}
	live.refresh_dirty = false
	job = new(Chat_List_Work)
	job.client, job.account = client, strings.clone_to_cstring(ui.account_ref)
	job.revision = chat_list_revision
	job.include_archived = include_archived
	chat_list_snapshot(job, ui)
	job.worker = thread.create(chat_list_worker)
	job.worker.data = job
	live.refresh = job
	thread.start(job.worker)
}

@(private)
live_apply :: proc(live: ^Live, ui: ^Ui_State, client: ^marmot.Client, job: ^Chat_List_Work) {
	if string(job.account) != ui.account_ref {return}
	if job.revision != chat_list_revision {
		live.refresh_dirty ||= ui.page == .Archived
		return
	}
	// Unread counts before the reload, to spot the chats that gained
	// messages for desktop notifications.
	old_unread := make(map[string]u64, context.temp_allocator)
	for chat in ui.chats {
		old_unread[chat.group_id] = chat.unread
	}
	chat_list_apply(ui, job)
	focused := rl.IsWindowFocused()
	for chat, i in ui.chats {
		gate := Notify_Gate {
			enabled = ui.prefs.notify_desktop,
			focused = focused,
			viewing = i == ui.selected,
			muted   = chat.muted,
			from_me = chat.last_mine,
			blocked = chat.last_blocked,
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
	if ui.selected >= 0 &&
	   focused &&
	   !ui.timeline_loading &&
	   !ui.tl_has_after &&
	   ui.chats[ui.selected].unread > 0 {
		timeline_mark_read(ui)
	}
}

@(private)
Members_Work :: struct {
	worker:         ^thread.Thread,
	client:         ^marmot.Client,
	account, group: cstring,
	details:        ^marmot.Group_Details,
	err:            string,
}

@(private)
members_job: ^Members_Work
@(private)
members_retired: [dynamic]^Members_Work

// Group details enrich every member. Keep that database work off the UI thread.
load_members :: proc(client: ^marmot.Client, ui: ^Ui_State) {
	if ui.selected < 0 {return}
	if members_job != nil {append(&members_retired, members_job)}
	job := new(Members_Work)
	job.client = client
	job.account = strings.clone_to_cstring(ui.account_ref)
	job.group = strings.clone_to_cstring(ui.chats[ui.selected].group_id)
	job.worker = thread.create(proc(t: ^thread.Thread) {
		context.allocator = reload_allocator()
		job := (^Members_Work)(t.data)
		defer frame_wake()
		defer free_all(context.temp_allocator)
		if marmot.group_details(job.client, job.account, job.group, &job.details) != .OK {
			job.err = marmot.last_error()
		}
	})
	job.worker.data = job
	members_job = job
	thread.start(job.worker)
}

@(private)
members_free :: proc(job: ^Members_Work) {
	thread.join(job.worker)
	thread.destroy(job.worker)
	if job.details != nil {marmot.group_details_free(job.details)}
	delete(job.account); delete(job.group); delete(job.err)
	free(job)
}

@(private)
members_stop :: proc() {
	if members_job != nil {members_free(members_job); members_job = nil}
	for job in members_retired {members_free(job)}
	delete(members_retired); members_retired = {}
}

@(private)
members_drain :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	for i := len(members_retired) - 1; i >= 0; i -= 1 {
		if thread.is_done(members_retired[i].worker) {
			members_free(members_retired[i])
			unordered_remove(&members_retired, i)
		}
	}
	job := members_job
	if job == nil || !thread.is_done(job.worker) {return}
	members_job = nil
	defer members_free(job)
	if ui.selected < 0 ||
	   ui.account_ref != string(job.account) ||
	   ui.chats[ui.selected].group_id != string(job.group) {return}
	if job.details == nil {
		set_status(
			ui,
			fmt.aprintf("%s %s", tr("Couldn't load group members. Please try again."), job.err),
			.Error,
		)
		return
	}
	members_apply(ui, client, job.details)
}

@(private)
members_apply :: proc(ui: ^Ui_State, client: ^marmot.Client, details: ^marmot.Group_Details) {
	delete(ui.group_desc)
	ui.group_desc = strings.clone(
		details.group.description != nil ? string(details.group.description) : "",
	)
	ui.group_retention = details.group.disappearing_message_secs

	members_clear(ui)
	ui.member_nick = -1 // fresh rows invalidate the editor index
	ui.member_menu = -1
	for i in 0 ..< details.members_len {
		member := &details.members[i]
		// Local nickname wins over the published name, like contacts.
		name: string
		if nick, ok := ui.nicknames[string(member.member_id_hex)];
		   ok && len(nick) > 0 && !member.is_self {
			name = nick
		} else if member.display_name != nil && len(string(member.display_name)) > 0 {
			name = string(member.display_name)
		} else if member.is_self {
			name = "you"
		} else {
			name = profile_label(client, string(member.member_id_hex))
		}
		append(
			&ui.members,
			Member_Ui {
				pic_url = strings.clone(
					profile_info(client, string(member.member_id_hex)).pic_url,
				),
				id_hex = strings.clone(string(member.member_id_hex)),
				npub = hex_npub(string(member.member_id_hex)),
				name = strings.clone(name),
				is_admin = member.is_admin,
				is_self = member.is_self,
			},
		)
	}
}

@(private)
members_clear :: proc(ui: ^Ui_State) {
	for member in ui.members {
		delete(member.id_hex); delete(member.npub); delete(member.name); delete(member.pic_url)
	}
	clear(&ui.members)
}

// Optimistic-send plumbing: Enter appends a grayed "sending…" row
// and clears the composer immediately. A worker thread runs the
// blocking marmot call, and the frame loop drains completions (ack
// replaces the row with the confirmed record via reload; failure
// turns it danger with tap-to-retry).
//
//   Enter ──► ui.pending + worker ──► sends_done ──► drain_sends
//                (grayed row)          (mutex)     (drop row + reload,
//                                                   or mark failed)
Pending_Send :: struct {
	gif:                ^Gif_Job, // selected GIF while its upload bytes are preparing
	forward:            ^Forward_Job, // source snapshot while attachments are preparing
	forward_title:      string, // destination label retained through send completion
	forward_ticket:     int, // original action shared by its text and media sends
	forward_cancelled:  bool,
	account_ref:        string, // originating profile; never reassigned
	excerpt:            Excerpt,
	sticker:            Sticker_Ref,
	effect:             int,
	visible_since:      time.Tick, // compose action until first presented optimistic row
	sending_since:      time.Tick, // start of the current send attempt
	ticket:             int, // matches a Send_Done back to its row
	group_id:           string,
	sender:             string, // own display label, mirrors confirmed rows
	body:               string, // composed text; file name for a non-image upload
	reply_to:           string, // message id, "" = plain send
	thread:             string, // thread parent id, "" = main timeline
	atts:               [dynamic]Pending_Att, // upload payloads, owned until drained
	failed:             bool,
	thread_unavailable: bool,
	queued:             bool, // waiting for the auto-retry timer (offline.odin)
	acknowledged:       bool, // sent; preview retained until the timeline contains its replacement
	dismissed:          bool, // hidden during an active send; freed when its worker completes
	purged:             bool, // wiped while a worker still borrows the row
	attempts:           int, // failed tries so far, capped by MAX_SEND_ATTEMPTS
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
	emoji:      string, // NIP-30 shortcode this image defines, "" otherwise
}

Job_Att :: struct {
	name:       cstring,
	media_type: cstring,
	dim:        cstring, // nil for non-images
	data:       [^]u8, // borrowed from the Pending_Att
	data_len:   uint,
	emoji:      cstring, // nil unless the Pending_Att carries a shortcode
}

Send_Job :: struct {
	tags:    []marmot.Message_Tag,
	ticket:  int,
	client:  ^marmot.Client,
	account: cstring,
	group:   cstring,
	text:    cstring,
	reply:   cstring, // nil = plain send
	thread:  cstring, // nil = main timeline; else the kind-1111 parent
	caption: cstring, // nil, or the body to ride along with atts (aliases text)
	atts:    []Job_Att, // non-empty = upload_media instead of a text send
	sticker: [3]cstring, // pack, shortcode, hash; nil pack = not a sticker
}

Send_Done :: struct {
	ticket:             int,
	status:             marmot.Status, // classifies a failure as queued vs failed
	thread_unavailable: bool,
	err:                string, // "" = ok
	ids:                [dynamic]string, // hide a dismissed send even if publishing succeeds
	refresh_requested:  bool,
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

// MDK authors thread placement and imeta. Only NIP-30 needs a tag
// built from the upload result: ["emoji", shortcode, blossom_url].
@(private = "file")
send_message_refs :: proc(
	job: ^Send_Job,
	result: ^marmot.Media_Upload_Result,
	ids: ^[dynamic]string,
) -> marmot.Status {
	tags := job.tags
	refs: []marmot.Media_Attachment_Reference
	if result != nil {
		refs = make(
			[]marmot.Media_Attachment_Reference,
			result.attachments_len,
			context.temp_allocator,
		)
		rows: [dynamic]marmot.Message_Tag
		for &ref, i in refs {
			ref = result.attachments[i].reference
			if i >= len(job.atts) || job.atts[i].emoji == nil || ref.locators_len == 0 {
				continue
			}
			if rows == nil {
				rows = make(
					[dynamic]marmot.Message_Tag,
					0,
					len(tags) + len(refs),
					context.temp_allocator,
				)
				append(&rows, ..tags)
			}
			values := make([]cstring, 3, context.temp_allocator)
			values[0] = "emoji"
			values[1] = job.atts[i].emoji
			values[2] = ref.locators[0].value
			append(&rows, marmot.Message_Tag{raw_data(values), 3})
		}
		if rows != nil {tags = rows[:]}
	}

	summary: ^marmot.Send_Summary
	status: marmot.Status
	if job.thread != nil {
		status = marmot.send_thread_message(
			job.client,
			job.account,
			job.group,
			job.thread,
			job.text,
			raw_data(refs),
			uint(len(refs)),
			raw_data(tags),
			uint(len(tags)),
			&summary,
		)
	} else {
		status = marmot.send_tagged_media(
			job.client,
			job.account,
			job.group,
			raw_data(refs),
			uint(len(refs)),
			raw_data(tags),
			uint(len(tags)),
			job.caption,
			&summary,
		)
	}
	if status == .OK {
		sent_ids(ids, summary)
		marmot.send_summary_free(summary)
	}
	return status
}

@(private = "file")
send_job_execute :: proc(job: ^Send_Job, ids: ^[dynamic]string) -> marmot.Status {
	status: marmot.Status
	if job.sticker[0] != nil {
		// MDK builds the sticker tag; the reply and effect ride in job.tags.
		summary: ^marmot.Send_Summary
		status = marmot.send_tagged_sticker(
			job.client,
			job.account,
			job.group,
			job.sticker[0],
			job.sticker[1],
			job.sticker[2],
			raw_data(job.tags),
			uint(len(job.tags)),
			&summary,
		)
		if status == .OK {
			sent_ids(ids, summary)
			marmot.send_summary_free(summary)
		}
	} else if len(job.atts) > 0 {
		// One upload_media round trip: encrypt, push to Blossom, and
		// (main timeline) publish the kind-9 message in the same call.
		// A thread upload keeps send=false and publishes the references
		// itself as a kind-1111 event; upload_media sends kind 9.
		// Custom emoji also keep send=false: their NIP-30 tags need the
		// Blossom URLs, which exist only after the upload.
		has_emoji := false
		for a in job.atts {has_emoji ||= a.emoji != nil}
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
			message_tags     = raw_data(job.tags),
			message_tags_len = uint(len(job.tags)),
			attachments      = raw_data(requests),
			attachments_len  = uint(len(requests)),
			caption          = job.caption,
			send             = job.thread == nil && !has_emoji,
		}
		result: ^marmot.Media_Upload_Result
		status = marmot.upload_media(job.client, job.account, job.group, &request, &result)
		if status == .OK {
			if job.thread != nil || has_emoji {
				status = send_message_refs(job, result, ids)
			} else {
				sent_ids(ids, result.sent)
			}
			marmot.media_upload_result_free(result)
		}
		delete(requests)
	} else {
		summary: ^marmot.Send_Summary
		if job.thread != nil {
			return send_message_refs(job, nil, ids)
		} else if len(job.tags) > 0 {
			status = marmot.send_tagged_text(
				job.client,
				job.account,
				job.group,
				raw_data(job.tags),
				uint(len(job.tags)),
				job.text,
				&summary,
			)
		} else if job.reply != nil {
			status = marmot.reply_to_message(
				job.client,
				job.account,
				job.group,
				job.reply,
				job.text,
				&summary,
			)
		} else {
			status = marmot.send_text(job.client, job.account, job.group, job.text, &summary)
		}
		if status == .OK {
			sent_ids(ids, summary)
			marmot.send_summary_free(summary)
		}
	}
	return status
}

@(private = "file")
send_thread_available :: proc(job: ^Send_Job) -> (marmot.Status, bool) {
	available: u8
	status := marmot.thread_reply_context(
		job.client,
		job.account,
		job.group,
		job.thread,
		&available,
		nil,
	)
	return status, available != 0
}

send_worker :: proc(t: ^thread.Thread) {
	timing_start := time.tick_now()
	defer local_timing_end(.message_send, timing_start)
	context.allocator = reload_allocator()
	defer frame_wake()
	job := (^Send_Job)(t.data)
	status := marmot.Status.OK
	available := true
	if job.thread != nil && len(job.atts) > 0 {
		// Offline attempts may belong to a different chat than the open timeline.
		status, available = send_thread_available(job)
	}
	execute := status == .OK && available
	thread_unavailable := status == .OK && !available
	ids: [dynamic]string
	if execute {status = send_job_execute(job, &ids)}
	err: string
	if status != .OK {
		err = marmot.last_error()
		if err == "" {err = fmt.aprintf("%v", status)}
		// MDK reports placement rejection as RUNTIME. Only a successful
		// local lookup can turn that error into a terminal thread failure.
		if execute && job.thread != nil && status == .RUNTIME {
			check, still_available := send_thread_available(job)
			thread_unavailable = check == .OK && !still_available
		}
	}
	if thread_unavailable {
		delete(err)
		err = strings.clone(N_("Original message unavailable"))
	}
	fmt.eprintfln("send: ticket=%d done status=%v err=%s", job.ticket, status, err)
	sync.lock(&sends_mutex)
	append(
		&sends_done,
		Send_Done {
			ticket = job.ticket,
			status = status,
			thread_unavailable = thread_unavailable,
			err = err,
			ids = ids,
		},
	)
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
		if a.emoji != nil {
			delete(a.emoji)
		}
		// a.data belongs to the Pending_Att; drain_sends frees it.
	}
	delete(job.atts)
	for value in job.sticker {delete(value)}
	for tag in job.tags {
		for value in tag.values[:tag.values_len] {delete(value)}
		delete(tag.values[:tag.values_len])
	}
	delete(job.tags)
	free(job)
}

spawn_send :: proc(ui: ^Ui_State, client: ^marmot.Client, p: ^Pending_Send) {
	if !pending_send_allowed(ui, p^) {return}
	if p.gif != nil {gif_send_start(p); return}
	if p.forward != nil {forward_start(p); return}
	p.sending_since = time.tick_now()
	job := new(Send_Job)
	job.ticket = p.ticket
	job.client = client
	job.account = strings.clone_to_cstring(p.account_ref)
	job.group = strings.clone_to_cstring(p.group_id)
	job.text = strings.clone_to_cstring(p.body)
	job.reply = len(p.reply_to) > 0 ? strings.clone_to_cstring(p.reply_to) : nil
	job.thread = len(p.thread) > 0 ? strings.clone_to_cstring(p.thread) : nil
	job.tags = send_message_tags(p)
	if p.sticker.pack != "" {
		job.sticker = {
			strings.clone_to_cstring(p.sticker.pack),
			strings.clone_to_cstring(p.sticker.code),
			strings.clone_to_cstring(p.sticker.sha),
		}
	} else if len(p.atts) > 0 {
		// upload_media publishes the kind-9 itself, so the typed body
		// only survives as its caption. Staged files carry no typed
		// body (their name is the row label), and the thread path
		// sends job.text as the kind-1111 content already.
		emoji_only := job.thread == nil && len(p.body) > 0
		for a in p.atts {
			emoji_only &= a.emoji != ""
		}
		if emoji_only || p.sticker.sha != "" {
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
				emoji      = len(a.emoji) > 0 ? strings.clone_to_cstring(a.emoji) : nil,
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
	if !thread_can_send(ui) {return}
	started := time.tick_now()
	ui.scroll_pending = true // Reveal the preview before the relay responds.
	delete(ui.jump_id); ui.jump_id = ""
	info := profile_info(client, ui.account_ref)
	send_ticket += 1
	append(
		&ui.pending,
		Pending_Send {
			visible_since = started,
			effect        = ui.fx_armed,
			ticket        = send_ticket,
			account_ref   = strings.clone(ui.account_ref),
			group_id      = strings.clone(ui.chats[ui.selected].group_id),
			sender        = strings.clone(len(info.name) > 0 ? info.name : "you"),
			body          = strings.clone(body),
			// A reply can't carry a thread tag, so the open thread wins.
			reply_to      = strings.clone(len(thread_cur(ui)) > 0 ? "" : ui.replying),
			thread        = strings.clone(thread_cur(ui)),
		},
	)
	attach_body_emoji(&ui.pending[len(ui.pending) - 1], body)
	spawn_send(ui, client, &ui.pending[len(ui.pending) - 1])
}

// Ship the image behind every :shortcode: in the body, so the group
// (and any NIP-30 client) renders it instead of the literal text.
@(private = "file")
attach_body_emoji :: proc(p: ^Pending_Send, body: string) {
	for code in emoji_codes_in(body) {
		name, data := emoji_payload(code)
		if data == nil {
			continue
		}
		append(
			&p.atts,
			Pending_Att {
				name = name,
				media_type = media_type_for(name),
				data = data,
				emoji = strings.clone(code),
			},
		)
	}
}

free_pending :: proc(p: ^Pending_Send) {
	if p.gif != nil {gif_job_free(p.gif)}
	forward_free(p.forward)
	delete(p.forward_title)
	delete(p.account_ref)
	delete(p.group_id)
	sticker_ref_free(p.sticker)
	delete(p.sender)
	delete(p.body)
	delete(p.reply_to)
	delete(p.thread)
	for &a in p.atts {
		delete(a.name)
		delete(a.dim)
		delete(a.data)
		delete(a.emoji)
		if a.tex != nil {
			sticker_texture_free(a.tex^)
			free(a.tex)
		}
	}
	delete(p.atts)
}

// Move the staged chips into pending sends and kick upload workers:
// all images become ONE pending (the kind-9 album grid), every other
// file its own pending. Chips clear immediately; a failed upload
// turns its row danger for retry.
queue_staged :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if len(ui.staged) == 0 || !thread_can_send(ui) {
		return
	}
	started := time.tick_now()
	ui.scroll_pending = true
	delete(ui.jump_id); ui.jump_id = ""
	info := profile_info(client, ui.account_ref)
	sender := len(info.name) > 0 ? info.name : "you"
	group := ui.chats[ui.selected].group_id

	album := Pending_Send {
		account_ref   = strings.clone(ui.account_ref),
		effect        = len(ui.compose) == 0 ? ui.fx_armed : 0,
		reply_to      = strings.clone(thread_cur(ui) == "" ? ui.replying : ""),
		visible_since = started,
	}
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
				account_ref   = strings.clone(ui.account_ref),
				effect        = len(ui.compose) == 0 ? ui.fx_armed : 0,
				reply_to      = strings.clone(thread_cur(ui) == "" ? ui.replying : ""),
				visible_since = started,
				ticket        = send_ticket,
				group_id      = strings.clone(group),
				sender        = strings.clone(sender),
				body          = strings.clone(f.name),
				thread        = strings.clone(thread_cur(ui)),
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
		append(&ui.pending, album)
		spawn_send(ui, client, &ui.pending[len(ui.pending) - 1])
	}
	if len(album.atts) == 0 {free_pending(&album)}
	clear(&ui.staged) // fields moved into the pendings above
}

// Frame-loop drain: settle acked/failed sends and reap worker threads.
drain_sends :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	drain_gif_sends(ui, client)
	drain_forwards(ui, client)
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
	offline_changed := false
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
			for &p in ui.pending {
				if p.ticket != d.ticket ||
				   !pending_in_workspace(ui, p, string(timeline_job.group)) {
					continue
				}
				p.acknowledged = true
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
			offline_changed = true
			p.thread_unavailable = d.thread_unavailable
			if p.purged || account_revoked(ui, p.account_ref) {
				if !p.purged && !p.dismissed && d.err != "" && (p.queued || p.attempts > 0) {
					p.failed = true
					p.queued = false
				} else {
					free_pending(&p)
					ordered_remove(&ui.pending, i)
				}
				break
			}
			current := p.account_ref == ui.account_ref
			if p.dismissed || len(d.err) == 0 {
				forward_settled(ui, &p, p.dismissed ? .Cancelled : .Sent)
				if p.dismissed && len(d.ids) > 0 {
					for id in d.ids {
						if !ui.hidden[id] {
							ui.hidden[strings.clone(id)] = true
						}
					}
					save_hidden(ui)
				}
				if !p.dismissed &&
				   d.err == "" &&
				   p.forward_title != "" &&
				   p.account_ref == ui.account_ref {
					toast(ui, fmt.tprintf(tr("Forwarded to %s"), p.forward_title))
				}
				free_pending(&p)
				ordered_remove(&ui.pending, i)
				reload ||= current && len(d.err) == 0
			} else {
				// Transport-shaped failures queue for auto-retry until
				// the attempt cap; definitive errors fail outright.
				p.attempts += 1
				if !p.thread_unavailable &&
				   send_retryable(d.status) &&
				   p.attempts < MAX_SEND_ATTEMPTS {
					p.queued = true
				} else {
					p.failed = true
					if current {
						shake() // a send that is not coming back deserves it
						play_sound(.Error)
					}
				}
				if current {
					detail := p.thread_unavailable ? tr("Original message unavailable") : d.err
					set_status(ui, fmt.aprintf(tr("Send failed: %s"), detail), .Error)
				}
			}
			break
		}
	}
	if offline_changed {
		save_offline(ui)
	}
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
	ticket:       int,
	client:       ^marmot.Client,
	op:           Msg_Op,
	account:      cstring,
	group:        cstring,
	target:       cstring,
	emoji:        cstring, // nil for delete
	emoji_file:   cstring, // .React with a :code: this device has an image for
	emoji_png:    []u8, // that image's bytes, owned
	content:      cstring, // poll question or edit
	poll_values:  []cstring, // option labels on creation; selected ids on voting
	poll_type:    marmot.Poll_Type,
	poll_ends_at: u64,
	secs:         u64, // .Retention only
	advisory:     marmot.Status,
	retry_epoch:  u64,
}

Activation_Op_Result :: struct {
	status:      marmot.Status,
	disposition: marmot.Send_Accept_Disposition,
	published:   u32,
	baseline:    map[string]bool,
}

Op_Done :: struct {
	ticket:                          int,
	op:                              Msg_Op,
	err:                             string, // "" = ok, else the owned marmot error
	account, group, target, content: string,
	history:                         [dynamic]^marmot.Timeline_Edit_Page,
	has_original:                    bool, // .History: content holds the original plaintext
	original_at:                     u64,
	activation:                      Activation_Op_Result,
}

ops_mutex: sync.Mutex
ops_done: [dynamic]Op_Done
op_ticket: int

@(private = "file")
ENABLE_ACCOUNT_DEVICES_INTENT :: "enable_account_devices"

@(private)
activation_failures :: proc(
	client: ^marmot.Client,
	account, group: cstring,
	out: ^map[string]bool,
) -> marmot.Status {
	list: ^marmot.Group_Change_Not_Delivered_List
	status := marmot.group_changes_not_delivered(client, account, group, &list)
	if status != .OK || list == nil {return status}
	defer marmot.group_change_not_delivered_list_free(list)
	ids: map[string]bool
	for failure in list.items[:list.len] {
		if string(failure.intent_kind) != ENABLE_ACCOUNT_DEVICES_INTENT {continue}
		id := string(failure.commit_id_hex)
		if !ids[id] {ids[strings.clone(id)] = true}
	}
	out^ = ids
	return .OK
}

@(private)
activation_free_failures :: proc(ids: map[string]bool) {
	for id in ids {delete(id)}
	delete(ids)
}

@(private = "file")
enable_account_devices :: proc(job: ^Op_Job, out: ^Activation_Op_Result) -> marmot.Status {
	client, account, group := job.client, job.account, job.group
	status := activation_failures(client, account, group, &out.baseline)
	if status != .OK {return status}
	if job.advisory != .OK &&
	   job.retry_epoch != sync.atomic_load(&activation_epoch) {return .CLOSED}
	acknowledged: bool
	#partial switch job.advisory {
	case .OK:
	case .GROUP_COMMIT_UNDELIVERED:
		status = marmot.acknowledge_group_commit_undelivered(client, account, group, &acknowledged)
	case:
		return job.advisory
	}
	if status != .OK {return status}
	if job.advisory != .OK &&
	   job.retry_epoch != sync.atomic_load(&activation_epoch) {return .CLOSED}
	result: ^marmot.Group_Mutation_Result
	status = marmot.enable_account_devices(client, account, group, &result)
	if result != nil {
		out.disposition = result.summary.accept_disposition
		out.published = result.summary.published
		marmot.group_mutation_result_free(result)
	}
	return status
}

// NIP-30 reaction, the kind-7 counterpart of send_emoji_media: upload
// the image unsent, then react with its imeta plus ["emoji", code, url].
@(private = "file")
react_custom_emoji :: proc(job: ^Op_Job, summary: ^^marmot.Send_Summary) -> marmot.Status {
	upload := marmot.Media_Upload_Attachment_Request {
		file_name     = job.emoji_file,
		media_type    = strings.clone_to_cstring(
			media_type_for(string(job.emoji_file)),
			context.temp_allocator,
		),
		plaintext     = raw_data(job.emoji_png),
		plaintext_len = uint(len(job.emoji_png)),
	}
	request := marmot.Media_Upload_Request {
		attachments     = &upload,
		attachments_len = 1,
	}
	result: ^marmot.Media_Upload_Result
	if status := marmot.upload_media(job.client, job.account, job.group, &request, &result);
	   status != .OK {
		return status
	}
	defer marmot.media_upload_result_free(result)

	ref := &result.attachments[0].reference
	if ref.locators_len == 0 {
		return marmot.react_to_message(
			job.client,
			job.account,
			job.group,
			job.target,
			job.emoji,
			summary,
		)
	}
	code, _ := emoji_shortcode(string(job.emoji))
	values := [3]cstring {
		"emoji",
		strings.clone_to_cstring(code, context.temp_allocator),
		ref.locators[0].value,
	}
	tag := marmot.Message_Tag{raw_data(values[:]), 3}
	return marmot.react_with_media(
		job.client,
		job.account,
		job.group,
		job.target,
		job.emoji,
		ref,
		1,
		&tag,
		1,
		summary,
	)
}

@(private)
poll_thread_tags :: proc(
	parent: cstring,
	placement: ^marmot.Thread_Reply_Context,
	values: ^[5][4]cstring,
) -> [5]marmot.Message_Tag {
	values^ = {
		{"E", placement.root_message_id_hex, "", placement.root_author},
		{"K", fmt.ctprintf("%d", placement.root_kind), nil, nil},
		{"P", placement.root_author, nil, nil},
		{"e", parent, "", placement.parent_author},
		{"k", fmt.ctprintf("%d", placement.parent_kind), nil, nil},
	}
	return {
		{raw_data(values^[0][:]), 4},
		{raw_data(values^[1][:]), 2},
		{raw_data(values^[2][:]), 2},
		{raw_data(values^[3][:]), 4},
		{raw_data(values^[4][:]), 2},
	}
}

@(private = "file")
send_poll_job :: proc(job: ^Op_Job, summary: ^^marmot.Send_Summary) -> (marmot.Status, bool) {
	placement: ^marmot.Thread_Reply_Context
	defer if placement != nil {marmot.thread_reply_context_free(placement)}
	values: [5][4]cstring
	tags: [5]marmot.Message_Tag
	rows: []marmot.Message_Tag
	if string(job.target) != "" {
		available: u8
		status := marmot.thread_reply_context(
			job.client,
			job.account,
			job.group,
			job.target,
			&available,
			&placement,
		)
		if status != .OK {return status, false}
		if available == 0 {return .OK, true}
		tags = poll_thread_tags(job.target, placement, &values)
		rows = tags[:]
	}
	status := marmot.create_tagged_poll(
		job.client,
		job.account,
		job.group,
		job.content,
		raw_data(job.poll_values),
		uint(len(job.poll_values)),
		u32(job.poll_type),
		u8(job.poll_ends_at != 0),
		job.poll_ends_at,
		raw_data(rows),
		uint(len(rows)),
		summary,
	)
	return status, false
}

op_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer frame_wake()
	job := (^Op_Job)(t.data)
	summary: ^marmot.Send_Summary
	done := Op_Done {
		ticket = job.ticket,
		op     = job.op,
	}
	status: marmot.Status
	uninvited: bool
	poll_target_unavailable: bool
	switch job.op {
	case .Lookup_Member:
		done.content = nip05_lookup(string(job.target))
		status = .OK
	case .Retry_Convergence:
		status = marmot.retry_group_convergence(job.client, job.account, job.group, &summary)
	case .History:
		before: u64
		before_id: cstring
		for {
			page: ^marmot.Timeline_Edit_Page
			status = marmot.message_edit_history(
				job.client,
				job.account,
				job.group,
				job.target,
				before_id != nil ? 1 : 0,
				before,
				before_id,
				100,
				&page,
			)
			if status != .OK {break}
			append(&done.history, page)
			if !page.has_more || page.len == 0 {break}
			before, before_id = page.versions[0].edited_at, page.versions[0].id
		}
		// An empty history also covers deleted or invisible targets.
		if status == .OK && len(done.history) > 0 && done.history[0].len > 0 {
			records: ^marmot.App_Message_List
			// ponytail: scans the group's retained messages; use an ID lookup
			// when marmot-c exposes one. Keep the scan off the UI thread.
			status = marmot.messages(job.client, job.account, job.group, 0, 0, nil, 0, &records)
			if status == .OK && records != nil {
				for record in records.items[:records.len] {
					if string(record.message_id_hex) != string(job.target) {continue}
					done.has_original = true
					done.original_at = record.recorded_at
					done.content = strings.clone(string(record.plaintext))
					break
				}
			}
			if records != nil {marmot.app_message_list_free(records)}
		}
	case .React:
		if job.emoji_png != nil {
			status = react_custom_emoji(job, &summary)
		} else {
			status = marmot.react_to_message(
				job.client,
				job.account,
				job.group,
				job.target,
				job.emoji,
				&summary,
			)
		}
	case .Unreact:
		status = marmot.unreact_from_message(
			job.client,
			job.account,
			job.group,
			job.target,
			&summary,
		)
	case .Delete:
		status = marmot.delete_message(job.client, job.account, job.group, job.target, &summary)
	case .Edit:
		status = marmot.edit_message(
			job.client,
			job.account,
			job.group,
			job.target,
			job.content,
			&summary,
		)
	case .Poll_Create:
		status, poll_target_unavailable = send_poll_job(job, &summary)
	case .Poll_Vote:
		status = marmot.cast_poll_vote(
			job.client,
			job.account,
			job.group,
			job.target,
			raw_data(job.poll_values),
			uint(len(job.poll_values)),
			&summary,
		)
	case .Retention:
		status = marmot.update_message_retention(
			job.client,
			job.account,
			job.group,
			job.secs,
			&summary,
		)
	case .Rename:
		status = marmot.update_group_profile(
			job.client,
			job.account,
			job.group,
			job.target,
			nil,
			&summary,
		)
	case .Invite:
		refs := [1]cstring{job.target}
		invite: ^marmot.Invite_Members_Result
		status = marmot.invite_members(
			job.client,
			job.account,
			job.group,
			raw_data(refs[:]),
			1,
			&invite,
		)
		// An invitee without a usable KeyPackage leaves nothing to send.
		uninvited = invite != nil && invite.summary == nil
		marmot.invite_members_free(invite)
	case .Remove:
		refs := [1]cstring{job.target}
		status = marmot.remove_members(
			job.client,
			job.account,
			job.group,
			raw_data(refs[:]),
			1,
			&summary,
		)
	case .Promote:
		status = marmot.promote_admin(job.client, job.account, job.group, job.target, &summary)
	case .Demote:
		status = marmot.demote_admin(job.client, job.account, job.group, job.target, &summary)
	case .Enable_Account_Devices:
		done.activation.status = enable_account_devices(job, &done.activation)
	}

	err: string
	if job.op != .Enable_Account_Devices {
		if poll_target_unavailable {
			err = strings.clone(N_("Original message unavailable"))
		} else if status == .OK {
			marmot.send_summary_free(summary)
		} else {
			err = marmot.last_error()
			if err == "" {err = strings.clone(N_("Group action unavailable."))}
		}
	}
	if uninvited {
		err = strings.clone(
			N_(
				"Couldn't invite them. They have no key package White Noise can use. Ask them to open White Noise, then try again.",
			),
		)
	}
	done.err = err
	if job.op == .Retry_Convergence && string(job.target) != "" {
		report := fmt.tprintf("status=%v\nerror=%s\n", status, err)
		if write_err := os.write_entire_file(
			string(job.target),
			transmute([]u8)report,
			{.Read_User, .Write_User},
		); write_err != nil {
			fmt.eprintfln("%v: couldn't write result: %v", job.op, write_err)
		}
	}
	if job.op == .History ||
	   job.op == .Edit ||
	   job.op == .Lookup_Member ||
	   job.op == .Enable_Account_Devices ||
	   (job.op == .Invite && err != "") {
		done.account = strings.clone(string(job.account))
		done.group = strings.clone(string(job.group))
		if job.op != .Enable_Account_Devices &&
		   job.op != .Invite {done.target = strings.clone(string(job.target))}
		if job.op == .Edit {done.content = strings.clone(string(job.content))}
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
	delete(job.emoji_file)
	delete(job.emoji_png)
	for value in job.poll_values {delete(value)}
	delete(job.poll_values)
	if job.content != nil {
		delete(job.content)
	}
	free(job)
}

// Own every string before starting the worker: drafts and timeline
// projections can be replaced while native validation/publishing is in flight.
spawn_poll :: proc(
	ui: ^Ui_State,
	client: ^marmot.Client,
	op: Msg_Op,
	target, question: string,
	values: []string,
	poll_type: marmot.Poll_Type = .Single_Choice,
	ends_at: u64 = 0,
) {
	op_ticket += 1
	job := new(Op_Job)
	job.ticket = op_ticket
	job.client = client
	job.op = op
	job.account = strings.clone_to_cstring(ui.account_ref)
	job.group = strings.clone_to_cstring(ui.chats[ui.selected].group_id)
	job.target = strings.clone_to_cstring(target)
	job.content = strings.clone_to_cstring(question)
	job.poll_type = poll_type
	job.poll_ends_at = ends_at
	job.poll_values = make([]cstring, len(values))
	for value, i in values {job.poll_values[i] = strings.clone_to_cstring(value)}
	t := thread.create(op_worker)
	t.data = job
	append(&send_threads, t)
	thread.start(t)
}

spawn_op :: proc(
	ui: ^Ui_State,
	client: ^marmot.Client,
	op: Msg_Op,
	message_id, emoji: string,
	secs: u64 = 0,
	advisory: marmot.Status = .OK,
) -> int {
	op_ticket += 1
	ticket := op_ticket
	job := new(Op_Job)
	job.ticket = ticket
	job.client = client
	job.op = op
	job.account = strings.clone_to_cstring(ui.account_ref)
	job.group = strings.clone_to_cstring(
		op == .Lookup_Member && ui.new_chat_open ? "" : ui.chats[ui.selected].group_id,
	)
	if op != .Enable_Account_Devices {job.target = strings.clone_to_cstring(message_id)}
	if op == .React {
		job.emoji = strings.clone_to_cstring(emoji)
		if code, custom := emoji_shortcode(emoji); custom {
			name, data := emoji_payload(code)
			if data != nil {
				job.emoji_file = strings.clone_to_cstring(name)
				job.emoji_png = data
				delete(name)
			}
		}
	}
	if op == .Edit {job.content = strings.clone_to_cstring(emoji)}
	job.secs = secs
	job.advisory = advisory
	if advisory != .OK {job.retry_epoch = ui.activation.revision}

	t := thread.create(op_worker)
	t.data = job
	append(&send_threads, t)
	thread.start(t)
	return ticket
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

	reload := false
	for d in done {
		if d.op == .Enable_Account_Devices {activation_complete(ui, client, d); continue}
		poll_complete(d.ticket)
		if d.op == .Poll_Create && d.ticket == ui.poll_ticket {
			ui.poll_ticket = 0
			if d.err == "" {
				poll_close(ui)
				ui.scroll_pending = true
				play_sound(.Send)
			}
		}
		if d.op == .Lookup_Member {nip05_complete(ui, d); continue}
		reload = true
		if d.op == .History {
			if d.ticket == ui.hist_ticket {
				ui.hist_ticket = 0
				if d.err !=
				   "" {set_status(ui, strings.clone(tr("Couldn't load edit history. Please try again.")), .Error)} else {
					ui.hist_original = d.has_original
					if d.has_original {append(&ui.hist_versions, history_version(client, d.original_at, d.content))}
					for i := len(d.history) - 1; i >= 0; i -= 1 {
						for v in d.history[i].versions[:d.history[i].len] {append(&ui.hist_versions, history_version(client, v.edited_at, string(v.plaintext)))}
					}
					history_highlight(ui.hist_versions[:])
				}
			}
			for page in d.history {marmot.edit_history_free(page)}
			delete(d.history); edit_result_free(d)
			continue
		}
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
		if d.op == .Invite &&
		   (ui.account_ref != d.account ||
				   ui.page != .Chats ||
				   ui.add_account_open ||
				   ui.new_chat_open ||
				   ui.selected < 0 ||
				   ui.selected >= len(ui.chats) ||
				   ui.chats[ui.selected].group_id != d.group) {
			edit_result_free(d)
			continue
		}
		#partial switch d.op {
		case .Retention:
			load_members(client, ui) // undo the optimistic chip flip
		case .Rename:
			refresh_after_action(ui, client) // undo the optimistic title
		}
		// d.err is marmot's error text or an N_ msgid from the worker.
		set_status(ui, fmt.aprintf(tr("Action failed: %s"), tr(d.err)), .Error)
		edit_result_free(d)
		shake()
		play_sound(.Error)
	}
	if reload {load_timeline(client, ui)}
}

@(private)
ops_stop :: proc() {
	for done in ops_done {
		for page in done.history {marmot.edit_history_free(page)}
		delete(done.history)
		activation_free_failures(done.activation.baseline)
		edit_result_free(done)
	}
	delete(ops_done)
	ops_done = {}
}

// Which hover action a chat row offers (rail rows archive, archive-page
// rows unarchive); also selects the chip's nendo ID for click handling.

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
	if marmot.prewarm_group_member_key_packages(
		   job.client,
		   account,
		   raw_data(refs[:]),
		   1,
		   &summary,
	   ) ==
		   .OK &&
	   summary != nil {
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
	if marmot.refresh_user_relay_lists(
		   job.client,
		   id,
		   raw_data(DEFAULT_RELAYS),
		   uint(len(DEFAULT_RELAYS)),
		   &lists,
	   ) ==
		   .OK &&
	   lists != nil {
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
// A fresh key and picture are prepared offline. Only "Create and publish"
// starts account setup, picture upload and profile publication.
//
// A remote signer makes up to three trips, after a permission review:
//
//   Continue ─► card: review grants (no worker; Cancel drops the session)
//   Allow ────► worker: approve ─► pair: offer ─► card: pairing code
//                                  bunker: connect
//               worker: connect (pair) ─► worker: login ─► land

@(private)
Starter_Phase :: enum {
	Prepare,
	Review,
	Create,
	Result,
}

Auth_Job :: struct {
	client:                    ^marmot.Client,
	nsec:                      string,
	method:                    Login_Method,
	prior_accounts:            [dynamic]string,
	session:                   ^marmot.Nip46_Session,
	grants:                    Nip46_Grants, // what the review step shows and approves
	reviewing:                 bool, // the card waits for "Allow and connect"
	approved:                  bool,
	pair_uri:                  string, // pairing offer; a credential
	remote_login:              bool,
	cancelled, cancel_cleanup: bool,
	previous_session:          ^Nip46_Account,
	signer_state:              Nip46_State,
	starter_phase:             Starter_Phase,
	starter_image:             rl.Image,
	starter_preview:           rl.Texture2D,
	starter_saved:             bool,
	consent_pressed:           bool,
	consent_rect:              nendo.Rect,
	name:                      string,
	hex:                       string, // the reviewed or signed-in account
	pic_url:                   string,
	profile_confirmed:         bool,
	err:                       string, // "" = it worked
	first_import:              bool,
	unlinked_target:           string,
	refused_unlinked:          bool,
	wiping, wipe_retried:      bool,
}

// Non-nil while a sign-in is in flight; the login pane reads it.
auth_job: ^Auth_Job
@(private = "file")
auth_thread: ^thread.Thread

@(private)
auth_stop :: proc() {
	if auth_job != nil && auth_job.session != nil {marmot.nip46_cancel(auth_job.session)}
	if auth_thread != nil {
		thread.join(auth_thread)
		thread.destroy(auth_thread)
		auth_thread = nil
	}
	if auth_job != nil {auth_job_free(auth_job); auth_job = nil}
	auth_done = false
}

auth_job_free :: proc(job: ^Auth_Job) {
	if job.session != nil {marmot.nip46_free(job.session)}
	nip46_state_free(&job.signer_state)
	nip46_grants_free(&job.grants)
	mem.zero_slice(transmute([]u8)job.nsec)
	mem.zero_slice(transmute([]u8)job.pair_uri)
	for id in job.prior_accounts {delete(id)}
	delete(job.prior_accounts)
	delete(job.nsec); delete(job.pair_uri)
	delete(job.name); delete(job.hex); delete(job.pic_url); delete(job.err)
	rl.UnloadTexture(job.starter_preview)
	free(job.starter_image.data)
	delete(job.unlinked_target)
	job.client = nil
	free(job)
}

@(private)
reload_jobs_busy :: proc() -> bool {
	// Remote transport is cancellable; session_stop cancels it before joining.
	if auth_thread != nil && (auth_job == nil || auth_job.session == nil) {return true}
	// Preparation can finish between frames, before its upload is spawned.
	if g_ui != nil {
		for p in g_ui.pending {
			if (p.forward != nil || p.gif != nil) && !p.failed && !p.dismissed {return true}
		}
	}
	for worker in send_threads {
		if !thread.is_done(worker) {return true}
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
	switch job.method {
	case .Import:
		before: ^marmot.Account_Summary_List
		known := marmot.list_accounts(job.client, &before) == .OK
		hex, status, detail := import_identity_blocking(job.client, job.nsec)
		job.hex = hex
		if status != .OK {
			job.err = strings.clone(
				tr("Couldn't sign in with that key. Double-check it and try again."),
			)
			auth_check_unlinked(job, status, detail)
		} else if known {
			job.first_import = true
			if before != nil {
				for row in before.items[:before.len] {
					if string(row.account_id_hex) == hex {job.first_import = false; break}
				}
			}
		}
		delete(detail)
		if before != nil {marmot.account_summary_list_free(before)}
	case .Create:
		if job.starter_phase == .Prepare {
			prepare_starter(job)
		} else {
			create_starter(job)
		}
	case .Bunker, .Pair:
		if job.cancel_cleanup {
			if job.remote_login {
				outcome: ^marmot.Sign_Out_Outcome
				status := marmot.sign_out(
					job.client,
					strings.clone_to_cstring(job.hex, context.temp_allocator),
					0,
					&outcome,
				)
				if outcome != nil {marmot.sign_out_outcome_free(outcome)}
				if status != .OK {job.err = marmot.last_error()}
			}
			marmot.nip46_logout(job.session)
			if job.err == "" {job.err = strings.clone(tr("Connection cancelled."))}
		} else if !job.approved {
			job.err = nip46_approve(job.session, job.grants)
			job.approved = job.err == ""
			// Pairing shows its code before connecting; drain_auth restarts.
			if job.approved && job.method == .Pair {
				uri: cstring
				if marmot.nip46_pairing_offer(job.session, &uri) != .OK {
					job.err = marmot.last_error()
				} else {
					job.pair_uri = strings.clone(string(uri))
					mem.zero_slice(transmute([]u8)string(uri)); marmot.string_free(uri)
				}
			} else if job.approved {
				auth_connect(job)
			}
		} else if !job.remote_login {
			auth_connect(job)
		} else {
			if job.previous_session !=
			   nil {nip46_account_free(job.previous_session); job.previous_session = nil}
			// MDK persists the verified session; nothing goes to the vault.
			summary: ^marmot.Account_Summary
			status := marmot.nip46_login(
				job.client,
				job.session,
				raw_data(ONBOARDING_RELAYS),
				len(ONBOARDING_RELAYS),
				raw_data(ONBOARDING_RELAYS),
				len(ONBOARDING_RELAYS),
				nil,
				0,
				&summary,
			)
			if status != .OK {
				job.err = marmot.last_error()
				auth_check_unlinked(job, status, job.err)
			} else {
				delete(job.hex); job.hex = strings.clone(string(summary.account_id_hex))
				marmot.account_summary_free(summary)
			}
		}
	case .Menu, .Existing:
		job.err = strings.clone(tr("Choose a sign-in method."))
	}
	free_all(context.temp_allocator)

	sync.lock(&auth_mutex)
	auth_done = true
	sync.unlock(&auth_mutex)
}

@(private)
auth_unlinked_target :: proc(
	accounts: ^marmot.Account_Summary_List,
	method: Login_Method,
	detail, verified: string,
) -> string {
	if accounts == nil {return ""}
	REFUSAL :: "this device was unlinked from the account: "
	ref := verified
	if method == .Import {
		if !strings.has_prefix(detail, REFUSAL) {return ""}
		ref = detail[len(REFUSAL):]
	}
	if ref == "" {return ""}
	match: string
	for row in accounts.items[:accounts.len] {
		if !row.signed_out || !row.unlinked {continue}
		hex := string(row.account_id_hex)
		if hex != ref && !(method == .Import && string(row.label) == ref) {continue}
		if match != "" {return ""}
		match = hex
	}
	return match
}

@(private = "file")
auth_check_unlinked :: proc(job: ^Auth_Job, status: marmot.Status, detail: string) {
	if status != .ACCOUNT_UNLINKED {return}
	job.refused_unlinked = true
	if job.wipe_retried {return}
	accounts: ^marmot.Account_Summary_List
	if marmot.list_accounts(job.client, &accounts) == .OK {
		job.unlinked_target = strings.clone(
			auth_unlinked_target(accounts, job.method, detail, job.hex),
		)
	}
	if accounts != nil {marmot.account_summary_list_free(accounts)}
}

@(private)
auth_wipe_start :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	job := auth_job
	if job == nil ||
	   job.unlinked_target == "" ||
	   job.wiping ||
	   ui.devices.panel_account != job.unlinked_target {return}
	if wipe := account_job_new(ui, client, .Wipe_Unlinked, job.unlinked_target); wipe != nil {
		job.wiping = true
		account_job_start(wipe)
	}
}

@(private)
auth_unlink_cancel :: proc(ui: ^Ui_State) {
	if auth_job == nil || auth_job.wiping || auth_job.unlinked_target == "" {return}
	auth_job_free(auth_job); auth_job = nil
	login_pair_clear(ui)
	devices_notice_closed(ui)
}

@(private)
auth_wipe_finished :: proc(ui: ^Ui_State, client: ^marmot.Client, account: string, removed: bool) {
	job := auth_job
	if job == nil || !job.wiping || job.unlinked_target != account || job.client != client {return}
	job.wiping = false
	if !removed {
		if ui.devices.panel == .Auth_Unlinked {devices_close(ui)}
		auth_job_free(job); auth_job = nil
		return
	}
	if job.method != .Import {
		ui.login_method = job.method
		ui.login_error = strings.clone(tr("Connect your signer again to sign in."))
		ui.add_account_open = ui.account_ref != ""
		auth_job_free(job); auth_job = nil
		return
	}
	delete(job.err); job.err = ""
	delete(job.unlinked_target); job.unlinked_target = ""
	job.refused_unlinked, job.wipe_retried = false, true
	auth_thread = thread.create(auth_worker); auth_thread.data = job; thread.start(auth_thread)
}

@(private = "file")
auth_connect :: proc(job: ^Auth_Job) {
	user: cstring
	if marmot.nip46_connect(job.session, &user) != .OK {job.err = marmot.last_error(); return}
	job.hex = strings.clone(string(user)); marmot.string_free(user)
}

start_auth :: proc(
	ui: ^Ui_State,
	client: ^marmot.Client,
	nsec: string,
	method: Login_Method,
	session: ^marmot.Nip46_Session = nil,
) {
	if auth_job != nil || client == nil {
		return
	}
	delete(ui.login_error); ui.login_error = ""

	auth_job = new(Auth_Job)
	auth_job.client = client
	auth_job.nsec = strings.clone(nsec)
	auth_job.method = method
	if auth_job.method == .Import {
		for account in ui.accounts {append(&auth_job.prior_accounts, strings.clone(account.id_hex))}
	}
	auth_job.session = session
	// A remote session first waits on the card for its permission review.
	if session != nil {auth_job.reviewing = true; return}
	auth_thread = thread.create(auth_worker)
	auth_thread.data = auth_job
	thread.start(auth_thread)
}

// "Allow and connect" on the review step: approve and connect on the worker.
auth_allow :: proc() {
	if auth_job == nil || !auth_job.reviewing {
		return
	}
	auth_job.reviewing = false
	auth_thread = thread.create(auth_worker)
	auth_thread.data = auth_job
	thread.start(auth_thread)
}

@(private)
auth_create_start :: proc(ui: ^Ui_State, name: string) {
	if auth_job.starter_phase == .Review {
		delete(auth_job.name)
		auth_job.name = strings.clone(name)
		editor_forget(ui)
		clear(&ui.login_input)
		rl.UnloadTexture(auth_job.starter_preview)
		auth_job.starter_preview = {}
	}
	kb_focus = ""
	touch_field = {}
	auth_job.consent_pressed = false
	auth_job.consent_rect = {}
	delete(auth_job.err); auth_job.err = ""
	auth_job.starter_phase = .Create
	auth_thread = thread.create(auth_worker)
	auth_thread.data = auth_job
	thread.start(auth_thread)
}

@(private)
auth_create_finish :: proc(ui: ^Ui_State) {
	job := auth_job
	auth_job = nil
	defer auth_job_free(job)
	finish_starter(ui, job)
	open_key_export(ui, job.hex)
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
	if job.cancelled && job.session == nil {
		auth_job = nil
		defer auth_job_free(job)
		if job.method == .Import && job.hex != "" {
			known := false
			for id in job.prior_accounts {if id == job.hex {known = true; break}}
			if !known {
				// Back leaves an imported identity's existing data intact.
				account_job_start(
					account_job_new(ui, client, .Sign_Out, job.hex, sign_out_intent = .Back),
				)
			}
		}
		ui.login_error = ""
		login_pair_clear(ui)
		return
	}
	if job.cancelled && job.err == "" {
		job.cancel_cleanup = true
		auth_thread = thread.create(auth_worker); auth_thread.data = job; thread.start(auth_thread)
		return
	}
	if job.refused_unlinked && !job.cancelled {
		editor_forget(ui); session_buffer_forget(&ui.login_input)
		login_pair_clear(ui)
		if job.unlinked_target != "" {
			devices_mark_unlinked(ui, job.unlinked_target, "")
			devices_show(ui, .Auth_Unlinked, job.unlinked_target)
			return
		}
		ui.devices.inventory_dirty = true
		auth_job = nil
		auth_job_free(job)
		ui.add_account_open = false
		ui.login_error = strings.clone(
			tr("This device was unlinked. Remove the unlinked profile before signing in again."),
		)
		return
	}
	// The pairing offer landed: show its code while the signer connects.
	if job.err == "" && job.pair_uri != "" && job.hex == "" {
		login_pair_show(ui, job.pair_uri)
		auth_thread = thread.create(auth_worker); auth_thread.data = job; thread.start(auth_thread)
		return
	}
	if job.err == "" && job.session != nil && !job.remote_login {
		previous := nip46_find(job.hex)
		busy := false
		for pending in account_jobs {if pending.account == job.hex {busy = true; break}}
		if !busy {
			if previous != nil {
				marmot.nip46_cancel(previous.handle)
				for item, i in nip46_accounts {if item == previous {ordered_remove(&nip46_accounts, i); break}}
				job.previous_session = previous
			}
			job.remote_login = true
			auth_thread = thread.create(
				auth_worker,
			); auth_thread.data = job; thread.start(auth_thread)
			return
		}
		job.err = strings.clone(
			tr("Your account has a pending action. Complete it before reconnecting your signer."),
		)
	}
	if job.method == .Create {
		if job.starter_phase == .Create {
			job.starter_phase = .Result
			return
		}
		if job.err == "" {
			job.starter_preview = rl.LoadTextureFromImage(job.starter_image)
			if job.starter_preview.tex != nil {
				job.starter_phase = .Review
				kb_focus = ""
				touch_field = {}
				ed_set(ui, &ui.login_input, job.name)
				return
			}
			job.err = strings.clone(tr("Couldn't prepare your starter profile. Please try again."))
		}
	}
	auth_job = nil
	defer auth_job_free(job)

	if job.cancelled {
		ui.login_error = ""
		login_pair_clear(ui)
		return
	}
	if len(job.err) > 0 {
		ui.login_error = strings.clone(job.err)
		login_pair_clear(ui)
		return
	}
	if job.session != nil {
		item := new(
			Nip46_Account,
		); item.account = strings.clone(job.hex); item.client = client; item.registered = true; append(&nip46_accounts, item)
		item.handle = job.session; job.session = nil
	}
	login_pair_clear(ui)
	finish_auth(ui, client, job.hex)
	if job.first_import && ui.account_ref == job.hex {devices_first_import(ui)}
}
