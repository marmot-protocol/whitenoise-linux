// Forward picker, the slint forward flow (src/wiring/forward.rs):
// "Forward" in the message context menu opens a destination-chat
// picker with a live name filter; picking a chat re-sends the body
// through the optimistic send pipeline (grayed pending row in the
// target chat, tap-to-retry on failure), and attachments are
// downloaded and decoded off-thread, then re-encrypted for the
// target group by the upload worker.
package main

import "core:math"

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

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
		layout = {
			sizing = {width = clay.SizingFixed(modal_w(clay.ID("FwdModal"), 440))},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(20),
			childGap = 12,
		},
		backgroundColor = CARD,
		cornerRadius = rr(16),
		border = {color = CARD_BORDER, width = bw()},
		floating = {
			attachTo = .Root,
			zIndex = 13,
			offset = {0, rise(clay.ID("FwdModal"))},
			attachment = {element = .CenterCenter, parent = .CenterCenter},
		},
	},
	) {
		if clay.UI(clay.ID("FwdHead"))(
		{layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}},
		) {
			clay.Text(
				tr(ui.fwd_kind == .Theme ? "Share theme with" : "Forward to"),
				{fontId = FONT_TITLE, fontSize = 20, textColor = TEXT},
			)
			if clay.UI(clay.ID("FwdHeadGap"))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if clay.UI(clay.ID("FwdClose"))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(26), height = clay.SizingFixed(26)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(7),
			},
			) {
				clay.Text(ICON_CLOSE, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_DIM})
			}
		}

		if clay.UI(clay.ID("FwdFilter"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(36)},
				padding = {left = 12, right = 12},
				childAlignment = {y = .Center},
			},
			backgroundColor = ROW_BG,
			cornerRadius = rr(8),
			border = {color = ui.focus == .Fwd ? ACCENT : FIELD_BORDER, width = bw()},
		},
		) {
			field_text(
				ui,
				"FwdFilter",
				&ui.fwd_filter,
				"Filter chats",
				ui.focus == .Fwd,
				13,
				TEXT_LO,
			)
		}

		if clay.UI(clay.ID("FwdList"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow(), height = clay.SizingFit({max = 320})},
				layoutDirection = .TopToBottom,
				childGap = 2,
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			for chat, i in ui.chats {
				if !fwd_visible(ui, i) {
					continue
				}
				if clay.UI(clay.ID("FwdRow", u32(i)))(
				{
					layout = {
						sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(44)},
						padding = {left = 10, right = 10},
						childGap = 10,
						childAlignment = {y = .Center},
					},
					backgroundColor = hovered() ? HOVER : {},
					cornerRadius = rr(8),
				},
				) {
					avatar("FwdAvatar", u32(i), chat.avatar_key, chat.title, 30, chat_pic(chat))
					clay.Text(chat.title, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
				}
			}
		}
		scrollbar(clay.ID("FwdList"), 14) // the modal floats at 13
	}
}

// Pending_Send owns the snapshot until preparation finishes or its failed row
// is deleted. Workers never borrow the timeline page or a chat-list index.
Forward_Job :: struct {
	client:          ^marmot.Client,
	account, source: cstring,
	refs:            []marmot.Media_Attachment_Reference,
	invalid:         bool,
	mutex:           sync.Mutex,
	done, ok:        bool,
	atts:            [dynamic]Pending_Att,
	images:          [dynamic]rl.Image,
}

@(private)
forward_source :: proc(ui: ^Ui_State) -> int {
	if ui.selected < 0 ||
	   ui.selected >= len(ui.chats) ||
	   ui.chats[ui.selected].group_id != ui.fwd_source {return -1}
	for msg, i in ui.messages {if msg.id == ui.fwd_msg {return i}}
	return -1
}

