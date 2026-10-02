package main

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

@(private)
Search_Kind :: enum {
	Global,
	Sidebar,
	Mentions,
}
@(private)
Search_Job :: struct {
	worker:         ^thread.Thread,
	client:         ^marmot.Client,
	kind:           Search_Kind,
	account, input: string,
	group, sender:  string,
	since, until:   u64,
	attachment:     u32,
	cursor_at:      u64,
	cursor_id:      string,
	cursor_group:   string,
	append_page:    bool,
	more:           bool,
	next_at:        u64,
	next_id:        string,
	next_group:     string,
	groups:         [dynamic]string,
	hidden:         map[string]bool,
	revision:       u64,
	cancel:         bool, // atomic; stop obsolete work between store reads
	hits:           [dynamic]Gs_Hit,
	chats:          ^marmot.Presented_Chat_List,
	read_chats:     bool,
	matched:        [dynamic]string,
	err:            string,
	ready:          bool,
}
@(private)
search_active: [Search_Kind]^Search_Job
@(private)
search_pending: [Search_Kind]^Search_Job
@(private)
search_revision: u64

@(private)
search_free :: proc(job: ^Search_Job) {
	if job == nil {return}
	for group in job.groups {delete(group)}
	delete(job.groups)
	for id in job.hidden {delete(id)}
	delete(job.hidden)
	for hit in job.hits {gs_free_hit(hit)}
	delete(job.hits)
	if job.chats != nil {marmot.presented_chat_list_free(job.chats)}
	for group in job.matched {delete(group)}
	delete(job.matched)
	delete(job.account); delete(job.input); delete(job.err)
	delete(job.group); delete(job.sender); delete(job.cursor_id); delete(job.next_id)
	delete(job.cursor_group); delete(job.next_group)
	free(job)
}

// One active job and one replacement per surface. Typing never starts an
// unbounded set of threads, and replacing a queued query discards it outright.
@(private)
search_request :: proc(ui: ^Ui_State, client: ^marmot.Client, kind: Search_Kind) {
	if kind == .Global {gs_check_account(ui)}
	input :=
		kind == .Mentions ? "" : kind == .Global ? string(ui.gs_input[:]) : string(ui.sidebar_filter[:])
	since, until: u64
	if kind == .Global {
		valid: bool
		since, until, valid = gs_dates(ui)
		if !valid {
			if active := search_active[kind];
			   active != nil {sync.atomic_store(&active.cancel, true)}
			search_free(search_pending[kind]); search_pending[kind] = nil
			ui.gs_loading = false
			return
		}
	}
	for job in ([]^Search_Job{search_pending[kind], search_active[kind]}) {
		if job != nil &&
		   !sync.atomic_load(&job.cancel) &&
		   job.account == ui.account_ref &&
		   job.input == input &&
		   (kind != .Global || search_filters_match(job, ui, since, until)) &&
		   job.revision == search_revision &&
		   (kind == .Sidebar || job.worker != nil || job == search_pending[kind]) {
			if job.worker == nil {job.ready = true}
			return
		}
	}
	if active := search_active[kind]; active != nil {sync.atomic_store(&active.cancel, true)}
	search_free(search_pending[kind])
	search_pending[kind] = nil
	if client == nil || (kind == .Sidebar && strings.trim_space(input) == "") {
		if kind == .Global {ui.gs_loading = false}
		return
	}
	job := new(Search_Job)
	job.client, job.kind, job.revision = client, kind, search_revision
	job.account, job.input = strings.clone(ui.account_ref), strings.clone(input)
	if kind == .Global {
		job.group, job.sender = strings.clone(ui.gs_group), strings.clone(ui.gs_sender)
		job.since, job.until, job.attachment = since, until, ui.gs_attachment
		job.append_page = ui.gs_append
		job.cursor_at, job.cursor_id = ui.gs_cursor_at, strings.clone(ui.gs_cursor_id)
		job.cursor_group = strings.clone(ui.gs_cursor_group)
		active := search_active[kind]
		job.read_chats =
			len(ui.gs_chats) == 0 ||
			active == nil ||
			active.account != ui.account_ref ||
			active.revision != search_revision
		ui.gs_loading = true
	}
	for chat in ui.chats {
		if kind == .Global {break}
		if kind != .Sidebar && chat.pending {continue}
		append(&job.groups, strings.clone(chat.group_id))
	}
	for id, hidden in ui.hidden {
		if hidden {job.hidden[strings.clone(id)] = true}
	}
	search_pending[kind] = job
}

