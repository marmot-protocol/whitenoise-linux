package main

import "core:fmt"
import "core:strings"
import "core:time"

import "nendo"
import rl "sdlrl"

import marmot "../marmot"

@(private)
PENDING_DELETE_DELAY :: 30 * time.Second

@(private)
pending_can_delete :: proc(p: Pending_Send, now: time.Tick) -> bool {
	return(
		!p.dismissed &&
		(p.failed ||
				p.queued ||
				(p.sending_since != {} &&
						time.tick_diff(p.sending_since, now) >= PENDING_DELETE_DELAY)) \
	)
}

// Per-attachment and per-reaction nendo ids share one band per message row,
// so the same label can repeat on every row without colliding:
//
//   row 0: 0 ..< 1024   row 1: 1024 ..< 2048   row n: n * 1024 + slot
//
// Pending rows use the same layout for their image previews.
// ponytail: slot 1024 of row n aliases slot 0 of row n + 1, so the excess
// attachment or reaction chip stops taking hovers and clicks. Widen the
// stride, or scope these ids under the row's element, if a message can
// carry that many.
@(private)
MSG_SLOT_STRIDE :: 1024

// nendo id seed for slot `slot` (attachment or reaction) of message row `index`.
@(private)
msg_slot_id :: proc(index: u32, slot: int) -> u32 {
	return index * MSG_SLOT_STRIDE + u32(slot)
}

pending_row :: proc(index: u32, ui: ^Ui_State, p: Pending_Send) {
	if p.dismissed {
		return
	}
	body_color := p.failed ? DANGER : TEXT_DIM
	can_delete := pending_can_delete(p, time.tick_now())
	if nendo.box(nendo.id("PendingRow", index))(
	{
		width = nendo.grow(),
		padding = {left = 16, right = 16, top = 6, bottom = 6},
		gap = 10,
		color = hovered() ? HOVER : {},
	},
	) {
		avatar("PendingAvatar", index, ui.account_ref, p.sender, 28, url_pic(ui.my_pic_url))
		if nendo.box(nendo.id("PendingCol", index))(
		{width = nendo.grow(), direction = .Column, gap = 3},
		) {
			if nendo.box(nendo.id("PendingHead", index))(
			{
				width = nendo.grow(),
				direction = single_pane() ? .Column : .Row,
				gap = 8,
				align = {y = .Center},
			},
			) {
				nendo.text(p.sender, {font = FONT_TITLE, size = 13, color = TEXT_DIM})
				nendo.text(
					p.failed ? tr("Failed") : p.queued ? tr("Queued") : p.forward != nil ? tr("Preparing attachments…") : tr("Sending..."),
					{font = FONT_BODY, size = 11, color = p.failed ? DANGER : TEXT_LO},
				)
				if can_delete {
					if nendo.box(nendo.id("PendingDelete", index))(
					{
						height = nendo.fit(min = tap_size() ? tap_min() : 0),
						padding = nendo.pad(4),
						align = {y = .Center},
						color = hovered() ? HOVER : {},
						radius = rr(4),
					},
					) {
						nendo.text(
							tr("Delete for me"),
							{font = FONT_BODY, size = 11, color = DANGER},
						)
					}
				}
			}

			if p.gif != nil && !p.failed {
				anim_moving += 1
				if nendo.box(nendo.id("PendingGifTrack", index))(
				{width = nendo.fixed(100), height = nendo.fixed(3), color = FIELD_BORDER},
				) {
					if nendo.box(nendo.id("PendingGifBar", index))(
					{
						width = nendo.fixed(30),
						height = nendo.fixed(3),
						floating = {
							attach_to = .Parent,
							offset = {f32(anim_frame % 90) / 90 * 70, 0},
							attach = {element = .Left_Top, parent = .Left_Top},
						},
						color = ACCENT,
					},
					) {}
				}
			}

			for a, j in p.atts {
				if a.tex == nil {
					continue
				}
				ratio := a.tex.height > 0 ? f32(a.tex.width) / f32(a.tex.height) : 1
				if nendo.box(nendo.id("PendingImage", msg_slot_id(index, j)))(
				{
					width = nendo.fixed(
						p.sticker.sha != "" ? min(att_w(), min(220, 220 * ratio)) : att_w(),
					),
					aspect = ratio,
					image = a.tex,
					user_data = p.sticker.sha != "" ? rawptr(STICKER_IMAGE) : nil,
					radius = rr(8),
				},
				) {}
			}

			if !message_excerpt(0xF00000 + index * 8, p.body, body_color, p.excerpt) {
				body_text(
					0xF00000 + index * 8,
					p.body,
					14,
					body_color,
					wrap_w = body_wrap_w(),
					emoji = .Jumbo,
				)
			}
			if can_delete {
				if nendo.box(nendo.id("PendingDeleteEnd", index))(
				{
					height = nendo.fit(min = tap_size() ? tap_min() : 0),
					padding = nendo.pad(4),
					align = {y = .Center},
					color = hovered() ? HOVER : {},
					radius = rr(4),
				},
				) {
					nendo.text(tr("Delete for me"), {font = FONT_BODY, size = 11, color = DANGER})
				}
			}
			if p.failed {
				nendo.text(
					tr("failed · tap to retry"),
					{font = FONT_BODY, size = 11, color = DANGER},
				)
			}
		}
	}
}

// Gap between mosaic cells, both axes.
ALBUM_GAP :: 4

// Failed image cell under the pointer (its cache key), rebound every
// build.
img_retry_hover: string

// Click on a failed cell: forget the cached failure and reload, which
// re-kicks the download.
handle_img_retry :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if img_retry_hover == "" || !mouse_released() {
		return
	}
	key, _ := delete_key(&media_textures, img_retry_hover)
	delete(key)
	img_retry_hover = ""
	load_timeline(client, ui)
}

// Reply preview under the pointer (the parent's message id), rebound
// every build.
reply_jump_hover: string

// Click a reply preview: center a parent in this view, or explain why
// the quote cannot jump without changing another pending scroll.
handle_reply_jump :: proc(ui: ^Ui_State) {
	if reply_jump_hover == "" || !mouse_released() {
		return
	}
	defer reply_jump_hover = ""
	for msg, i in ui.messages {
		if msg.id != reply_jump_hover {continue}
		if !nendo.element(nendo.id("MsgRow", u32(i))).found {break}
		delete(ui.jump_id)
		ui.jump_id = strings.clone(reply_jump_hover)
		gs_flash_jump(ui, ui.jump_id)
		ui.reading_pending = {}
		return
	}
	toast(ui, tr("The original message isn't loaded in this view."))
}

// Failed-media banner under the pointer, rebound every build.
media_retry_hover: bool

// Click the banner: forget every cached failure (nil view) so the
// reload re-kicks the downloads, same shape as handle_img_retry but
// covering the video/audio/mesh/gcode/pdf caches.
handle_media_retry :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	if !media_retry_hover || !mouse_released() {
		return
	}
	media_retry_hover = false
	drop_nil_views(&video_views)
	drop_nil_views(&stl_views)
	drop_nil_views(&gcode_views)
	drop_nil_views(&pdf_views)
	load_timeline(client, ui)
}

@(private = "file")
drop_nil_views :: proc(views: ^map[string]^$T) {
	stale := make([dynamic]string, context.temp_allocator)
	for key, view in views {
		if view == nil {
			append(&stale, key)
		}
	}
	for key in stale {
		k, _ := delete_key(views, key)
		delete(k)
	}
}

// "1.4 MB" when this session has seen the blob's bytes, "" otherwise
// (the imeta tag carries no size; see blob_sizes).
att_size_label :: proc(msg: Msg_Ui, att: int) -> string {
	if att < len(msg.attachments) {
		if size, ok := blob_sizes[msg.attachments[att].key]; ok {
			return human_size(size)
		}
	}
	return ""
}

// "m:ss" playback stamp for the audio tile.
fmt_clock :: proc(s: f64) -> string {
	total := int(max(s, 0))
	return fmt.tprintf("%d:%02d", total / 60, total % 60)
}

