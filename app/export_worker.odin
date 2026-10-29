package main

import "core:mem"
import "core:slice"
import "core:strings"
import "core:thread"

import marmot "../marmot"

@(private)
Transcript_Attachment :: struct {
	name, rejection: string,
	reference:       ^marmot.Media_Attachment_Reference,
}

@(private)
Transcript_Message :: struct {
	body, sender, at_full: string,
	system, mine, deleted: bool,
	attachments:           []Transcript_Attachment,
	record:                ^marmot.Timeline_Message_Record,
}

@(private)
Transcript_Job :: struct {
	worker:                ^thread.Thread,
	client:                ^marmot.Client,
	account, group, title: string,
	kind:                  Transcript_Kind,
	stale, presented:      bool,
	reading:               bool,
	page:                  ^marmot.Timeline_Page,
	messages:              []Transcript_Message,
	images, completed:     int, // completed is atomic; images is fixed before start
	bytes:                 []u8,
	result_allocator:      mem.Allocator,
}

// Own only the raw-event projection, never pointers into the live timeline.
@(private)
transcript_record_strings :: proc(r: ^marmot.Timeline_Message_Record) -> [10]^cstring {
	return {
		&r.message_id_hex,
		&r.source_message_id_hex,
		&r.direction,
		&r.group_id_hex,
		&r.sender,
		&r.plaintext,
		&r.reply_to_message_id_hex,
		&r.media_json,
		&r.deleted_by_message_id_hex,
		&r.invalidation_status,
	}
}

@(private)
transcript_reference_strings :: proc(r: ^marmot.Media_Attachment_Reference) -> [7]^cstring {
	return {
		&r.ciphertext_sha256,
		&r.plaintext_sha256,
		&r.nonce_hex,
		&r.file_name,
		&r.media_type,
		&r.dim,
		&r.thumbhash,
	}
}

@(private)
transcript_snapshot :: proc(ui: ^Ui_State, job: ^Transcript_Job, page: ^marmot.Timeline_Page) {
	records := make(map[string]^marmot.Timeline_Message_Record, allocator = context.temp_allocator)
	for &record in page.messages[:page.messages_len] {
		if record.message_id_hex != nil {records[string(record.message_id_hex)] = &record}
	}
	job.messages = make([]Transcript_Message, len(ui.messages))
	for msg, i in ui.messages {
		out := &job.messages[i]
		out^ = {
			body    = strings.clone(msg.body),
			sender  = strings.clone(msg.sender),
			at_full = strings.clone(msg.at_full),
			system  = msg.system,
			mine    = msg.mine,
			deleted = msg.deleted,
		}
		if msg.system || msg.deleted {continue}
		record := records[msg.id]
		if record != nil {
			r := new(marmot.Timeline_Message_Record)
			r^ = {
				kind        = record.kind,
				timeline_at = record.timeline_at,
				received_at = record.received_at,
				deleted     = record.deleted,
				tags_len    = record.tags_len,
			}
			sources := transcript_record_strings(record)
			for field, j in transcript_record_strings(r) {
				if src := sources[j]^; src != nil {field^ = strings.clone_to_cstring(string(src))}
			}
			tags := make([]marmot.Message_Tag, record.tags_len)
			for &tag, j in tags {
				values := make([]cstring, record.tags[j].values_len)
				for &value, k in values {value = strings.clone_to_cstring(string(record.tags[j].values[k]))}
				tag = {raw_data(values), uint(len(values))}
			}
			r.tags = raw_data(tags)
			out.record = r
		}
		out.attachments = make([]Transcript_Attachment, len(msg.attachments))
		for slot, j in msg.attachments {
			att := &out.attachments[j]
			att.name = strings.clone(slot.name)
			if slot.state == .Rejected {
				// Locale can change during export. Translate on the UI thread.
				att.rejection = strings.clone(tr(slot.rejection))
			} else if strings.has_prefix(media_type_for(slot.name), "image/") {
				job.images += 1
				if reference := media_reference(record, j); reference != nil {
					att.reference = new(marmot.Media_Attachment_Reference)
					att.reference^ = reference^
					for field in transcript_reference_strings(att.reference) {
						if field^ != nil {field^ = strings.clone_to_cstring(string(field^))}
					}
					locators := make([]marmot.Media_Locator, reference.locators_len)
					for &locator, k in locators {
						locator = {
							strings.clone_to_cstring(string(reference.locators[k].kind)),
							strings.clone_to_cstring(string(reference.locators[k].value)),
						}
					}
					att.reference.locators = raw_data(locators)
				}
			}
		}
	}
}

