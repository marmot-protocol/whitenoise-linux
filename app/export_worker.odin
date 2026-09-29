package main

import "core:mem"
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
transcript_snapshot :: proc(ui: ^Ui_State, job: ^Transcript_Job) {
	records := make(map[string]^marmot.Timeline_Message_Record, allocator = context.temp_allocator)
	for &record in timeline_page.messages[:timeline_page.messages_len] {
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
		out.attachments = make([]Transcript_Attachment, len(msg.att_names))
		for name, j in msg.att_names {
			att := &out.attachments[j]
			att.name = strings.clone(name)
			if rejection, rejected := msg.att_rejected[j]; rejected {
				// Locale can change during export. Translate on the UI thread.
				att.rejection = strings.clone(tr(rejection))
			} else if strings.has_prefix(media_type_for(name), "image/") {
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
export_stop :: proc(ui: ^Ui_State) {
	job := ui.transcript
	if job == nil {return}
	if job.worker != nil {thread.join(job.worker); thread.destroy(job.worker)}
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
	transcript_html(job, &b)
	job.bytes = b.buf[:]
}
