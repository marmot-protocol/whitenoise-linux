package main

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:unicode/utf8"

import rl "sdlrl"

@(private)
CONTACT_NOTE_MAX :: 4096
@(private)
CONTACT_PNG_MAX :: 2 * 1024 * 1024
@(private)
CONTACT_PHOTO_EDGE :: 512
@(private = "file")
CONTACT_ID_LEN :: 64
@(private = "file")
CONTACT_FORMAT :: "whitenoise/private-contact/v1\x00"
@(private = "file")
CONTACT_HEADER_LEN :: len(CONTACT_FORMAT) + 2 * CONTACT_ID_LEN + 2

@(private)
Contact_Photo_Change :: enum {
	Keep,
	Replace,
	Remove,
}

@(private)
Contact_Record :: struct {
	note:                     string,
	photo:                    ^rl.Texture2D,
	has_photo:                bool,
	unreadable:               bool,
	peer:                     [CONTACT_ID_LEN]u8,
	loaded, saving, done, ok: bool,
}

@(private = "file")
Contact_Read :: enum {
	Missing,
	Ready,
	Unreadable,
}

@(private = "file")
Contact_Job :: struct {
	next:                      ^Contact_Job,
	allocator:                 mem.Allocator,
	owner, peer:               [CONTACT_ID_LEN]u8,
	epoch:                     u64,
	save:                      bool,
	change:                    Contact_Photo_Change,
	note:                      string,
	png, pixels:               []u8,
	edge:                      i32,
	has_photo, unreadable, ok: bool,
}

@(private = "file")
Contact_Queue :: struct {
	head, tail: ^Contact_Job,
}

// Only the frame thread owns the cache and SDL textures. The disk lock
// serializes a job with purge. Code holding both locks takes the disk lock first.
@(private = "file")
contact_owner: string
@(private = "file")
contact_epoch: u64
@(private = "file")
contact_purged_epoch: u64
@(private = "file")
contact_records: map[string]^Contact_Record
@(private = "file")
contact_jobs, contact_completed: Contact_Queue
@(private = "file")
contact_failed_owners: map[[CONTACT_ID_LEN]u8]bool
@(private = "file")
contact_queue_lock, contact_disk_lock: sync.Mutex
@(private = "file")
contact_ready: sync.Cond
@(private = "file")
contact_worker: ^thread.Thread
@(private = "file")
contact_stopping: bool

@(private = "file")
contact_id_valid :: proc(id: string) -> bool {
	if len(id) != CONTACT_ID_LEN {return false}
	for c in transmute([]u8)id {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {return false}
	}
	return true
}

@(private = "file")
contact_root :: proc() -> string {
	return fmt.tprintf("%s/private-contacts", data_home)
}

when ODIN_OS != .Windows {
	@(private = "file")
	contact_sync_dir :: proc(path: string) -> bool {
		dir, err := os.open(path, {.Read})
		if err != nil {return false}
		defer os.close(dir)
		return os.sync(dir) == nil
	}
}

@(private = "file")
contact_directory :: proc(path: string, parent := "") -> Contact_Read {
	info, err := os.lstat(path, context.temp_allocator)
	if err == .Not_Exist && parent != "" {
		mkdir_err := os.make_directory(path, {.Read_User, .Write_User, .Execute_User})
		if mkdir_err == nil {
			when ODIN_OS != .Windows {
				if !contact_sync_dir(parent) {os.remove(path); return .Unreadable}
			}
			return .Ready
		}
		if mkdir_err != .Exist {return .Unreadable}
		info, err = os.lstat(path, context.temp_allocator)
	}
	if err == .Not_Exist {return .Missing}
	if err != nil || info.type != .Directory {return .Unreadable}
	return .Ready
}

