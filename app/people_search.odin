package main

import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"

import marmot "../marmot"
import rl "sdlrl"

// People search in the new-chat fields, as on Android and iOS: a typed name
// or Nostr address searches the identity directory up to two follow hops
// out, and the hits list after the matching contacts.
//
//   typing --300 ms pause--> worker: marmot_search_users(1..2)
//                                     | one update per traversal step
//                                     v
//   frame: people_search_drain <-- job.hits (under job.lock)
//            merges by account id into ui.people.hits, best first

@(private = "file")
PEOPLE_DEBOUNCE :: 0.3 // seconds of no typing before a search starts
@(private = "file")
PEOPLE_RADIUS_END :: 2 // MDK's widest radius: people your follows follow
@(private = "file")
PEOPLE_POLL_MS :: 100 // bounds how long a replaced search keeps running

@(private)
People_Hit :: struct {
	id_hex, npub, name, nip05, pic_url: string,
	radius:                             u8,
	followed:                           bool,
	field:                              marmot.Matched_Field,
	quality:                            marmot.Match_Quality,
	rank:                               f64, // provider rank; -1 when unranked
}

@(private)
People_Status :: enum {
	Idle,
	Searching, // waiting out the debounce or the traversal
	Done,
	Incomplete, // a radius timed out or was truncated
	Failed,
}

// What the UI shows for one account and query.
@(private)
People_Search :: struct {
	account, query: string,
	typed_at:       f64, // rl.GetTime() when the query last changed
	status:         People_Status,
	hits:           [dynamic]People_Hit,
}

@(private = "file")
People_Job :: struct {
	worker:             ^thread.Thread,
	client:             ^marmot.Client,
	account, query:     string,
	cancel:             bool, // atomic
	lock:               sync.Mutex,
	hits:               [dynamic]People_Hit, // under lock until drained
	incomplete, failed: bool, // under lock
}

@(private = "file")
people_job: ^People_Job

// The text to search for: a name or Nostr address in the focused new-chat
// field. Keys and links resolve locally, so they never reach the directory.
@(private)
people_query :: proc(ui: ^Ui_State) -> string {
	if !ui.new_chat_open {return ""}
	text: string
	if ui.nc_page == .Contacts {
		text = string(ui.nc_search[:])
	} else if ui.focus == .NC_Member && ui.nc_member_choice == 0 {
		text = string(ui.nc_member[:])
	}
	query := strings.trim_space(text)
	if query == "" || strings.contains(query, ",") || nc_address_hex(ui, query) != "" {return ""}
	lower := strings.to_lower(query, context.temp_allocator)
	for prefix in ([]string{"npub1", "nprofile1", "nostr:", "marmot:"}) {
		if strings.has_prefix(lower, prefix) {return ""}
	}
	return query
}

// Hits not already listed among the matching contacts, as ui.people.hits
// indices in rank order.
@(private)
people_rows :: proc(ui: ^Ui_State, contacts: []Contact_Order) -> []int {
	listed := make(map[string]bool, len(contacts), context.temp_allocator)
	for row in contacts {listed[ui.nc_contacts[row.idx].id_hex] = true}
	rows := make([dynamic]int, 0, len(ui.people.hits), context.temp_allocator)
	for hit, i in ui.people.hits {
		if !listed[hit.id_hex] {append(&rows, i)}
	}
	return rows[:]
}

// Your nickname, then the published name, then the generated alias.
@(private)
people_label :: proc(ui: ^Ui_State, hit: People_Hit) -> string {
	if nick := ui.nicknames[hit.id_hex]; nick != "" {return nick}
	if hit.name != "" {return hit.name}
	return sender_label(hit.id_hex)
}

@(private)
people_sublabel :: proc(hit: People_Hit) -> string {
	if hit.followed {return tr("You follow")}
	if hit.nip05 != "" {return strings.trim_prefix(hit.nip05, "_@")}
	return npub_tail(hit.npub)
}

@(private)
people_retry :: proc(ui: ^Ui_State) {
	if ui.people.status != .Failed && ui.people.status != .Incomplete {return}
	people_hits_free(&ui.people.hits)
	ui.people.status = .Searching
	ui.people.typed_at = 0
}

// Follow the focused field's query: cancel a search the user typed past,
// merge the running one's hits, and start the next after the debounce.
@(private)
people_search_drain :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	search := &ui.people
	query := people_query(ui)
	if query != search.query || ui.account_ref != search.account {
		delete(search.query); search.query = strings.clone(query)
		delete(search.account); search.account = strings.clone(ui.account_ref)
		people_hits_free(&search.hits)
		search.typed_at = rl.GetTime()
		search.status = query == "" ? .Idle : .Searching
		if people_job != nil {sync.atomic_store(&people_job.cancel, true)}
	}
	if job := people_job; job != nil {
		current := !sync.atomic_load(&job.cancel)
		done := thread.is_done(job.worker)
		if current {people_merge(search, job, done)}
		if !done {return}
		thread.join(job.worker); thread.destroy(job.worker)
		people_job_free(job)
		people_job = nil
	}
	if search.status != .Searching ||
	   client == nil ||
	   rl.GetTime() - search.typed_at < PEOPLE_DEBOUNCE {return}
	job := new(People_Job)
	job.client = client
	job.account, job.query = strings.clone(search.account), strings.clone(search.query)
	job.worker = thread.create(people_worker)
	job.worker.data = job
	people_job = job
	thread.start(job.worker)
}

