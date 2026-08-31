package main

import "core:c"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:text/edit"
import "core:unicode/utf8"
import "core:sync"
import "core:thread"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

Live :: struct {
	mutex:        sync.Mutex,
	dirty:        bool, // chat list changed
	dirty_groups: [dynamic]string, // group ids with changed rows
	sub:          ^marmot.Chat_List_Subscription,
	worker:       ^thread.Thread,
}

live_worker :: proc(t: ^thread.Thread) {
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
		append(&live.dirty_groups, strings.clone(string(row.group_id_hex)))
		sync.unlock(&live.mutex)
		marmot.chat_list_row_free(row)
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
	live.worker.data = live
	thread.start(live.worker)
}

// The subscription is the fast path, and this is the safety net: a
// stream that never wakes (a dropped relay socket, a subscription that
// silently stops) would otherwise leave the rail and the open timeline
// stale until the user switched chats by hand. The poll just marks the
// list dirty; drain_live does the one refresh either way, and only
// reloads the timeline when the open chat's newest id actually moved.
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

// Apply pending live updates on the UI thread, preserving selection
// by group id across the chat-list reload.
drain_live :: proc(live: ^Live, ui: ^Ui_State, client: ^marmot.Client) {
	sync.lock(&live.mutex)
	dirty := live.dirty
	live.dirty = false
	timeline_hit := false
	if ui.selected >= 0 {
		for group in live.dirty_groups {
			if group == ui.chats[ui.selected].group_id {
				timeline_hit = true
				break
			}
		}
	}
	had_events := len(live.dirty_groups) > 0
	for group in live.dirty_groups {
		delete(group)
	}
	clear(&live.dirty_groups)
	sync.unlock(&live.mutex)

	if !dirty {
		return
	}
	if had_events {
		sync_at = rl.GetTime() // the status bar shows SYNCING for a beat
	}

	selected_group: string
	// The open chat's newest message id before the reload. The dirty-group
	// ids are the primary signal, but a mismatch there (a differently
	// formatted id, an event for a group the list renamed) would silently
	// strand the open timeline: the rail row updates and the messages
	// don't. Comparing the id across the reload catches that case from
	// the data instead of from the event.
	selected_last: string
	if ui.selected >= 0 {
		selected_group = ui.chats[ui.selected].group_id
		selected_last = ui.chats[ui.selected].last_id
	}
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
	if ui.selected >= 0 && (timeline_hit || ui.chats[ui.selected].last_id != selected_last) {
		load_timeline(client, ui)
		// Messages that arrive in the chat you are watching count as
		// read, so the badge doesn't pile up on screen.
		if focused && ui.chats[ui.selected].unread > 0 {
			mark_chat_read(ui, client, ui.selected)
		}
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
	ticket:   int, // matches a Send_Done back to its row
	group_id: string,
	sender:   string, // own display label, mirrors confirmed rows
	body:     string, // composed text; file name for a non-image upload
	reply_to: string, // message id, "" = plain send
	atts:     [dynamic]Pending_Att, // upload payloads, owned until drained
	failed:   bool,
	queued:   bool, // waiting for the auto-retry timer (offline.odin)
	attempts: int, // failed tries so far, capped by MAX_SEND_ATTEMPTS
}

// One attachment moved out of Staged_File at send time. The worker's
// upload request points straight at `data`, so an atts-carrying
// pending is only ever freed by drain_sends (never by the
// arrival-settlement in load_timeline).
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
	atts:    []Job_Att, // non-empty = upload_media instead of a text send
}

Send_Done :: struct {
	ticket: int,
	status: marmot.Status, // classifies a failure as queued vs failed
	err:    string, // "" = ok
}

sends_mutex: sync.Mutex
sends_done: [dynamic]Send_Done
send_threads: [dynamic]^thread.Thread
send_ticket: int

