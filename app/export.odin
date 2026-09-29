// Chat transcript and contact list exports. Each builds the whole
// file in memory and hands it to start_blob_save, so the user picks
// the destination in the native save dialog.
//
//   members panel → export_chat (HTML with inlined images and
//                   raw-event panels, or plain Markdown)
//   contacts rail → export_contacts (CSV or JSON)
package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import "core:thread"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

Transcript_Kind :: enum {
	Html,
	Markdown,
}

Contacts_Kind :: enum {
	Csv,
	Json,
}

// Escape text landing inside an HTML element or attribute.
html_esc :: proc(text: string) -> string {
	esc, _ := strings.replace_all(text, "&", "&amp;", context.temp_allocator)
	esc, _ = strings.replace_all(esc, "<", "&lt;", context.temp_allocator)
	esc, _ = strings.replace_all(esc, ">", "&gt;", context.temp_allocator)
	esc, _ = strings.replace_all(esc, "\"", "&quot;", context.temp_allocator)
	return esc
}

@(private)
export_drain :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	job := ui.transcript
	if job == nil {return}
	if ui.account_ref != job.account ||
	   ui.page != .Chats ||
	   ui.selected < 0 ||
	   ui.selected >= len(ui.chats) ||
	   ui.chats[ui.selected].group_id != job.group {job.stale = true}
	if job.worker != nil {
		if !thread.is_done(job.worker) {return}
		if !job.stale {
			title, _ := strings.replace_all(job.title, "/", "-", context.temp_allocator)
			start_blob_save(fmt.tprintf("%s.html", title), job.bytes, take_ownership = true)
			job.bytes = nil
		}
		export_stop(ui)
		return
	}
	if job.stale {export_stop(ui); return}
	if !job.presented || ui.timeline_loading {return}
	if timeline_page == nil {
		toast(ui, tr("Couldn't export the chat. Please try again."))
		export_stop(ui)
		return
	}
	if job.kind == .Markdown {
		b := strings.builder_make(context.temp_allocator)
		transcript_md(ui, ui.chats[ui.selected], &b)
		title, _ := strings.replace_all(job.title, "/", "-", context.temp_allocator)
		start_blob_save(fmt.tprintf("%s.md", title), b.buf[:])
		export_stop(ui)
		return
	}
	transcript_snapshot(ui, job)
	job.worker = thread.create(transcript_worker)
	job.worker.data = job
	thread.start(job.worker)
}

// Export the selected chat's loaded window as a transcript file.
// `index` targets a rail row other than the open one (the row menu);
// the transcript is built from the loaded timeline, so that row is
// opened first.
export_chat :: proc(ui: ^Ui_State, client: ^marmot.Client, kind: Transcript_Kind, index := -1) {
	if ui.transcript != nil {return}
	if index >= 0 && index != ui.selected {
		select_chat(ui, client, index)
	}
	if ui.selected < 0 {
		return
	}
	chat := ui.chats[ui.selected]

	ui.transcript = new(Transcript_Job)
	ui.transcript^ = {
		client           = client,
		account          = strings.clone(ui.account_ref),
		group            = strings.clone(chat.group_id),
		title            = strings.clone(chat.title),
		kind             = kind,
		result_allocator = reload_allocator(),
	}
}