// Move the worker's hits into the UI list, replacing earlier copies of the
// same person, and settle the status once the worker has finished.
@(private = "file")
people_merge :: proc(search: ^People_Search, job: ^People_Job, done: bool) {
	sync.guard(&job.lock)
	if done {
		search.status = job.failed ? .Failed : job.incomplete ? .Incomplete : .Done
	}
	if len(job.hits) == 0 {return}
	at := make(map[string]int, len(search.hits), context.temp_allocator)
	for hit, i in search.hits {at[hit.id_hex] = i}
	for hit in job.hits {
		if hit.id_hex == search.account {people_hit_free(hit); continue}
		if i, ok := at[hit.id_hex]; ok {
			people_hit_free(search.hits[i])
			search.hits[i] = hit
			continue
		}
		at[hit.id_hex] = len(search.hits)
		append(&search.hits, hit)
	}
	clear(&job.hits)
	slice.sort_by(search.hits[:], people_less)
}

// MDK's own order: people you follow, then nearer hops, then the
// provider's rank, then the closer match on the more specific field.
@(private = "file")
people_less :: proc(a, b: People_Hit) -> bool {
	if a.followed != b.followed {return a.followed}
	if a.radius != b.radius {return a.radius < b.radius}
	if a.rank != b.rank {return a.rank > b.rank}
	if a.quality != b.quality {return a.quality < b.quality}
	if a.field != b.field {return a.field < b.field}
	return a.id_hex < b.id_hex
}

@(private = "file")
people_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	job := (^People_Job)(t.data)
	sub: ^marmot.User_Search_Subscription
	if marmot.search_users(
		   job.client,
		   strings.clone_to_cstring(job.account, context.temp_allocator),
		   strings.clone_to_cstring(job.query, context.temp_allocator),
		   1,
		   PEOPLE_RADIUS_END,
		   &sub,
	   ) !=
	   .OK {
		sync.guard(&job.lock)
		job.failed = true
		return
	}
	defer marmot.user_search_free(sub)
	for !sync.atomic_load(&job.cancel) {
		update: ^marmot.User_Search_Update
		status := marmot.user_search_next(sub, PEOPLE_POLL_MS, &update)
		if status == .TIMEOUT {continue}
		if status != .OK {
			sync.guard(&job.lock)
			job.failed ||= status != .CLOSED
			return
		}
		finished := people_take(job, update)
		marmot.user_search_update_free(update)
		frame_wake()
		if finished {return}
	}
}

// Copy one update's hits out of MDK memory; true once the search is over.
@(private = "file")
people_take :: proc(job: ^People_Job, update: ^marmot.User_Search_Update) -> bool {
	sync.guard(&job.lock)
	for result in update.new_results[:update.new_results_len] {append(&job.hits, people_hit(result))}
	for result in update.updated_results[:update.updated_results_len] {
		append(&job.hits, people_hit(result))
	}
	#partial switch update.trigger.tag {
	case .RADIUS_TIMEOUT, .RADIUS_TRUNCATED:
		job.incomplete = true
	case .ERROR:
		job.failed = true
	case .SEARCH_COMPLETED:
		return true
	}
	return false
}

@(private = "file")
people_hit :: proc(result: marmot.User_Directory_Search_Result) -> People_Hit {
	hit := People_Hit {
		id_hex   = strings.clone(string(result.account_id_hex)),
		npub     = strings.clone(string(result.npub)),
		radius   = result.radius,
		followed = result.is_followed_by_searcher,
		field    = result.matched_field,
		quality  = result.match_quality,
		rank     = result.has_provider_rank ? result.provider_rank : -1,
	}
	if meta := result.profile; meta != nil {
		name := string(meta.display_name)
		if name == "" {name = string(meta.name)}
		hit.name = strings.clone(name)
		hit.nip05 = strings.clone(string(meta.nip05))
		hit.pic_url = strings.clone(string(meta.picture))
	}
	return hit
}

@(private = "file")
people_hit_free :: proc(hit: People_Hit) {
	delete(hit.id_hex); delete(hit.npub); delete(hit.name)
	delete(hit.nip05); delete(hit.pic_url)
}

@(private = "file")
people_hits_free :: proc(hits: ^[dynamic]People_Hit) {
	for hit in hits {people_hit_free(hit)}
	clear(hits)
}

@(private = "file")
people_job_free :: proc(job: ^People_Job) {
	people_hits_free(&job.hits)
	delete(job.hits)
	delete(job.account); delete(job.query)
	free(job)
}

@(private)
people_search_stop :: proc(ui: ^Ui_State) {
	if job := people_job; job != nil {
		sync.atomic_store(&job.cancel, true)
		thread.join(job.worker); thread.destroy(job.worker)
		people_job_free(job)
		people_job = nil
	}
	people_hits_free(&ui.people.hits)
	delete(ui.people.hits)
	delete(ui.people.account); delete(ui.people.query)
	ui.people = {}
}