// Identity is inside the authenticated ciphertext, not inferred from the path.
// Binary payload: format marker, owner, peer, big-endian note length, note, PNG.
@(private = "file")
contact_read :: proc(
	path, owner, peer: string,
) -> (
	plain: []u8,
	note: string,
	png: []u8,
	state: Contact_Read,
) {
	info, stat_err := os.lstat(path, context.temp_allocator)
	if stat_err == .Not_Exist {return nil, "", nil, .Missing}
	if stat_err != nil || info.type != .Regular {return nil, "", nil, .Unreadable}
	flags := os.File_Flags{.Read}
	when ODIN_OS != .Windows {flags += {.Non_Blocking}}
	f, open_err := os.open(path, flags)
	if open_err != nil {return nil, "", nil, .Unreadable}
	defer os.close(f)
	sealed_min :: VAULT_NONCE_LEN + VAULT_TAG_LEN + CONTACT_HEADER_LEN
	opened, size_err := os.fstat(f, context.temp_allocator)
	size := opened.size
	if size_err != nil ||
	   opened.type != .Regular ||
	   size < sealed_min ||
	   size > sealed_min + CONTACT_NOTE_MAX + CONTACT_PNG_MAX {
		return nil, "", nil, .Unreadable
	}
	sealed := make([]u8, int(size))
	defer delete(sealed)
	if _, err := os.read_full(f, sealed); err != nil {return nil, "", nil, .Unreadable}
	extra: [1]u8
	if n, err := os.read(f, extra[:]); n != 0 || err != io.Error.EOF {
		return nil, "", nil, .Unreadable
	}
	body, ok := vault_open_blob(sealed)
	if !ok {return nil, "", nil, .Unreadable}
	owner_at :: len(CONTACT_FORMAT)
	peer_at :: owner_at + CONTACT_ID_LEN
	length_at :: peer_at + CONTACT_ID_LEN
	note_len := int(body[length_at]) << 8 | int(body[length_at + 1])
	if string(body[:owner_at]) == CONTACT_FORMAT &&
	   string(body[owner_at:peer_at]) == owner &&
	   string(body[peer_at:length_at]) == peer &&
	   note_len <= CONTACT_NOTE_MAX &&
	   note_len <= len(body) - CONTACT_HEADER_LEN {
		note_end := CONTACT_HEADER_LEN + note_len
		note = string(body[CONTACT_HEADER_LEN:note_end])
		png = body[note_end:]
		if utf8.valid_string(note) && len(png) <= CONTACT_PNG_MAX {return body, note, png, .Ready}
	}
	contact_bytes_free(body)
	return nil, "", nil, .Unreadable
}

@(private = "file")
contact_write :: proc(dir, path, owner, peer, note: string, png: []u8) -> bool {
	if note == "" && len(png) == 0 {
		err := os.remove(path)
		if err != nil && err != .Not_Exist {return false}
		if err == .Not_Exist && contact_directory(dir) == .Missing {return true}
		when ODIN_OS != .Windows {return contact_sync_dir(dir)}
		return true
	}
	plain := make([]u8, CONTACT_HEADER_LEN + len(note) + len(png))
	defer contact_bytes_free(plain)
	at := copy(plain, CONTACT_FORMAT)
	at += copy(plain[at:], owner)
	at += copy(plain[at:], peer)
	plain[at], plain[at + 1] = u8(len(note) >> 8), u8(len(note))
	at += 2
	at += copy(plain[at:], note)
	copy(plain[at:], png)
	sealed, ok := vault_seal_blob(plain)
	if !ok {return false}
	defer delete(sealed)

	random: [16]u8
	crypto.rand_bytes(random[:])
	suffix := hex.encode(random[:], context.temp_allocator)
	tmp := fmt.tprintf("%s/.write-%s", dir, string(suffix))
	f, err := os.open(tmp, {.Write, .Create, .Excl}, {.Read_User, .Write_User})
	if err != nil {return false}
	n, write_err := os.write(f, sealed)
	synced := n == len(sealed) && write_err == nil && os.sync(f) == nil
	closed := os.close(f) == nil
	if !synced || !closed || os.rename(tmp, path) != nil {
		os.remove(tmp)
		return false
	}
	when ODIN_OS != .Windows {return contact_sync_dir(dir)}
	return true
}

@(private = "file")
contact_png_edge :: proc(png: []u8) -> i32 {
	if len(png) < 33 ||
	   len(png) > CONTACT_PNG_MAX ||
	   string(png[:16]) != "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" {return 0}
	w := u32(png[16]) << 24 | u32(png[17]) << 16 | u32(png[18]) << 8 | u32(png[19])
	if w == 0 || w > CONTACT_PHOTO_EDGE || string(png[16:20]) != string(png[20:24]) {return 0}
	return i32(w)
}