// Audio tile: mpv plays the decrypted bytes through its own ao; the
// tile is the controls (play/pause, scrub bar, size + position).
audio_tile :: proc(
	id: u32,
	msg: Msg_Ui,
	att: int,
	name: string,
	size_label: string,
	view: ^Video_View,
) {
	msg_id := msg.id
	if nendo.box(nendo.id("MsgAudio", id))(
	{
		width = nendo.fixed(att_w()),
		padding = nendo.pad(10),
		gap = 10,
		direction = .Column,
		color = PLATE,
		radius = rr(8),
	},
	) {
		att_dl_button("DlAud", id, msg_id, att, name)
		if nendo.box(nendo.id("MsgAudioControls", id))(
		{width = nendo.grow(), gap = 10, align = {y = .Top}},
		) {
			if nendo.box(nendo.id("MsgAudioPlay", id))(
			{
				width = nendo.fixed(tap_size() ? tap_min() : 36),
				height = nendo.fixed(tap_size() ? tap_min() : 36),
				align = {x = .Center, y = .Center},
				color = ACCENT,
				radius = rr(18),
			},
			) {
				if hovered() {
					video_hover = view // handle_video cycles pause
				}
				nendo.text(
					view.paused ? "" : "",
					{font = FONT_ICON, size = 14, color = ON_ACCENT},
				)
			}
			if nendo.box(nendo.id("MsgAudioCol", id))(
			{
				width = nendo.fixed(max(1, att_w() - (tap_size() ? 74 : 66))),
				direction = .Column,
				gap = 6,
			},
			) {
				if nendo.box(nendo.id("MsgAudioName", id))(
				{width = nendo.grow(), clip = {x = true}},
				) {
					nendo.text(name, {font = FONT_TITLE, size = 12, color = TEXT, wrap = .None})
					if hovered() {
						tooltip(name)
					}
				}

				bar_id := nendo.id("MsgAudioBar", id)
				append(&video_bars, Video_Bar{bar_id, view})
				bar_w := max(1, att_w() - (tap_size() ? 74 : 66))
				frac := view.dur > 0 ? clamp(f32(view.time / view.dur), 0, 1) : 0
				if nendo.box(bar_id)(
				{
					width = nendo.grow(),
					height = nendo.fixed(tap_size() ? tap_min() : 14),
					padding = {left = 2, right = 2},
					align = {y = .Center},
					color = ROW_BG,
					radius = rr(7),
				},
				) {
					if nendo.box(nendo.id("MsgAudioFill", id))(
					{
						width = nendo.fixed(max(2, frac * (bar_w - 4))),
						height = nendo.fixed(10),
						color = ACCENT,
						radius = rr(5),
					},
					) {}
				}

				if nendo.box(nendo.id("MsgAudioMeta", id))(
				{width = nendo.grow(), direction = single_pane() ? .Column : .Row, gap = 8},
				) {
					if len(size_label) > 0 {
						nendo.text(size_label, {font = FONT_BODY, size = 11, color = TEXT_DIM})
					}
					if nendo.box(nendo.id("MsgAudioPad", id))({width = nendo.grow()}) {}
					nendo.text(
						fmt.tprintf("%s / %s", fmt_clock(view.time), fmt_clock(view.dur)),
						{font = FONT_BODY, size = 11, color = TEXT_DIM},
					)
				}
				if g_ui.prefs.stt_enabled {
					active :=
						g_ui.stt.file != nil &&
						g_ui.stt.message == msg_id &&
						g_ui.stt.attachment == att
					button := fmt.tprintf("AudioTranscribe%d", id)
					// Keep every card the same height while recognition starts and stops.
					if nendo.box(nendo.id("AudioTranscribeRow", id))(
					{
						width = nendo.grow(),
						height = tap_size() ? nendo.fit(min = 44) : nendo.fixed(31),
						direction = single_pane() ? .Column : .Row,
						gap = 8,
						align = {y = .Center},
					},
					) {
						label :=
							active ? N_("Transcribing...") : view.transcript_done ? (view.transcript_open ? N_("Collapse transcription") : N_("View transcription")) : N_("Transcribe")
						micro_button(
							button,
							tr(label),
							active || (!view.transcript_done && g_ui.stt.file != nil) ? TEXT_LO : {},
						)
						if active {
							cancel := fmt.tprintf("AudioSttCancel%d", id)
							micro_button(cancel, tr("Cancel"))
							if nendo.pointer_over(nendo.id(cancel)) {stt_hover = {
									message    = msg_id,
									attachment = att,
									action     = .Cancel,
								}}
						}
					}
					if nendo.pointer_over(nendo.id(button)) &&
					   !active &&
					   (view.transcript_done || g_ui.stt.file == nil) {
						stt_hover = {
							message    = msg_id,
							attachment = att,
							view       = view,
							action     = view.transcript_done ? .Toggle : .Transcribe,
						}
					}
				}
			}
		}
		if view.transcript_open && view.transcript != "" {
			result := translation_lookup(g_ui, msg, .Transcript, att)
			text :=
				result != nil && result.phase == .Ready && result.show ? result.text : view.transcript
			nendo.text(text, {font = FONT_BODY, size = 12, color = TEXT})
			if result != nil {
				translation_controls(g_ui, id, msg, .Transcript, att)
			} else if translation_eligible(g_ui, msg, .Transcript, att) {
				micro_button(fmt.tprintf("TranscriptTranslationStart%d", id), tr("Translate"))
			}
		}
	}
}