@(private)
forward_snapshot :: proc(ui: ^Ui_State, client: ^marmot.Client) -> ^Forward_Job {
	job := new(Forward_Job)
	job.client = client
	job.account = strings.clone_to_cstring(ui.account_ref)
	job.source = strings.clone_to_cstring(ui.fwd_source)
	job.invalid = true
	if timeline_page == nil {return job}
	for &record in timeline_page.messages[:timeline_page.messages_len] {
		if string(record.message_id_hex) != ui.fwd_msg {continue}
		job.invalid = record.media_len == 0
		job.refs = make([]marmot.Media_Attachment_Reference, record.media_len)
		for &r, i in job.refs {
			ref := media_reference(&record, i)
			if ref == nil {job.invalid = true; continue}
			r = ref^
			for field in ([]^cstring{&r.ciphertext_sha256, &r.plaintext_sha256, &r.nonce_hex, &r.file_name, &r.media_type, &r.dim, &r.thumbhash}) {
				if field^ != nil {field^ = strings.clone_to_cstring(string(field^))}
			}
			locators := make([]marmot.Media_Locator, r.locators_len)
			for locator, j in r.locators[:r.locators_len] {
				locators[j] = {
					strings.clone_to_cstring(string(locator.kind)),
					strings.clone_to_cstring(string(locator.value)),
				}
			}
			r.locators = raw_data(locators)
		}
		break
	}
	return job
}

@(private)
forward_payload_clear :: proc(job: ^Forward_Job) {
	for a in job.atts {delete(a.name); delete(a.dim); delete(a.data)}
	delete(job.atts); job.atts = {}
	for image in job.images {if image.data != nil {rl.UnloadImage(image)}}
	delete(job.images); job.images = {}
}

@(private)
forward_free :: proc(job: ^Forward_Job) {
	if job == nil {return}
	forward_payload_clear(job)
	for &r in job.refs {
		for field in ([]cstring{r.ciphertext_sha256, r.plaintext_sha256, r.nonce_hex, r.file_name, r.media_type, r.dim, r.thumbhash}) {
			if field != nil {delete(field)}
		}
		for locator in r.locators[:r.locators_len] {delete(locator.kind); delete(locator.value)}
		delete(r.locators[:r.locators_len])
	}
	delete(job.refs); delete(job.account); delete(job.source); free(job)
}

@(private)
forward_worker :: proc(t: ^thread.Thread) {
	context.allocator = reload_allocator()
	defer free_all(context.temp_allocator)
	job := (^Forward_Job)(t.data)
	defer {
		sync.lock(&job.mutex); job.done = true; sync.unlock(&job.mutex)
		frame_wake()
	}
	if job.invalid {return}
	for &reference in job.refs {
		result: ^marmot.Media_Download_Result
		if marmot.download_media(job.client, job.account, job.source, &reference, &result) != .OK {
			fmt.eprintfln("forward: download failed: %s", marmot.last_error())
			forward_payload_clear(job)
			return
		}
		name :=
			result.file_name != nil && len(string(result.file_name)) > 0 ? string(result.file_name) : "attachment"
		att := Pending_Att {
			name       = strings.clone(name),
			media_type = media_type_for(name),
			data       = make([]u8, result.plaintext_len),
			dim        = strings.clone(string(reference.dim)),
		}
		copy(att.data, result.plaintext[:result.plaintext_len])
		marmot.media_download_result_free(result)
		image: rl.Image
		if strings.has_prefix(att.media_type, "image/") && len(att.data) <= 64 * 1024 * 1024 {
			image = rl.LoadImageFromMemory(
				"",
				raw_data(att.data),
				i32(len(att.data)),
				4096,
				64 * 1024 * 1024,
			)
			if image.data != nil {
				if att.dim == "" {att.dim = fmt.aprintf("%dx%d", image.width, image.height)}
				image = sticker_thumb(image)
			}
		}
		append(&job.atts, att); append(&job.images, image)
	}
	job.ok = true
}

@(private)
forward_start :: proc(p: ^Pending_Send) {
	job := p.forward
	job.done, job.ok = false, false
	p.sending_since = time.tick_now()
	t := thread.create(forward_worker)
	t.data = job
	append(&send_threads, t)
	thread.start(t)
}

