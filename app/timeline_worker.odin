package main

import marmot "../marmot"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import rl "sdlrl"

@(private)
Timeline_Direction :: enum {
	None,
	Older,
	Newer,
}
@(private)
Timeline_Work :: struct {
	mutex:                  sync.Mutex,
	worker:                 ^thread.Thread,
	client:                 ^marmot.Client,
	account, group, search: cstring, // immutable, owned until the worker joins
	cancel:                 bool,
	issues:                 bool, // full retained projection while browsing issue discussions
	request:                Timeline_Direction,
	history:                [dynamic]^marmot.Timeline_Page, // older pages, issue discussions only
	page:                   ^marmot.Timeline_Page, // mailbox owns the latest complete snapshot
	err:                    string,
	paged:                  bool,
	at:                     time.Tick,
	read_request:           cstring,
	read_latest:            string, // UI-thread deduplication, newest MLS order seen
	read_row:               ^marmot.Chat_List_Row,
	read_error:             string,
}
@(private)
timeline_job: ^Timeline_Work
@(private)
timeline_retired: [dynamic]^Timeline_Work
@(private)
timeline_page: ^marmot.Timeline_Page // UI-owned; local actions can re-project it

@(private)
timeline_history: [dynamic]^marmot.Timeline_Page

@(private)
timeline_scope :: proc(ui: ^Ui_State, search: string) -> bool {
	return(
		timeline_job != nil &&
		ui.selected >= 0 &&
		string(timeline_job.account) == ui.account_ref &&
		string(timeline_job.group) == ui.chats[ui.selected].group_id &&
		string(timeline_job.search) == search &&
		timeline_job.issues == ui.issues_open \
	)
}

@(private)
timeline_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	job := (^Timeline_Work)(t.data)
	defer frame_wake()
	open_start := time.tick_now()
	sub: ^marmot.Timeline_Subscription
	status := marmot.timeline_subscribe(job.client, job.account, job.group, true, TL_PAGE, &sub)
	defer {if sub != nil {marmot.timeline_sub_free(sub)}}
	page: ^marmot.Timeline_Page
	if status == .OK {
		status = marmot.timeline_snapshot(sub, &page)
	}
	local_timing_end(.timeline_open, open_start)
	history: [dynamic]^marmot.Timeline_Page
	direction := Timeline_Direction.None
	for {
		if status == .OK && page != nil && (string(job.search) != "" || job.issues) {
			marmot.timeline_page_free(page)
			page = nil
			query := marmot.Timeline_Message_Query {
				group_id_hex = job.group,
				search       = job.search,
				has_limit    = true,
				limit        = TL_PAGE,
			}
			status = marmot.timeline_messages(job.client, job.account, &query, &page)
		}
		// ponytail: issue browsing scans retained history because the C timeline
		// query has no root filter. Use a root-filtered query when MDK exposes it.
		if job.issues && status == .OK && page != nil {
			previous := page
			for previous.has_more_before && previous.messages_len > 0 {
				sync.lock(&job.mutex)
				cancelled := job.cancel
				sync.unlock(&job.mutex)
				if cancelled {break}
				first := &previous.messages[0]
				query := marmot.Timeline_Message_Query {
					group_id_hex      = job.group,
					has_before        = true,
					before            = first.timeline_at,
					before_message_id = first.message_id_hex,
					has_limit         = true,
					limit             = TL_PAGE,
				}
				older: ^marmot.Timeline_Page
				status = marmot.timeline_messages(job.client, job.account, &query, &older)
				if status != .OK {break}
				append(&history, older)
				previous = older
			}
		}

		sync.lock(&job.mutex)
		if status == .OK && page != nil {
			if job.page != nil {marmot.timeline_page_free(job.page)}
			for older in job.history {marmot.timeline_page_free(older)}
			delete(job.history)
			job.history, history = history, {}
			job.page = page
			page = nil
			job.at = time.tick_now()
		}
		job.paged ||= direction != .None
		if status != .OK && status != .TIMEOUT {
			delete(job.err)
			job.err = marmot.last_error()
			if job.err == "" {job.err = strings.clone(N_("Timeline subscription closed."))}
		}
		cancel := job.cancel
		direction = job.request
		job.request = .None
		read_request := job.read_request
		job.read_request = nil
		sync.unlock(&job.mutex)
		if status != .TIMEOUT {frame_wake()}
		if read_request != nil {
			row: ^marmot.Chat_List_Row
			read_status := marmot.mark_timeline_message_read(
				job.client,
				job.account,
				job.group,
				read_request,
				&row,
			)
			delete(read_request)
			err := read_status != .OK ? marmot.last_error() : ""
			sync.lock(&job.mutex)
			if job.read_row != nil {marmot.chat_list_row_free(job.read_row)}
			delete(job.read_error)
			job.read_row, job.read_error = row, err
			sync.unlock(&job.mutex)
			frame_wake()
		}
		if cancel || (status != .OK && status != .TIMEOUT) {break}
		page_start := time.tick_now()
		switch direction {
		case .Older:
			status = marmot.timeline_back(sub, TL_PAGE, &page)
		case .Newer:
			status = marmot.timeline_forward(sub, TL_PAGE, &page)
		case .None:
			status = marmot.timeline_next(sub, 100, &page)
		}
		if direction != .None {local_timing_end(.timeline_page, page_start)}
		free_all(context.temp_allocator)
	}
	if page != nil {marmot.timeline_page_free(page)}
	for older in history {marmot.timeline_page_free(older)}
	delete(history)
}