@(private)
transcript_read :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	job := (^Transcript_Job)(t.data)
	query := marmot.Timeline_Message_Query {
		group_id_hex = strings.clone_to_cstring(job.group, context.temp_allocator),
		has_limit    = true,
		limit        = TL_PAGE,
	}
	marmot.timeline_messages(
		job.client,
		strings.clone_to_cstring(job.account, context.temp_allocator),
		&query,
		&job.page,
	)
}

// A row export projects just transcript data, without touching the live timeline,
// selection, media views, or conversation navigation.
@(private)
export_page_snapshot :: proc(ui: ^Ui_State, job: ^Transcript_Job) {
	rows := make([dynamic]Msg_Ui, context.temp_allocator)
	page := job.page
	originals := make(map[string]^marmot.Timeline_Message_Record, context.temp_allocator)
	edits := make(map[string]^marmot.Timeline_Message_Record, context.temp_allocator)
	for &record in page.messages[:page.messages_len] {originals[string(record.message_id_hex)] = &record}
	for &record in page.messages[:page.messages_len] {
		if record.kind != 1009 {continue}
		target := first_event_ref(&record)
		original := originals[target]
		if original == nil || string(original.sender) != string(record.sender) {continue}
		if old := edits[target];
		   old == nil || old.received_at < record.received_at {edits[target] = &record}
	}
	for &record in page.messages[:page.messages_len] {
		id := string(record.message_id_hex)
		if record.kind == 1009 ||
		   record.kind == 5 ||
		   record.kind == KIND_POLL_VOTE ||
		   ui.hidden[id] ||
		   ui.blocked[string(record.sender)] {continue}
		content := &record
		if edit := edits[id]; edit != nil {content = edit}
		msg := Msg_Ui {
			id      = id,
			sender  = dm_title(job.client, string(record.sender)),
			body    = string(content.plaintext),
			at_full = format_full(record.timeline_at),
			sort_at = record.timeline_at,
			mine    = string(record.direction) == "sent",
			deleted = record.deleted,
		}
		if record.kind == 1210 &&
		   record.group_system !=
			   nil {msg.system = true; msg.body = system_text(job.client, record.group_system)}
		if record.poll != nil {msg.body = string(record.poll.question)}
		for outcome in record.media[:record.media_len] {
			slot: Att_Slot
			if outcome.tag ==
			   .REJECTED {slot.state = .Rejected; slot.rejection = media_rejection_text(outcome.body.rejected.rejection.kind)} else {slot.name = string(outcome.body.accepted.reference.file_name)}
			append(&msg.attachments, slot)
		}
		append(&rows, msg)
	}
	slice.sort_by(rows[:], proc(a, b: Msg_Ui) -> bool {return a.sort_at < b.sort_at})
	snapshot := Ui_State {
		messages = rows,
	}
	transcript_snapshot(&snapshot, job, page)
	for msg in rows {delete(msg.at_full); delete(msg.attachments)}
}

@(private)
export_stop :: proc(ui: ^Ui_State) {
	job := ui.transcript
	if job == nil {return}
	if job.worker != nil {thread.join(job.worker); thread.destroy(job.worker)}
	if job.page != nil {marmot.timeline_page_free(job.page)}
	for msg in job.messages {
		delete(msg.body); delete(msg.sender); delete(msg.at_full)
		if r := msg.record; r != nil {
			for field in transcript_record_strings(r) {delete(field^)}
			for tag in r.tags[:r.tags_len] {
				for value in tag.values[:tag.values_len] {delete(value)}
				delete(tag.values[:tag.values_len])
			}
			delete(r.tags[:r.tags_len]); free(r)
		}
		for att in msg.attachments {
			delete(att.name); delete(att.rejection)
			if r := att.reference; r != nil {
				for field in transcript_reference_strings(r) {delete(field^)}
				for locator in r.locators[:r.locators_len] {delete(locator.kind); delete(locator.value)}
				delete(r.locators[:r.locators_len]); free(r)
			}
		}
		delete(msg.attachments)
	}
	delete(job.messages); delete(job.bytes)
	delete(job.account); delete(job.group); delete(job.title)
	free(job); ui.transcript = nil
}

@(private)
transcript_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	defer frame_wake()
	job := (^Transcript_Job)(t.data)
	b := strings.builder_make(job.result_allocator)
	if job.kind == .Html {transcript_html(job, &b)} else {transcript_md(job, &b)}
	job.bytes = b.buf[:]
}