// Keep one preparation row until every attachment is ready. No text is sent
// on a partial download failure; retry still owns the original source refs.
@(private)
drain_forwards :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	for i := len(ui.pending) - 1; i >= 0; i -= 1 {
		p := &ui.pending[i]
		job := p.forward
		if job == nil || p.failed {continue}
		sync.lock(&job.mutex); done := job.done; sync.unlock(&job.mutex)
		if !done {continue}
		if p.dismissed {free_pending(p); ordered_remove(&ui.pending, i); continue}
		if !job.ok {
			p.failed = true
			ui.client_status = strings.clone("Couldn't forward. Please try again.")
			continue
		}
		p.atts = job.atts; job.atts = {}
		for &att, j in p.atts {
			image := job.images[j]
			if image.data == nil {continue}
			att.tex = new(rl.Texture2D)
			is_sticker :=
				p.sticker.sha != "" && p.sticker.sha == string(job.refs[j].plaintext_sha256)
			att.tex^ = is_sticker ? sticker_texture_load(image) : rl.LoadTextureFromImage(image)
		}
		forward_free(job); p.forward = nil
		// Text and album remain separate sends, with the effect on the album.
		text: Pending_Send
		if p.body != "" {
			send_ticket += 1
			text = Pending_Send {
				ticket        = send_ticket,
				visible_since = p.visible_since,
				group_id      = strings.clone(p.group_id),
				account_ref   = strings.clone(p.account_ref),
				sender        = strings.clone(p.sender),
				forward_title = strings.clone(p.forward_title),
				body          = p.body,
			}
			p.body = ""
		}
		if text.ticket != 0 {
			spawn_send(ui, client, &text)
		}
		spawn_send(ui, client, p)
		if text.ticket != 0 {
			append(&ui.pending, text)
		}
	}
}

do_forward :: proc(ui: ^Ui_State, client: ^marmot.Client, dest: int) {
	index := forward_source(ui)
	if index < 0 || dest < 0 || dest >= len(ui.chats) {return}
	msg := ui.messages[index]
	if msg.body == "" && len(msg.att_names) == 0 {return}
	info := profile_info(client, ui.account_ref)
	send_ticket += 1
	p := Pending_Send {
		ticket        = send_ticket,
		visible_since = time.tick_now(),
		group_id      = strings.clone(ui.chats[dest].group_id),
		account_ref   = strings.clone(ui.account_ref),
		forward_title = strings.clone(ui.chats[dest].title),
		sender        = strings.clone(info.name != "" ? info.name : "you"),
		body          = strings.clone(msg.body),
		effect        = msg.effect,
	}
	if len(msg.att_names) > 0 {
		p.sticker = sticker_ref_clone(msg.sticker)
		p.forward = forward_snapshot(ui, client)
	}
	append(&ui.pending, p)
	spawn_send(ui, client, &ui.pending[len(ui.pending) - 1])
}

// The destination need not be open. Keep its forwarding status in the shell
// through download, upload and failure, even while the user changes chats.
@(private)
forward_progress :: proc(ui: ^Ui_State) {
	chosen := -1
	for p, i in ui.pending {
		if p.forward_title == "" || p.dismissed || p.account_ref != ui.account_ref {continue}
		if chosen < 0 || (ui.pending[chosen].failed && !p.failed) {chosen = i}
	}
	if chosen < 0 {return}
	p := ui.pending[chosen]
	if clay.UI(clay.ID("ForwardProgress"))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = clay.PaddingAll(8),
			childGap = 8,
			childAlignment = {y = .Center},
		},
		backgroundColor = CARD,
	},
	) {
		label :=
			p.failed ? tr("Couldn't forward to %s. Open the chat to retry.") : p.forward != nil ? tr("Preparing attachments for %s…") : tr("Forwarding to %s…")
		clay.Text(
			fmt.tprintf(label, p.forward_title),
			{fontId = FONT_BODY, fontSize = 12, textColor = p.failed ? DANGER : TEXT_DIM},
		)
		if !p.failed {
			anim_moving += 1
			if clay.UI(clay.ID("ForwardTrack"))(
			{
				layout = {sizing = {width = clay.SizingFixed(100), height = clay.SizingFixed(3)}},
				backgroundColor = FIELD_BORDER,
			},
			) {
				if clay.UI(clay.ID("ForwardBar"))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(24), height = clay.SizingFixed(3)},
					},
					backgroundColor = ACCENT,
					floating = {
						attachTo = .Parent,
						offset = {f32(38 * (1 + f32(math.sin(rl.GetTime() * 4)))), 0},
					},
				},
				) {}
			}
		}
	}
}

@(private)
forward_stop :: proc(ui: ^Ui_State) {
	// send_threads have joined; decoded pixels are outside the tracked heap.
	for &p in ui.pending {forward_free(p.forward); p.forward = nil}
	delete(ui.fwd_msg); delete(ui.fwd_source)
}

// Click/keyboard handling for the open forward picker; anything
// outside the modal dismisses it.
handle_forward :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	// A forward needs its source message to still exist; a theme share
	// carries its own payload and does not.
	stale := ui.fwd_kind == .Message && forward_source(ui) < 0
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
