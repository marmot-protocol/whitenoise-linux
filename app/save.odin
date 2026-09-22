// Attachment saving: any media reference on any message can be saved
// to disk. Entry points are the unsupported-file chip (click) and the
// per-attachment "Save …" rows in the message context menu. Both open
// the native save dialog; when the path arrives, the bytes are
// re-fetched from the record and written.
//
//   chip / ctx row → start_att_save (remembers the pick, opens dialog)
//   frame loop     → rl.SavedFiles() → save_attachment (fetch + write)
package main

import "core:fmt"
import "core:os"
import "core:strings"

import marmot "../marmot"
import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// A tile-list element: the rendered view plus the media index it
// came from, so every tile can name its attachment to the save flow.
Att_Item :: struct($V: typeid) {
	view: V,
	att:  int,
}

// One attachment pick: enough to re-find the media reference later
// (records are freed after every timeline load, so nothing marmot
// owns can be retained).
Att_Pick :: struct {
	group:  string,
	msg_id: string,
	index:  int, // position in the record's media list
	name:   string,
}

att_hover: Att_Pick // chip under the pointer, rebound every build
pending_save: Att_Pick // owns its strings; set while a dialog is open
pending_blob: []u8 // in-memory save source (preview modal); nil = record-based

// Save bytes already in memory (an archive entry in the preview
// modal); no re-fetch when the path arrives.
start_blob_save :: proc(name: string, bytes: []u8) {
	backup_saving = false // a cancelled backup dialog must not stamp this one
	delete(pending_blob)
	pending_blob = make([]u8, len(bytes))
	copy(pending_blob, bytes)

	delete(pending_save.group)
	delete(pending_save.msg_id)
	delete(pending_save.name)
	pending_save = {
		name = strings.clone(name),
	}
	rl.SaveFileDialog(name)
}

start_att_save :: proc(pick: Att_Pick) {
	backup_saving = false
	delete(pending_save.group)
	delete(pending_save.msg_id)
	delete(pending_save.name)
	pending_save = {
		group  = strings.clone(pick.group),
		msg_id = strings.clone(pick.msg_id),
		index  = pick.index,
		name   = strings.clone(pick.name),
	}
	rl.SaveFileDialog(pick.name)
}

// Corner download chip, shown while its attachment tile is hovered
// (call inside the tile's element block). Clicking it routes into
// the same save flow as the file chips; the tile handlers check
// att_hover so the click doesn't also trigger the tile's own action.
att_dl_button :: proc(id_str: string, id: u32, msg_id: string, att: int, name: string) {
	if !hovered() {
		return
	}
	if clay.UI(clay.ID(id_str, id))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(26), height = clay.SizingFixed(26)},
			childAlignment = {x = .Center, y = .Center},
		},
		floating = {
			attachTo = .Parent,
			zIndex = 6,
			offset = {-6, 6},
			attachment = {element = .RightTop, parent = .RightTop},
		},
		backgroundColor = {0, 0, 0, hovered() ? 210 : 150},
		cornerRadius = rr(13),
	},
	) {
		if hovered() {
			att_hover = {
				msg_id = msg_id,
				index  = att,
				name   = name,
			}
		}
		clay.Text(
			ICON_DOWNLOAD,
			{fontId = FONT_ICON, fontSize = 12, textColor = {255, 255, 255, 230}},
		)
	}
}

// Click on an unsupported-file chip; runs after layout like the other
// handlers. The chip can't reach ui, so the group lands here.
handle_att_click :: proc(ui: ^Ui_State) {
	if att_hover.msg_id == "" || !mouse_released() {
		return
	}
	if ui.selected < 0 || ui.selected >= len(ui.chats) {
		return
	}
	pick := att_hover
	pick.group = ui.chats[ui.selected].group_id
	start_att_save(pick)
}

// The dialog produced a destination: re-find the record, download the
// blob, write it.
// ponytail: blocks the UI thread like every other media fetch here;
// moves to the worker with the subscriptions phase.
save_attachment :: proc(ui: ^Ui_State, client: ^marmot.Client, path: string) {
	defer {
		delete(pending_save.group)
		delete(pending_save.msg_id)
		delete(pending_save.name)
		pending_save = {}
	}

	fail :: proc(ui: ^Ui_State, name: string) {
		ui.client_status = fmt.aprintf("couldn't save %s", name)
	}

	if pending_blob != nil {
		defer {
			delete(pending_blob)
			pending_blob = nil
		}
		if os.write_entire_file(path, pending_blob) != nil {
			fail(ui, pending_save.name)
		} else {
			ui.client_status = fmt.aprintf("saved %s", path)
		}
		return
	}
	if pending_save.msg_id == "" {
		return
	}

	result, ok := fetch_attachment(
		ui,
		client,
		pending_save.group,
		pending_save.msg_id,
		pending_save.index,
	)
	if !ok {
		fail(ui, pending_save.name)
		return
	}
	defer marmot.media_download_result_free(result)

	if os.write_entire_file(path, result.plaintext[:result.plaintext_len]) != nil {
		fail(ui, pending_save.name)
		return
	}
	ui.client_status = fmt.aprintf("saved %s", path)
}

// Use the retained window's media reference, or query if its chat was left.
// Shared by save_attachment and the lightbox "Copy image".
fetch_attachment :: proc(
	ui: ^Ui_State,
	client: ^marmot.Client,
	group, msg_id: string,
	index: int,
) -> (
	result: ^marmot.Media_Download_Result,
	ok: bool,
) {
	query := marmot.Timeline_Message_Query {
		group_id_hex = strings.clone_to_cstring(group, context.temp_allocator),
		has_limit    = true,
		limit        = 100,
	}
	page := timeline_page
	if timeline_job == nil ||
	   string(timeline_job.group) != group ||
	   string(timeline_job.account) != ui.account_ref {page = nil}
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	owned := page == nil
	if owned {
		if marmot.timeline_messages(client, account, &query, &page) != .OK {return}
	}
	defer {if owned {marmot.timeline_page_free(page)}}

	reference: ^marmot.Media_Attachment_Reference
	for i in 0 ..< page.messages_len {
		record := &page.messages[i]
		if record.message_id_hex == nil || string(record.message_id_hex) != msg_id {
			continue
		}
		if record.deleted || record.invalidation_status != nil {return}
		reference = media_reference(record, index)
		if reference == nil {return}
		break
	}
	// The file browser retains references outside the timeline's loaded window.
	if job := group_files_job;
	   reference == nil &&
	   job != nil &&
	   job.worker == nil &&
	   string(job.account) == ui.account_ref &&
	   string(job.group) == group {
		for file in job.files {
			if string(file.record.message_id_hex) == msg_id &&
			   file.index == index &&
			   group_file_matches(ui, file) {
				reference = media_reference(file.record, index)
				break
			}
		}
	}
	if reference == nil {return}
	group_c := strings.clone_to_cstring(group, context.temp_allocator)
	if marmot.download_media(client, account, group_c, reference, &result) != .OK {
		fmt.eprintfln("media: download failed: %s", marmot.last_error())
		return
	}
	// The chip's size label learns from any download that passes by.
	if sha := reference.plaintext_sha256; sha != nil && string(sha) not_in blob_sizes {
		blob_sizes[strings.clone(string(sha))] = i64(result.plaintext_len)
	}
	return result, true
}