@(private)
timeline_retire :: proc() {
	if timeline_job == nil {return}
	sync.lock(&timeline_job.mutex)
	timeline_job.cancel = true
	sync.unlock(&timeline_job.mutex)
	append(&timeline_retired, timeline_job)
	timeline_job = nil
	if timeline_page != nil {marmot.timeline_page_free(timeline_page)}
	timeline_page = nil
	for older in timeline_history {marmot.timeline_page_free(older)}
	delete(timeline_history); timeline_history = {}
}

@(private)
timeline_start :: proc(client: ^marmot.Client, ui: ^Ui_State, search: string) {
	timeline_retire()
	delete(ui.timeline_error); ui.timeline_error = ""
	if ui.messages_account != ui.account_ref ||
	   ui.messages_group != ui.chats[ui.selected].group_id {
		append(&retired_messages, ..ui.messages[:])
		clear(&ui.messages)
		ui.replying, ui.editing = "", ""
		sel_clear(ui)
	}
	ui.timeline_loading, ui.timeline_paging = true, false
	ui.tl_has_more, ui.tl_has_after = false, false
	job := new(Timeline_Work)
	job.client = client
	job.issues = ui.issues_open
	job.account = strings.clone_to_cstring(ui.account_ref)
	job.group = strings.clone_to_cstring(ui.chats[ui.selected].group_id)
	job.search = strings.clone_to_cstring(search)
	job.worker = thread.create(timeline_worker)
	job.worker.data = job
	timeline_job = job
	thread.start(job.worker)
}

@(private)
timeline_paginate :: proc(ui: ^Ui_State, direction: Timeline_Direction) {
	if timeline_job == nil || ui.timeline_loading || ui.timeline_paging {return}
	delete(ui.jump_id)
	ui.jump_id = ""
	if len(ui.messages) > 0 {
		index := direction == .Older ? 0 : len(ui.messages) - 1
		ui.jump_id = strings.clone(ui.messages[index].id)
	}
	ui.timeline_paging = true
	sync.lock(&timeline_job.mutex)
	timeline_job.request = direction
	sync.unlock(&timeline_job.mutex)
}

@(private)
timeline_free :: proc(job: ^Timeline_Work) {
	thread.join(job.worker)
	thread.destroy(job.worker)
	if job.page != nil {marmot.timeline_page_free(job.page)}
	for older in job.history {marmot.timeline_page_free(older)}
	delete(job.history)
	delete(job.account); delete(job.group); delete(job.search); delete(job.err)
	delete(job.read_request); delete(job.read_latest); delete(job.read_error)
	if job.read_row != nil {marmot.chat_list_row_free(job.read_row)}
	free(job)
}