@(private = "file")
contact_decode :: proc(png: []u8) -> ([]u8, i32) {
	edge := contact_png_edge(png)
	if edge == 0 {return nil, 0}
	image := rl.LoadImageFromMemory(
		".png",
		raw_data(png),
		i32(len(png)),
		edge,
		u32(edge * edge * 4),
	)
	if image.data == nil {return nil, 0}
	defer rl.UnloadImage(image)
	defer mem.zero_slice(image.data[:int(image.width) * int(image.height) * 4])
	if image.width != edge || image.height != edge {return nil, 0}
	return photo_square(image)
}

@(private = "file")
contact_bytes_free :: proc(bytes: []u8, allocator := context.allocator) {
	if len(bytes) == 0 {return}
	mem.zero_slice(bytes)
	delete(bytes, allocator)
}

@(private = "file")
contact_job_free :: proc(job: ^Contact_Job) {
	contact_bytes_free(transmute([]u8)job.note, job.allocator)
	contact_bytes_free(job.png, job.allocator)
	contact_bytes_free(job.pixels, job.allocator)
	free(job, job.allocator)
}

@(private = "file")
contact_push :: proc(q: ^Contact_Queue, job: ^Contact_Job) {
	if q.tail != nil {q.tail.next = job} else {q.head = job}
	q.tail = job
}

@(private = "file")
contact_pop :: proc(q: ^Contact_Queue) -> ^Contact_Job {
	job := q.head
	if job != nil {
		q.head = job.next
		job.next = nil
		if q.head == nil {q.tail = nil}
	}
	return job
}

@(private = "file")
contact_queue_free :: proc(q: ^Contact_Queue) {
	for job := contact_pop(q); job != nil; job = contact_pop(q) {contact_job_free(job)}
}

@(private = "file")
contact_run :: proc(job: ^Contact_Job) {
	owner, peer := string(job.owner[:]), string(job.peer[:])
	root := contact_root()
	dir := fmt.tprintf("%s/%s", root, owner)
	path := fmt.tprintf("%s/%s.bin", dir, peer)
	state := contact_directory(root)
	if state == .Ready {state = contact_directory(dir)}
	if state == .Unreadable {
		job.unreadable = true
		return
	}

	plain: []u8
	note: string
	png: []u8
	defer {contact_bytes_free(plain)}
	if state == .Ready && (!job.save || job.change == .Keep) {
		plain, note, png, state = contact_read(path, owner, peer)
	}
	if job.save && job.change == .Replace {png = job.png}
	job.has_photo = len(png) > 0
	if job.has_photo {job.pixels, job.edge = contact_decode(png)}
	job.unreadable = state == .Unreadable || (job.has_photo && job.pixels == nil)
	if !job.save {
		job.note = strings.clone(note)
		return
	}

	if job.change == .Keep && job.unreadable {return}
	if job.change == .Replace && job.pixels == nil {return}
	if job.note != "" || job.has_photo {
		if contact_directory(root, data_home) != .Ready ||
		   contact_directory(dir, root) != .Ready {return}
	}
	job.ok = contact_write(dir, path, owner, peer, job.note, png)
}

@(private = "file")
contact_work :: proc(_: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	for {
		sync.lock(&contact_queue_lock)
		for contact_jobs.head == nil && !contact_stopping {
			sync.cond_wait(&contact_ready, &contact_queue_lock)
		}
		stop := contact_stopping && contact_jobs.head == nil
		sync.unlock(&contact_queue_lock)
		if stop {return}

		sync.lock(&contact_disk_lock)
		sync.lock(&contact_queue_lock)
		job := contact_pop(&contact_jobs)
		valid := job != nil && (job.save || job.epoch == contact_epoch)
		sync.unlock(&contact_queue_lock)
		if valid {
			context.allocator = job.allocator
			contact_run(job)
			contact_bytes_free(job.png)
			job.png = nil
			free_all(context.temp_allocator)
		}
		sync.lock(&contact_queue_lock)
		publish := valid && job.epoch == contact_epoch
		failed_after_switch := valid && !publish && job.save && !job.ok
		wake := (publish && contact_completed.head == nil) || failed_after_switch
		if publish {contact_push(&contact_completed, job)}
		if failed_after_switch {contact_failed_owners[job.owner] = true}
		sync.unlock(&contact_queue_lock)
		sync.unlock(&contact_disk_lock)
		if wake {frame_wake()}
		if !publish && job != nil {contact_job_free(job)}
	}
}