@(private)
search_filters_match :: proc(job: ^Search_Job, ui: ^Ui_State, since, until: u64) -> bool {
	return(
		job.group == ui.gs_group &&
		job.sender == ui.gs_sender &&
		job.since == since &&
		job.until == until &&
		job.attachment == ui.gs_attachment &&
		job.append_page == ui.gs_append &&
		(!job.append_page ||
				(job.cursor_at == ui.gs_cursor_at &&
						job.cursor_id == ui.gs_cursor_id &&
						job.cursor_group == ui.gs_cursor_group)) \
	)
}

@(private)
search_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	job := (^Search_Job)(t.data)
	timing_start := time.tick_now()
	defer {if job.kind !=
		   .Mentions {local_timing_end(job.kind == .Global ? .message_search : .conversation_search, timing_start)}}
	defer frame_wake()
	defer free_all(context.temp_allocator)
	account := strings.clone_to_cstring(job.account, context.temp_allocator)
	if job.kind == .Global {
		search_global_page(job, account)
		return
	}
	for group in job.groups {
		if sync.atomic_load(&job.cancel) {return}
		query := marmot.Timeline_Message_Query {
			group_id_hex = strings.clone_to_cstring(group, context.temp_allocator),
			has_limit    = true,
			limit        = job.kind == .Mentions ? MI_FETCH_LIMIT : 1,
		}
		if job.kind == .Sidebar {
			query.search = strings.clone_to_cstring(job.input, context.temp_allocator)
			page: ^marmot.Timeline_Page
			if marmot.timeline_messages(job.client, account, &query, &page) != .OK {
				job.err = marmot.last_error()
				return
			}
			if page.messages_len > 0 {append(&job.matched, strings.clone(group))}
			marmot.timeline_page_free(page)
			continue
		}
		page: ^marmot.Timeline_Page
		if marmot.timeline_messages(job.client, account, &query, &page) != .OK {
			job.err = marmot.last_error()
			return
		}
		search_mentions_page(job, group, page)
		marmot.timeline_page_free(page)
	}
	slice.sort_by(job.hits[:], proc(a, b: Gs_Hit) -> bool {
		return a.when_at == b.when_at ? a.msg_id > b.msg_id : a.when_at > b.when_at
	})
	for len(job.hits) > MI_HITS_MAX {gs_free_hit(pop(&job.hits))}
}

@(private)
search_mentions_page :: proc(job: ^Search_Job, group: string, page: ^marmot.Timeline_Page) {
	for i := int(page.messages_len) - 1; i >= 0; i -= 1 {
		if sync.atomic_load(&job.cancel) {return}
		record := &page.messages[i]
		id := string(record.message_id_hex)
		if record.deleted ||
		   record.kind == 1009 ||
		   record.kind == 5 ||
		   id == "" ||
		   job.hidden[id] {continue}
		if string(record.direction) == "sent" ||
		   !text_mentions_me(string(record.plaintext), job.account) {continue}
		append(
			&job.hits,
			Gs_Hit {
				group = strings.clone(group),
				msg_id = strings.clone(id),
				sender = strings.clone(
					string(record.direction) == "sent" ? "you" : string(record.sender),
				),
				snippet = gs_snippet(string(record.plaintext), 0),
				when_at = record.timeline_at,
			},
		)
	}
}