@(private)
export_progress :: proc(ui: ^Ui_State) {
	job := ui.transcript
	if job == nil {return}
	job.presented = true
	completed := sync.atomic_load(&job.completed)
	if clay.UI(clay.ID("TranscriptProgress"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {12, 12, 8, 8},
			childGap = 6,
		},
		backgroundColor = PANEL,
	},
	) {
		label :=
			job.kind == .Html ? tr("Preparing HTML export...") : tr("Preparing Markdown export...")
		if job.worker == nil && ui.timeline_loading {label = tr("Loading messages for export...")}
		clay.Text(
			fmt.tprintf("%s %s", label, job.title),
			{fontId = FONT_BODY, fontSize = 13, textColor = TEXT},
		)
		if job.images > 0 {
			clay.Text(
				fmt.tprintf(tr("Images processed: %d of %d"), completed, job.images),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
			)
		} else {
			clay.Text(
				tr("Progress is indeterminate."),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_LO},
			)
		}
		if clay.UI(clay.ID("TranscriptProgressTrack"))(
		{
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(4)}},
			backgroundColor = ROW_BG,
		},
		) {
			if job.images == 0 {
				anim_moving += 1
				phase := f32(0.375 * (1 + math.sin(rl.GetTime() * 3)))
				if clay.UI(clay.ID("TranscriptProgressSpace"))(
				{
					layout = {
						sizing = {width = clay.SizingPercent(phase), height = clay.SizingFixed(4)},
					},
				},
				) {}
			}
			fraction := job.images > 0 ? f32(completed) / f32(job.images) : f32(0.25)
			if clay.UI(clay.ID("TranscriptProgressFill"))(
			{
				layout = {
					sizing = {width = clay.SizingPercent(fraction), height = clay.SizingFixed(4)},
				},
				backgroundColor = ACCENT,
			},
			) {}
		}
	}
}

TRANSCRIPT_CSS :: `body{background:#15151a;color:#e6e6ea;font:14px/1.5 sans-serif;max-width:720px;margin:0 auto;padding:24px}
h1{font-size:20px}
.msg{border-bottom:1px solid #2a2a32;padding:10px 0}
.sender{font-weight:700}
.mine .sender{color:#7ee0c0}
.when{color:#8a8a95;font-size:12px}
.sys,.deleted{color:#8a8a95;font-style:italic}
.sys{padding:6px 0}
.att{color:#8a8a95;font-size:12px}
img{max-width:100%;border-radius:8px;margin-top:6px}
details{margin-top:6px}
summary{color:#8a8a95;font-size:12px;cursor:pointer}
pre{background:#1d1d24;padding:10px;border-radius:8px;overflow-x:auto;font-size:11px;white-space:pre-wrap}`

transcript_html :: proc(job: ^Transcript_Job, b: ^strings.Builder) {
	fmt.sbprintf(
		b,
		"<!doctype html>\n<html><head><meta charset=\"utf-8\">\n<title>%s</title>\n<style>%s</style></head>\n<body>\n<h1>%s</h1>\n",
		html_esc(job.title),
		TRANSCRIPT_CSS,
		html_esc(job.title),
	)

	for msg in job.messages {
		if msg.system {
			fmt.sbprintf(
				b,
				"<div class=\"sys\">%s <span class=\"when\">%s</span></div>\n",
				html_esc(msg.body),
				msg.at_full,
			)
			continue
		}
		fmt.sbprintf(
			b,
			"<div class=\"msg%s\">\n<span class=\"sender\">%s</span> <span class=\"when\">%s</span>\n",
			msg.mine ? " mine" : "",
			html_esc(msg.sender),
			msg.at_full,
		)
		if msg.deleted {
			strings.write_string(b, "<div class=\"deleted\">Message deleted.</div>\n</div>\n")
			continue
		}
		if len(msg.body) > 0 {
			body, _ := strings.replace_all(
				html_esc(msg.body),
				"\n",
				"<br>",
				context.temp_allocator,
			)
			fmt.sbprintf(b, "<div class=\"body\">%s</div>\n", body)
		}
		record := msg.record
		for att in msg.attachments {
			if att.rejection != "" {
				fmt.sbprintf(b, "<div class=\"att\">%s</div>\n", html_esc(att.rejection))
			} else if strings.has_prefix(media_type_for(att.name), "image/") {
				inline_image(job, att.reference, att.name, b)
				sync.atomic_add(&job.completed, 1)
				frame_wake()
			} else {
				fmt.sbprintf(b, "<div class=\"att\">%s</div>\n", html_esc(att.name))
			}
		}
		if record != nil {
			fmt.sbprintf(
				b,
				"<details><summary>Raw event</summary><pre>%s</pre></details>\n",
				html_esc(record_json(record, context.temp_allocator)),
			)
		}
		strings.write_string(b, "</div>\n")
		free_all(context.temp_allocator)
	}
	strings.write_string(b, "</body></html>\n")
}

