package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import marmot "../marmot"
import rl "sdlrl"

@(private)
Timeline_Direction :: enum {None, Older, Newer}
@(private)
Timeline_Work :: struct {
	mutex: sync.Mutex,
	worker: ^thread.Thread,
	client: ^marmot.Client,
	account, group, search: cstring, // immutable, owned until the worker joins
	cancel: bool,
	request: Timeline_Direction,
	page: ^marmot.Timeline_Page, // mailbox owns the latest complete snapshot
	err: string,
	paged: bool,
	at: time.Tick,
}
@(private)
timeline_job: ^Timeline_Work
@(private)
timeline_retired: [dynamic]^Timeline_Work
@(private)
timeline_page: ^marmot.Timeline_Page // UI-owned; local actions can re-project it

@(private)
timeline_scope :: proc(ui: ^Ui_State, search: string) -> bool {
	return timeline_job != nil && ui.selected >= 0 &&
		string(timeline_job.account) == ui.account_ref &&
		string(timeline_job.group) == ui.chats[ui.selected].group_id &&
		string(timeline_job.search) == search
}

@(private)
timeline_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	job := (^Timeline_Work)(t.data)
	defer frame_wake()
	sub: ^marmot.Timeline_Subscription
	status := marmot.timeline_subscribe(job.client, job.account, job.group, true, TL_PAGE, &sub)
	defer { if sub != nil { marmot.timeline_sub_free(sub) } }
	page: ^marmot.Timeline_Page
	if status == .OK {
		status = marmot.timeline_snapshot(sub, &page)
	}
	direction := Timeline_Direction.None
	for {
		if status == .OK && page != nil && string(job.search) != "" {
			marmot.timeline_page_free(page)
			page = nil
			query := marmot.Timeline_Message_Query{group_id_hex = job.group, search = job.search, has_limit = true, limit = TL_PAGE}
			status = marmot.timeline_messages(job.client, job.account, &query, &page)
		}
		sync.lock(&job.mutex)
		if status == .OK && page != nil {
			if job.page != nil { marmot.timeline_page_free(job.page) }
			job.page = page
			page = nil
			job.at = time.tick_now()
		}
		job.paged ||= direction != .None
		if status != .OK && status != .TIMEOUT {
			delete(job.err)
			job.err = marmot.last_error()
			if job.err == "" { job.err = strings.clone("Timeline subscription closed.") }
		}
		cancel := job.cancel
		direction = job.request
		job.request = .None
		sync.unlock(&job.mutex)
		if status != .TIMEOUT { frame_wake() }
		if cancel || (status != .OK && status != .TIMEOUT) { break }
		switch direction {
		case .Older: status = marmot.timeline_back(sub, TL_PAGE, &page)
		case .Newer: status = marmot.timeline_forward(sub, TL_PAGE, &page)
		case .None: status = marmot.timeline_next(sub, 100, &page)
		}
		free_all(context.temp_allocator)
	}
	if page != nil { marmot.timeline_page_free(page) }
}

@(private)
timeline_retire :: proc() {
	if timeline_job == nil { return }
	sync.lock(&timeline_job.mutex)
	timeline_job.cancel = true
	sync.unlock(&timeline_job.mutex)
	append(&timeline_retired, timeline_job)
	timeline_job = nil
	if timeline_page != nil { marmot.timeline_page_free(timeline_page) }
	timeline_page = nil
}

@(private)
timeline_start :: proc(client: ^marmot.Client, ui: ^Ui_State, search: string) {
	timeline_retire()
	if ui.messages_account != ui.account_ref || ui.messages_group != ui.chats[ui.selected].group_id {
		append(&retired_messages, ..ui.messages[:])
		clear(&ui.messages)
		ui.replying, ui.editing = "", ""
		sel_clear(ui)
	}
	ui.timeline_loading, ui.timeline_paging = true, false
	ui.tl_has_more, ui.tl_has_after = false, false
	job := new(Timeline_Work)
	job.client = client
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
	if timeline_job == nil || ui.timeline_loading || ui.timeline_paging { return }
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
	if job.page != nil { marmot.timeline_page_free(job.page) }
	delete(job.account); delete(job.group); delete(job.search); delete(job.err)
	free(job)
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
	if job == nil { return }
	if !timeline_scope(ui, string(job.search)) {
		timeline_retire()
		ui.timeline_loading, ui.timeline_paging = false, false
		return
	}
	sync.lock(&job.mutex)
	page, err, paged, at := job.page, job.err, job.paged, job.at
	job.page, job.err, job.paged = nil, "", false
	sync.unlock(&job.mutex)
	if err != "" {
		ui.client_status = fmt.aprintf("%s %s", tr("Couldn't load messages. Please try again."), err)
		delete(err)
		ui.timeline_loading, ui.timeline_paging = false, false
	}
	if page == nil { return }
	previous := make(map[string]bool, context.temp_allocator)
	for msg in ui.messages { previous[msg.id] = true }
	initial := ui.timeline_loading
	if timeline_page != nil { marmot.timeline_page_free(timeline_page) }
	timeline_page = page
	timeline_apply(client, ui, page)
	ui.timeline_loading = false
	if initial { edit_restore(ui) }
	if paged {
		ui.timeline_paging = false
		ui.scroll_pending = false
	}
	if !initial && !paged {
		for &msg in ui.messages {
			if !previous[msg.id] && !msg.mine && !msg.system { msg.visible_since = at }
		}
	}
	if !page.has_more_after && rl.IsWindowFocused() && ui.chats[ui.selected].unread > 0 {
		mark_chat_read(ui, client, ui.selected)
	}
}

@(private)
timeline_stop :: proc() {
	timeline_retire()
	for job in timeline_retired { timeline_free(job) }
	delete(timeline_retired)
	timeline_retired = {}
}
