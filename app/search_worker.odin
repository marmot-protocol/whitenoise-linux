package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"

@(private)
Search_Kind :: enum {Global, Sidebar}
@(private)
Search_Page :: struct {page: ^marmot.Timeline_Page, folded: []string}
@(private)
Search_Job :: struct {
	worker: ^thread.Thread,
	client: ^marmot.Client,
	kind: Search_Kind,
	account, input: string,
	groups: [dynamic]string,
	hidden: map[string]bool,
	revision: u64,
	cancel: bool, // atomic; stop obsolete work between store reads
	cache: map[string]Search_Page, // exclusively owned by the worker while running
	hits: [dynamic]Gs_Hit,
	matched: [dynamic]string,
	err: string,
	ready: bool,
}
@(private)
search_active: [Search_Kind]^Search_Job
@(private)
search_pending: [Search_Kind]^Search_Job
@(private)
search_revision: u64

@(private)
search_free :: proc(job: ^Search_Job) {
	if job == nil { return }
	for group in job.groups { delete(group) }
	delete(job.groups)
	for id in job.hidden { delete(id) }
	delete(job.hidden)
	for group, entry in job.cache {
		marmot.timeline_page_free(entry.page)
		for text in entry.folded { delete(text) }
		delete(entry.folded); delete(group)
	}
	delete(job.cache)
	for hit in job.hits { gs_free_hit(hit) }
	delete(job.hits)
	for group in job.matched { delete(group) }
	delete(job.matched)
	delete(job.account); delete(job.input); delete(job.err)
	free(job)
}

// One active job and one replacement per surface. Typing never starts an
// unbounded set of threads, and replacing a queued query discards it outright.
@(private)
search_request :: proc(ui: ^Ui_State, client: ^marmot.Client, kind: Search_Kind) {
	input := kind == .Global ? string(ui.gs_input[:]) : string(ui.sidebar_filter[:])
	for job in ([]^Search_Job{search_pending[kind], search_active[kind]}) {
		if job != nil && !sync.atomic_load(&job.cancel) && job.account == ui.account_ref && job.input == input && job.revision == search_revision &&
			(kind == .Sidebar || job.worker != nil || job == search_pending[kind]) {
			if job.worker == nil { job.ready = true }
			return
		}
	}
	if active := search_active[kind]; active != nil { sync.atomic_store(&active.cancel, true) }
	search_free(search_pending[kind])
	search_pending[kind] = nil
	if client == nil || strings.trim_space(input) == "" { return }
	job := new(Search_Job)
	job.client, job.kind, job.revision = client, kind, search_revision
	job.account, job.input = strings.clone(ui.account_ref), strings.clone(input)
	for chat in ui.chats {
		if kind == .Global && chat.pending { continue }
		append(&job.groups, strings.clone(chat.group_id))
	}
	for id, hidden in ui.hidden {
		if hidden { job.hidden[strings.clone(id)] = true }
	}
	search_pending[kind] = job
}