// A store page is bounded before crossing the FFI. Advance over hidden rows too,
// otherwise a page containing only locally hidden messages would loop forever.
@(private)
search_global_page :: proc(job: ^Search_Job, account: cstring) {
	if sync.atomic_load(&job.cancel) {return}
	if job.read_chats {
		if marmot.presented_chat_list(job.client, account, true, &job.chats) != .OK {
			job.err = marmot.last_error()
			return
		}
	}
	if job.input == "" &&
	   job.group == "" &&
	   job.sender == "" &&
	   job.since == 0 &&
	   job.until == 0 &&
	   job.attachment == 0 {return}
	query := marmot.Timeline_Message_Query {
		search            = strings.clone_to_cstring(job.input, context.temp_allocator),
		has_limit         = true,
		limit             = GS_HITS_MAX,
		has_since         = job.since != 0,
		since             = job.since,
		has_until         = job.until != 0,
		until             = job.until,
		attachment_type   = marmot.Timeline_Attachment_Type(job.attachment),
		search_wall_clock = true,
	}
	if job.group !=
	   "" {query.group_id_hex = strings.clone_to_cstring(job.group, context.temp_allocator)}
	if job.sender !=
	   "" {query.sender = strings.clone_to_cstring(job.sender, context.temp_allocator)}
	if job.append_page && job.cursor_id != "" {
		query.has_before = true
		query.before = job.cursor_at
		query.before_message_id = strings.clone_to_cstring(job.cursor_id, context.temp_allocator)
		query.cursor_group_id = strings.clone_to_cstring(job.cursor_group, context.temp_allocator)
	}
	for {
		if sync.atomic_load(&job.cancel) {return}
		query.limit = u32(GS_HITS_MAX - len(job.hits))
		page: ^marmot.Timeline_Page
		if marmot.timeline_messages(job.client, account, &query, &page) != .OK {
			job.err = marmot.last_error()
			return
		}
		job.more = page.has_more_before && page.messages_len > 0
		if page.messages_len > 0 {
			job.next_at = page.messages[0].timeline_at
			delete(job.next_id)
			job.next_id = strings.clone(string(page.messages[0].message_id_hex))
			delete(job.next_group)
			job.next_group = strings.clone(string(page.messages[0].group_id_hex))
		}
		for i := int(page.messages_len) - 1; i >= 0; i -= 1 {
			record := &page.messages[i]
			id := string(record.message_id_hex)
			if record.deleted ||
			   record.kind == 1009 ||
			   record.kind == 5 ||
			   id == "" ||
			   job.hidden[id] {continue}
			group := string(record.group_id_hex)
			body := string(record.plaintext)
			pos := strings.index(body, job.input)
			append(
				&job.hits,
				Gs_Hit {
					group = strings.clone(group),
					msg_id = strings.clone(id),
					sender = strings.clone(
						string(record.direction) == "sent" ? "you" : string(record.sender),
					),
					snippet = gs_snippet(body, pos > 0 ? utf8.rune_count(body[:pos]) : 0),
					when_at = record.timeline_at,
				},
			)
		}
		marmot.timeline_page_free(page)
		if !job.more || len(job.hits) == GS_HITS_MAX {return}
		query.has_before = true
		query.before = job.next_at
		query.before_message_id = strings.clone_to_cstring(job.next_id, context.temp_allocator)
		query.cursor_group_id = strings.clone_to_cstring(job.next_group, context.temp_allocator)
	}
}

@(private)
search_current :: proc(job: ^Search_Job, ui: ^Ui_State) -> bool {
	input :=
		job.kind == .Mentions ? "" : job.kind == .Global ? string(ui.gs_input[:]) : string(ui.sidebar_filter[:])
	if job.kind == .Global {
		since, until, valid := gs_dates(ui)
		if !valid ||
		   ui.gs_error != "" ||
		   !search_filters_match(job, ui, since, until) {return false}
	}
	return(
		!sync.atomic_load(&job.cancel) &&
		job.account == ui.account_ref &&
		job.input == input &&
		(job.kind == .Mentions || job.revision == search_revision) &&
		(job.kind != .Global || ui.gs_open) \
	)
}

