// Forward picker, the slint forward flow (src/wiring/forward.rs):
// "Forward" in the message context menu opens a destination-chat
// picker with a live name filter; picking a chat re-sends the body
// through the optimistic send pipeline (grayed pending row in the
// target chat, tap-to-retry on failure), and attachments are
// re-downloaded (decrypted) here and re-encrypted for the target
// group by the upload worker.
package main

import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

// What a pick in the destination picker sends. Forwarding a message
// and sharing a theme want the same list and the same filter; only the
// title and the action differ.
Fwd_Kind :: enum {
	Message,
	Theme,
}

// Destination rows: every chat except pending invites, matching the
// filter against the title, case-insensitive. Forwarding also hides
// the chat the message is already in; sharing a theme does not, since
// the open chat is a perfectly good destination for it.
fwd_visible :: proc(ui: ^Ui_State, index: int) -> bool {
	chat := ui.chats[index]
	if chat.pending || (ui.fwd_kind == .Message && index == ui.selected) {
		return false
	}
	filter := strings.to_lower(string(ui.fwd_filter[:]), context.temp_allocator)
	if len(filter) == 0 {
		return true
	}
	return strings.contains(strings.to_lower(chat.title, context.temp_allocator), filter)
}

forward_modal :: proc(ui: ^Ui_State) {
	if clay.UI(clay.ID("FwdModal"))(
	{
		layout = {sizing = {width = clay.SizingFixed(modal_w(clay.ID("FwdModal"), 440))}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(20), childGap = 12},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {attachTo = .Root, zIndex = 13, offset = {0, rise(clay.ID("FwdModal"))}, attachment = {element = .CenterCenter, parent = .CenterCenter}},
	},
	) {
		if clay.UI(clay.ID("FwdHead"))({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}}) {
			clay.Text(
				tr(ui.fwd_kind == .Theme ? "Share theme with" : "Forward to"),
				{fontId = FONT_TITLE, fontSize = 20, textColor = TEXT},
			)
			if clay.UI(clay.ID("FwdHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("FwdClose"))(
			{layout = {sizing = {width = clay.SizingFixed(26), height = clay.SizingFixed(26)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(7)},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}

		if clay.UI(clay.ID("FwdFilter"))(
		{
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(36)}, padding = {left = 12, right = 12}, childAlignment = {y = .Center}},
			backgroundColor = ROW_BG,
			cornerRadius = rr(8),
			border = {color = ui.focus == .Fwd ? ACCENT : FIELD_BORDER, width = bw()},
		},
		) {
			field_text(ui, "FwdFilter", &ui.fwd_filter, "Filter chats", ui.focus == .Fwd, 13, TEXT_LO)
		}

		if clay.UI(clay.ID("FwdList"))(
		{
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFit({max = 320})}, layoutDirection = .TopToBottom, childGap = 2},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			for chat, i in ui.chats {
				if !fwd_visible(ui, i) {
					continue
				}
				if clay.UI(clay.ID("FwdRow", u32(i)))(
				{
					layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(44)}, padding = {left = 10, right = 10}, childGap = 10, childAlignment = {y = .Center}},
					backgroundColor = hovered() ? HOVER : {},
					cornerRadius = rr(8),
				},
				) {
					avatar("FwdAvatar", u32(i), chat.group_id, chat.title, 30, chat_pic(chat))
					clay.Text(chat.title, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
				}
			}
		}
		scrollbar(clay.ID("FwdList"), 14) // the modal floats at 13
	}
}