// Group-system line (kind-1210): one dim sentence in a centered pill.
// No avatar, no actions, no message chrome.
// Centered by grow spacers, like the unread divider (a cross-axis
// x=center child drops in this nendo build, quirks).
system_row :: proc(index: u32, msg: Msg_Ui) {
	if nendo.box(nendo.id("SysRow", index))(
	{
		width = nendo.grow(),
		padding = {left = 16, right = 16, top = 4, bottom = 4},
		align = {y = .Center},
	},
	) {
		if nendo.box(nendo.id("SysGapL", index))({width = nendo.grow()}) {}
		if nendo.box(nendo.id("SysPill", index))(
		{
			padding = {left = 12, right = 12, top = 4, bottom = 4},
			gap = 8,
			align = {y = .Center},
			color = PLATE,
			radius = rr(11),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			if len(msg.sys_text) > 0 {
				segs := inline_segs(msg.sys_text)
				render_segs(0xD00000 + index * 8, segs[:], 11, TEXT_LO, 14, chips = true)
			} else {
				nendo.text(msg.body, {font = FONT_BODY, size = 11, color = TEXT_LO})
			}
			if len(msg.sys_added_hex) > 0 &&
			   (g_ui == nil || msg.sys_added_hex != g_ui.account_ref) {
				action_chip("SysWave", index, tr("Wave hi"))
			}
			nendo.text(msg.at, {font = FONT_MONO, size = 10, color = TEXT_LO})
		}
		if nendo.box(nendo.id("SysGapR", index))({width = nendo.grow()}) {}
	}
}

// A row from someone you blocked. Consecutive ones collapse behind one
// blocked_run_row until you reveal them, like Discord:
//
//   [ban] 3 blocked messages  [Show]     collapsed, rows not built
//   [ban] 3 blocked messages  [Hide]     revealed, rows follow
@(private)
msg_blocked :: proc(ui: ^Ui_State, msg: Msg_Ui) -> bool {
	return !msg.system && !msg.mine && ui.blocked[msg.sender_id]
}

// Rows in the blocked run starting at `start`. The run ends where the
// timeline loop draws something between rows: a day or unread marker.
@(private)
blocked_run_len :: proc(ui: ^Ui_State, start: int) -> int {
	first := ui.messages[start]
	count := 0
	for msg, j in ui.messages[start:] {
		if msg.thread_of != first.thread_of {continue}
		if msg.day != first.day || !msg_blocked(ui, msg) {break}
		if j > 0 && msg.id == ui.unread_mark_id {break}
		count += 1
	}
	return count
}

@(private)
blocked_run_row :: proc(index: u32, count: int, open: bool) {
	if nendo.box(nendo.id("BlockedRun", index))(
	{
		width = nendo.grow(),
		padding = {left = 16, right = 16, top = 4, bottom = 4},
		gap = 8,
		align = {y = .Center},
	},
	) {
		nendo.text(ICON_BAN, {font = FONT_ICON, size = 12, color = TEXT_LO})
		nendo.text(
			fmt.tprintf(
				tr(count == 1 ? N_("%d blocked message") : N_("%d blocked messages")),
				count,
			),
			{font = FONT_BODY, size = 12, color = TEXT_DIM},
		)
		action_chip("BlockedToggle", index, open ? tr("Hide") : tr("Show"))
	}
}

// Floating jump-to-latest over the timeline's bottom-right, shown once
// the view sits more than a screen above the newest message; the click
// (handle_chat) re-arms the bottom jump.
JUMP_SIZE :: f32(36)
JUMP_DROP :: f32(14) // px it sinks toward the corner as it leaves

jump_latest_button :: proc() {
	data := nendo.scroll(nendo.id("Timeline"))
	if !data.found {
		return
	}
	view_h := data.viewport.height
	overflow := data.content.height - view_h
	// scrollPosition.y runs 0 (top) to -overflow (bottom).
	above_bottom := overflow + data.position.y
	// Springs in and out rather than blinking on and off, and drops
	// back toward the corner it came from on the way out.
	if !open_now(nendo.id("JumpLatest"), overflow > 0 && above_bottom >= view_h) {
		return
	}
	t := open_t(nendo.id("JumpLatest"))
	target_size := tap_size() ? f32(44) : JUMP_SIZE
	size := target_size * t

	if nendo.box(nendo.id("JumpLatest"))(
	{
		width = nendo.fixed(size),
		height = nendo.fixed(size),
		align = {x = .Center, y = .Center},
		floating = {
			attach_to = .Element,
			parent = nendo.id("Timeline").id,
			z = 8,
			pointer = .Capture,
			offset = {-16 - (target_size - size) / 2, -16 + (1 - t) * JUMP_DROP},
			attach = {element = .Right_Bottom, parent = .Right_Bottom},
		},
		color = fade(hovered() ? ACCENT : CARD, t),
		radius = rr(size / 2),
		border = {color = fade(ELEVATED_BORDER, t), width = bw()},
	},
	) {
		nendo.text(
			ICON_DOWN,
			{font = FONT_ICON, size = 14, color = fade(hovered() ? ON_ACCENT : TEXT_DIM, t)},
		)
	}
}

DEL_SECS :: 0.32
TOMBSTONE_H :: f32(34) // the height of the "message was deleted" line

// When each row was first seen deleted, and how tall it was just
// before.
// ponytail: one entry per deleted message, never collected. Deletes are
// rare; a per-chat map is the upgrade if that stops being true.
del_seen: map[string]struct {
	at:   f64,
	from: f32,
}

// Height for a row mid-collapse, and whether it is still collapsing.
// The body is already gone from the model by the time the tombstone
// arrives, so what animates is the row closing to the tombstone's size.
delete_collapse :: proc(index: u32, id: string) -> (h: f32, active: bool, started: bool) {
	entry, seen := del_seen[id]
	started = !seen
	if !seen {
		entry = {rl.GetTime(), TOMBSTONE_H}
		if box := nendo.element(nendo.id("MsgRow", index)); box.found {
			entry.from = box.rect.height
		}
		del_seen[strings.clone(id)] = entry
	}
	t := f32(clamp((rl.GetTime() - entry.at) / DEL_SECS, 0, 1))
	if t >= 1 || entry.from <= TOMBSTONE_H {
		return 0, false, started
	}
	anim_moving += 1
	return entry.from + (TOMBSTONE_H - entry.from) * ease_out(t), true, started
}

COUNT_FS :: u16(12)
COUNT_LINE :: f32(15) // one line of COUNT_FS, the roll's travel

// A number that changed rolls: the old one leaves upward as the new one
// arrives from below, inside a one-line clip. nendo gives clip elements a
// child offset (it is how scrolling works), which is the whole trick.
count_roll :: proc(slot: u32, count: string, was: string, t: f32) {
	if len(was) == 0 || t >= 1 {
		nendo.text(count, {font = FONT_BODY, size = COUNT_FS, color = TEXT})
		return
	}
	if nendo.box(nendo.id("ReactRoll", slot))(
	{
		height = nendo.fixed(COUNT_LINE),
		direction = .Column,
		clip = {y = true, offset = {0, -t * COUNT_LINE}},
	},
	) {
		nendo.text(was, {font = FONT_BODY, size = COUNT_FS, color = TEXT_LO})
		nendo.text(count, {font = FONT_BODY, size = COUNT_FS, color = TEXT})
	}
}

// Image cells: albums lay out as a justified mosaic. Each row gets one
// height and cell widths follow each image's aspect
// (h = row_width / sum(aspects)); extreme ratios are cropped so
// screenshots cannot collapse into tiny strips. A leading landscape
// image is promoted to a full-width hero and a greedy fill packs the
// rest 2-3 per row, stopping once the row is tight enough. The shape
// therefore varies with the aspect mix, like the telegram album
// layouter. Failed cells ride along as 4:3 retry plates. `cells` is a
// run of image slots starting at source index `first`.
@(private)
Album_Source :: enum {
	Attachments,
	Links,
}

@(private)
image_album :: proc(
	index: u32,
	msg: Msg_Ui,
	first: int,
	cells: []Att_Slot,
	source := Album_Source.Attachments,
	width: f32 = 0,
) {
	if source == .Links {
		for &cell in cells {
			if tex := nev_img(cell.key);
			   tex != nil && tex.width > 0 && tex.height > 0 {cell.view = tex}
		}
	}
	aspect :: proc(cell: Att_Slot) -> f32 {
		if tex, ok := cell.view.(^rl.Texture2D); ok && tex.height > 0 {
			return clamp(f32(tex.width) / f32(tex.height), 0.5, 3)
		}
		return 4.0 / 3.0
	}
	Mosaic_Row :: struct {
		start, count: int,
		h:            f32,
	}
	n := len(cells)
	album_w := att_w(n == 1 ? 480 : 400)
	if width > 0 {album_w = min(album_w, width)}
	// Four portrait screenshots read as two pairs, not three tiny cells and an orphan.
	paired := n == 4
	if paired {
		for cell in cells {if aspect(cell) >= 1 {paired = false; break}}
	}
	rows := make([dynamic]Mosaic_Row, context.temp_allocator)
	i := 0
	if n >= 3 && aspect(cells[0]) >= 1.15 {
		append(&rows, Mosaic_Row{0, 1, 0})
		i = 1
	}
	for i < n {
		start := i
		sum: f32
		for i < n && i - start < (paired ? 2 : 3) {
			sum += aspect(cells[i])
			i += 1
			// Tight enough: stop before the row gets short.
			if !paired && (album_w - ALBUM_GAP * f32(i - start - 1)) / sum <= 120 {
				break
			}
		}
		append(&rows, Mosaic_Row{start, i - start, 0})
	}
	for &row in rows {
		sum: f32
		for c in cells[row.start:row.start + row.count] {
			sum += aspect(c)
		}
		row.h = min((album_w - ALBUM_GAP * f32(row.count - 1)) / sum, 320)
	}

	id_base := source == .Links ? index : msg_slot_id(index, 0)
	if nendo.box(nendo.id(source == .Links ? "LinkAlbum" : "MsgAlbum", id_base + u32(first)))(
	{direction = .Column, gap = ALBUM_GAP},
	) {
		for row in rows {
			if nendo.box(
				nendo.id(
					source == .Links ? "LinkImgRow" : "MsgImgRow",
					id_base + u32(first + row.start),
				),
			)(
				{gap = ALBUM_GAP},
			) {
				for cell, k in cells[row.start:row.start + row.count] {
					att := first + row.start + k
					cell_id := id_base + u32(att)
					cw := row.h * aspect(cell)
					tex, ready := cell.view.(^rl.Texture2D)
					if !ready {
						if nendo.box(
							nendo.id(source == .Links ? "LinkImgFallback" : "MsgImgFail", cell_id),
						)(
							{
								width = nendo.fixed(cw),
								height = nendo.fixed(row.h),
								padding = nendo.pad(10),
								align = {x = .Center, y = .Center},
								color = hovered() ? HOVER : PLATE,
								radius = rr(8),
							},
						) {
							if source == .Links {
								if hovered() {link_hover = cell.key; cursor_raise(.Pointer)}
								nendo.text(
									text_ellipsis(cell.key, max(1, cw - 20), FONT_BODY, 11),
									{font = FONT_BODY, size = 11, color = ACCENT},
								)
								continue
							}
							if hovered() {
								img_retry_hover = cell.key
							}
							nendo.text(
								tr("Couldn't load image. Click to retry."),
								{font = FONT_BODY, size = 11, color = TEXT_DIM},
							)
						}
						continue
					}
					view := new(Image_Crop, context.temp_allocator)
					view^ = {
						kind = .Image_Crop,
						tex  = tex,
					}
					if nendo.box(nendo.id(source == .Links ? "LinkImage" : "MsgImage", cell_id))(
					{
						width = nendo.fixed(cw),
						height = nendo.fixed(row.h),
						custom = view,
						radius = rr(8),
					},
					) {
						if source == .Links {
							if hovered() {
								img_link_hover, img_link_cells = cell.key, cells
								cursor_raise(.Pointer)
							}
							continue
						}
						// Click opens the lightbox slideshow on this image
						// (handle_img_click; dl chip wins via att_hover).
						if hovered() {
							img_hover = {
								msg_id = msg.id,
								att    = att,
							}
						}
						att_dl_button("DlImg", cell_id, msg.id, att, cell.name)
					}
				}
			}
		}
	}
}

// Discord-style grouping: a row continues the one above it when the same
// sender posts again within GROUP_WINDOW_SECS of the run's first row, with
// no one else in between, while the run stays under GROUP_LINES lines of
// text. A continued row drops the avatar and the name/time head.
//
//   [av] Danny 15:35
//        first message
//        second message      <- .Continued, time shows in the gutter on hover
GROUP_WINDOW_SECS :: 5 * 60
GROUP_LINES :: 15

Msg_Head :: enum u8 {
	Full,
	Continued,
}

// The run the next row may join. Zero value = no run (start of the list,
// or right after a marker, system line, or tombstone).
Msg_Run :: struct {
	sender: string,
	start:  u64, // head row's timestamp, seconds
	lines:  int,
}

// `wrap_w` is the body column width (body_wrap_w), so the budget counts
// lines as drawn: one long paragraph that wraps to 20 lines is 20.
msg_run_step :: proc(run: ^Msg_Run, msg: Msg_Ui, wrap_w: f32) -> Msg_Head {
	if msg.system || msg.deleted {
		run^ = {}
		return .Full
	}
	at := msg.sort_at > 100_000_000_000 ? msg.sort_at / 1000 : msg.sort_at
	lines := len(wrapped_lines(msg.body, wrap_w, BODY_FS, .Cards))
	if run.sender != "" &&
	   msg.sender_id == run.sender &&
	   at >= run.start &&
	   at - run.start < GROUP_WINDOW_SECS &&
	   run.lines + lines < GROUP_LINES {
		run.lines += lines
		return .Continued
	}
	run^ = {msg.sender_id, at, lines}
	return .Full
}

// Hover actions for a row: in the head for a full row, floating at the
// row's top-right for a continued one.
@(private = "file")
msg_actions :: proc(index: u32, msg: Msg_Ui) {
	if g_ui != nil && g_ui.selected >= 0 && g_ui.chats[g_ui.selected].archived {return}
	// A reply can't carry a thread tag, so thread rows
	// offer Thread (nesting) instead of Reply.
	if len(msg.thread_of) == 0 {
		action_chip("MsgReply", index, tr("Reply"))
	}
	action_chip("MsgThread", index, tr("Thread"))
	if msg.mine {
		action_chip("MsgEdit", index, tr("Edit"))
		action_chip("MsgDel", index, tr("Delete"))
	}
}

MSG_PAD_Y :: u16(6) // a message row's vertical padding

message_row :: proc(index: u32, msg: Msg_Ui, head := Msg_Head.Full) {
	// A message that just landed glows in the accent surface and fades
	// back to the row's normal fill, so the eye is carried to it without
	// anything moving.
	fresh, landed := msg_fresh(msg.id)
	if landed && !msg.mine && (g_ui == nil || !g_ui.blocked[msg.sender_id]) {
		play_sound(.Receive)
	}
	// A deleted row shrinks into its tombstone rather than snapping to
	// it, so the message visibly goes away instead of being swapped.
	collapse_h, collapsing := f32(0), false
	if msg.deleted {
		started := false
		collapse_h, collapsing, started = delete_collapse(index, msg.id)
		// A message deleted while it was on screen comes apart. One
		// already deleted when the chat opened just is a tombstone:
		// `landed` marks the first sighting, which is that case.
		if started && collapsing && !landed {
			dissolve(msg.id)
		}
	}
	// A continued row sits tight under the one above it.
	pad_top := head == .Continued ? 0 : MSG_PAD_Y
	// The row whose text is in the composer holds the selected fill and
	// an accent rule, so it is clear which message the edit replaces.
	editing := g_ui != nil && len(msg.id) > 0 && g_ui.editing == msg.id
	replying := g_ui != nil && len(msg.id) > 0 && g_ui.replying == msg.id
	notes :=
		g_ui != nil &&
		g_ui.selected >= 0 &&
		g_ui.selected < len(g_ui.chats) &&
		g_ui.chats[g_ui.selected].group_id == g_ui.prefs.notes_group
	base := THEME_WALLPAPER != nil || BACKDROP != "" ? fade(BG, 0.94) : nendo.Color{}
	if msg.mine && !notes {base = mix_color(base, SELECTED, 0.22)}
	glow := max(fresh * 0.85, gs_jump_glow(msg.id))
	if nendo.box(nendo.id("MsgRow", index))(
	{
		width = nendo.grow(),
		height = collapsing ? nendo.fixed(collapse_h) : {},
		padding = {left = 16, right = 16, top = pad_top, bottom = MSG_PAD_Y},
		gap = 10,
		color = editing || replying ? SELECTED : mix_color(!rl.HasTouch() && hovered() ? HOVER : base, SELECTED, glow),
		border = editing || replying ? nendo.Border{color = ACCENT, width = {left = 3}} : (msg.mine && !notes ? nendo.Border{color = ACCENT_DIM, width = {left = 2}} : {}),
		clip = collapsing ? nendo.Clip{y = true} : {},
	},
	) {
		row_hovered := hovered()
		burst_layer(index, msg.id) // particle effect anchored to this row
		if notes {
			// Self notes need no repeated sender identity or avatar gutter.
		} else if head == .Full {
			peephole_avatar(
				"MsgAvatar",
				index,
				msg.sender_id,
				msg.sender,
				tap_size() ? tap_min() : 28,
				url_pic(msg.pic_url),
				nendo.pointer_over(nendo.id("MsgAvatar", index)) ? .Open : .Closed,
				fade(ACCENT, fresh),
			)
		} else {
			// The avatar's column, holding the time while hovered.
			if nendo.box(nendo.id("MsgGutter", index))(
			{
				width = nendo.fixed(tap_size() ? tap_min() : 28),
				padding = {top = 3},
				align = {x = .Center},
			},
			) {
				if row_hovered {
					nendo.text(
						msg.at,
						{font = FONT_BODY, size = 10, color = TEXT_LO, wrap = .None},
					)
				}
			}
			if !tap_size() && row_hovered && !msg.deleted {
				if nendo.box(nendo.id("MsgActions", index))(
				{
					gap = 8,
					floating = {
						attach_to = .Parent,
						clip_to = .Parent,
						pointer = .Passthrough,
						z = 6,
						offset = {-16, 0},
						attach = {element = .Right_Top, parent = .Right_Top},
					},
				},
				) {
					msg_actions(index, msg)
				}
			}
		}
		if nendo.box(nendo.id("MsgCol", index))(
		{width = nendo.grow(), direction = .Column, gap = 3},
		) {
			// The head reserves an action chip's height whether or not the
			// chips are showing, so hovering a row doesn't resize it. A
			// continued row has no head.
			if head == .Full && !notes {
				if nendo.box(nendo.id("MsgHead", index))(
				{
					width = nendo.grow(),
					height = nendo.fit(min = chip_h()),
					gap = 8,
					align = {y = .Center},
				},
				) {
					if nendo.box(nendo.id("MsgSender", index))(
					{
						width = tap_size() ? nendo.grow() : nendo.fit(),
						height = nendo.fit(min = tap_size() ? tap_min() : 0),
						clip = {x = true},
					},
					) {
						nendo.text(
							g_ui != nil && g_ui.nicknames[msg.sender_id] != "" ? g_ui.nicknames[msg.sender_id] : msg.sender,
							{font = FONT_TITLE, size = 13, color = TEXT, wrap = .None},
						)
					}
					if !tap_size() {if nendo.box(nendo.id("MsgTime", index))({}) {
							nendo.text(msg.at, {font = FONT_BODY, size = 11, color = TEXT_LO})
							// Full date on hover.
							if hovered() && len(msg.at_full) > 0 {
								if nendo.box(nendo.id("MsgTimeTip", index))(
								{
									padding = {left = 8, right = 8, top = 4, bottom = 4},
									floating = {
										attach_to = .Parent,
										z = 12,
										attach = {element = .Left_Bottom, parent = .Left_Top},
									},
									color = CARD,
									radius = rr(6),
									border = {color = ELEVATED_BORDER, width = bw()},
								},
								) {
									nendo.text(
										msg.at_full,
										{font = FONT_BODY, size = 11, color = TEXT},
									)
								}
							}
						}}

					// Row actions, shown while a pointer hovers the row. Kept
					// before any grow sibling (after-gap siblings drop in this
					// nendo). Narrow layouts open the same actions from a
					// right click, a long press, or a tap on touch screens.
					// A tombstone offers none.
					if !tap_size() && hovered() && !msg.deleted {
						msg_actions(index, msg)
					}
				}
			}

			// The quoted parent sits above the body it answers; a click
			// centers that message (handle_reply_jump).
			// A parent from someone you blocked quotes as a bare
			// "Blocked message": no author, text or image, and no jump
			// into their collapsed run.
			reply_from, reply_text, reply_image := msg.reply_from, msg.reply_text, msg.reply_image
			if g_ui != nil &&
			   g_ui.nicknames[msg.reply_from_id] !=
				   "" {reply_from = g_ui.nicknames[msg.reply_from_id]}
			reply_blocked := g_ui != nil && g_ui.blocked[msg.reply_from_id]
			if reply_blocked {
				reply_from, reply_text, reply_image = "", tr("Blocked message"), ""
			}
			if len(reply_from) > 0 || len(reply_text) > 0 || len(reply_image) > 0 {
				jumpable := len(msg.reply_id) > 0 && !reply_blocked
				if nendo.box(nendo.id("MsgReplyPrev", index))(
				{
					width = nendo.grow(),
					gap = 8,
					padding = nendo.pad(8),
					color = jumpable && hovered() ? HOVER : ROW_BG,
					radius = rr(6),
				},
				) {
					if jumpable && hovered() {
						reply_jump_hover = msg.reply_id
					}
					if nendo.box(nendo.id("MsgReplyBar", index))(
					{
						width = nendo.fixed(3),
						height = nendo.grow(),
						color = ACCENT,
						radius = rr(2),
					},
					) {}
					if nendo.box(nendo.id("MsgReplyCol", index))({direction = .Column, gap = 2}) {
						// No author line when the parent is unavailable.
						if len(reply_from) > 0 {
							nendo.text(reply_from, {font = FONT_TITLE, size = 11, color = ACCENT})
						}
						// Wrapped so a long token (a cashu string, a URL)
						// breaks instead of pushing the bubble off-pane.
						body_text(
							index * 4096 + 3072,
							reply_text,
							12,
							TEXT_DIM,
							wrap_w = body_wrap_w() - 40,
						)
						if reply_image != "" {
							tex, seen := media_textures[reply_image]
							if !seen {
								view, found := media_cached(.Sticker, reply_image)
								tex, seen = (^rl.Texture2D)(view), found
							}
							if tex != nil && tex.width > 0 && tex.height > 0 {
								scale := min(f32(96) / f32(tex.width), f32(64) / f32(tex.height))
								if nendo.box(nendo.id("MsgReplyImage", index))(
								{
									width = nendo.fixed(f32(tex.width) * scale),
									height = nendo.fixed(f32(tex.height) * scale),
									image = tex,
									radius = rr(4),
								},
								) {}
							} else if nendo.box(nendo.id("MsgReplyImage", index))(
							{
								width = nendo.fixed(96),
								height = nendo.fixed(64),
								align = {x = .Center, y = .Center},
								color = PLATE,
								radius = rr(4),
							},
							) {
								if seen {
									if hovered() {
										img_retry_hover = reply_image
										reply_jump_hover = ""
									}
									nendo.text(
										tr("Couldn't load image. Click to retry."),
										{font = FONT_BODY, size = 11, color = TEXT_DIM},
									)
								} else {
									nendo.text(
										tr("Loading…"),
										{font = FONT_BODY, size = 11, color = TEXT_DIM},
									)
								}
							}
						}
					}
				}
			}

			if msg.sticker.sha != "" {message_sticker(g_ui, index, msg)}
			media_failed := false
			// Seeds for the markdown and code-line id ranges, which share the
			// row's index * 4096 band and so stay compact per kind.
			text_seed, code_seed: u32
			// Slots render in source order; rejected and loading slots keep
			// their place between accepted siblings.
			for att := 0; att < len(msg.attachments); att += 1 {
				slot := msg.attachments[att]
				id := msg_slot_id(index, att)
				// The sticker draws above; an emoji asset draws wherever its
				// shortcode appears.
				if slot.kind == .Sticker || slot.kind == .Emoji {
					continue
				}
				if slot.state == .Rejected {
					if nendo.box(nendo.id("MediaRejected", id))(
					{padding = nendo.pad(12), color = PLATE, radius = rr(6)},
					) {
						nendo.text(
							tr(slot.rejection),
							{font = FONT_BODY, size = 13, color = TEXT_DIM},
						)
					}
					continue
				}
				if slot.state == .Loading {
					if nendo.box(nendo.id("MediaLoading", id))(
					{padding = nendo.pad(12), color = PLATE, radius = rr(6)},
					) {
						nendo.text(
							tr("Loading…"),
							{font = FONT_BODY, size = 13, color = TEXT_DIM},
						)
					}
					continue
				}
				// Only adjacent image slots share an album; a loading or
				// other slot ends it (rejected slots carry no kind).
				if slot.kind == .Image {
					end := att + 1
					for end < len(msg.attachments) &&
					    msg.attachments[end].kind == .Image &&
					    msg.attachments[end].state != .Loading {
						end += 1
					}
					image_album(index, msg, att, msg.attachments[att:end])
					att = end - 1
					continue
				}
				// Mesh, g-code, video and PDF failures share one retry banner
				// below the slots; other kinds fall back to a file chip.
				if slot.state == .Failed {
					#partial switch slot.kind {
					case .Mesh, .Gcode, .Video, .Loop, .Pdf:
						media_failed = true
						continue
					}
				}
				switch view in slot.view {
				case ^rl.Texture2D: // drawn by image_album or message_sticker
				case ^Video_View:
					// Audio tiles: mpv plays through its own ao, no frames;
					// the tile is the controls.
					if slot.kind == .Audio {
						audio_tile(id, msg, att, slot.name, att_size_label(msg, att), view)
						break
					}
					// Video tiles: the mpv-fed texture, with a play glyph while
					// paused. Click toggles pause (handle_video).
					ratio := view.w > 0 && view.h > 0 ? f32(view.w) / f32(view.h) : 16.0 / 9.0
					tile_w := min(att_w(), 320 * ratio)
					if nendo.box(nendo.id("MsgVideo", id))(
					{
						width = nendo.fixed(tile_w),
						align = {x = .Center, y = .Center},
						aspect = ratio,
						image = &view.tex,
						radius = rr(8),
					},
					) {
						att_dl_button("DlVid", id, msg.id, att, slot.name)
						if hovered() {
							video_hover = view
						}
						if nendo.box(nendo.id("MsgVideoFull", id))(
						{
							width = nendo.fit(min = tap_size() ? tap_min() : 0),
							height = nendo.fit(min = tap_size() ? tap_min() : 0),
							padding = nendo.pad(8),
							align = {x = .Center, y = .Center},
							floating = {
								attach_to = .Parent,
								clip_to = .Parent,
								z = 7,
								offset = {6, 6},
								attach = {element = .Left_Top, parent = .Left_Top},
							},
							color = {0, 0, 0, 150},
							radius = rr(4),
						},
						) {
							if hovered() {
								video_full_hover = {view, slot.name}
								tooltip(tr("Fullscreen"))
							}
							nendo.text(
								"\uf065",
								{font = FONT_ICON, size = 14, color = {255, 255, 255, 230}},
							)
						}
						if view.paused {
							if nendo.box(nendo.id("MsgVideoPlay", id))(
							{
								width = nendo.fixed(44),
								height = nendo.fixed(44),
								align = {x = .Center, y = .Center},
								color = {0, 0, 0, 140},
								radius = rr(22),
							},
							) {
								nendo.text(
									"",
									{font = FONT_ICON, size = 18, color = {255, 255, 255, 230}},
								)
							}
						}
						// Duration stamp, bottom-right.
						if !view.looping && view.dur > 0 {
							if nendo.box(nendo.id("MsgVideoDur", id))(
							{
								padding = {left = 6, right = 6, top = 2, bottom = 2},
								floating = {
									attach_to = .Parent,
									clip_to = .Parent,
									pointer = .Passthrough,
									z = 6,
									offset = {-6, -20},
									attach = {element = .Right_Bottom, parent = .Right_Bottom},
								},
								color = {0, 0, 0, 150},
								radius = rr(4),
							},
							) {
								nendo.text(
									fmt_clock(view.dur),
									{font = FONT_BODY, size = 11, color = {255, 255, 255, 230}},
								)
							}
						}
						video_scrub_bar(nendo.id("MsgVideoBar", id), view, tile_w)
					}

				// PDF tiles: one rendered page; prev/next chips when there
				// are more.
				case ^Pdf_View:
					ratio := view.h > 0 ? f32(view.w) / f32(view.h) : 0.77
					if nendo.box(nendo.id("MsgPdf", id))(
					{
						width = nendo.fixed(att_w()),
						align = {x = .Center, y = .Bottom},
						aspect = ratio,
						image = &view.tex,
						radius = rr(8),
					},
					) {
						att_dl_button("DlPdf", id, msg.id, att, slot.name)
						if nendo.box(nendo.id("MsgPdfFull", id))(
						{
							width = nendo.fit(min = tap_size() ? tap_min() : 0),
							height = nendo.fit(min = tap_size() ? tap_min() : 0),
							padding = nendo.pad(8),
							align = {x = .Center, y = .Center},
							floating = {
								attach_to = .Parent,
								clip_to = .Parent,
								z = 7,
								offset = {6, 6},
								attach = {element = .Left_Top, parent = .Left_Top},
							},
							color = {0, 0, 0, 150},
							radius = rr(4),
						},
						) {
							if hovered() {
								pdf_full_hover = {msg.id, att, slot.name}
								pdf_full_page = view.page
								tooltip(tr("Fullscreen"))
							}
							nendo.text(
								"\uf065",
								{font = FONT_ICON, size = 14, color = {255, 255, 255, 230}},
							)
						}
						if view.pages > 1 {
							if nendo.box(nendo.id("MsgPdfNav", id))(
							{
								padding = {left = 8, right = 8, top = 4, bottom = 4},
								gap = 10,
								align = {y = .Center},
								color = {0, 0, 0, 140},
								radius = rr(12),
							},
							) {
								if nendo.box(nendo.id("MsgPdfPrev", id))(
								{
									width = nendo.fit(min = tap_size() ? tap_min() : 0),
									height = nendo.fit(min = tap_size() ? tap_min() : 0),
									padding = nendo.pad(4),
									align = {x = .Center, y = .Center},
								},
								) {
									if view.page > 0 && hovered() {
										pdf_flip_hover = view
										pdf_flip_dir = -1
									}
									nendo.text(
										"<",
										{
											font = FONT_TITLE,
											size = 13,
											color = {255, 255, 255, view.page > 0 ? 230 : 80},
										},
									)
								}
								nendo.text(
									fmt.tprintf("%d / %d", view.page + 1, view.pages),
									{font = FONT_BODY, size = 11, color = {255, 255, 255, 230}},
								)
								if nendo.box(nendo.id("MsgPdfNext", id))(
								{
									width = nendo.fit(min = tap_size() ? tap_min() : 0),
									height = nendo.fit(min = tap_size() ? tap_min() : 0),
									padding = nendo.pad(4),
									align = {x = .Center, y = .Center},
								},
								) {
									if view.page < view.pages - 1 && hovered() {
										pdf_flip_hover = view
										pdf_flip_dir = 1
									}
									nendo.text(
										">",
										{
											font = FONT_TITLE,
											size = 13,
											color = {
												255,
												255,
												255,
												view.page < view.pages - 1 ? 230 : 80,
											},
										},
									)
								}
							}
						}
					}

				// 3D tiles: the plate rect comes from nendo, the model itself
				// from a Custom render command. Hover feeds the orbit/zoom
				// handler. Plate and model are separate elements because nendo
				// folds a backgroundColor into the CUSTOM command instead of
				// drawing it.
				case ^Stl_View:
					if nendo.box(nendo.id("MsgModel", id))(
					{
						width = nendo.fixed(att_w()),
						height = nendo.fixed(320),
						color = PLATE,
						radius = rr(8),
					},
					) {
						att_dl_button("DlMesh", id, msg.id, att, slot.name)
						if nendo.box(nendo.id("MsgModelView", id))(
						{width = nendo.grow(), height = nendo.grow(), custom = view},
						) {
							if hovered() {
								orbit_hover = &view.orbit
								model_hover = {msg.id, att, slot.name}
							}
						}
					}

				// G-code tiles: same shape plus the print-progress slider.
				case ^Gcode_View:
					if nendo.box(nendo.id("MsgGcode", id))(
					{
						width = nendo.fixed(att_w()),
						height = nendo.fixed(320),
						color = PLATE,
						radius = rr(8),
					},
					) {
						att_dl_button("DlGc", id, msg.id, att, slot.name)
						if nendo.box(nendo.id("MsgGcodeView", id))(
						{width = nendo.grow(), height = nendo.grow(), custom = view},
						) {
							if hovered() {
								orbit_hover = &view.orbit
							}
						}
					}
					bar_id := nendo.id("MsgGcodeBar", id)
					append(&gcode_bars, Gcode_Bar{bar_id, view})
					if nendo.box(bar_id)(
					{
						width = nendo.fixed(att_w()),
						height = nendo.fixed(14),
						padding = {left = 2, right = 2},
						align = {y = .Center},
						color = ROW_BG,
						radius = rr(7),
					},
					) {
						if nendo.box(nendo.id("MsgGcodeFill", id))(
						{
							width = nendo.fixed(max(10, view.frac * 316)),
							height = nendo.fixed(10),
							color = ACCENT,
							radius = rr(5),
						},
						) {}
					}

				// Archive tiles: the file listing; clicking an entry opens it
				// in the preview modal. An archive holding only a .nes ROM is
				// a cartridge tile instead.
				case ^Arc_View:
					if view.nes != nil {
						rom := view.entries[0].name
						nes_tile(
							view.nes,
							id,
							msg.id,
							att,
							slot.name,
							rom[strings.last_index_byte(rom, '/') + 1:],
						)
					} else if nendo.box(nendo.id("MsgArc", id))(
					{
						direction = .Column,
						width = nendo.fixed(att_w()),
						padding = nendo.pad(8),
						gap = 2,
						color = PLATE,
						radius = rr(8),
					},
					) {
						att_dl_button("DlArc", id, msg.id, att, slot.name)
						// The archive's own name, above its listing.
						if nendo.box(nendo.id("MsgArcName", id))(
						{
							width = nendo.grow(),
							padding = {left = 6, bottom = 4},
							clip = {x = true},
						},
						) {
							nendo.text(
								arc_short_name(slot.name),
								{font = FONT_TITLE, size = 12, color = TEXT},
							)
						}
						rows := view.expanded ? len(view.entries) : ARC_TILE_ROWS
						for entry, k in view.entries {
							if k >= rows {
								break
							}
							if nendo.box(nendo.id_local("MsgArcRow", u32(k)))(
							{
								width = nendo.grow(),
								height = nendo.fit(min = tap_size() ? tap_min() : 0),
								gap = 8,
								padding = {left = 6, right = 6, top = 4, bottom = 4},
								align = {y = .Center},
								color = hovered() ? HOVER : {},
								radius = rr(6),
							},
							) {
								if hovered() {
									arc_hover = {view, entry.index, entry.name}
								}
								nendo.text(
									text_ellipsis(
										entry.name,
										max(1, att_w() - 100),
										FONT_BODY,
										12,
									),
									{font = FONT_BODY, size = 12, color = TEXT},
								)
								if nendo.box(nendo.id_local("MsgArcPad"))(
								{width = nendo.grow()},
								) {}
								nendo.text(
									arc_size_label(entry.size),
									{font = FONT_BODY, size = 11, color = TEXT_DIM},
								)
							}
						}
						// Tap to list the rest, tap again to fold it back.
						if len(view.entries) > ARC_TILE_ROWS {
							if nendo.box(nendo.id("MsgArcMore", id))(
							{
								width = nendo.grow(),
								height = nendo.fit(min = tap_size() ? tap_min() : 0),
								padding = {left = 6, right = 6, top = 4, bottom = 4},
								color = hovered() ? HOVER : {},
								radius = rr(6),
							},
							) {
								if hovered() {
									arc_more_hover = view
								}
								label :=
									view.expanded ? tr("Show fewer files") : fmt.tprintf(tr("and %d more files"), len(view.entries) - ARC_TILE_ROWS)
								nendo.text(label, {font = FONT_BODY, size = 11, color = TEXT_DIM})
							}
						}
					}

				// Torrent tiles: name, file listing, copyable magnet link.
				case ^Tor_View:
					tor_tile(view, id, msg.id, att, slot.name)

				// Webxdc app tiles: icon + name, no execution.
				case ^Xdc_View:
					xdc_tile(view, id, msg.id, att, slot.name)

				// NES cartridge tiles: Play runs it in the player modal.
				case ^Nes_View:
					nes_tile(view, id, msg.id, att, slot.name, slot.name)

				// Markdown tiles: wrap to the plate, with a bounded scroll area.
				case ^Txt_View:
					if nendo.box(nendo.id("MsgTxt", id))(
					{
						direction = .Column,
						width = nendo.fixed(att_w()),
						height = nendo.fit(max = 320),
						padding = nendo.pad(10),
						gap = 6,
						clip = {x = true, y = true, scroll = true},
						color = PLATE,
						radius = rr(8),
					},
					) {
						att_dl_button("DlTxt", id, msg.id, att, slot.name)
						shown := min(len(view.blocks), TXT_TILE_BLOCKS)
						md_blocks(
							view.blocks[:shown],
							index * 4096 + 2048 + text_seed * 512,
							wrap_w = att_w() - 20,
						)
						if len(view.blocks) > shown {
							nendo.text(
								fmt.tprintf(tr("and %d more blocks"), len(view.blocks) - shown),
								{font = FONT_BODY, size = 11, color = TEXT_DIM},
							)
						}
					}
					text_seed += 1

				// Text/source tiles: numbered lines with the file name on top.
				// Click opens the preview modal (handle_code_click).
				case ^Code_View:
					if nendo.box(nendo.id("MsgCode", id))(
					{
						direction = .Column,
						width = nendo.fixed(att_w(480)),
						height = nendo.fit(max = 320),
						padding = nendo.pad(10),
						gap = 2,
						clip = {x = true, y = true, scroll = true},
						color = PLATE,
						radius = rr(8),
					},
					) {
						if hovered() {
							code_hover = {msg.id, att, slot.name}
						}
						att_dl_button("DlCode", id, msg.id, att, slot.name)
						if nendo.box(nendo.id("MsgCodeName", id))(
						{padding = {bottom = 4}, gap = 8},
						) {
							nendo.text(slot.name, {font = FONT_TITLE, size = 12, color = TEXT})
							nendo.text(
								tr(view.lang),
								{font = FONT_BODY, size = 11, color = TEXT_DIM},
							)
						}
						code_lines(
							view,
							index * 4096 + 3072 + code_seed * 512,
							CODE_TILE_LINES,
							att_w(480) - 20,
							nendo.id("MsgCode", id),
							// Padding + filename row + gap.
							28,
							2,
						)
					}
					scrollbar(nendo.id("MsgCode", id))
					code_seed += 1

				// Font tiles: the rasterized specimen.
				case ^Ttf_View:
					ratio := view.h > 0 ? f32(view.w) / f32(view.h) : 4
					if nendo.box(nendo.id("MsgFont", id))(
					{
						width = nendo.fixed(att_w()),
						aspect = ratio,
						image = &view.tex,
						radius = rr(8),
					},
					) {
						att_dl_button("DlFont", id, msg.id, att, slot.name)
					}

				// File chips (no inline renderer, or a failed download of a
				// kind without its own retry): name + size when this session
				// knows it, offer the download.
				case nil:
					if nendo.box(nendo.id("MsgFile", id))(
					{
						width = nendo.fixed(att_w()),
						height = nendo.fit(min = tap_size() ? tap_min() : 0),
						padding = nendo.pad(10),
						gap = 10,
						align = {y = .Center},
						color = hovered() ? HOVER : PLATE,
						radius = rr(8),
					},
					) {
						if hovered() {
							// group is filled at click time (no ui here).
							att_hover = {
								msg_id = msg.id,
								index  = att,
								name   = slot.name,
							}
						}
						nendo.text(ICON_DOWNLOAD, {font = FONT_ICON, size = 14, color = TEXT_DIM})
						if nendo.box(nendo.id("MsgFileCol", id))(
						{width = nendo.grow(), direction = .Column, gap = 2, clip = {x = true}},
						) {
							nendo.text(
								slot.name,
								{font = FONT_TITLE, size = 12, color = TEXT, wrap = .None},
							)
							size := att_size_label(msg, att)
							nendo.text(
								len(size) > 0 ? fmt.tprintf(tr("%s · Click to download."), size) : tr("Click to download."),
								{font = FONT_BODY, size = 11, color = TEXT_DIM},
							)
						}
					}
				}
			}

			if media_failed {
				if nendo.box(nendo.id("MsgMediaFail", index))(
				{padding = nendo.pad(10), color = hovered() ? HOVER : PLATE, radius = rr(8)},
				) {
					if hovered() {
						media_retry_hover = true
					}
					nendo.text(
						tr("Couldn't load attachment. Click to retry."),
						{font = FONT_BODY, size = 12, color = TEXT_DIM},
					)
				}
			}

			// Bodies draw a card in place of every GitHub link they hold.
			gh_cards_on = true
			geo_owner = msg.id
			rendition := g_ui != nil ? translation_lookup(g_ui, msg) : nil
			translated := rendition != nil && rendition.phase == .Ready && rendition.show
			if translated {
				body_text(index * 4096, rendition.text, 14, TEXT, true)
			}
			giphy := !translated && !msg.deleted && giphy_message(index, msg.body)
			// GIPHY already owns the download, including its loading fallback.
			if giphy_message_url(msg.body) != "" {
				gh_cards_on = false
			}
			// A body that is one bare npub/nprofile becomes that person's
			// card. Either way the text itself is not drawn.
			replaced := giphy || translated
			if !replaced && !msg.deleted && len(msg.secrets) == 0 {
				if hex := bare_mention_hex(msg.body); len(hex) > 0 {
					profile_card(index * 4096, hex, att_w(360), .Message)
					replaced = true
				}
			}

			cropped :=
				!replaced &&
				len(msg.blocks) == 0 &&
				!msg.deleted &&
				message_excerpt(index * 4096, msg.body, TEXT, msg.excerpt)
			if !replaced && !cropped && len(msg.blocks) == 0 && len(msg.body) > 0 {
				body_text(index * 4096, msg.body, 14, TEXT, true, emoji = .Jumbo)
			}

			// A shared theme: swatches off the pack itself, so the offer
			// shows what it would do before it is taken.
			if len(msg.theme_name) > 0 {
				theme_offer(index, msg)
			}

			// Tombstone placeholder for a deleted message.
			if msg.deleted {
				nendo.text(
					tr("This message was deleted"),
					{font = FONT_BODY, size = 13, color = TEXT_LO},
				)
			}

			if !replaced &&
			   len(msg.secrets) == 0 &&
			   !cropped &&
			   excerpt_body(
				   index * 4096,
				   "",
				   msg.blocks[:],
				   msg.excerpt,
				   body_wrap_w(),
				   TEXT,
				   emoji = .Jumbo,
			   ) {
				message_more(index * 4096, msg.excerpt)
			}

			gh_cards_on = false
			geo_owner = ""
			if g_ui != nil {translation_controls(g_ui, index, msg)}

			if len(msg.secrets) > 0 && !msg.deleted {
				for layer in 0 ..= len(msg.secrets) {
					blocks := msg.blocks[:]
					if layer > 0 {
						if !msg.secrets[layer - 1].open {break}
						blocks = msg.secrets[layer - 1].blocks[:]
					}
					// Keep the low bits distinct too: line/emoji IDs multiply this base.
					block_id :=
						layer == 0 ? index * 4096 : 0x60000008 + index * 65536 + u32(layer) * 4096
					if layer == len(msg.secrets) {
						md_blocks(blocks, block_id, true)
						continue
					}
					// Leave Markdown above an emoji carrier outside its outline.
					last := len(blocks) - 1
					carrier: [1]Md_Block_Ui
					if last > 0 &&
					   blocks[last].kind == .Para &&
					   text_emoji(strings.trim_space(blocks[last].text)) != nil {
						md_blocks(blocks[:last], block_id, true)
						block_id += u32(last) * 16
						carrier[0] = blocks[last]
						carrier[0].blank_lines_before = 0
						blocks = carrier[:]
					}
					cover_cropped := false
					if nendo.box(nendo.id("MsgReveal", index * 4096 + u32(layer)))(
					{
						direction = .Column,
						padding = nendo.pad(8),
						width = nendo.fit(min = 44),
						height = nendo.fit(min = 44),
						custom = &hidden_border,
					},
					) {
						if layer == 0 {
							cover_cropped = excerpt_body(
								block_id,
								"",
								blocks,
								msg.excerpt,
								body_wrap_w() - 16,
								TEXT,
								.Embed,
							)
						} else {
							md_blocks(blocks, block_id, wrap_w = body_wrap_w() - 16)
						}
						if hovered() {
							tooltip(
								msg.secrets[layer].open ? tr("Hide hidden message") : tr("Reveal hidden message"),
								.Above,
							)
						}
					}
					if cover_cropped {message_more(index * 4096, msg.excerpt)}
				}
			}

			// Poll options under the question; clicks vote (handle_chat).
			if len(msg.poll_opts) > 0 {
				poll_block(index, msg)
			}

			if tap_size() || notes || msg.edited {
				if nendo.box(nendo.id("MsgMeta", index))(
				{width = nendo.grow(), gap = 8, align = {y = .Center}},
				) {
					nendo.text(msg.at, {font = FONT_BODY, size = 11, color = TEXT_LO})
					if msg.edited {
						if nendo.box(nendo.id("MsgEdited", index))(
						{
							height = nendo.fit(min = tap_size() ? tap_min() : 0),
							align = {y = .Center},
						},
						) {
							nendo.text(
								tr("edited"),
								{font = FONT_BODY, size = 11, color = TEXT_DIM},
							)
						}
					}
				}
			}
			if msg.mine && msg.delivery == .PENDING {
				nendo.text(
					tr("Saved locally. Relay delivery pending."),
					{font = FONT_BODY, size = 11, color = TEXT_DIM},
				)
			} else if msg.mine && msg.delivery == .FAILED {
				nendo.text(tr("Not sent to relays"), {font = FONT_BODY, size = 11, color = DANGER})
			}
			// Reactions close the row, under the body.
			if len(msg.reactions) > 0 {
				if nendo.box(nendo.id("MsgReactions", index))(
				{width = nendo.grow(), gap = 6, clip = {x = true, scroll = true}},
				) {
					for chip, j in msg.reactions {
						slot := msg_slot_id(index, j)
						// A chip whose count changed swells and settles, and
						// the number itself rolls over.
						pop, was, roll := bump(nendo.id("MsgReactionChip", slot).id, chip.count)
						pad := bump_pad(pop)
						// A chip whose react/unreact is still on the wire is
						// drawn faded, the same tell as a pending send row.
						if nendo.box(nendo.id("MsgReactionChip", slot))(
						{
							width = nendo.fit(min = tap_size() ? tap_min() : 0),
							height = nendo.fit(min = tap_size() ? tap_min() : 0),
							padding = {left = 8 + pad, right = 8 + pad, top = 3, bottom = 3},
							gap = 4,
							align = {y = .Center},
							color = ROW_BG,
							radius = rr(10),
							border = chip.mine ? nendo.Border{color = chip.ghost ? ACCENT_DIM : ACCENT, width = bw()} : {},
						},
						) {
							// Emoji tile + count, text fallback when the
							// sheet has no tile for this emoji.
							if tex := emoji_tex(chip.emoji); tex != nil {
								if nendo.box(nendo.id("MsgReactionImg", slot))(
								{width = nendo.fixed(14), aspect = 1, image = tex},
								) {}
								if chip.ghost {
									// Nothing to roll: the count is a guess
									// until the ack lands.
									nendo.text(
										chip.count,
										{font = FONT_BODY, size = COUNT_FS, color = TEXT_LO},
									)
								} else {
									count_roll(slot, chip.count, was, roll)
								}
							} else {
								nendo.text(
									chip.label,
									{
										font = FONT_BODY,
										size = 12,
										color = chip.ghost ? TEXT_LO : TEXT,
									},
								)
							}
							// Who reacted, on hover. Above the chip: the row may
							// sit against the compose box.
							if len(chip.who) > 0 && hovered() {
								tooltip(chip.who, .Above)
							}
						}
					}
				}
			}

			scrollbar(nendo.id("MsgReactions", index))
			// Thread reply count, click opens the panel on this root.
			if msg.thread_replies > 0 && msg.id != thread_cur(g_ui) {
				if nendo.box(nendo.id("MsgThreadChip", index))(
				{
					height = nendo.fit(min = tap_size() ? tap_min() : 0),
					padding = {left = 8, right = 8, top = 3, bottom = 3},
					gap = 5,
					align = {y = .Center},
					color = hovered() ? HOVER : ROW_BG,
					radius = rr(10),
				},
				) {
					nendo.text(ICON_COMMENTS, {font = FONT_ICON, size = 11, color = ACCENT})
					nendo.text(
						fmt.tprintf(
							tr(msg.thread_replies == 1 ? N_("%d reply") : N_("%d replies")),
							msg.thread_replies,
						),
						{font = FONT_BODY, size = 12, color = TEXT},
					)
				}
			}

		}
	}
}

