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
import "core:strings"

import marmot "../marmot"

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

// Export the selected chat's loaded window as a transcript file.
// ponytail: image re-downloads block the UI thread like every other
// media fetch here; moves to the worker with the subscriptions phase.
// `index` targets a rail row other than the open one (the row menu);
// the transcript is built from the loaded timeline, so that row is
// opened first.
export_chat :: proc(ui: ^Ui_State, client: ^marmot.Client, kind: Transcript_Kind, index := -1) {
	if index >= 0 && index != ui.selected {
		select_chat(ui, client, index)
	}
	if ui.selected < 0 {
		return
	}
	chat := ui.chats[ui.selected]

	// One timeline query covers both the raw-event panels and the
	// image re-downloads (records aren't retained between loads).
	query := marmot.Timeline_Message_Query {
		group_id_hex = strings.clone_to_cstring(chat.group_id, context.temp_allocator),
		has_limit    = true,
		limit        = tl_limit(ui, chat.group_id),
	}
	page: ^marmot.Timeline_Page
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	if marmot.timeline_messages(client, account, &query, &page) != .OK {
		ui.client_status = fmt.aprintf("Couldn't export the chat. %s", marmot.last_error())
		return
	}
	defer marmot.timeline_page_free(page)

	records := make(map[string]^marmot.Timeline_Message_Record, allocator = context.temp_allocator)
	for i in 0 ..< page.messages_len {
		record := &page.messages[i]
		if record.message_id_hex != nil {
			records[string(record.message_id_hex)] = record
		}
	}

	b := strings.builder_make(context.temp_allocator)
	if kind == .Html {
		transcript_html(ui, client, chat, records, &b)
	} else {
		transcript_md(ui, chat, &b)
	}

	title, _ := strings.replace_all(chat.title, "/", "-", context.temp_allocator)
	start_blob_save(fmt.tprintf("%s.%s", title, kind == .Html ? "html" : "md"), b.buf[:])
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

transcript_html :: proc(ui: ^Ui_State, client: ^marmot.Client, chat: Chat_Row_Ui, records: map[string]^marmot.Timeline_Message_Record, b: ^strings.Builder) {
	fmt.sbprintf(b, "<!doctype html>\n<html><head><meta charset=\"utf-8\">\n<title>%s</title>\n<style>%s</style></head>\n<body>\n<h1>%s</h1>\n", html_esc(chat.title), TRANSCRIPT_CSS, html_esc(chat.title))

	for msg in ui.messages {
		if msg.system {
			fmt.sbprintf(b, "<div class=\"sys\">%s <span class=\"when\">%s</span></div>\n", html_esc(msg.body), msg.at_full)
			continue
		}
		fmt.sbprintf(b, "<div class=\"msg%s\">\n<span class=\"sender\">%s</span> <span class=\"when\">%s</span>\n", msg.mine ? " mine" : "", html_esc(msg.sender), msg.at_full)
		if msg.deleted {
			strings.write_string(b, "<div class=\"deleted\">Message deleted.</div>\n</div>\n")
			continue
		}
		if len(msg.body) > 0 {
			body, _ := strings.replace_all(html_esc(msg.body), "\n", "<br>", context.temp_allocator)
			fmt.sbprintf(b, "<div class=\"body\">%s</div>\n", body)
		}
		record := records[msg.id]
		for name, j in msg.att_names {
			if rejection, rejected := msg.att_rejected[j]; rejected {
				fmt.sbprintf(b, "<div class=\"att\">%s</div>\n", html_esc(tr(rejection)))
			} else if strings.has_prefix(media_type_for(name), "image/") {
				inline_image(ui, client, record, j, name, b)
			} else {
				fmt.sbprintf(b, "<div class=\"att\">%s</div>\n", html_esc(name))
			}
		}
		if record != nil {
			fmt.sbprintf(b, "<details><summary>Raw event</summary><pre>%s</pre></details>\n", html_esc(record_json(record, context.temp_allocator)))
		}
		strings.write_string(b, "</div>\n")
	}
	strings.write_string(b, "</body></html>\n")
}

// Re-download one image attachment and inline it as a data URI; a
// failed download degrades to a visible note.
inline_image :: proc(ui: ^Ui_State, client: ^marmot.Client, record: ^marmot.Timeline_Message_Record, index: int, name: string, b: ^strings.Builder) {
	result: ^marmot.Media_Download_Result
	reference := media_reference(record, index)
	ok := reference != nil
	if ok {
		account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
		group := strings.clone_to_cstring(string(record.group_id_hex), context.temp_allocator)
		ok = marmot.download_media(client, account, group, reference, &result) == .OK
	}
	if !ok {
		fmt.sbprintf(b, "<div class=\"att\">%s (image unavailable)</div>\n", html_esc(name))
		return
	}
	defer marmot.media_download_result_free(result)

	encoded := base64.encode(result.plaintext[:result.plaintext_len], base64.ENC_TABLE, context.temp_allocator)
	fmt.sbprintf(b, "<img alt=\"%s\" src=\"data:%s;base64,%s\">\n", html_esc(name), media_type_for(name), encoded)
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
			append(&rows, Row{contact.name, contact.npub, ui.nicknames[contact.id_hex], ui.blocked[contact.id_hex]})
		}
		data, err := json.marshal(rows[:], {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
		if err != nil {
			ui.client_status = "Couldn't export contacts. Please try again."
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