// Re-download the source message's attachments (decrypted plaintext)
// into Pending_Att payloads the upload worker re-encrypts for the
// target group. Any failure aborts the whole forward.
fwd_download_atts :: proc(ui: ^Ui_State, client: ^marmot.Client, msg_id: string) -> (atts: [dynamic]Pending_Att, ok: bool) {
	page := timeline_page
	account := strings.clone_to_cstring(ui.account_ref, context.temp_allocator)
	if page == nil { return atts, false }

	for i in 0 ..< page.messages_len {
		record := &page.messages[i]
		if record.message_id_hex == nil || string(record.message_id_hex) != msg_id {
			continue
		}
		for j in 0 ..< record.media_len {
			result: ^marmot.Media_Download_Result
			group := strings.clone_to_cstring(ui.chats[ui.selected].group_id, context.temp_allocator)
			reference := media_reference(record, int(j))
			if reference == nil || marmot.download_media(client, account, group, reference, &result) != .OK {
				if reference != nil {
					fmt.eprintfln("forward: download failed: %s", marmot.last_error())
				}
				for &a in atts {
					delete(a.name)
					delete(a.dim)
					delete(a.data)
					if a.tex != nil {
						rl.UnloadTexture(a.tex^)
						free(a.tex)
					}
				}
				delete(atts)
				return {}, false
			}
			name := result.file_name != nil && len(string(result.file_name)) > 0 ? string(result.file_name) : "attachment"
			att := Pending_Att {
				name       = strings.clone(name),
				media_type = media_type_for(name),
				data       = make([]u8, result.plaintext_len),
			}
			copy(att.data, result.plaintext[:result.plaintext_len])
			marmot.media_download_result_free(result)

			// Images decode a thumbnail for the pending row; it also
			// provides the re-upload's "WxH" dim, like stage_file.
			if strings.has_prefix(att.media_type, "image/") {
				ext := strings.clone_to_cstring(fmt.tprintf(".%s", strings.trim_prefix(att.media_type, "image/")), context.temp_allocator)
				image := rl.LoadImageFromMemory(ext, raw_data(att.data), i32(len(att.data)))
				if image.data != nil {
					att.tex = new(rl.Texture2D)
					att.tex^ = rl.LoadTextureFromImage(image)
					rl.UnloadImage(image)
					att.dim = fmt.aprintf("%dx%d", att.tex.width, att.tex.height)
				}
			}
			append(&atts, att)
		}
		return atts, true
	}
	return atts, len(atts) > 0 // not found = nothing to download
}

// Re-send the picked message into the destination chat through the
// optimistic pipeline: text and attachments each become a Pending_Send
// (the worker sends either a text or an upload, never both).
// ponytail: all attachments go out as one album send; per-file sends
// like the slint flush if mixed-type forwards ever look wrong.
do_forward :: proc(ui: ^Ui_State, client: ^marmot.Client, dest: int) {
	msg := ui.messages[ui.fwd_msg]
	group := ui.chats[dest].group_id
	info := profile_info(client, ui.account_ref)
	sender := len(info.name) > 0 ? info.name : "you"

	atts: [dynamic]Pending_Att
	if len(msg.att_names) > 0 {
		ok: bool
		atts, ok = fwd_download_atts(ui, client, msg.id)
		if !ok {
			ui.client_status = strings.clone("Couldn't forward. Please try again.")
			return
		}
	}

	if len(msg.body) > 0 {
		send_ticket += 1
		append(&ui.pending, Pending_Send{
			ticket   = send_ticket,
			group_id = strings.clone(group),
			sender   = strings.clone(sender),
			body     = strings.clone(msg.body),
		})
		spawn_send(ui, client, &ui.pending[len(ui.pending) - 1])
	}
	if len(atts) > 0 {
		send_ticket += 1
		append(&ui.pending, Pending_Send{
			ticket   = send_ticket,
			group_id = strings.clone(group),
			sender   = strings.clone(sender),
			body     = strings.clone(""),
			atts     = atts,
		})
		spawn_send(ui, client, &ui.pending[len(ui.pending) - 1])
	}
}

// Click/keyboard handling for the open forward picker; anything
// outside the modal dismisses it.
handle_forward :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	// A forward needs its source message to still exist; a theme share
	// carries its own payload and does not.
	stale := ui.fwd_kind == .Message && (ui.fwd_msg < 0 || ui.fwd_msg >= len(ui.messages))
	if stale || rl.IsKeyPressed(.ESCAPE) {
		ui.fwd_open = false
		ui.focus = .Compose
		return
	}
	edit_text(ui, &ui.fwd_filter)
	if field_mouse(ui, &ui.fwd_filter, "FwdFilter") {
		ui.focus = .Fwd
		return
	}
	if !mouse_released() {
		return
	}
	for _, i in ui.chats {
		if fwd_visible(ui, i) && clay.PointerOver(clay.ID("FwdRow", u32(i))) {
			ui.fwd_open = false
			ui.focus = .Compose
			if ui.fwd_kind == .Theme {
				share_theme(ui, client, i)
			} else {
				do_forward(ui, client, i)
			}
			return
		}
	}
	if clicked("FwdClose") || !clay.PointerOver(clay.ID("FwdModal")) {
		ui.fwd_open = false
		ui.focus = .Compose
	}
}