// Only mark messages in the applied latest window. The unread divider was
// captured before this request; neither a rail update nor its result moves it.
@(private)
timeline_mark_read :: proc(ui: ^Ui_State) {
	job := timeline_job
	if job == nil ||
	   !timeline_scope(ui, "") ||
	   ui.timeline_loading ||
	   ui.tl_has_after ||
	   len(ui.messages) == 0 {return}
	last := len(ui.messages) - 1
	for msg, i in ui.messages {
		if msg.mls_order > ui.messages[last].mls_order {last = i}
	}
	id := ui.messages[last].id
	if id == job.read_latest {return}
	delete(job.read_latest)
	job.read_latest = strings.clone(id)
	if ui.chats[ui.selected].group_id in ui.prefs.unread_ids {
		delete_key(&ui.prefs.unread_ids, ui.chats[ui.selected].group_id)
		ui.settings_dirty = true
	}
	sync.lock(&job.mutex)
	delete(job.read_request)
	job.read_request = strings.clone_to_cstring(id)
	sync.unlock(&job.mutex)
}

@(private)
timeline_drain :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	for i := len(timeline_retired) - 1; i >= 0; i -= 1 {
		if thread.is_done(timeline_retired[i].worker) {
			timeline_free(timeline_retired[i])
			unordered_remove(&timeline_retired, i)
		}
	}
	job := timeline_job
	if job == nil {return}
	if !timeline_scope(ui, string(job.search)) {
		timeline_retire()
		ui.timeline_loading, ui.timeline_paging = false, false
		return
	}
	sync.lock(&job.mutex)
	page, err, paged, at := job.page, job.err, job.paged, job.at
	history := job.history
	job.history = {}
	job.page, job.err, job.paged = nil, "", false
	read_row, read_error := job.read_row, job.read_error
	job.read_row, job.read_error = nil, ""
	sync.unlock(&job.mutex)
	if read_row != nil {
		chat := &ui.chats[ui.selected]
		// A newer rail event may already have arrived while this write ran.
		if read_row.last_message != nil &&
		   chat.last_id == string(read_row.last_message.message_id_hex) {
			chat.unread = read_row.unread_count
			delete(chat.first_unread)
			chat.first_unread = strings.clone(string(read_row.first_unread_message_id_hex))
		}
		marmot.chat_list_row_free(read_row)
	}
	if read_error != "" {
		set_status(
			ui,
			fmt.aprintf("%s %s", tr("Couldn't mark the chat read. Please try again."), read_error),
			.Error,
		)
		delete(read_error)
	}
	if err != "" {
		delete(ui.timeline_error)
		ui.timeline_error = fmt.aprintf(
			"%s %s",
			tr("Couldn't load messages. Please try again."),
			tr(err), // marmot's error text or the worker's N_ fallback
		)
		set_status(ui, strings.clone(ui.timeline_error), .Error)
		delete(err)
		ui.timeline_loading, ui.timeline_paging = false, false
	}
	if page == nil {return}
	local_timing_end(.timeline_handoff, at)
	previous := make(map[string]bool, context.temp_allocator)
	for msg in ui.messages {previous[msg.id] = true}
	initial := ui.timeline_loading
	// An explicit latest click must survive a page already in flight.
	latest := ui.scroll_pending && ui.jump_id == ""
	if timeline_page != nil {marmot.timeline_page_free(timeline_page)}
	for older in timeline_history {marmot.timeline_page_free(older)}
	delete(timeline_history)
	timeline_history = history
	timeline_page = page
	timeline_apply(client, ui, page)
	ui.timeline_loading = false
	if initial {edit_restore(ui)}
	if paged {
		ui.timeline_paging = false
		ui.scroll_pending = latest
	}
	if !initial && !paged {
		for &msg in ui.messages {
			if !previous[msg.id] && !msg.mine && !msg.system {msg.visible_since = at}
		}
	}
	if !page.has_more_after && (initial || rl.IsWindowFocused()) {
		timeline_mark_read(ui)
	}
}

@(private)
timeline_stop :: proc() {
	timeline_retire()
	for job in timeline_retired {timeline_free(job)}
	delete(timeline_retired)
	timeline_retired = {}
}
