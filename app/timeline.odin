package main

import "core:fmt"
import "core:strings"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
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

pending_row :: proc(index: u32, ui: ^Ui_State, p: Pending_Send) {
	if p.dismissed {
		return
	}
	body_color := p.failed ? DANGER : TEXT_DIM
	can_delete := pending_can_delete(p, time.tick_now())
	if clay.UI(clay.ID("PendingRow", index))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {left = 16, right = 16, top = 6, bottom = 6},
			childGap = 10,
		},
		backgroundColor = hovered() ? HOVER : {},
	},
	) {
		avatar("PendingAvatar", index, ui.account_ref, p.sender, 28, url_pic(ui.my_pic_url))
		if clay.UI(clay.ID("PendingCol", index))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				childGap = 3,
			},
		},
		) {
			if clay.UI(clay.ID("PendingHead", index))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					childGap = 8,
					childAlignment = {y = .Center},
				},
			},
			) {
				clay.Text(p.sender, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT_DIM})
				clay.Text(
					p.failed ? "failed" : p.queued ? "queued" : p.gif != nil ? tr("Sending...") : p.forward != nil ? tr("Preparing attachments…") : "sending…",
					{fontId = FONT_BODY, fontSize = 11, textColor = p.failed ? DANGER : TEXT_LO},
				)
				if can_delete {
					if clay.UI(clay.ID("PendingDelete", index))(
					{
						layout = {padding = clay.PaddingAll(4)},
						backgroundColor = hovered() ? HOVER : {},
						cornerRadius = rr(4),
					},
					) {
						clay.Text(
							tr("Delete for me"),
							{fontId = FONT_BODY, fontSize = 11, textColor = DANGER},
						)
					}
				}
			}

			if p.gif != nil && !p.failed {
				anim_moving += 1
				if clay.UI(clay.ID("PendingGifTrack", index))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(100), height = clay.SizingFixed(3)},
					},
					backgroundColor = FIELD_BORDER,
				},
				) {
					if clay.UI(clay.ID("PendingGifBar", index))(
					{
						layout = {
							sizing = {width = clay.SizingFixed(30), height = clay.SizingFixed(3)},
						},
						floating = {
							attachTo = .Parent,
							offset = {f32(anim_frame % 90) / 90 * 70, 0},
							attachment = {element = .LeftTop, parent = .LeftTop},
						},
						backgroundColor = ACCENT,
					},
					) {}
				}
			}

			for a, j in p.atts {
				if a.tex == nil {
					continue
				}
				ratio := a.tex.height > 0 ? f32(a.tex.width) / f32(a.tex.height) : 1
				if clay.UI(clay.ID("PendingImage", index * 1024 + u32(j)))(
				{
					layout = {
						sizing = {
							width = clay.SizingFixed(
								p.sticker.sha != "" ? min(att_w(), min(220, 220 * ratio)) : att_w(),
							),
						},
					},
					aspectRatio = {ratio},
					image = {imageData = a.tex},
					userData = p.sticker.sha != "" ? rawptr(STICKER_IMAGE) : nil,
					cornerRadius = rr(8),
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
				if clay.UI(clay.ID("PendingDeleteEnd", index))(
				{
					layout = {padding = clay.PaddingAll(4)},
					backgroundColor = hovered() ? HOVER : {},
					cornerRadius = rr(4),
				},
				) {
					clay.Text(
						tr("Delete for me"),
						{fontId = FONT_BODY, fontSize = 11, textColor = DANGER},
					)
				}
			}
			if p.failed {
				clay.Text(
					tr("failed · tap to retry"),
					{fontId = FONT_BODY, fontSize = 11, textColor = DANGER},
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

// Click a reply preview: center the parent row via the jump path. A
// parent outside the loaded window simply doesn't match and the jump
// is dropped (main's centering loop).
handle_reply_jump :: proc(ui: ^Ui_State) {
	if reply_jump_hover == "" || !mouse_released() {
		return
	}
	delete(ui.jump_id)
	ui.jump_id = strings.clone(reply_jump_hover)
	reply_jump_hover = ""
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
	msg_id: string,
	att: int,
	name: string,
	size_label: string,
	view: ^Video_View,
) {
	if clay.UI(clay.ID("MsgAudio", id))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(att_w())},
			padding = clay.PaddingAll(10),
			childGap = 10,
			layoutDirection = .TopToBottom,
		},
		backgroundColor = PLATE,
		cornerRadius = rr(8),
	},
	) {
		att_dl_button("DlAud", id, msg_id, att, name)
		if clay.UI(clay.ID("MsgAudioControls", id))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 10,
				childAlignment = {y = .Top},
			},
		},
		) {
			if clay.UI(clay.ID("MsgAudioPlay", id))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(36), height = clay.SizingFixed(36)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = ACCENT,
				cornerRadius = rr(18),
			},
			) {
				if hovered() {
					video_hover = view // handle_video cycles pause
				}
				clay.Text(
					view.paused ? "" : "",
					{fontId = FONT_ICON, fontSize = 14, textColor = ON_ACCENT},
				)
			}
			if clay.UI(clay.ID("MsgAudioCol", id))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(max(1, att_w() - 66))},
					layoutDirection = .TopToBottom,
					childGap = 6,
				},
			},
			) {
				if clay.UI(clay.ID("MsgAudioName", id))(
				{layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}},
				) {
					clay.Text(
						name,
						{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT, wrapMode = .None},
					)
					if hovered() {
						tooltip(name)
					}
				}

				bar_id := clay.ID("MsgAudioBar", id)
				append(&video_bars, Video_Bar{bar_id, view})
				bar_w := max(1, att_w() - 66)
				frac := view.dur > 0 ? clamp(f32(view.time / view.dur), 0, 1) : 0
				if clay.UI(bar_id)(
				{
					layout = {
						sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(14)},
						padding = {left = 2, right = 2},
						childAlignment = {y = .Center},
					},
					backgroundColor = ROW_BG,
					cornerRadius = rr(7),
				},
				) {
					if clay.UI(clay.ID("MsgAudioFill", id))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(max(2, frac * (bar_w - 4))),
								height = clay.SizingFixed(10),
							},
						},
						backgroundColor = ACCENT,
						cornerRadius = rr(5),
					},
					) {}
				}

				if clay.UI(clay.ID("MsgAudioMeta", id))(
				{layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}},
				) {
					if len(size_label) > 0 {
						clay.Text(
							size_label,
							{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
						)
					}
					if clay.UI(clay.ID("MsgAudioPad", id))(
					{layout = {sizing = {width = clay.SizingGrow()}}},
					) {}
					clay.Text(
						fmt.tprintf("%s / %s", fmt_clock(view.time), fmt_clock(view.dur)),
						{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
					)
				}
				if g_ui.prefs.stt_enabled {
					active :=
						g_ui.stt.file != nil &&
						g_ui.stt.message == msg_id &&
						g_ui.stt.attachment == att
					button := fmt.tprintf("AudioTranscribe%d", id)
					// Keep every card the same height while recognition starts and stops.
					if clay.UI(clay.ID("AudioTranscribeRow", id))(
					{
						layout = {
							sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(31)},
							childGap = 8,
							childAlignment = {y = .Center},
						},
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
							if clay.PointerOver(clay.ID(cancel)) {stt_hover = {
									message    = msg_id,
									attachment = att,
									action     = .Cancel,
								}}
						}
					}
					if clay.PointerOver(clay.ID(button)) &&
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
			clay.Text(view.transcript, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT})
		}
	}
}

