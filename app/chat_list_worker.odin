package main

import marmot "../marmot"
import "core:fmt"
import "core:strings"
import "core:thread"
import "core:time"

@(private)
Chat_List_Work :: struct {
	worker:           ^thread.Thread,
	client:           ^marmot.Client,
	account:          cstring,
	rows:             ^marmot.Presented_Chat_List,
	previews:         map[string]^marmot.Timeline_Page, // only fallback system pages; keys borrow rows
	reading_previews: map[string]Chat_Preview, // keys borrow rows; preview text is owned
	blocked:          map[string]bool, // owned copy of ui.blocked; the worker must not read Ui_State
	members:          map[string][]string, // group id to member pubkey hex, read only when read_members
	read_members:     bool, // some folder rule looks at membership
	folder_facts:     map[string]Folder_Async_Facts,
	read_facts:       Folder_Async_Facts,
	failed_facts:     Folder_Async_Facts,
	include_archived: bool,
	err:              string,
	revision:         u64,
}

@(private)
chat_list_revision: u64

// The job's own copies of UI state, taken on the UI thread.
@(private)
chat_list_snapshot :: proc(job: ^Chat_List_Work, ui: ^Ui_State) {
	for hex in ui.blocked {job.blocked[strings.clone(hex)] = true}
	job.read_members = folder_rules_need_members(ui.prefs)
	job.read_facts = folder_async_facts(ui.prefs)
}

@(private)
chat_list_read :: proc(job: ^Chat_List_Work) {
	started := time.tick_now()
	defer local_timing_end(.chat_list_load, started)
	if marmot.presented_chat_list(job.client, job.account, job.include_archived, &job.rows) !=
	   .OK {
		job.err = marmot.last_error()
		return
	}
	if job.read_members {
		chat_members_fetch(job.client, job.account, job.rows, &job.members)
	}
	chat_identity_members_fetch(job.client, job.account, job.rows, &job.members)
	for fact in Folder_Async_Fact {
		if fact not_in job.read_facts {continue}
		list: ^marmot.String_List
		status: marmot.Status
		switch fact {
		case .Mention:
			status = marmot.folder_unread_mentions(job.client, job.account, &list)
		case .Pending:
			status = marmot.folder_pending_sends(job.client, job.account, &list)
		}
		if status != .OK {
			job.failed_facts += {fact}
			err := marmot.last_error()
			fmt.eprintfln("folder facts: %v: %s", fact, err)
			delete(err)
			continue
		}
		for id in list.items[:list.len] {
			key := string(id)
			if facts, ok := &job.folder_facts[key]; ok {
				facts^ += {fact}
			} else {
				job.folder_facts[strings.clone(key)] = {fact}
			}
		}
		marmot.string_list_free(list)
	}
	for i in 0 ..< job.rows.rows_len {
		chat_prepare_preview(job, job.client, string(job.account), &job.rows.rows[i].row)
	}
}

@(private)
chat_prepare_preview :: proc(
	job: ^Chat_List_Work,
	client: ^marmot.Client,
	account: string,
	row: ^marmot.Chat_List_Row,
) {
	last := row.last_message
	// System summaries resolve profile labels through UI-owned caches.
	if last == nil ||
	   (last.group_system != nil &&
			   record_class(last.kind, string(last.plaintext)) == .System) {return}
	// An empty prepared preview also keeps the UI from repeating a read.
	preview, system_page := chat_row_preview(client, row, account, job.blocked, mode = .Worker)
	if system_page != nil {
		job.previews[string(row.group_id_hex)] = system_page
	} else {
		preview.text = strings.clone(preview.text)
		job.reading_previews[string(row.group_id_hex)] = preview
	}
}

@(private)
chat_list_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer frame_wake()
	defer free_all(context.temp_allocator)
	chat_list_read((^Chat_List_Work)(t.data))
}

// group_members reads the local roster. Resolve legacy UNKNOWN conversations
// here (and in archive/search loaders), never by doing I/O from UI helpers.
@(private)
chat_identity_members_fetch :: proc(
	client: ^marmot.Client,
	account: cstring,
	rows: ^marmot.Presented_Chat_List,
	members: ^map[string][]string,
) {
	if rows == nil {return}
	for i in 0 ..< rows.rows_len {
		chat_identity_member_fetch(client, account, &rows.rows[i], members)
	}
}

@(private)
chat_identity_member_fetch :: proc(
	client: ^marmot.Client,
	account: cstring,
	presented: ^marmot.Presented_Chat_Row,
	members: ^map[string][]string,
) {
	row := &presented.row
	group := string(row.group_id_hex)
	if group in members^ {return} 	// reuse folder-rule roster reads
	if !(row.conversation_kind == .UNKNOWN && chat_name_is_unnamed(string(row.group_name))) &&
	   !(row.conversation_kind == .DIRECT &&
			   !row.pending_confirmation &&
			   string(presented.presentation.peer_id) == "") {return}
	list: ^marmot.Group_Member_Record_List
	if marmot.group_members(client, account, row.group_id_hex, &list) != .OK ||
	   list == nil {return}
	ids := make([]string, list.len)
	for member, j in list.items[:list.len] {ids[j] = strings.clone(string(member.member_id_hex))}
	marmot.app_group_member_record_list_free(list)
	members^[strings.clone(group)] = ids
}

@(private)
chat_list_free :: proc(job: ^Chat_List_Work) {
	if job.worker != nil {thread.join(job.worker); thread.destroy(job.worker)}
	for _, page in job.previews {if page != nil {marmot.timeline_page_free(page)}}
	delete(job.previews)
	for _, preview in job.reading_previews {delete(preview.text)}
	delete(job.reading_previews)
	for hex in job.blocked {delete(hex)}
	delete(job.blocked)
	chat_members_free(&job.members)
	for id in job.folder_facts {delete(id)}
	delete(job.folder_facts)
	if job.rows != nil {marmot.presented_chat_list_free(job.rows)}
	delete(job.account); delete(job.err)
}