send_worker :: proc(t: ^thread.Thread) {
	job := (^Send_Job)(t.data)
	status: marmot.Status
	if len(job.atts) > 0 {
		// One upload_media round trip with send=true: encrypt, push to
		// Blossom, publish the kind-9 message.
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
			send            = true,
		}
		result: ^marmot.Media_Upload_Result
		status = marmot.upload_media(job.client, job.account, job.group, &request, &result)
		if status == .OK {
			marmot.media_upload_result_free(result)
		}
		delete(requests)
	} else {
		summary: ^marmot.Send_Summary
		if job.reply != nil {
			status = marmot.reply_to_message(job.client, job.account, job.group, job.reply, job.text, &summary)
		} else {
			status = marmot.send_text(job.client, job.account, job.group, job.text, &summary)
		}
		if status == .OK {
			marmot.send_summary_free(summary)
		}
	}

	err: string
	if status != .OK {
		err = marmot.last_error()
	}
	fmt.eprintfln("send: ticket=%d done status=%v err=%s", job.ticket, status, err)
	sync.lock(&sends_mutex)
	append(&sends_done, Send_Done{ticket = job.ticket, status = status, err = err})
	sync.unlock(&sends_mutex)

	delete(job.account)
	delete(job.group)
	delete(job.text)
	if job.reply != nil {
		delete(job.reply)
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

spawn_send :: proc(ui: ^Ui_State, client: ^marmot.Client, p: Pending_Send) {
	job := new(Send_Job)
	job.ticket = p.ticket
	job.client = client
	job.account = strings.clone_to_cstring(ui.account_ref)
	job.group = strings.clone_to_cstring(p.group_id)
	job.text = strings.clone_to_cstring(p.body)
	job.reply = len(p.reply_to) > 0 ? strings.clone_to_cstring(p.reply_to) : nil
	if len(p.atts) > 0 {
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
	info := profile_info(client, ui.account_ref)
	send_ticket += 1
	append(&ui.pending, Pending_Send{
		ticket   = send_ticket,
		group_id = strings.clone(ui.chats[ui.selected].group_id),
		sender   = strings.clone(len(info.name) > 0 ? info.name : "you"),
		body     = strings.clone(body),
		reply_to = strings.clone(ui.replying),
	})
	spawn_send(ui, client, ui.pending[len(ui.pending) - 1])
}

free_pending :: proc(p: ^Pending_Send) {
	delete(p.group_id)
	delete(p.sender)
	delete(p.body)
	delete(p.reply_to)
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
	info := profile_info(client, ui.account_ref)
	sender := len(info.name) > 0 ? info.name : "you"
	group := ui.chats[ui.selected].group_id

	album: Pending_Send
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
				ticket   = send_ticket,
				group_id = strings.clone(group),
				sender   = strings.clone(sender),
				body     = strings.clone(f.name),
			}
			append(&p.atts, att)
			append(&ui.pending, p)
			spawn_send(ui, client, ui.pending[len(ui.pending) - 1])
		}
	}
	if len(album.atts) > 0 {
		send_ticket += 1
		album.ticket = send_ticket
		album.group_id = strings.clone(group)
		album.sender = strings.clone(sender)
		album.body = strings.clone("")
		append(&ui.pending, album)
		spawn_send(ui, client, ui.pending[len(ui.pending) - 1])
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

	reload := false
	for d in done {
		for &p, i in ui.pending {
			if p.ticket != d.ticket {
				continue
			}
			fmt.eprintfln("send: ticket=%d settled err=%s", d.ticket, d.err)
			if len(d.err) == 0 {
				free_pending(&p)
				ordered_remove(&ui.pending, i)
				reload = true
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
				delete(d.err)
			}
			break
		}
	}
	save_offline(ui)
	// ponytail: a live-worker reload can show the confirmed record a
	// frame before the ack drops the pending row (brief duplicate);
	// key pending rows by wire id if it ever shows.
	if reload {
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
}

Op_Done :: struct {
	ticket: int,
	err:    string, // "" = ok, else the owned marmot error
}

ops_mutex: sync.Mutex
ops_done: [dynamic]Op_Done
op_ticket: int

op_worker :: proc(t: ^thread.Thread) {
	job := (^Op_Job)(t.data)
	summary: ^marmot.Send_Summary
	status: marmot.Status
	switch job.op {
	case .React:
		status = marmot.react_to_message(job.client, job.account, job.group, job.target, job.emoji, &summary)
	case .Unreact:
		status = marmot.unreact_from_message(job.client, job.account, job.group, job.target, &summary)
	case .Delete:
		status = marmot.delete_message(job.client, job.account, job.group, job.target, &summary)
	}

	err: string
	if status == .OK {
		marmot.send_summary_free(summary)
	} else {
		err = marmot.last_error()
	}
	sync.lock(&ops_mutex)
	append(&ops_done, Op_Done{ticket = job.ticket, err = err})
	sync.unlock(&ops_mutex)

	delete(job.account)
	delete(job.group)
	delete(job.target)
	if job.emoji != nil {
		delete(job.emoji)
	}
	free(job)
}

spawn_op :: proc(ui: ^Ui_State, client: ^marmot.Client, op: Msg_Op, message_id, emoji: string) -> int {
	op_ticket += 1
	job := new(Op_Job)
	job.ticket = op_ticket
	job.client = client
	job.op = op
	job.account = strings.clone_to_cstring(ui.account_ref)
	job.group = strings.clone_to_cstring(ui.chats[ui.selected].group_id)
	job.target = strings.clone_to_cstring(message_id)
	job.emoji = op == .React ? strings.clone_to_cstring(emoji) : nil

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
			continue
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
@(private = "file")
auth_mutex: sync.Mutex
@(private = "file")
auth_done: bool

@(private = "file")
auth_worker :: proc(t: ^thread.Thread) {
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