@(private)
search_drain :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	for kind in Search_Kind {
		job := search_active[kind]
		if job != nil && kind == .Global && !ui.gs_open {sync.atomic_store(&job.cancel, true)}
		if job != nil &&
		   (job.account != ui.account_ref ||
				   (kind != .Mentions && job.revision != search_revision)) &&
		   (kind != .Global || ui.gs_open) &&
		   search_pending[kind] == nil {
			if kind == .Global {gs_refresh(ui, client)} else {search_request(ui, client, kind)}
		}
		if job != nil && job.worker != nil && thread.is_done(job.worker) {
			thread.join(job.worker); thread.destroy(job.worker)
			job.worker = nil
			job.ready = true
		}
		if job != nil && job.worker == nil && job.ready {
			job.ready = false
			if search_current(job, ui) {
				if job.err != "" {
					if kind == .Global {
						ui.gs_loading = false
						delete(ui.gs_error); ui.gs_error = strings.clone(job.err)
					}
					set_status(
						ui,
						fmt.aprintf(
							"%s %s",
							tr("Couldn't search messages. Please try again."),
							job.err,
						),
						.Error,
					)
				} else {
					indices := make(map[string]int, context.temp_allocator)
					for chat, i in ui.chats {indices[chat.group_id] = i}
					titles := make(map[string]string, context.temp_allocator)
					if kind != .Sidebar {
						if kind == .Global {
							if !job.append_page {gs_clear_hits(ui)}
							if job.chats != nil {
								fresh := make([dynamic]Chat_Row_Ui, 0, int(job.chats.rows_len))
								for i in 0 ..< job.chats.rows_len {append(&fresh, row_to_ui(client, &job.chats.rows[i], ui.account_ref))}
								chats_replace(&ui.gs_chats, fresh)
							}
							for chat in ui.gs_chats {titles[chat.group_id] = chat.title}
							ui.gs_loading, ui.gs_more = false, job.more
							ui.gs_cursor_at = job.next_at
							delete(ui.gs_cursor_id); ui.gs_cursor_id = strings.clone(job.next_id)
							delete(
								ui.gs_cursor_group,
							); ui.gs_cursor_group = strings.clone(job.next_group)
						} else {mi_clear(ui)}
						for &hit in job.hits {
							// Mentions by someone you blocked never reach the bell.
							if kind == .Mentions &&
							   (ui.hidden[hit.msg_id] || ui.blocked[hit.sender]) {continue}
							i, ok := indices[hit.group]
							if kind == .Global || ok {
								hit.chat = ok ? i : -1
								title := ok ? ui.chats[i].title : short_hex(hit.group)
								if stored_title, found := titles[hit.group];
								   found {title = stored_title}
								hit.title = strings.clone(title)
								label :=
									hit.sender == "you" ? "you" : profile_label(client, hit.sender)
								name := strings.clone(label)
								delete(hit.sender); hit.sender = name
								hit.at = format_full(hit.when_at)
								if kind == .Global {
									append(&ui.gs_hits, hit)
								} else {
									append(
										&ui.mi_hits,
										Mention_Hit {
											group = hit.group,
											msg_id = hit.msg_id,
											title = hit.title,
											sender = hit.sender,
											snippet = hit.snippet,
											at = hit.at,
											when_at = hit.when_at,
											unread = !mi_is_read(ui, hit.msg_id),
										},
									)
									if ui.mi_open {mi_mark_read(ui, hit.msg_id)}
								}
								hit = {}
							}
						}
						if kind ==
						   .Global {stagger_arm(clay.ID("GsList").id)} else if ui.mi_open {save_settings(ui)}
					} else {
						resize(&ui.filter_hits, len(ui.chats))
						for &hit in ui.filter_hits {hit = false}
						for group in job.matched {
							if i, ok := indices[group]; ok {ui.filter_hits[i] = true}
						}
					}
				}
			}
		}
		if job != nil && job.worker != nil {continue}
		next := search_pending[kind]
		if next == nil {
			if job != nil &&
			   (kind == .Mentions ||
					   job.account != ui.account_ref ||
					   job.revision != search_revision ||
					   (kind == .Global && !ui.gs_open)) {
				search_free(job); search_active[kind] = nil
			}
			continue
		}
		search_pending[kind] = nil
		if next.account != ui.account_ref || (kind == .Global && !ui.gs_open) {
			search_free(next)
			continue
		}
		search_free(job)
		next.worker = thread.create(search_worker)
		next.worker.data = next
		search_active[kind] = next
		thread.start(next.worker)
	}
}

@(private)
search_stop :: proc() {
	for kind in Search_Kind {
		job := search_active[kind]
		if job != nil && job.worker != nil {
			sync.atomic_store(&job.cancel, true)
			thread.join(job.worker); thread.destroy(job.worker)
		}
		search_free(job); search_free(search_pending[kind])
		search_active[kind], search_pending[kind] = nil, nil
	}
}