@(private)
search_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	job := (^Search_Job)(t.data)
	timing_start := time.tick_now()
	defer local_timing_end(job.kind == .Global ? .search_global : .search_sidebar, timing_start)
	defer frame_wake()
	defer free_all(context.temp_allocator)
	account := strings.clone_to_cstring(job.account, context.temp_allocator)
	needle := gs_fold(strings.trim_space(job.input), context.temp_allocator)
	for group in job.groups {
		if sync.atomic_load(&job.cancel) { return }
		query := marmot.Timeline_Message_Query{group_id_hex = strings.clone_to_cstring(group, context.temp_allocator),
			has_limit = true, limit = job.kind == .Global ? GS_FETCH_LIMIT : 1}
		if job.kind == .Sidebar {
			query.search = strings.clone_to_cstring(job.input, context.temp_allocator)
			page: ^marmot.Timeline_Page
			if marmot.timeline_messages(job.client, account, &query, &page) != .OK {
				job.err = marmot.last_error()
				return
			}
			if page.messages_len > 0 { append(&job.matched, strings.clone(group)) }
			marmot.timeline_page_free(page)
			continue
		}
		entry, cached := job.cache[group]
		if !cached {
			if marmot.timeline_messages(job.client, account, &query, &entry.page) != .OK {
				job.err = marmot.last_error()
				return
			}
			entry.folded = make([]string, int(entry.page.messages_len))
			for i in 0 ..< entry.page.messages_len {
				entry.folded[i] = gs_fold(string(entry.page.messages[i].plaintext), context.allocator)
			}
			job.cache[strings.clone(group)] = entry
		}
		for i := int(entry.page.messages_len) - 1; i >= 0; i -= 1 {
			if sync.atomic_load(&job.cancel) { return }
			record := &entry.page.messages[i]
			id := string(record.message_id_hex)
			if record.deleted || record.kind == 1009 || record.kind == 5 || id == "" || job.hidden[id] { continue }
			hay := entry.folded[i]
			pos := strings.index(hay, needle)
			if pos < 0 && !gs_subseq(hay, needle) { continue }
			append(&job.hits, Gs_Hit{group = strings.clone(group), msg_id = strings.clone(id),
				sender = strings.clone(string(record.direction) == "sent" ? "you" : string(record.sender)),
				snippet = gs_snippet(string(record.plaintext), pos > 0 ? utf8.rune_count(hay[:pos]) : 0),
				when_at = record.timeline_at, exact = pos >= 0})
		}
	}
	slice.sort_by(job.hits[:], proc(a, b: Gs_Hit) -> bool {
		return a.exact == b.exact ? a.when_at > b.when_at : a.exact
	})
	for len(job.hits) > GS_HITS_MAX { gs_free_hit(pop(&job.hits)) }
}

@(private)
search_current :: proc(job: ^Search_Job, ui: ^Ui_State) -> bool {
	input := job.kind == .Global ? string(ui.gs_input[:]) : string(ui.sidebar_filter[:])
	return !sync.atomic_load(&job.cancel) && job.account == ui.account_ref && job.input == input &&
		job.revision == search_revision && (job.kind != .Global || ui.gs_open)
}

@(private)
search_drain :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	for kind in Search_Kind {
		job := search_active[kind]
		if job != nil && kind == .Global && !ui.gs_open { sync.atomic_store(&job.cancel, true) }
		if job != nil && (job.account != ui.account_ref || job.revision != search_revision) &&
			(kind != .Global || ui.gs_open) && search_pending[kind] == nil {
			search_request(ui, client, kind)
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
					ui.client_status = fmt.aprintf("%s %s", tr("Couldn't search messages. Please try again."), job.err)
				} else {
					indices := make(map[string]int, context.temp_allocator)
					for chat, i in ui.chats { indices[chat.group_id] = i }
					if kind == .Global {
						gs_clear_hits(ui)
						for &hit in job.hits {
							if i, ok := indices[hit.group]; ok {
								hit.chat = i
								hit.title = strings.clone(ui.chats[i].title)
								label := hit.sender == "you" ? "you" : profile_label(client, hit.sender)
								name := strings.clone(label)
								delete(hit.sender); hit.sender = name
								hit.at = format_full(hit.when_at)
								append(&ui.gs_hits, hit)
								hit = {}
							}
						}
						stagger_arm(clay.ID("GsList").id)
					} else {
						resize(&ui.filter_hits, len(ui.chats))
						for &hit in ui.filter_hits { hit = false }
						for group in job.matched {
							if i, ok := indices[group]; ok { ui.filter_hits[i] = true }
						}
					}
				}
			}
		}
		if job != nil && job.worker != nil { continue }
		next := search_pending[kind]
		if next == nil {
			if job != nil && (job.account != ui.account_ref || job.revision != search_revision || (kind == .Global && !ui.gs_open)) {
				search_free(job); search_active[kind] = nil
			}
			continue
		}
		search_pending[kind] = nil
		if next.account != ui.account_ref || (kind == .Global && !ui.gs_open) {
			search_free(next)
			continue
		}
		if job != nil && job.account == next.account && job.revision == next.revision {
			next.cache = job.cache
			job.cache = nil
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