@(private = "file")
contact_new_job :: proc(peer: string) -> ^Contact_Job {
	job := new(Contact_Job)
	job.allocator = context.allocator
	copy(job.owner[:], contact_owner)
	copy(job.peer[:], peer)
	job.epoch = contact_epoch
	return job
}

@(private = "file")
contact_enqueue :: proc(job: ^Contact_Job) -> bool {
	sync.lock(&contact_queue_lock)
	defer sync.unlock(&contact_queue_lock)
	if sync.atomic_load(&contact_purged_epoch) == job.epoch {return false}
	if contact_worker == nil {
		contact_worker = thread.create(contact_work)
		if contact_worker == nil {return false}
		thread.start(contact_worker)
	}
	contact_push(&contact_jobs, job)
	sync.cond_signal(&contact_ready)
	return true
}

@(private = "file")
contact_get :: proc(peer: string) -> ^Contact_Record {
	if record := contact_records[peer]; record != nil {return record}
	if !contact_id_valid(peer) {return nil}
	job := contact_new_job(peer)
	if !contact_enqueue(job) {contact_job_free(job); return nil}
	record := new(Contact_Record)
	copy(record.peer[:], peer)
	contact_records[string(record.peer[:])] = record
	return record
}

@(private = "file")
contact_photo_free :: proc(photo: ^rl.Texture2D) {
	if photo == nil {return}
	forget_avatar(photo)
	rl.UnloadTexture(photo^)
	free(photo)
}

@(private = "file")
contact_record_clear :: proc(record: ^Contact_Record) {
	contact_bytes_free(transmute([]u8)record.note)
	contact_photo_free(record.photo)
}

@(private = "file")
contact_records_clear :: proc() {
	for _, record in contact_records {
		contact_record_clear(record)
		free(record)
	}
	delete(contact_records)
	contact_records = nil
}

// Switch owners without waiting for disk I/O. Accepted saves still commit;
// work from the previous selection cannot publish into the new cache.
@(private)
contact_store_select :: proc(owner: string) {
	if owner == contact_owner {return}
	next := owner if contact_id_valid(owner) else ""
	if next == contact_owner {return}
	sync.lock(&contact_queue_lock)
	prior := contact_owner
	contact_owner = strings.clone(next)
	contact_epoch += 1
	discard := contact_completed
	contact_completed = {}
	for job := discard.head; job != nil; job = job.next {
		if job.save && !job.ok {contact_failed_owners[job.owner] = true}
	}
	sync.unlock(&contact_queue_lock)
	delete(prior)
	contact_records_clear()
	contact_queue_free(&discard)
}

@(private = "file")
contact_owner_active :: proc(owner: string) -> bool {
	return(
		owner != "" &&
		owner == contact_owner &&
		sync.atomic_load(&contact_purged_epoch) != contact_epoch \
	)
}

@(private)
contact_store_entry :: proc(owner, peer: string) -> ^Contact_Record {
	if !contact_owner_active(owner) {return nil}
	record := contact_get(peer)
	return record if record != nil && record.loaded else nil
}

@(private)
contact_store_save :: proc(
	owner, peer, note: string,
	photo: []u8,
	change: Contact_Photo_Change,
) -> bool {
	if !contact_owner_active(owner) ||
	   len(note) > CONTACT_NOTE_MAX ||
	   !utf8.valid_string(note) ||
	   (change == .Replace && contact_png_edge(photo) == 0) {return false}
	record := contact_get(peer)
	if record == nil || record.saving {return false}
	job := contact_new_job(peer)
	job.save = true
	job.change = change
	job.note = strings.clone(note)
	if change == .Replace {
		job.png = make([]u8, len(photo))
		copy(job.png, photo)
	}
	if !contact_enqueue(job) {contact_job_free(job); return false}
	record.saving, record.done = true, false
	return true
}