// Re-download one image attachment and inline it as a data URI; a
// failed download degrades to a visible note.
inline_image :: proc(
	job: ^Transcript_Job,
	reference: ^marmot.Media_Attachment_Reference,
	name: string,
	b: ^strings.Builder,
) {
	result: ^marmot.Media_Download_Result
	ok := reference != nil
	if ok {
		account := strings.clone_to_cstring(job.account, context.temp_allocator)
		group := strings.clone_to_cstring(job.group, context.temp_allocator)
		ok = marmot.download_media(job.client, account, group, reference, &result) == .OK
	}
	if !ok {
		fmt.sbprintf(b, "<div class=\"att\">%s (image unavailable)</div>\n", html_esc(name))
		return
	}
	defer marmot.media_download_result_free(result)

	encoded := base64.encode(
		result.plaintext[:result.plaintext_len],
		base64.ENC_TABLE,
		context.temp_allocator,
	)
	fmt.sbprintf(
		b,
		"<img alt=\"%s\" src=\"data:%s;base64,%s\">\n",
		html_esc(name),
		media_type_for(name),
		encoded,
	)
}

transcript_md :: proc(ui: ^Ui_State, chat: Chat_Row_Ui, b: ^strings.Builder) {
	fmt.sbprintfln(b, "# %s", chat.title)
	for msg in ui.messages {
		strings.write_string(b, "\n")
		if msg.system {
			fmt.sbprintfln(b, "_%s_ · %s", msg.body, msg.at_full)
			continue
		}
		fmt.sbprintfln(b, "**%s** · %s", msg.sender, msg.at_full)
		if msg.deleted {
			fmt.sbprintln(b, "_Message deleted._")
			continue
		}
		if len(msg.body) > 0 {
			fmt.sbprintln(b, msg.body)
		}
		for name, j in msg.att_names {
			if rejection, rejected := msg.att_rejected[j]; rejected {
				fmt.sbprintfln(b, "_%s_", tr(rejection))
			} else if strings.has_prefix(media_type_for(name), "image/") {
				fmt.sbprintfln(b, "![%s](attachment)", name)
			}
		}
	}
}

export_contacts :: proc(ui: ^Ui_State, kind: Contacts_Kind) {
	b := strings.builder_make(context.temp_allocator)

	if kind == .Csv {
		strings.write_string(&b, "name,npub,nickname,blocked\n")
		for contact in ui.contacts {
			csv_field(&b, contact.name)
			strings.write_byte(&b, ',')
			csv_field(&b, contact.npub)
			strings.write_byte(&b, ',')
			csv_field(&b, ui.nicknames[contact.id_hex])
			fmt.sbprintf(&b, ",%t\n", ui.blocked[contact.id_hex])
		}
	} else {
		Row :: struct {
			name, npub, nickname: string,
			blocked:              bool,
		}
		rows := make([dynamic]Row, context.temp_allocator)
		for contact in ui.contacts {
			append(
				&rows,
				Row {
					contact.name,
					contact.npub,
					ui.nicknames[contact.id_hex],
					ui.blocked[contact.id_hex],
				},
			)
		}
		data, err := json.marshal(
			rows[:],
			{pretty = true, use_spaces = true, spaces = 2},
			context.temp_allocator,
		)
		if err != nil {
			set_status(ui, tr("Couldn't export contacts. Please try again."), .Error)
			return
		}
		strings.write_bytes(&b, data)
	}

	start_blob_save(kind == .Csv ? "contacts.csv" : "contacts.json", b.buf[:])
}

// One CSV field, quoted, inner quotes doubled.
csv_field :: proc(b: ^strings.Builder, value: string) {
	strings.write_byte(b, '"')
	for ch in value {
		if ch == '"' {
			strings.write_byte(b, '"')
		}
		strings.write_rune(b, ch)
	}
	strings.write_byte(b, '"')
}