// One row of the message context menu: 16px glyph column, hover
// highlight, 32px tall.


// The card a shared theme arrives as: its name, a strip of its own
// colors, and the one control that applies it. Nothing here changes
// the running theme; handle_chat does that when the button is hit.
THEME_SWATCHES :: 6

theme_offer :: proc(index: u32, msg: Msg_Ui) {
	if nendo.box(nendo.id("ThemeCard", index))(
	{
		width = nendo.fixed(att_w(260)),
		direction = .Column,
		padding = nendo.pad(12),
		gap = 8,
		color = PLATE,
		radius = rr(10),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		nendo.text(tr("SHARED THEME"), {font = FONT_MONO, size = 10, color = TEXT_LO, spacing = 2})
		nendo.text(msg.theme_name, {font = FONT_TITLE, size = 14, color = TEXT})
		if nendo.box(nendo.id("ThemeSwatches", index))({gap = 4}) {
			for color, i in msg.theme_swatch {
				if nendo.box(nendo.id("ThemeSwatch", index * 16 + u32(i)))(
				{
					width = nendo.fixed(28),
					height = nendo.fixed(28),
					color = color,
					radius = rr(6),
					border = {color = DIVIDER, width = bw()},
				},
				) {}
			}
		}
		micro_button(fmt.tprintf("ThemeApply%d", index), tr("Use this theme"))
	}
}
