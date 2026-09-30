package main

import marmot "../marmot"
import "core:strings"
import "core:thread"
import "core:time"

@(private)
Chat_List_Work :: struct {
	worker:       ^thread.Thread,
	client:       ^marmot.Client,
	account:      cstring,
	rows:         ^marmot.Presented_Chat_List,
	previews:     map[string]^marmot.Timeline_Page, // keys borrow rows; nil means a failed preview read
	blocked:      map[string]bool, // owned copy of ui.blocked; the worker must not read Ui_State
	members:      map[string][]string, // group id to member pubkey hex, read only when read_members
	read_members: bool, // some folder rule looks at membership
	err:          string,
	revision:     u64,
}

@(private)
chat_list_revision: u64

// The job's own copies of UI state, taken on the UI thread.
@(private)
chat_list_snapshot :: proc(job: ^Chat_List_Work, ui: ^Ui_State) {
	for hex in ui.blocked {job.blocked[strings.clone(hex)] = true}
	job.read_members = folder_rules_need_members(ui.prefs)
}

@(private)
chat_list_read :: proc(job: ^Chat_List_Work) {
	started := time.tick_now()
	defer local_timing_end(.chat_list_load, started)
	if marmot.presented_chat_list(job.client, job.account, false, &job.rows) != .OK {
		job.err = marmot.last_error()
		return
	}
	if job.read_members {
		chat_members_fetch(job.client, job.account, job.rows, &job.members)
	}
	for i in 0 ..< job.rows.rows_len {
		row := &job.rows.rows[i].row
		last := row.last_message
		if last != nil && last.kind == 1210 && last.group_system != nil {continue}
		// A blocked sender's message never previews: row_to_ui phrases
		// the newest one from someone else out of this page instead.
		blocked := last != nil && last.sender != nil && job.blocked[string(last.sender)]
		if last == nil ||
		   (!blocked &&
				   last.kind != 1210 &&
				   !strings.has_prefix(
						   strings.trim_space(string(last.plaintext)),
						   XDC_SENTINEL,
					   )) {continue}
		query := marmot.Timeline_Message_Query {
			group_id_hex = row.group_id_hex,
			has_limit    = true,
			limit        = 16,
		}
		page: ^marmot.Timeline_Page
		// The selected preview remains usable if its richer timeline is unavailable.
		if marmot.timeline_messages(job.client, job.account, &query, &page) != .OK {page = nil}
		job.previews[string(row.group_id_hex)] = page
	}
}

@(private)
chat_list_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer frame_wake()
	defer free_all(context.temp_allocator)
	chat_list_read((^Chat_List_Work)(t.data))
}

@(private)
chat_list_free :: proc(job: ^Chat_List_Work) {
	if job.worker != nil {thread.join(job.worker); thread.destroy(job.worker)}
	for _, page in job.previews {if page != nil {marmot.timeline_page_free(page)}}
	delete(job.previews)
	for hex in job.blocked {delete(hex)}
	delete(job.blocked)
	chat_members_free(&job.members)
	if job.rows != nil {marmot.presented_chat_list_free(job.rows)}
	delete(job.account); delete(job.err)
}