// Group-system line (kind-1210): one dim sentence in a centered pill.
// No avatar, no actions, no message chrome.
// Centered by grow spacers, like the unread divider (a cross-axis
// x=center child drops in this clay build, quirks).
system_row :: proc(index: u32, msg: Msg_Ui) {
	if clay.UI(clay.ID("SysRow", index))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {left = 16, right = 16, top = 4, bottom = 4},
			childAlignment = {y = .Center},
		},
	},
	) {
		if clay.UI(clay.ID("SysGapL", index))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
		if clay.UI(clay.ID("SysPill", index))(
		{
			layout = {
				padding = {left = 12, right = 12, top = 4, bottom = 4},
				childGap = 8,
				childAlignment = {y = .Center},
			},
			backgroundColor = PLATE,
			cornerRadius = rr(11),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			if len(msg.sys_text) > 0 {
				segs := inline_segs(msg.sys_text)
				render_segs(0xD00000 + index * 8, segs[:], 11, TEXT_LO, 14, chips = true)
			} else {
				clay.Text(msg.body, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
			}
			if len(msg.sys_added_hex) > 0 &&
			   (g_ui == nil || msg.sys_added_hex != g_ui.account_ref) {
				action_chip("SysWave", index, tr("Wave hi"))
			}
			clay.Text(msg.at, {fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO})
		}
		if clay.UI(clay.ID("SysGapR", index))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
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
	if clay.UI(clay.ID("BlockedRun", index))(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {left = 16, right = 16, top = 4, bottom = 4},
			childGap = 8,
			childAlignment = {y = .Center},
		},
	},
	) {
		clay.Text(ICON_BAN, {fontId = FONT_ICON, fontSize = 12, textColor = TEXT_LO})
		clay.Text(
			fmt.tprintf(
				tr(count == 1 ? N_("%d blocked message") : N_("%d blocked messages")),
				count,
			),
			{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
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
	data := clay.GetScrollContainerData(clay.ID("Timeline"))
	if !data.found {
		return
	}
	view_h := data.scrollContainerDimensions.height
	overflow := data.contentDimensions.height - view_h
	// scrollPosition.y runs 0 (top) to -overflow (bottom).
	above_bottom := overflow + data.scrollPosition.y
	// Springs in and out rather than blinking on and off, and drops
	// back toward the corner it came from on the way out.
	if !open_now(clay.ID("JumpLatest"), overflow > 0 && above_bottom >= view_h) {
		return
	}
	t := open_t(clay.ID("JumpLatest"))
	size := JUMP_SIZE * t

	if clay.UI(clay.ID("JumpLatest"))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(size), height = clay.SizingFixed(size)},
			childAlignment = {x = .Center, y = .Center},
		},
		floating = {
			attachTo = .ElementWithId,
			parentId = clay.ID("Timeline").id,
			zIndex = 8,
			offset = {-16 - (JUMP_SIZE - size) / 2, -16 + (1 - t) * JUMP_DROP},
			attachment = {element = .RightBottom, parent = .RightBottom},
		},
		backgroundColor = fade(hovered() ? ACCENT : CARD, t),
		cornerRadius = rr(size / 2),
		border = {color = fade(ELEVATED_BORDER, t), width = bw()},
	},
	) {
		clay.Text(
			ICON_DOWN,
			{
				fontId = FONT_ICON,
				fontSize = 14,
				textColor = fade(hovered() ? ON_ACCENT : TEXT_DIM, t),
			},
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
		if box := clay.GetElementData(clay.ID("MsgRow", index)); box.found {
			entry.from = box.boundingBox.height
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
// arrives from below, inside a one-line clip. clay gives clip elements a
// child offset (it is how scrolling works), which is the whole trick.
count_roll :: proc(slot: u32, count: string, was: string, t: f32) {
	if len(was) == 0 || t >= 1 {
		clay.Text(count, {fontId = FONT_BODY, fontSize = COUNT_FS, textColor = TEXT})
		return
	}
	if clay.UI(clay.ID("ReactRoll", slot))(
	{
		layout = {
			sizing = {height = clay.SizingFixed(COUNT_LINE)},
			layoutDirection = .TopToBottom,
		},
		clip = {vertical = true, childOffset = {0, -t * COUNT_LINE}},
	},
	) {
		clay.Text(was, {fontId = FONT_BODY, fontSize = COUNT_FS, textColor = TEXT_LO})
		clay.Text(count, {fontId = FONT_BODY, fontSize = COUNT_FS, textColor = TEXT})
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
@(private = "file")
image_album :: proc(index: u32, msg: Msg_Ui, first: int, cells: []Att_Slot) {
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
	rows := make([dynamic]Mosaic_Row, context.temp_allocator)
	i := 0
	if n >= 3 && aspect(cells[0]) >= 1.15 {
		append(&rows, Mosaic_Row{0, 1, 0})
		i = 1
	}
	for i < n {
		start := i
		sum: f32
		for i < n && i - start < 3 {
			sum += aspect(cells[i])
			i += 1
			// Tight enough: stop before the row gets short.
			if (album_w - ALBUM_GAP * f32(i - start - 1)) / sum <= 120 {
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

	if clay.UI(clay.ID("MsgAlbum", index * 1024 + u32(first)))(
	{layout = {layoutDirection = .TopToBottom, childGap = ALBUM_GAP}},
	) {
		for row in rows {
			if clay.UI(clay.ID("MsgImgRow", index * 1024 + u32(first + row.start)))(
			{layout = {childGap = ALBUM_GAP}},
			) {
				for cell, k in cells[row.start:row.start + row.count] {
					att := first + row.start + k
					cell_id := index * 1024 + u32(att)
					cw := row.h * aspect(cell)
					tex, ready := cell.view.(^rl.Texture2D)
					if !ready {
						if clay.UI(clay.ID("MsgImgFail", cell_id))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(cw),
									height = clay.SizingFixed(row.h),
								},
								padding = clay.PaddingAll(10),
								childAlignment = {x = .Center, y = .Center},
							},
							backgroundColor = hovered() ? HOVER : PLATE,
							cornerRadius = rr(8),
						},
						) {
							if hovered() {
								img_retry_hover = cell.key
							}
							clay.Text(
								tr("Couldn't load image. Click to retry."),
								{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
							)
						}
						continue
					}
					view := new(Image_Crop, context.temp_allocator)
					view^ = {
						kind = .Image_Crop,
						tex  = tex,
					}
					if clay.UI(clay.ID("MsgImage", cell_id))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(cw),
								height = clay.SizingFixed(row.h),
							},
						},
						custom = {customData = view},
						cornerRadius = rr(8),
					},
					) {
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
	// A reply can't carry a thread tag, so thread rows
	// offer Thread (nesting) instead of Reply.
	if len(msg.thread_of) == 0 || g_ui.compose_issue != "" {
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
	if clay.UI(clay.ID("MsgRow", index))(
	{
		layout = {
			sizing = {
				width = clay.SizingGrow(),
				height = collapsing ? clay.SizingFixed(collapse_h) : {},
			},
			padding = {left = 16, right = 16, top = pad_top, bottom = MSG_PAD_Y},
			childGap = 10,
		},
		backgroundColor = editing ? SELECTED : mix_color(hovered() ? HOVER : {}, SELECTED, fresh * 0.85),
		border = editing ? clay.BorderElementConfig{color = ACCENT, width = {left = 3}} : {},
		clip = collapsing ? clay.ClipElementConfig{vertical = true} : {},
	},
	) {
		row_hovered := hovered()
		burst_layer(index, msg.id) // particle effect anchored to this row
		if head == .Full {
			peephole_avatar(
				"MsgAvatar",
				index,
				msg.sender_id,
				msg.sender,
				28,
				url_pic(msg.pic_url),
				clay.PointerOver(clay.ID("MsgAvatar", index)) ? .Open : .Closed,
				fade(ACCENT, fresh),
			)
		} else {
			// The avatar's column, holding the time while hovered.
			if clay.UI(clay.ID("MsgGutter", index))(
			{
				layout = {
					sizing = {width = clay.SizingFixed(28)},
					padding = {top = 3},
					childAlignment = {x = .Center},
				},
			},
			) {
				if row_hovered {
					clay.Text(
						msg.at,
						{fontId = FONT_BODY, fontSize = 10, textColor = TEXT_LO, wrapMode = .None},
					)
				}
			}
			if row_hovered && !msg.deleted {
				if clay.UI(clay.ID("MsgActions", index))(
				{
					layout = {childGap = 8},
					floating = {
						attachTo = .Parent,
						clipTo = .AttachedParent,
						pointerCaptureMode = .Passthrough,
						zIndex = 6,
						offset = {-16, 0},
						attachment = {element = .RightTop, parent = .RightTop},
					},
				},
				) {
					msg_actions(index, msg)
				}
			}
		}
		if clay.UI(clay.ID("MsgCol", index))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				childGap = 3,
			},
		},
		) {
			// The head reserves an action chip's height whether or not the
			// chips are showing, so hovering a row doesn't resize it. A
			// continued row has no head.
			if head == .Full {
				if clay.UI(clay.ID("MsgHead", index))(
				{
					layout = {
						sizing = {
							width = clay.SizingGrow(),
							height = clay.SizingFit({min = chip_h()}),
						},
						childGap = 8,
						childAlignment = {y = .Center},
					},
				},
				) {
					clay.Text(msg.sender, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
					if clay.UI(clay.ID("MsgTime", index))({layout = {}}) {
						clay.Text(msg.at, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
						// Full date on hover.
						if hovered() && len(msg.at_full) > 0 {
							if clay.UI(clay.ID("MsgTimeTip", index))(
							{
								layout = {padding = {left = 8, right = 8, top = 4, bottom = 4}},
								floating = {
									attachTo = .Parent,
									zIndex = 12,
									attachment = {element = .LeftBottom, parent = .LeftTop},
								},
								backgroundColor = CARD,
								cornerRadius = rr(6),
								border = {color = ELEVATED_BORDER, width = bw()},
							},
							) {
								clay.Text(
									msg.at_full,
									{fontId = FONT_BODY, fontSize = 11, textColor = TEXT},
								)
							}
						}
					}

					// Row actions, shown while the row is hovered. Kept before
					// any grow sibling (after-gap siblings drop in this clay).
					// A tombstone offers none.
					if hovered() && !msg.deleted {
						msg_actions(index, msg)
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
				id := index * 1024 + u32(att)
				// The sticker draws above; an emoji asset draws wherever its
				// shortcode appears.
				if slot.kind == .Sticker || slot.kind == .Emoji {
					continue
				}
				if slot.state == .Rejected {
					if clay.UI(clay.ID("MediaRejected", id))(
					{
						layout = {padding = clay.PaddingAll(12)},
						backgroundColor = PLATE,
						cornerRadius = rr(6),
					},
					) {
						clay.Text(
							tr(slot.rejection),
							{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
						)
					}
					continue
				}
				if slot.state == .Loading {
					if clay.UI(clay.ID("MediaLoading", id))(
					{
						layout = {padding = clay.PaddingAll(12)},
						backgroundColor = PLATE,
						cornerRadius = rr(6),
					},
					) {
						clay.Text(
							tr("Loading…"),
							{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
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
						audio_tile(id, msg.id, att, slot.name, att_size_label(msg, att), view)
						break
					}
					// Video tiles: the mpv-fed texture, with a play glyph while
					// paused. Click toggles pause (handle_video).
					ratio := view.w > 0 && view.h > 0 ? f32(view.w) / f32(view.h) : 16.0 / 9.0
					tile_w := min(att_w(), 320 * ratio)
					if clay.UI(clay.ID("MsgVideo", id))(
					{
						layout = {
							sizing = {width = clay.SizingFixed(tile_w)},
							childAlignment = {x = .Center, y = .Center},
						},
						aspectRatio = {ratio},
						image = {imageData = &view.tex},
						cornerRadius = rr(8),
					},
					) {
						att_dl_button("DlVid", id, msg.id, att, slot.name)
						if hovered() {
							video_hover = view
						}
						if clay.UI(clay.ID("MsgVideoFull", id))(
						{
							layout = {padding = clay.PaddingAll(8)},
							floating = {
								attachTo = .Parent,
								clipTo = .AttachedParent,
								zIndex = 7,
								offset = {6, 6},
								attachment = {element = .LeftTop, parent = .LeftTop},
							},
							backgroundColor = {0, 0, 0, 150},
							cornerRadius = rr(4),
						},
						) {
							if hovered() {
								video_full_hover = {view, slot.name}
								tooltip(tr("Fullscreen"))
							}
							clay.Text(
								"\uf065",
								{
									fontId = FONT_ICON,
									fontSize = 14,
									textColor = {255, 255, 255, 230},
								},
							)
						}
						if view.paused {
							if clay.UI(clay.ID("MsgVideoPlay", id))(
							{
								layout = {
									sizing = {
										width = clay.SizingFixed(44),
										height = clay.SizingFixed(44),
									},
									childAlignment = {x = .Center, y = .Center},
								},
								backgroundColor = {0, 0, 0, 140},
								cornerRadius = rr(22),
							},
							) {
								clay.Text(
									"",
									{
										fontId = FONT_ICON,
										fontSize = 18,
										textColor = {255, 255, 255, 230},
									},
								)
							}
						}
						// Duration stamp, bottom-right.
						if !view.looping && view.dur > 0 {
							if clay.UI(clay.ID("MsgVideoDur", id))(
							{
								layout = {padding = {left = 6, right = 6, top = 2, bottom = 2}},
								floating = {
									attachTo = .Parent,
									clipTo = .AttachedParent,
									pointerCaptureMode = .Passthrough,
									zIndex = 6,
									offset = {-6, -20},
									attachment = {element = .RightBottom, parent = .RightBottom},
								},
								backgroundColor = {0, 0, 0, 150},
								cornerRadius = rr(4),
							},
							) {
								clay.Text(
									fmt_clock(view.dur),
									{
										fontId = FONT_BODY,
										fontSize = 11,
										textColor = {255, 255, 255, 230},
									},
								)
							}
						}
						video_scrub_bar(clay.ID("MsgVideoBar", id), view, tile_w)
					}

				// PDF tiles: one rendered page; prev/next chips when there
				// are more.
				case ^Pdf_View:
					ratio := view.h > 0 ? f32(view.w) / f32(view.h) : 0.77
					if clay.UI(clay.ID("MsgPdf", id))(
					{
						layout = {
							sizing = {width = clay.SizingFixed(att_w())},
							childAlignment = {x = .Center, y = .Bottom},
						},
						aspectRatio = {ratio},
						image = {imageData = &view.tex},
						cornerRadius = rr(8),
					},
					) {
						att_dl_button("DlPdf", id, msg.id, att, slot.name)
						if clay.UI(clay.ID("MsgPdfFull", id))(
						{
							layout = {padding = clay.PaddingAll(8)},
							floating = {
								attachTo = .Parent,
								clipTo = .AttachedParent,
								zIndex = 7,
								offset = {6, 6},
								attachment = {element = .LeftTop, parent = .LeftTop},
							},
							backgroundColor = {0, 0, 0, 150},
							cornerRadius = rr(4),
						},
						) {
							if hovered() {
								pdf_full_hover = {msg.id, att, slot.name}
								pdf_full_page = view.page
								tooltip(tr("Fullscreen"))
							}
							clay.Text(
								"\uf065",
								{
									fontId = FONT_ICON,
									fontSize = 14,
									textColor = {255, 255, 255, 230},
								},
							)
						}
						if view.pages > 1 {
							if clay.UI(clay.ID("MsgPdfNav", id))(
							{
								layout = {
									padding = {left = 8, right = 8, top = 4, bottom = 4},
									childGap = 10,
									childAlignment = {y = .Center},
								},
								backgroundColor = {0, 0, 0, 140},
								cornerRadius = rr(12),
							},
							) {
								if clay.UI(clay.ID("MsgPdfPrev", id))(
								{layout = {padding = clay.PaddingAll(4)}},
								) {
									if hovered() {
										pdf_flip_hover = view
										pdf_flip_dir = -1
									}
									clay.Text(
										"<",
										{
											fontId = FONT_TITLE,
											fontSize = 13,
											textColor = {255, 255, 255, 230},
										},
									)
								}
								clay.Text(
									fmt.tprintf("%d / %d", view.page + 1, view.pages),
									{
										fontId = FONT_BODY,
										fontSize = 11,
										textColor = {255, 255, 255, 230},
									},
								)
								if clay.UI(clay.ID("MsgPdfNext", id))(
								{layout = {padding = clay.PaddingAll(4)}},
								) {
									if hovered() {
										pdf_flip_hover = view
										pdf_flip_dir = 1
									}
									clay.Text(
										">",
										{
											fontId = FONT_TITLE,
											fontSize = 13,
											textColor = {255, 255, 255, 230},
										},
									)
								}
							}
						}
					}

				// 3D tiles: the plate rect comes from clay, the model itself
				// from a Custom render command. Hover feeds the orbit/zoom
				// handler. Plate and model are separate elements because clay
				// folds a backgroundColor into the CUSTOM command instead of
				// drawing it.
				case ^Stl_View:
					if clay.UI(clay.ID("MsgModel", id))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(att_w()),
								height = clay.SizingFixed(320),
							},
						},
						backgroundColor = PLATE,
						cornerRadius = rr(8),
					},
					) {
						att_dl_button("DlMesh", id, msg.id, att, slot.name)
						if clay.UI(clay.ID("MsgModelView", id))(
						{
							layout = {
								sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()},
							},
							custom = {customData = view},
						},
						) {
							if hovered() {
								orbit_hover = &view.orbit
								model_hover = {msg.id, att, slot.name}
							}
						}
					}

				// G-code tiles: same shape plus the print-progress slider.
				case ^Gcode_View:
					if clay.UI(clay.ID("MsgGcode", id))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(att_w()),
								height = clay.SizingFixed(320),
							},
						},
						backgroundColor = PLATE,
						cornerRadius = rr(8),
					},
					) {
						att_dl_button("DlGc", id, msg.id, att, slot.name)
						if clay.UI(clay.ID("MsgGcodeView", id))(
						{
							layout = {
								sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()},
							},
							custom = {customData = view},
						},
						) {
							if hovered() {
								orbit_hover = &view.orbit
							}
						}
					}
					bar_id := clay.ID("MsgGcodeBar", id)
					append(&gcode_bars, Gcode_Bar{bar_id, view})
					if clay.UI(bar_id)(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(att_w()),
								height = clay.SizingFixed(14),
							},
							padding = {left = 2, right = 2},
							childAlignment = {y = .Center},
						},
						backgroundColor = ROW_BG,
						cornerRadius = rr(7),
					},
					) {
						if clay.UI(clay.ID("MsgGcodeFill", id))(
						{
							layout = {
								sizing = {
									width = clay.SizingFixed(max(10, view.frac * 316)),
									height = clay.SizingFixed(10),
								},
							},
							backgroundColor = ACCENT,
							cornerRadius = rr(5),
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
					} else if clay.UI(clay.ID("MsgArc", id))(
					{
						layout = {
							layoutDirection = .TopToBottom,
							sizing = {width = clay.SizingFixed(att_w())},
							padding = clay.PaddingAll(8),
							childGap = 2,
						},
						backgroundColor = PLATE,
						cornerRadius = rr(8),
					},
					) {
						att_dl_button("DlArc", id, msg.id, att, slot.name)
						// The archive's own name, above its listing.
						if clay.UI(clay.ID("MsgArcName", id))(
						{layout = {padding = {left = 6, bottom = 4}}},
						) {
							clay.Text(
								arc_short_name(slot.name),
								{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT},
							)
						}
						rows := view.expanded ? len(view.entries) : ARC_TILE_ROWS
						for entry, k in view.entries {
							if k >= rows {
								break
							}
							if clay.UI(clay.ID_LOCAL("MsgArcRow", u32(k)))(
							{
								layout = {
									sizing = {width = clay.SizingGrow()},
									childGap = 8,
									padding = {left = 6, right = 6, top = 4, bottom = 4},
									childAlignment = {y = .Center},
								},
								backgroundColor = hovered() ? HOVER : {},
								cornerRadius = rr(6),
							},
							) {
								if hovered() {
									arc_hover = {view, entry.index, entry.name}
								}
								clay.Text(
									entry.name,
									{fontId = FONT_BODY, fontSize = 12, textColor = TEXT},
								)
								if clay.UI(clay.ID_LOCAL("MsgArcPad"))(
								{layout = {sizing = {width = clay.SizingGrow()}}},
								) {}
								clay.Text(
									arc_size_label(entry.size),
									{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
								)
							}
						}
						// Tap to list the rest, tap again to fold it back.
						if len(view.entries) > ARC_TILE_ROWS {
							if clay.UI(clay.ID("MsgArcMore", id))(
							{
								layout = {
									sizing = {width = clay.SizingGrow()},
									padding = {left = 6, right = 6, top = 4, bottom = 4},
								},
								backgroundColor = hovered() ? HOVER : {},
								cornerRadius = rr(6),
							},
							) {
								if hovered() {
									arc_more_hover = view
								}
								label :=
									view.expanded ? tr("Show fewer files") : fmt.tprintf(tr("and %d more files"), len(view.entries) - ARC_TILE_ROWS)
								clay.Text(
									label,
									{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
								)
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
					if clay.UI(clay.ID("MsgTxt", id))(
					{
						layout = {
							layoutDirection = .TopToBottom,
							sizing = {
								width = clay.SizingFixed(att_w()),
								height = clay.SizingFit({max = 320}),
							},
							padding = clay.PaddingAll(10),
							childGap = 6,
						},
						clip = {
							horizontal = true,
							vertical = true,
							childOffset = clay.GetScrollOffset(),
						},
						backgroundColor = PLATE,
						cornerRadius = rr(8),
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
							clay.Text(
								fmt.tprintf(tr("and %d more blocks"), len(view.blocks) - shown),
								{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
							)
						}
					}
					text_seed += 1

				// Text/source tiles: numbered lines with the file name on top.
				// Click opens the preview modal (handle_code_click).
				case ^Code_View:
					if clay.UI(clay.ID("MsgCode", id))(
					{
						layout = {
							layoutDirection = .TopToBottom,
							sizing = {
								width = clay.SizingFixed(att_w(480)),
								height = clay.SizingFit({max = 320}),
							},
							padding = clay.PaddingAll(10),
							childGap = 2,
						},
						clip = {
							horizontal = true,
							vertical = true,
							childOffset = clay.GetScrollOffset(),
						},
						backgroundColor = PLATE,
						cornerRadius = rr(8),
					},
					) {
						if hovered() {
							code_hover = {msg.id, att, slot.name}
						}
						att_dl_button("DlCode", id, msg.id, att, slot.name)
						if clay.UI(clay.ID("MsgCodeName", id))(
						{layout = {padding = {bottom = 4}, childGap = 8}},
						) {
							clay.Text(
								slot.name,
								{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT},
							)
							clay.Text(
								tr(view.lang),
								{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
							)
						}
						code_lines(
							view,
							index * 4096 + 3072 + code_seed * 512,
							CODE_TILE_LINES,
							att_w(480) - 20,
							clay.ID("MsgCode", id),
							// Padding + filename row + gap.
							28,
							2,
						)
					}
					code_seed += 1

				// Font tiles: the rasterized specimen.
				case ^Ttf_View:
					ratio := view.h > 0 ? f32(view.w) / f32(view.h) : 4
					if clay.UI(clay.ID("MsgFont", id))(
					{
						layout = {sizing = {width = clay.SizingFixed(att_w())}},
						aspectRatio = {ratio},
						image = {imageData = &view.tex},
						cornerRadius = rr(8),
					},
					) {
						att_dl_button("DlFont", id, msg.id, att, slot.name)
					}

				// File chips (no inline renderer, or a failed download of a
				// kind without its own retry): name + size when this session
				// knows it, offer the download.
				case nil:
					if clay.UI(clay.ID("MsgFile", id))(
					{
						layout = {
							padding = clay.PaddingAll(10),
							childGap = 10,
							childAlignment = {y = .Center},
						},
						backgroundColor = hovered() ? HOVER : PLATE,
						cornerRadius = rr(8),
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
						clay.Text(
							ICON_DOWNLOAD,
							{fontId = FONT_ICON, fontSize = 14, textColor = TEXT_DIM},
						)
						if clay.UI(clay.ID("MsgFileCol", id))(
						{layout = {layoutDirection = .TopToBottom, childGap = 2}},
						) {
							clay.Text(
								slot.name,
								{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT},
							)
							size := att_size_label(msg, att)
							clay.Text(
								len(size) > 0 ? fmt.tprintf(tr("%s · Click to download."), size) : tr("Click to download."),
								{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
							)
						}
					}
				}
			}

			if media_failed {
				if clay.UI(clay.ID("MsgMediaFail", index))(
				{
					layout = {padding = clay.PaddingAll(10)},
					backgroundColor = hovered() ? HOVER : PLATE,
					cornerRadius = rr(8),
				},
				) {
					if hovered() {
						media_retry_hover = true
					}
					clay.Text(
						tr("Couldn't load attachment. Click to retry."),
						{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
					)
				}
			}

			// The quoted parent sits above the body it answers; a click
			// centers that message (handle_reply_jump).
			// A parent from someone you blocked quotes as a bare
			// "Blocked message": no author, text or image, and no jump
			// into their collapsed run.
			reply_from, reply_text, reply_image := msg.reply_from, msg.reply_text, msg.reply_image
			reply_blocked := g_ui != nil && g_ui.blocked[msg.reply_from_id]
			if reply_blocked {
				reply_from, reply_text, reply_image = "", tr("Blocked message"), ""
			}
			if len(reply_from) > 0 || len(reply_text) > 0 || len(reply_image) > 0 {
				jumpable := len(msg.reply_id) > 0 && !reply_blocked
				if clay.UI(clay.ID("MsgReplyPrev", index))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						childGap = 8,
						padding = clay.PaddingAll(8),
					},
					backgroundColor = jumpable && hovered() ? HOVER : ROW_BG,
					cornerRadius = rr(6),
				},
				) {
					if jumpable && hovered() {
						reply_jump_hover = msg.reply_id
					}
					if clay.UI(clay.ID("MsgReplyBar", index))(
					{
						layout = {
							sizing = {width = clay.SizingFixed(3), height = clay.SizingGrow()},
						},
						backgroundColor = ACCENT,
						cornerRadius = rr(2),
					},
					) {}
					if clay.UI(clay.ID("MsgReplyCol", index))(
					{layout = {layoutDirection = .TopToBottom, childGap = 2}},
					) {
						// No author line when the parent is unavailable.
						if len(reply_from) > 0 {
							clay.Text(
								reply_from,
								{fontId = FONT_TITLE, fontSize = 11, textColor = ACCENT},
							)
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
								if clay.UI(clay.ID("MsgReplyImage", index))(
								{
									layout = {
										sizing = {
											width = clay.SizingFixed(f32(tex.width) * scale),
											height = clay.SizingFixed(f32(tex.height) * scale),
										},
									},
									image = {imageData = tex},
									cornerRadius = rr(4),
								},
								) {}
							} else if clay.UI(clay.ID("MsgReplyImage", index))(
							{
								layout = {
									sizing = {
										width = clay.SizingFixed(96),
										height = clay.SizingFixed(64),
									},
									childAlignment = {x = .Center, y = .Center},
								},
								backgroundColor = PLATE,
								cornerRadius = rr(4),
							},
							) {
								if seen {
									if hovered() {
										img_retry_hover = reply_image
										reply_jump_hover = ""
									}
									clay.Text(
										tr("Couldn't load image. Click to retry."),
										{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
									)
								} else {
									clay.Text(
										tr("Loading…"),
										{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
									)
								}
							}
						}
					}
				}
			}

			// Bodies draw a card in place of every GitHub link they hold.
			gh_cards_on = true
			geo_owner = msg.id
			giphy := !msg.deleted && giphy_message(index, msg.body)
			// GIPHY already owns the download, including its loading fallback.
			if giphy_message_url(msg.body) != "" {
				gh_cards_on = false
			}
			// A body that is one bare npub/nprofile becomes that person's
			// card. Either way the text itself is not drawn.
			replaced := giphy
			if !giphy && !msg.deleted && len(msg.secrets) == 0 {
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
				clay.Text(
					tr("This message was deleted"),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_LO},
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
					if clay.UI(clay.ID("MsgReveal", index * 4096 + u32(layer)))(
					{
						layout = {
							layoutDirection = .TopToBottom,
							padding = clay.PaddingAll(8),
							sizing = {
								width = clay.SizingFit({min = 44}),
								height = clay.SizingFit({min = 44}),
							},
						},
						custom = {customData = &hidden_border},
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

			// Reactions close the row, under the body.
			if len(msg.reactions) > 0 {
				if clay.UI(clay.ID("MsgReactions", index))({layout = {childGap = 6}}) {
					for chip, j in msg.reactions {
						slot := index * 1024 + u32(j)
						// A chip whose count changed swells and settles, and
						// the number itself rolls over.
						pop, was, roll := bump(clay.ID("MsgReactionChip", slot).id, chip.count)
						pad := bump_pad(pop)
						// A chip whose react/unreact is still on the wire is
						// drawn faded, the same tell as a pending send row.
						if clay.UI(clay.ID("MsgReactionChip", slot))(
						{
							layout = {
								padding = {left = 8 + pad, right = 8 + pad, top = 3, bottom = 3},
								childGap = 4,
								childAlignment = {y = .Center},
							},
							backgroundColor = ROW_BG,
							cornerRadius = rr(10),
							border = chip.mine ? clay.BorderElementConfig{color = chip.ghost ? ACCENT_DIM : ACCENT, width = bw()} : {},
						},
						) {
							// Emoji tile + count, text fallback when the
							// sheet has no tile for this emoji.
							if tex := emoji_tex(chip.emoji); tex != nil {
								if clay.UI(clay.ID("MsgReactionImg", slot))(
								{
									layout = {sizing = {width = clay.SizingFixed(14)}},
									aspectRatio = {1},
									image = {imageData = tex},
								},
								) {}
								if chip.ghost {
									// Nothing to roll: the count is a guess
									// until the ack lands.
									clay.Text(
										chip.count,
										{
											fontId = FONT_BODY,
											fontSize = COUNT_FS,
											textColor = TEXT_LO,
										},
									)
								} else {
									count_roll(slot, chip.count, was, roll)
								}
							} else {
								clay.Text(
									chip.label,
									{
										fontId = FONT_BODY,
										fontSize = 12,
										textColor = chip.ghost ? TEXT_LO : TEXT,
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

			// Thread reply count, click opens the panel on this root.
			if msg.thread_replies > 0 && msg.id != thread_cur(g_ui) {
				if clay.UI(clay.ID("MsgThreadChip", index))(
				{
					layout = {
						padding = {left = 8, right = 8, top = 3, bottom = 3},
						childGap = 5,
						childAlignment = {y = .Center},
					},
					backgroundColor = hovered() ? HOVER : ROW_BG,
					cornerRadius = rr(10),
				},
				) {
					clay.Text(
						ICON_COMMENTS,
						{fontId = FONT_ICON, fontSize = 11, textColor = ACCENT},
					)
					clay.Text(
						fmt.tprintf(
							tr(msg.thread_replies == 1 ? N_("%d reply") : N_("%d replies")),
							msg.thread_replies,
						),
						{fontId = FONT_BODY, fontSize = 12, textColor = TEXT},
					)
				}
			}

			// Tiny accent "edited" marker, click opens the history modal.
			if msg.edited {
				if clay.UI(clay.ID("MsgEdited", index))(
				{layout = {padding = {top = 1, bottom = 1, right = 4}}},
				) {
					clay.Text(
						tr("edited"),
						{fontId = FONT_BODY, fontSize = 10, textColor = ACCENT},
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
	if clay.UI(clay.ID("ThemeCard", index))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(260)},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(12),
			childGap = 8,
		},
		backgroundColor = PLATE,
		cornerRadius = rr(10),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		clay.Text(
			tr("SHARED THEME"),
			{fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO, letterSpacing = 2},
		)
		clay.Text(msg.theme_name, {fontId = FONT_TITLE, fontSize = 14, textColor = TEXT})
		if clay.UI(clay.ID("ThemeSwatches", index))({layout = {childGap = 4}}) {
			for color, i in msg.theme_swatch {
				if clay.UI(clay.ID("ThemeSwatch", index * 16 + u32(i)))(
				{
					layout = {
						sizing = {width = clay.SizingFixed(28), height = clay.SizingFixed(28)},
					},
					backgroundColor = color,
					cornerRadius = rr(6),
					border = {color = DIVIDER, width = bw()},
				},
				) {}
			}
		}
		micro_button(fmt.tprintf("ThemeApply%d", index), tr("Use this theme"))
	}
}