@(private)
contact_store_drain :: proc(editing_peer := "") -> (save_failed: bool) {
	if sync.atomic_load(&contact_purged_epoch) == contact_epoch {contact_records_clear()}
	sync.lock(&contact_queue_lock)
	ready := contact_completed
	contact_completed = {}
	if contact_owner != "" && len(contact_failed_owners) != 0 {
		key: [CONTACT_ID_LEN]u8
		copy(key[:], contact_owner)
		_, save_failed = delete_key(&contact_failed_owners, key)
	}
	sync.unlock(&contact_queue_lock)
	for job := contact_pop(&ready); job != nil; job = contact_pop(&ready) {
		peer := string(job.peer[:])
		record := contact_records[peer]
		if record != nil && contact_owner_active(string(job.owner[:])) {
			if !job.save || job.ok {
				contact_record_clear(record)
				record.note, job.note = job.note, ""
				record.photo = nil
				if job.pixels != nil {
					photo := photo_install(job.pixels, job.edge)
					job.pixels = nil
					if photo.tex != nil {record.photo = photo} else {contact_photo_free(photo)}
				}
				record.loaded = true
				record.has_photo = job.has_photo
				record.unreadable = job.unreadable
			} else if job.change == .Keep && job.unreadable {
				record.unreadable = true
			}
			if job.save {
				record.saving, record.done, record.ok = false, true, job.ok
				save_failed |= !job.ok && peer != editing_peer
			}
		}
		contact_job_free(job)
	}
	return
}

@(private)
contact_store_result :: proc(owner, peer: string) -> (done, ok: bool) {
	if !contact_owner_active(owner) {return}
	if record := contact_records[peer]; record != nil && record.done {
		record.done = false
		return true, record.ok
	}
	return
}

@(private)
contact_store_stop :: proc() {
	contact_store_select("")
	if contact_worker == nil {return}
	sync.lock(&contact_queue_lock)
	contact_stopping = true
	sync.cond_signal(&contact_ready)
	sync.unlock(&contact_queue_lock)
	thread.join(contact_worker)
	thread.destroy(contact_worker)
	contact_worker = nil
	contact_stopping = false
	sync.lock(&contact_queue_lock)
	delete(contact_failed_owners)
	contact_failed_owners = nil
	sync.unlock(&contact_queue_lock)
}

@(private = "file")
contact_remove_tree :: proc(path: string) -> bool {
	info, err := os.lstat(path, context.temp_allocator)
	if err == .Not_Exist {return true}
	if err != nil {return false}
	if info.type == .Directory {err = os.remove_all(path)} else {err = os.remove(path)}
	return err == nil || err == .Not_Exist
}

// Account deletion can call from its worker. The frame thread drops the cache
// at drain, or sooner when it selects another owner.
@(private)
contact_store_purge :: proc(owner: string) -> bool {
	if !contact_id_valid(owner) {return false}
	sync.lock(&contact_disk_lock)
	defer sync.unlock(&contact_disk_lock)

	sync.lock(&contact_queue_lock)
	pending := contact_jobs
	contact_jobs = {}
	discard: Contact_Queue
	for job := contact_pop(&pending); job != nil; job = contact_pop(&pending) {
		contact_push(&discard if string(job.owner[:]) == owner else &contact_jobs, job)
	}
	key: [CONTACT_ID_LEN]u8
	copy(key[:], owner)
	delete_key(&contact_failed_owners, key)
	if owner == contact_owner {
		sync.atomic_store(&contact_purged_epoch, contact_epoch)
		for job := contact_pop(&contact_completed);
		    job != nil;
		    job = contact_pop(&contact_completed) {
			contact_push(&discard, job)
		}
	}
	sync.unlock(&contact_queue_lock)
	contact_queue_free(&discard)
	defer frame_wake()

	root := contact_root()
	state := contact_directory(root)
	if state == .Missing {return true}
	if state == .Unreadable ||
	   !contact_remove_tree(fmt.tprintf("%s/%s", root, owner)) {return false}
	when ODIN_OS != .Windows {return contact_sync_dir(root)}
	return true
}

@(private)
contact_store_purge_all :: proc() {
	contact_store_stop()
	sync.lock(&contact_disk_lock)
	defer sync.unlock(&contact_disk_lock)
	if !contact_remove_tree(
		contact_root(),
	) {fmt.eprintln("Could not remove private contact records")}
}
