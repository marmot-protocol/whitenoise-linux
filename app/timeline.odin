package main

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

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
					p.failed ? "failed" : p.queued ? "queued" : "sending…",
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

			for a, j in p.atts {
				if a.tex == nil {
					continue
				}
				ratio := a.tex.height > 0 ? f32(a.tex.width) / f32(a.tex.height) : 1
				if clay.UI(clay.ID("PendingImage", index * 1024 + u32(j)))(
				{
					layout = {sizing = {width = clay.SizingFixed(att_w())}},
					aspectRatio = {ratio},
					image = {imageData = a.tex},
					cornerRadius = rr(8),
				},
				) {}
			}

			if !message_excerpt(0xF00000 + index * 8, p.body, body_color) {
				body_text(0xF00000 + index * 8, p.body, 14, body_color, wrap_w = body_wrap_w())
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

// One album-grid cell: a loaded texture, or (tex nil) a failed
// download identified by its cache key for the retry click.
Img_Cell :: struct {
	tex: ^rl.Texture2D,
	att: int,
	key: string,
}

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
	if att < len(msg.att_keys) {
		if size, ok := blob_sizes[msg.att_keys[att]]; ok {
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
							label,
							active || (!view.transcript_done && g_ui.stt.file != nil) ? TEXT_LO : {},
						)
						if active {
							cancel := fmt.tprintf("AudioSttCancel%d", id)
							micro_button(cancel, "Cancel")
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

// Group-system line (kind-1210): one dim sentence in a centered pill,
// the slint SystemLine. No avatar, no actions, no message chrome.
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

// Each sorted media list advances once while source attachment positions render.
@(private = "file")
media_at :: proc(
	items: []Att_Item($T),
	cursor: ^int,
	att: int,
) -> (
	entry: Att_Item(T),
	index: int,
	ok: bool,
) {
	index = cursor^
	if index >= len(items) || items[index].att != att {
		return
	}
	cursor^ += 1
	return items[index], index, true
}

message_row :: proc(index: u32, msg: Msg_Ui) {
	// A message that just landed glows in the accent surface and fades
	// back to the row's normal fill, so the eye is carried to it without
	// anything moving.
	fresh, landed := msg_fresh(msg.id)
	if landed && !msg.mine {
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
	// Rows trail a fast scroll by a few px, more the further they sit
	// from the middle of the view, and settle when it stops.
	lag_top, lag_bottom := scroll_lag(index)
	if clay.UI(clay.ID("MsgRow", index))(
	{
		layout = {
			sizing = {
				width = clay.SizingGrow(),
				height = collapsing ? clay.SizingFixed(collapse_h) : {},
			},
			padding = {left = 16, right = 16, top = lag_top, bottom = lag_bottom},
			childGap = 10,
		},
		backgroundColor = mix_color(hovered() ? HOVER : {}, SELECTED, fresh * 0.85),
		clip = collapsing ? clay.ClipElementConfig{vertical = true} : {},
	},
	) {
		burst_layer(index, msg.id) // particle effect anchored to this row
		avatar(
			"MsgAvatar",
			index,
			msg.sender_id,
			msg.sender,
			28,
			url_pic(msg.pic_url),
			fade(ACCENT, fresh),
		)
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
			// chips are showing, so hovering a row doesn't resize it.
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
					action_chip("MsgReact", index, "+1")
					// A reply can't carry a thread tag, so thread rows
					// offer Thread (nesting) instead of Reply.
					if len(msg.thread_of) == 0 || g_ui.compose_issue != "" {
						action_chip("MsgReply", index, "Reply")
					}
					action_chip("MsgThread", index, "Thread")
					if msg.mine {
						action_chip("MsgEdit", index, "Edit")
						action_chip("MsgDel", index, "Delete")
					}
				}
			}

			// Image cells: albums lay out as a justified mosaic. Each row
			// gets one height and cell widths follow each image's aspect
			// (h = row_width / sum(aspects)); extreme ratios are cropped so
			// screenshots cannot collapse into tiny strips. A
			// leading landscape image is promoted to a full-width hero and
			// a greedy fill packs the rest 2-3 per row, stopping once the
			// row is tight enough. The shape therefore varies with the
			// aspect mix, like the telegram album layouter. Failed cells
			// ride along as 4:3 retry plates.
			img_cells := make([dynamic]Img_Cell, context.temp_allocator)
			for entry in msg.images {
				append(&img_cells, Img_Cell{entry.view, entry.att, ""})
			}
			for entry in msg.img_failed {
				append(&img_cells, Img_Cell{nil, entry.att, entry.view})
			}
			slice.sort_by(img_cells[:], proc(a, b: Img_Cell) -> bool {
				return a.att < b.att
			})
			// Keep rejected and loading slots between their accepted siblings.
			image_pos, video_pos, audio_pos, pdf_pos, model_pos, gcode_pos: int
			arc_pos, xdc_pos, text_pos, code_pos, font_pos, file_pos, pending_pos: int
			for att := 0; att < len(msg.att_names); att += 1 {
				if rejection, rejected := msg.att_rejected[att]; rejected {
					if clay.UI(clay.ID("MediaRejected", index * 1024 + u32(att)))(
					{
						layout = {padding = clay.PaddingAll(12)},
						backgroundColor = PLATE,
						cornerRadius = rr(6),
					},
					) {
						clay.Text(
							tr(rejection),
							{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_DIM},
						)
					}
					continue
				}
				if pending_pos < len(msg.media_pending) &&
				   msg.media_pending[pending_pos].index == att {
					pending_pos += 1
					if clay.UI(clay.ID("MediaLoading", index * 1024 + u32(att)))(
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
				// Only adjacent image slots share an album; a rejection breaks it.
				start := image_pos
				for image_pos < len(img_cells) &&
				    img_cells[image_pos].att == att + image_pos - start {
					image_pos += 1
				}
				cells := img_cells[start:image_pos]
				aspect :: proc(c: Img_Cell) -> f32 {
					if c.tex != nil && c.tex.height > 0 {
						return clamp(f32(c.tex.width) / f32(c.tex.height), 0.5, 3)
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
				if len(rows) > 0 {
					if clay.UI(clay.ID("MsgAlbum", index * 1024 + u32(att)))(
					{layout = {layoutDirection = .TopToBottom, childGap = ALBUM_GAP}},
					) {
						for row in rows {
							if clay.UI(
								clay.ID("MsgImgRow", index * 1024 + u32(cells[row.start].att)),
							)(
								{layout = {childGap = ALBUM_GAP}},
							) {
								for cell in cells[row.start:row.start + row.count] {
									cell_id := index * 1024 + u32(cell.att)
									cw := row.h * aspect(cell)
									if cell.tex != nil {
										view := new(Image_Crop, context.temp_allocator)
										view^ = {
											kind = .Image_Crop,
											tex  = cell.tex,
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
											// Click opens the lightbox slideshow on this
											// image (handle_img_click; dl chip wins via
											// att_hover).
											if hovered() {
												img_hover = {
													msg_id = msg.id,
													att    = cell.att,
												}
											}
											att_dl_button(
												"DlImg",
												cell_id,
												msg.id,
												cell.att,
												msg.att_names[cell.att],
											)
										}
									} else {
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
												{
													fontId = FONT_BODY,
													fontSize = 11,
													textColor = TEXT_DIM,
												},
											)
										}
									}
								}
							}
						}
					}
				}
				// Video tiles: the mpv-fed texture, with a play glyph while
				// paused. Click toggles pause (handle_video).
				if entry, j, found := media_at(msg.videos[:], &video_pos, att); found {
					view := entry.view
					ratio := view.w > 0 && view.h > 0 ? f32(view.w) / f32(view.h) : 16.0 / 9.0
					tile_w := min(att_w(), 320 * ratio)
					if clay.UI(clay.ID("MsgVideo", index * 1024 + u32(j)))(
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
						att_dl_button(
							"DlVid",
							index * 1024 + u32(j),
							msg.id,
							entry.att,
							msg.att_names[entry.att],
						)
						if hovered() {
							video_hover = view
						}
						if clay.UI(clay.ID("MsgVideoFull", index * 1024 + u32(j)))(
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
								video_full_hover = {view, msg.att_names[entry.att]}
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
							if clay.UI(clay.ID("MsgVideoPlay", index * 1024 + u32(j)))(
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
						// Duration stamp, bottom-right (the slint tile's badge).
						if !view.looping && view.dur > 0 {
							if clay.UI(clay.ID("MsgVideoDur", index * 1024 + u32(j)))(
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
						video_scrub_bar(
							clay.ID("MsgVideoBar", index * 1024 + u32(j)),
							view,
							tile_w,
						)
					}
				}

				// Audio tiles: mpv plays through its own ao, no frames; the
				// tile is the controls.
				if entry, j, found := media_at(msg.audios[:], &audio_pos, att); found {
					audio_tile(
						index * 1024 + u32(j),
						msg.id,
						entry.att,
						msg.att_names[entry.att],
						att_size_label(msg, entry.att),
						entry.view,
					)
				}

				// PDF tiles: one rendered page; prev/next chips when there
				// are more.
				if entry, j, found := media_at(msg.pdfs[:], &pdf_pos, att); found {
					view := entry.view
					ratio := view.h > 0 ? f32(view.w) / f32(view.h) : 0.77
					if clay.UI(clay.ID("MsgPdf", index * 1024 + u32(j)))(
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
						att_dl_button(
							"DlPdf",
							index * 1024 + u32(j),
							msg.id,
							entry.att,
							msg.att_names[entry.att],
						)
						if view.pages > 1 {
							if clay.UI(clay.ID("MsgPdfNav", index * 1024 + u32(j)))(
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
								if clay.UI(clay.ID("MsgPdfPrev", index * 1024 + u32(j)))(
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
								if clay.UI(clay.ID("MsgPdfNext", index * 1024 + u32(j)))(
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
				}

				// 3D tiles: the plate rect comes from clay, the model itself
				// from a Custom render command. Hover feeds the orbit/zoom
				// handler. Plate and model are separate elements because clay
				// folds a backgroundColor into the CUSTOM command instead of
				// drawing it.
				if entry, j, found := media_at(msg.models[:], &model_pos, att); found {
					view := entry.view
					if clay.UI(clay.ID("MsgModel", index * 1024 + u32(j)))(
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
						att_dl_button(
							"DlMesh",
							index * 1024 + u32(j),
							msg.id,
							entry.att,
							msg.att_names[entry.att],
						)
						if clay.UI(clay.ID("MsgModelView", index * 1024 + u32(j)))(
						{
							layout = {
								sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()},
							},
							custom = {customData = view},
						},
						) {
							if hovered() {
								orbit_hover = &view.orbit
								model_hover = {msg.id, entry.att, msg.att_names[entry.att]}
							}
						}
					}
				}

				// G-code tiles: same shape plus the print-progress slider.
				if entry, j, found := media_at(msg.gcodes[:], &gcode_pos, att); found {
					view := entry.view
					if clay.UI(clay.ID("MsgGcode", index * 1024 + u32(j)))(
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
						att_dl_button(
							"DlGc",
							index * 1024 + u32(j),
							msg.id,
							entry.att,
							msg.att_names[entry.att],
						)
						if clay.UI(clay.ID("MsgGcodeView", index * 1024 + u32(j)))(
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
					bar_id := clay.ID("MsgGcodeBar", index * 1024 + u32(j))
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
						if clay.UI(clay.ID("MsgGcodeFill", index * 1024 + u32(j)))(
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
				}

				// Archive tiles: the file listing; clicking an entry opens it
				// in the preview modal.
				if entry, j, found := media_at(msg.arcs[:], &arc_pos, att); found {
					view := entry.view
					if clay.UI(clay.ID("MsgArc", index * 1024 + u32(j)))(
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
						att_dl_button(
							"DlArc",
							index * 1024 + u32(j),
							msg.id,
							entry.att,
							msg.att_names[entry.att],
						)
						// The archive's own name, above its listing.
						if clay.UI(clay.ID("MsgArcName", index * 1024 + u32(j)))(
						{layout = {padding = {left = 6, bottom = 4}}},
						) {
							clay.Text(
								arc_short_name(msg.att_names[entry.att]),
								{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT},
							)
						}
						rows := view.expanded ? len(view.entries) : ARC_TILE_ROWS
						for entry, k in view.entries {
							if k >= rows {
								break
							}
							if clay.UI(
								clay.ID("MsgArcRow", index * 65536 + u32(j) * 4096 + u32(k)),
							)(
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
								if clay.UI(
									clay.ID("MsgArcPad", index * 65536 + u32(j) * 4096 + u32(k)),
								)(
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
							if clay.UI(clay.ID("MsgArcMore", index * 1024 + u32(j)))(
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
									view.expanded ? "Show fewer files" : fmt.tprintf("and %d more files", len(view.entries) - ARC_TILE_ROWS)
								clay.Text(
									label,
									{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
								)
							}
						}
					}
				}

				// Webxdc app tiles: icon + name, no execution.
				if entry, j, found := media_at(msg.xdcs[:], &xdc_pos, att); found {
					xdc_tile(
						entry.view,
						index * 1024 + u32(j),
						msg.id,
						entry.att,
						msg.att_names[entry.att],
					)
				}

				// Markdown tiles: wrap to the plate, with a bounded scroll area.
				if entry, j, found := media_at(msg.txts[:], &text_pos, att); found {
					view := entry.view
					if clay.UI(clay.ID("MsgTxt", index * 1024 + u32(j)))(
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
						att_dl_button(
							"DlTxt",
							index * 1024 + u32(j),
							msg.id,
							entry.att,
							msg.att_names[entry.att],
						)
						shown := min(len(view.blocks), TXT_TILE_BLOCKS)
						md_blocks(
							view.blocks[:shown],
							index * 4096 + 2048 + u32(j) * 512,
							wrap_w = att_w() - 20,
						)
						if len(view.blocks) > shown {
							clay.Text(
								fmt.tprintf("and %d more blocks", len(view.blocks) - shown),
								{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
							)
						}
					}
				}

				// Text/source tiles: numbered lines with the file name on top.
				// Click opens the preview modal (handle_code_click).
				if entry, j, found := media_at(msg.codes[:], &code_pos, att); found {
					view := entry.view
					if clay.UI(clay.ID("MsgCode", index * 1024 + u32(j)))(
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
							code_hover = {msg.id, entry.att, msg.att_names[entry.att]}
						}
						att_dl_button(
							"DlCode",
							index * 1024 + u32(j),
							msg.id,
							entry.att,
							msg.att_names[entry.att],
						)
						if clay.UI(clay.ID("MsgCodeName", index * 1024 + u32(j)))(
						{layout = {padding = {bottom = 4}, childGap = 8}},
						) {
							clay.Text(
								msg.att_names[entry.att],
								{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT},
							)
							clay.Text(
								view.lang,
								{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
							)
						}
						code_lines(view, index * 4096 + 3072 + u32(j) * 512, CODE_TILE_LINES)
					}
				}

				// Font tiles: the rasterized specimen.
				if entry, j, found := media_at(msg.fonts[:], &font_pos, att); found {
					view := entry.view
					ratio := view.h > 0 ? f32(view.w) / f32(view.h) : 4
					if clay.UI(clay.ID("MsgFont", index * 1024 + u32(j)))(
					{
						layout = {sizing = {width = clay.SizingFixed(att_w())}},
						aspectRatio = {ratio},
						image = {imageData = &view.tex},
						cornerRadius = rr(8),
					},
					) {
						att_dl_button(
							"DlFont",
							index * 1024 + u32(j),
							msg.id,
							entry.att,
							msg.att_names[entry.att],
						)
					}
				}

				// File chips (no inline renderer): name + size when this
				// session knows it, offer the download.
				if file_pos < len(msg.files) && msg.files[file_pos] == att {
					j := file_pos
					file_pos += 1
					att_index := att
					if clay.UI(clay.ID("MsgFile", index * 1024 + u32(j)))(
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
								index  = att_index,
								name   = msg.att_names[att_index],
							}
						}
						clay.Text(
							ICON_DOWNLOAD,
							{fontId = FONT_ICON, fontSize = 14, textColor = TEXT_DIM},
						)
						if clay.UI(clay.ID("MsgFileCol", index * 1024 + u32(j)))(
						{layout = {layoutDirection = .TopToBottom, childGap = 2}},
						) {
							clay.Text(
								msg.att_names[att_index],
								{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT},
							)
							size := att_size_label(msg, att_index)
							clay.Text(
								len(size) > 0 ? fmt.tprintf("%s · Click to download.", size) : "Click to download.",
								{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
							)
						}
					}
				}

				att += max(n - 1, 0)
			}

			if msg.media_failed {
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
			if len(msg.reply_from) > 0 || len(msg.reply_text) > 0 || len(msg.reply_image) > 0 {
				jumpable := len(msg.reply_id) > 0
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
						if len(msg.reply_from) > 0 {
							clay.Text(
								msg.reply_from,
								{fontId = FONT_TITLE, fontSize = 11, textColor = ACCENT},
							)
						}
						// Wrapped so a long token (a cashu string, a URL)
						// breaks instead of pushing the bubble off-pane.
						body_text(
							index * 4096 + 3072,
							msg.reply_text,
							12,
							TEXT_DIM,
							wrap_w = body_wrap_w() - 40,
						)
						if msg.reply_image != "" {
							tex, seen := media_textures[msg.reply_image]
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
										img_retry_hover = msg.reply_image
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

			cropped :=
				len(msg.blocks) == 0 &&
				!msg.deleted &&
				message_excerpt(index * 4096, msg.body, TEXT)
			if !cropped && len(msg.blocks) == 0 && len(msg.body) > 0 {
				body_text(index * 4096, msg.body, 14, TEXT, true)
			}

			// A shared theme: swatches off the pack itself, so the offer
			// shows what it would do before it is taken.
			if len(msg.theme_name) > 0 {
				theme_offer(index, msg)
			}

			// Tombstone placeholder body, the slint deleted row.
			if msg.deleted {
				clay.Text(
					tr("This message was deleted"),
					{fontId = FONT_BODY, fontSize = 13, textColor = TEXT_LO},
				)
			}

			if len(msg.secrets) == 0 &&
			   !cropped &&
			   md_blocks(msg.blocks[:], index * 4096, true, max_lines = MESSAGE_LINES) {
				message_more(index * 4096)
			}

			gh_cards_on = false

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
						cover_cropped = md_blocks(
							blocks,
							block_id,
							wrap_w = body_wrap_w() - 16,
							max_lines = layer == 0 ? MESSAGE_LINES : max(int),
						)
						if hovered() {
							tooltip(
								msg.secrets[layer].open ? tr("Hide hidden message") : tr("Reveal hidden message"),
								.Above,
							)
						}
					}
					if cover_cropped {message_more(index * 4096)}
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
							// Twemoji tile + count, text fallback when the
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
			if msg.thread_replies > 0 {
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
						fmt.tprintf(tr("%d replies"), msg.thread_replies),
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

// Blinking text caret, rendered after the text of the focused input.
// Width is in layout units; the render scale (UI_ZOOM x density)
// inflates it, so a fraction keeps it a hairline on screen.
CARET_W :: 0.7
CARET_BLINK :: 1.2 // seconds per on-off cycle
CARET_SOLID :: 0.55 // seconds it holds steady after an edit

// When the caret last moved or the text under it changed. Blinking
// through your own typing is the thing that makes a caret hard to
// follow, so an edit restarts the cycle from full.
caret_at: f64

caret_wake :: proc() {
	caret_at = rl.GetTime()
}

// Last frame's caret box, in layout units. The IME and a phone
// keyboard are placed against it.
caret_box: clay.BoundingBox

caret :: proc(h: f32 = 16) {
	if d := clay.GetElementData(clay.ID_LOCAL("Caret")); d.found {
		caret_box = d.boundingBox // one frame behind, which no one can see
		caret_box.width = CARET_W
	}
	alpha := f32(1)
	if motion_on() {
		// Timer-driven blink lets the rest of a focused chat sleep.
		next := caret_at + CARET_SOLID
		if now := rl.GetTime(); now >= next {
			phase := i64((now - next) / (CARET_BLINK / 2))
			alpha = phase % 2 == 0 ? 0 : 1
			next += f64(phase + 1) * (CARET_BLINK / 2)
		}
		frame_deadline = min(frame_deadline, next)
	}
	if clay.UI(clay.ID_LOCAL("Caret"))(
	{layout = {sizing = {width = clay.SizingFixed(0), height = clay.SizingFixed(h)}}},
	) {
		// Paint the caret without adding space between text spans.
		if clay.UI(clay.ID_LOCAL("CaretInk"))(
		{
			layout = {sizing = {width = clay.SizingFixed(CARET_W), height = clay.SizingFixed(h)}},
			backgroundColor = fade(TEXT, alpha),
			floating = {
				attachTo = .Parent,
				clipTo = .AttachedParent,
				pointerCaptureMode = .Passthrough,
			},
		},
		) {}
	}
}

// Active scrollbar-thumb drag: container id (0 = none) and the
// pointer-to-thumb-top offset captured at grab, in clay coords.
Scroll_Drag :: struct {
	container: u32,
	grab:      f32,
}
scroll_drag: Scroll_Drag

// Scrollbar for a clay scroll container, floated on its right edge
// from the previous frame's scroll data. Wheel scrolls; the thumb is
// also hand-draggable (grab it, scroll follows the pointer).
// `z` must beat the container's own stacking context: the default sits
// above base content, a scroll region inside a floating modal passes
// something above the modal's zIndex or the thumb paints beneath it.
scrollbar :: proc(container: clay.ElementId, z: i16 = 5) {
	data := clay.GetScrollContainerData(container)
	if !data.found || data.contentDimensions.height <= data.scrollContainerDimensions.height {
		return
	}
	append(&drag_targets, container) // a finger can throw this one
	track := data.scrollContainerDimensions.height
	thumb := max(24, track * data.scrollContainerDimensions.height / data.contentDimensions.height)
	span := data.contentDimensions.height - data.scrollContainerDimensions.height
	travel := track - thumb
	y := travel > 0 ? -data.scrollPosition.y / span * travel : 0

	thumb_id := clay.ID("ScrollThumb", container.id)
	mouse_y := rl.GetMousePosition().y / UI_ZOOM
	if rl.IsMouseButtonPressed(.LEFT) && clay.PointerOver(thumb_id) {
		scroll_drag = {container.id, mouse_y - y}
	}
	dragging := scroll_drag.container == container.id
	if dragging && travel > 0 {
		y = clamp(mouse_y - scroll_drag.grab, 0, travel)
		data.scrollPosition.y = -y / travel * span
	}

	if clay.UI(thumb_id)(
	{
		layout = {sizing = {width = clay.SizingFixed(5), height = clay.SizingFixed(thumb)}},
		floating = {
			attachTo = .ElementWithId,
			parentId = container.id,
			offset = {-3, y},
			zIndex = z,
			attachment = {element = .RightTop, parent = .RightTop},
		},
		backgroundColor = dragging || clay.PointerOver(thumb_id) ? ACCENT : FIELD_BORDER,
		cornerRadius = rr(3),
	},
	) {}
}

is_emoji_rune :: proc(r: rune) -> bool {
	switch {
	case r >= 0x1F000 && r <= 0x1FAFF:
		return true
	case r >= 0x2600 && r <= 0x27BF:
		return true
	case r == 0x2764 || r == 0x2B50 || r == 0x203C || r == 0x2049 || (r >= 0x2B00 && r <= 0x2BFF):
		return true
	}
	return false
}

// One inline text/emoji/mention segment of a body line. A mention seg
// keeps the raw token in text (composer lines render it literally) and
// the resolved pubkey in hex (body lines render the chip).
Inline_Seg :: struct {
	text:    string,
	fonts:   string,
	tex:     ^rl.Texture2D,
	hex:     string, // mentioned account, "" = not a mention
	url:     string, // http(s) link, "" = not a link (linkguard.odin)
	bad_ref: bool,
	evid:    string, // nevent/note event id hex, "" = not one (nevent.odin)
	hints:   []string, // the nevent's relay hints
	fx:      u8, // glyph-effect bits from {name} markup (effects.odin)
}

@(private)
Inline_Link :: struct {
	start, end: int,
	url:        string,
}

// Split text into text runs and emoji clusters (VS16/ZWJ ride along;
// a cluster the sheet misses falls back per rune, then raw text).
inline_segs :: proc(
	text: string,
	fonts: string = "",
	links: []Inline_Link = nil,
	offset: int = 0,
) -> [dynamic]Inline_Seg {
	segs := make([dynamic]Inline_Seg, context.temp_allocator)
	plain_start := 0
	i := 0
	link_index := 0
	for i < len(text) {
		if end, ref := nostr_at(text, i); ref.kind != .None {
			if i >
			   plain_start {append(&segs, Inline_Seg{text = text[plain_start:i], fonts = text_fonts(fonts, plain_start, i)})}
			seg := Inline_Seg {
				text    = text[i:end],
				bad_ref = ref.kind == .Invalid,
			}
			if ref.kind == .Profile {seg.hex = ref.key}
			if ref.kind == .Event ||
			   ref.kind == .Address {seg.evid, seg.hints = ref.key, ref.relays}
			append(&segs, seg)
			i, plain_start = end, end
			continue
		}
		for link_index < len(links) && links[link_index].end <= offset + i {link_index += 1}
		if link_index < len(links) && links[link_index].start <= offset + i {
			link := links[link_index]
			end := min(len(text), link.end - offset)
			if i > plain_start {
				append(
					&segs,
					Inline_Seg {
						text = text[plain_start:i],
						fonts = text_fonts(fonts, plain_start, i),
					},
				)
			}
			append(
				&segs,
				Inline_Seg{text = text[i:end], url = link.url, fonts = text_fonts(fonts, i, end)},
			)
			i, plain_start = end, end
			continue
		}
		r, w := utf8.decode_rune_in_string(text[i:])
		if r == 'm' || r == 'M' {
			// marmot://profile deep link becomes one mention chip too;
			// clicking it opens the profile like a mention.
			if end, hx, ok := marmot_link_at(text, i); ok {
				if i > plain_start {
					append(
						&segs,
						Inline_Seg {
							text = text[plain_start:i],
							fonts = text_fonts(fonts, plain_start, i),
						},
					)
				}
				append(&segs, Inline_Seg{text = text[i:end], hex = hx})
				i = end
				plain_start = end
				continue
			}
		}
		if r == '{' {
			// {name}…{/name} glyph effects: the inner text parses on its
			// own and every seg it yields carries this bit, so nesting
			// composes the way the slint renderer's bitmask does.
			if bit, after, ok := fx_open_at(text, i); ok {
				inner_end, next := fx_close(text, after, bit)
				if i > plain_start {
					append(
						&segs,
						Inline_Seg {
							text = text[plain_start:i],
							fonts = text_fonts(fonts, plain_start, i),
						},
					)
				}
				for seg in inline_segs(text[after:inner_end], text_fonts(fonts, after, inner_end), links[link_index:], offset + after) {
					tagged := seg
					tagged.fx |= bit
					// Motion acts per glyph, like slint's RunCell, so a
					// moving text seg splits into letters. A very long run
					// stays whole: the per-letter ids would collide.
					plain :=
						!tagged.bad_ref &&
						tagged.tex == nil &&
						len(tagged.hex) == 0 &&
						len(tagged.url) == 0 &&
						len(tagged.evid) == 0
					if tagged.fx & FX_MOTION == 0 || !plain || len(tagged.text) > FX_LETTERS_MAX {
						append(&segs, tagged)
						continue
					}
					for at := 0; at < len(tagged.text); {
						_, w := utf8.decode_rune_in_string(tagged.text[at:])
						letter := tagged
						letter.text = tagged.text[at:at + w]
						letter.fonts = text_fonts(tagged.fonts, at, at + w)
						append(&segs, letter)
						at += w
					}
				}
				i = next
				plain_start = next
				continue
			}
		}
		if r == 'h' {
			// http(s) URL becomes its own seg; bodies draw it as a link
			// that routes through the external-link guard.
			if end, link, ok := url_at(text, i); ok {
				if i > plain_start {
					append(
						&segs,
						Inline_Seg {
							text = text[plain_start:i],
							fonts = text_fonts(fonts, plain_start, i),
						},
					)
				}
				append(
					&segs,
					Inline_Seg{text = link, url = link, fonts = text_fonts(fonts, i, end)},
				)
				i = end
				plain_start = end
				continue
			}
		}
		if r == ':' {
			// Known :shortcode: becomes a custom-emoji tile; anything
			// else stays literal text.
			if end, ctex := shortcode_at(text, i); ctex != nil {
				if i > plain_start {
					append(
						&segs,
						Inline_Seg {
							text = text[plain_start:i],
							fonts = text_fonts(fonts, plain_start, i),
						},
					)
				}
				append(&segs, Inline_Seg{tex = ctex})
				i = end
				plain_start = end
				continue
			}
		}
		if !is_emoji_rune(r) && !(r >= '0' && r <= '9') && r != '#' && r != '*' {
			i += w
			continue
		}
		it := utf8.decode_grapheme_iterator_make(text[i:])
		cluster, _, _ := utf8.decode_grapheme_iterate(&it)
		j := i + len(cluster)
		tex := text_emoji(cluster)
		if tex == nil {i = j; continue}
		if i > plain_start {
			append(
				&segs,
				Inline_Seg{text = text[plain_start:i], fonts = text_fonts(fonts, plain_start, i)},
			)
		}
		append(&segs, Inline_Seg{tex = tex})
		i = j
		plain_start = j
	}
	if plain_start < len(text) {
		append(
			&segs,
			Inline_Seg {
				text = text[plain_start:],
				fonts = text_fonts(fonts, plain_start, len(text)),
			},
		)
	}
	return segs
}

// Emit segments inline into the current parent element. chips draws
// mention segs as name plates (bodies); composer lines keep the raw
// token so caret hit-mapping stays byte-accurate.
render_segs :: proc(
	id: u32,
	segs: []Inline_Seg,
	font_size: u16,
	color: clay.Color,
	tile_px: f32,
	chips := false,
) {
	for seg, k in segs {
		if seg.tex != nil {
			if clay.UI(clay.ID("SegEmoji", id * 128 + u32(k)))(
			{
				layout = {sizing = {width = clay.SizingFixed(tile_px)}},
				aspectRatio = {1},
				image = {imageData = seg.tex},
			},
			) {}
		} else if ref, is_gh := gh_ref(seg.url); chips && gh_cards_on && is_gh {
			// A GitHub PR or issue link is drawn as its own card, in
			// place of the URL run.
			gh_card(id * 128 + u32(k), ref)
		} else if key := hn_ref(seg.url); chips && gh_cards_on && key != "" {
			hn_card(id * 128 + u32(k), key, seg.url)
		} else if chips && gh_cards_on && len(seg.evid) > 0 {
			// A referenced Nostr event is drawn as its own card, in
			// place of the token.
			nev_card(
				id * 128 + u32(k),
				seg.evid,
				strings.trim_prefix(seg.text, "nostr:"),
				seg.hints,
			)
		} else if chips && seg.bad_ref {
			clay.Text(
				tr("Invalid Nostr reference"),
				{fontId = FONT_BODY, fontSize = font_size, textColor = DANGER, wrapMode = .None},
			)
		} else if chips && len(seg.url) > 0 {
			// Links only in bodies: composer lines keep the raw text so
			// caret hit-mapping stays byte-accurate.
			if clay.UI(clay.ID("SegLink", id * 128 + u32(k)))(
			{
				layout = {padding = {left = 2, right = 2}},
				backgroundColor = hovered() ? HOVER : {},
				cornerRadius = rr(4),
			},
			) {
				if hovered() {
					link_hover = seg.url
				}
				styled_text(seg.text, seg.fonts, font_size, ACCENT)
			}
		} else if chips && len(seg.hex) > 0 {
			// Chip tinted by the account's stable avatar hue; a mention
			// of me gets the accent border. Click opens the profile.
			me := g_ui != nil && seg.hex == g_ui.account_ref
			if clay.UI(clay.ID("SegMention", id * 128 + u32(k)))(
			{
				layout = {
					padding = {left = 2, right = 2, top = 1, bottom = 1},
					childGap = 2,
					childAlignment = {y = .Center},
				},
				backgroundColor = avatar_color(seg.hex),
				cornerRadius = rr(7),
				border = me ? clay.BorderElementConfig{color = ACCENT, width = bw()} : {},
			},
			) {
				if hovered() {
					mention_hover = seg.hex
				}
				info := profile_info(g_client, seg.hex)
				photo := url_pic(info.pic_url)
				avatar(
					"MentionPhoto",
					id * 128 + u32(k),
					seg.hex,
					mention_label(seg.hex),
					f32(font_size),
					photo,
				)
				if photo != nil {
					crop_circle("MentionCircle", id * 128 + u32(k), seg.hex, f32(font_size))
				}
				clay.Text(
					fmt.tprintf("@%s", mention_label(seg.hex)),
					{fontId = FONT_TITLE, fontSize = font_size, textColor = {255, 255, 255, 235}},
				)
			}
		} else if seg.fx != 0 {
			anim_moving += 1
			// The glyph sits in a fixed cell sized to its own text plus
			// the motion budget, and moves by padding inside it: motion
			// never disturbs the line's spacing, and (unlike the
			// floating cell this used to use) it stays inside the
			// timeline's scroll clip instead of painting over the header.
			dx, dy, size_mul, alpha_mul := fx_transform(seg.fx, k, rl.GetTime())
			size := u16(max(f32(font_size) * size_mul, 6))
			tint := color
			tint.a *= alpha_mul
			cell := rl.MeasureTextLine(FONT_BODY, size, seg.text, 0).x
			if clay.UI(clay.ID("SegFx", id * 128 + u32(k)))(
			{
				layout = {
					sizing = {
						width = clay.SizingFixed(cell + 2 * FX_AMP),
						height = clay.SizingFixed(f32(size) + 2 + 2 * FX_AMP),
					},
					padding = {
						left = u16(FX_AMP + clamp(dx, -FX_AMP, FX_AMP)),
						top = u16(FX_AMP + clamp(dy, -FX_AMP, FX_AMP)),
					},
				},
			},
			) {
				styled_text(seg.text, seg.fonts, size, tint)
			}
		} else {
			if len(seg.fonts) > 0 {
				styled_text(seg.text, seg.fonts, font_size, color)
			} else {
				clay.Text(
					seg.text,
					{
						fontId = FONT_BODY,
						fontSize = font_size,
						textColor = color,
						wrapMode = chips ? .Words : .None,
					},
				)
			}
		}
	}
}

// Wrap to the resolved text viewport, including the current pane and zoom.
compose_wrap_w :: proc() -> f32 {
	box := clay.GetElementData(clay.ID("ComposeClip"))
	width := g_ui != nil ? page_w(g_ui) - 64 - CARET_W : 480
	if box.found &&
	   box.boundingBox.width > CARET_W {width = min(width, box.boundingBox.width - CARET_W)}
	return max(width, 1)
}

@(private)
compose_cache: struct {
	text:         string,
	width, scale: f32,
	lines:        [dynamic][2]int,
}

// Byte ranges of the composer's visual lines: each physical '\n' line
// greedily wrapped to the pill's text width. Spaces stay in the ranges
// so every byte keeps exactly one row and caret
// hit-mapping stays byte-accurate.
compose_lines :: proc(text: string) -> [][2]int {
	context.allocator = runtime.default_context().allocator
	width := compose_wrap_w()
	keep := 0
	start := 0
	if compose_cache.width == width &&
	   compose_cache.scale == UI_SCALE &&
	   len(compose_cache.lines) > 0 {
		if compose_cache.text == text {return compose_cache.lines[:]}
		prefix := 0
		for prefix < min(len(text), len(compose_cache.text)) &&
		    text[prefix] == compose_cache.text[prefix] {prefix += 1}
		// Rewrap the preceding line too: deleting a space may pull the
		// next word back onto it. Unchanged prefixes retain their breaks.
		for line, i in compose_cache.lines {
			if line[1] >= prefix {keep = max(i - 1, 0); break}
		}
		start = compose_cache.lines[keep][0]
	}
	resize(&compose_cache.lines, keep)
	for {
		end := len(text)
		if nl := strings.index_byte(text[start:], '\n'); nl >= 0 {
			end = start + nl
		}
		at := start
		for {
			cut := wrap_break(text, at, end, width, BODY_FS, .Compose)
			append(&compose_cache.lines, [2]int{at, cut})
			if cut >= end {
				break
			}
			at = cut
		}
		if end == len(text) {
			break
		}
		start = end + 1
	}
	delete(compose_cache.text)
	compose_cache.text = strings.clone(text)
	compose_cache.width, compose_cache.scale = width, UI_SCALE
	return compose_cache.lines[:]
}

// One physical composer line [ls, le): up to three spans split at the
// selection [lo, hi) (middle span highlighted), the caret at the
// selection head, the IME preedit riding at the caret.
compose_line :: proc(i: u32, text: string, ls, le, lo, hi, head: int) {
	if clay.UI(clay.ID("ComposeLine", i))(
	{layout = {sizing = {height = clay.SizingFit({min = 20})}, childAlignment = {y = .Center}}},
	) {
		a := clamp(lo, ls, le)
		b := clamp(hi, ls, le)
		at_caret :: proc(head, pos, ls, le: int) -> bool {
			return head == pos && head >= ls && head <= le
		}

		if a > ls {
			render_segs(0xE00 + i * 8, inline_segs(text[ls:a])[:], BODY_FS, TEXT, 18)
		}
		if at_caret(head, a, ls, le) {
			if preedit := rl.Preedit(); len(preedit) > 0 {
				clay.Text(preedit, {fontId = FONT_BODY, fontSize = BODY_FS, textColor = ACCENT})
			}
			caret()
		}
		if b > a {
			if clay.UI(clay.ID("ComposeSel", i))(
			{backgroundColor = ACCENT, layout = {childGap = 1, childAlignment = {y = .Center}}},
			) {
				render_segs(0xE00 + i * 8 + 2, inline_segs(text[a:b])[:], BODY_FS, ON_ACCENT, 18)
			}
			if at_caret(head, b, ls, le) && head > a {
				caret()
			}
		}
		if b < le {
			render_segs(0xE00 + i * 8 + 4, inline_segs(text[b:le])[:], BODY_FS, TEXT, 18)
		}
	}
}

// Render a pre-wrapped line with the body's measured emoji tile size.
// `sel` is the selected byte range inside this line ({-1,-1} = none,
// bodysel.odin), drawn as a highlighted middle span like the composer.
// `boxed` wraps the line in an element hit-testing can measure; the
// caller sets it for pre-wrapped (selectable) bodies only, because an
// element around a plain Text would take clay's own wrapping away.
body_line :: proc(
	id: u32,
	text: string,
	font_size: u16,
	color: clay.Color,
	sel := [2]int{-1, -1},
	boxed := false,
	tile_px: f32 = 0,
	fonts: string = "",
	links: []Inline_Link = nil,
	offset: int = 0,
) {
	tile_px := tile_px > 0 ? tile_px : body_tile_size(text, font_size)
	if text == "" {
		if clay.UI(clay.ID("BodyLine", id))(
		{layout = {sizing = {height = clay.SizingFixed(f32(font_size))}}},
		) {}
		return
	}
	sel := sel
	if sel[0] >= 0 {
		// A selection through a card token would split it into
		// text runs and lose the card, so a line holding one draws
		// unselected; the copy still carries the token.
		for seg in inline_segs(text, fonts, links, offset) {
			_, gh := gh_ref(seg.url)
			if len(seg.evid) > 0 || (gh_cards_on && (gh || hn_ref(seg.url) != "")) {
				sel = {-1, -1}
				break
			}
		}
	}
	if sel[0] >= 0 {
		if clay.UI(clay.ID("BodyLine", id))(
		{layout = {childGap = 2, childAlignment = {y = .Center}}},
		) {
			if sel[0] > 0 {
				render_segs(
					id * 4,
					inline_segs(text[:sel[0]], text_fonts(fonts, 0, sel[0]), links, offset)[:],
					font_size,
					color,
					tile_px,
					true,
				)
			}
			if clay.UI(clay.ID("BodySel", id))(
			{layout = {childGap = 2, childAlignment = {y = .Center}}, backgroundColor = ACCENT},
			) {
				// chips inside the highlight too: a link that turned
				// into a card must not fall back to its URL the moment
				// a selection covers it.
				render_segs(
					id * 4 + 1,
					inline_segs(
						text[sel[0]:sel[1]],
						text_fonts(fonts, sel[0], sel[1]),
						links,
						offset + sel[0],
					)[:],
					font_size,
					ON_ACCENT,
					tile_px,
					true,
				)
			}
			if sel[1] < len(text) {
				render_segs(
					id * 4 + 2,
					inline_segs(
						text[sel[1]:],
						text_fonts(fonts, sel[1], len(text)),
						links,
						offset + sel[1],
					)[:],
					font_size,
					color,
					tile_px,
					true,
				)
			}
		}
		return
	}

	segs := inline_segs(text, fonts, links, offset)
	if len(fonts) == 0 &&
	   len(segs) == 1 &&
	   segs[0].tex == nil &&
	   len(segs[0].hex) == 0 &&
	   len(segs[0].url) == 0 &&
	   !segs[0].bad_ref &&
	   len(segs[0].evid) == 0 &&
	   len(segs[0].text) == len(text) {
		// No emoji or mention at all: plain Text keeps clay's wrapping.
		if !boxed {
			clay.Text(text, {fontId = FONT_BODY, fontSize = font_size, textColor = color})
			return
		}
		if clay.UI(clay.ID("BodyLine", id))({layout = {childAlignment = {y = .Center}}}) {
			clay.Text(text, {fontId = FONT_BODY, fontSize = font_size, textColor = color})
		}
		return
	}

	if clay.UI(clay.ID("BodyLine", id))(
	{layout = {childGap = 2, childAlignment = {y = .Center}}},
	) {
		render_segs(id, segs[:], font_size, color, tile_px, true)
	}
}

// Multi-line wrapper: one body_line per physical line.
// Markdown block list, shared by message bodies, .md/.txt tiles, and

// GFM table: header row on a plate, content-sized columns capped so a
// wide table stays inside the bubble, hairline cell borders. All cells
// left-aligned (the source alignments are ignored: cross-axis centering
// is dropped by this clay build inside the timeline, see PORT.md).
MD_TABLE_COL_MAX :: 140
MD_TABLE_PAD :: 7

md_table :: proc(id: u32, cells: [][]string, cell_fonts: [][]string = nil) {
	if len(cells) == 0 {
		return
	}
	cols := 0
	for row in cells {
		cols = max(cols, len(row))
	}
	if cols == 0 {
		return
	}

	widths := make([]f32, cols, context.temp_allocator)
	for row, r in cells {
		for cell, c in row {
			fonts := r < len(cell_fonts) && c < len(cell_fonts[r]) ? cell_fonts[r][c] : ""
			width: f32
			it := utf8.decode_grapheme_iterator_make(cell)
			for cluster, g in utf8.decode_grapheme_iterate(&it) {width += rl.MeasureTextLine(text_font(fonts, g.byte_index), 13, cluster, 0).x}
			widths[c] = max(widths[c], width)
		}
	}
	for &w in widths {
		w = min(w, MD_TABLE_COL_MAX) + MD_TABLE_PAD * 2
	}

	if clay.UI(clay.ID("MsgTable", id))(
	{
		layout = {layoutDirection = .TopToBottom},
		border = {color = FIELD_BORDER, width = bw()},
		cornerRadius = rr(4),
	},
	) {
		for row, r in cells {
			if clay.UI(clay.ID("MsgTableRow", id + u32(r) * 64))(
			{layout = {}, backgroundColor = r == 0 ? PLATE : {}},
			) {
				for c in 0 ..< cols {
					text := c < len(row) ? row[c] : ""
					if clay.UI(clay.ID("MsgTableCell", id + u32(r) * 64 + u32(c)))(
					{
						layout = {
							sizing = {
								width = clay.SizingFixed(widths[c]),
								height = clay.SizingGrow(),
							},
							padding = clay.PaddingAll(MD_TABLE_PAD),
						},
						border = {
							color = FIELD_BORDER,
							width = {0, c < cols - 1 ? 1 : 0, 0, r < len(cells) - 1 ? 1 : 0, 0},
						},
					},
					) {
						fonts :=
							r < len(cell_fonts) && c < len(cell_fonts[r]) ? cell_fonts[r][c] : ""
						if len(fonts) > 0 {
							if clay.UI()({layout = {layoutDirection = .TopToBottom}}) {
								body_text(
									id + u32(r) * 64 + u32(c),
									text,
									13,
									r == 0 ? TEXT : TEXT_DIM,
									wrap_w = widths[c] - MD_TABLE_PAD * 2,
									fonts = fonts,
								)
							}
						} else {
							clay.Text(
								text,
								{
									fontId = r == 0 ? FONT_TITLE : FONT_BODY,
									fontSize = 13,
									textColor = r == 0 ? TEXT : TEXT_DIM,
								},
							)
						}
					}
				}
			}
		}
	}
}
// the preview modal. id_base namespaces the clay ids per call site.
// wrap_w pre-wraps paragraphs to a width (event cards); 0 leaves
// wrapping to clay or, when selectable, the timeline measure.
md_blocks :: proc(
	blocks: []Md_Block_Ui,
	id_base: u32,
	selectable := false,
	wrap_w: f32 = 0,
	max_lines: int = max(int),
) -> bool {
	remaining := max_lines
	for block, j in blocks {
		if remaining <= 0 {return true}
		block_id := id_base + u32(j) * 16
		gap_lines := int(block.blank_lines_before)
		// Keep list items together; preserve any extra blank lines.
		if j > 0 && block.kind == .List_Item && blocks[j - 1].kind == .List_Item {
			gap_lines = max(gap_lines - 1, 0)
		}
		if gap_lines > 0 {
			// Paragraph spacing is half a line and does not consume the text excerpt.
			gap := f32(gap_lines) * f32(BODY_FS) / 2
			if clay.UI(clay.ID("MdGap", block_id))(
			{layout = {sizing = {height = clay.SizingFixed(gap)}}},
			) {}
		}
		used := 1
		switch block.kind {
		case .Para:
			used = body_text(
				block_id + 1,
				block.text,
				BODY_FS,
				TEXT,
				selectable,
				wrap_w,
				remaining,
				block.fonts,
			)
		case .Heading:
			size := u16(max(24 - block.level * 2, 15))
			fonts := block.fonts
			font := [1]u8{FONT_TITLE}
			if len(fonts) ==
			   0 {fonts = strings.repeat(string(font[:]), len(block.text), context.temp_allocator)}
			used = body_text(
				block_id + 1,
				block.text,
				size,
				TEXT,
				selectable,
				wrap_w,
				remaining,
				fonts,
			)
		case .Code:
			if clay.UI(clay.ID("MsgCode", block_id))(
			{
				layout = {
					layoutDirection = .TopToBottom,
					sizing = {width = clay.SizingGrow()},
					padding = clay.PaddingAll(10),
				},
				backgroundColor = PLATE,
				cornerRadius = rr(6),
			},
			) {
				font := [1]u8{FONT_MONO}
				fonts := strings.repeat(string(font[:]), len(block.text), context.temp_allocator)
				width := max(f32(1), (wrap_w > 0 ? wrap_w : body_wrap_w()) - 20)
				lines := wrapped_lines(block.text, width, 13, fonts = fonts)
				used = len(lines)
				for line in lines[:min(used, remaining)] {
					if clay.UI()({layout = {sizing = {height = clay.SizingFixed(13)}}}) {
						clay.Text(
							block.text[line.start:line.end],
							{
								fontId = FONT_MONO,
								fontSize = 13,
								textColor = TEXT,
								wrapMode = .None,
							},
						)
					}
				}
			}
		case .Quote:
			if clay.UI(clay.ID("MsgQuote", block_id))({layout = {childGap = 8}}) {
				if clay.UI(clay.ID("MsgQuoteBar", block_id))(
				{
					layout = {sizing = {width = clay.SizingFixed(3), height = clay.SizingGrow()}},
					backgroundColor = ACCENT,
					cornerRadius = rr(2),
				},
				) {}
				if clay.UI()({layout = {layoutDirection = .TopToBottom}}) {
					used = body_text(
						block_id + 1,
						block.text,
						15,
						TEXT_DIM,
						selectable,
						max(f32(1), (wrap_w > 0 ? wrap_w : body_wrap_w()) - 11),
						remaining,
						block.fonts,
					)
				}
			}
		case .List_Item:
			marker := block.text[:block.marker_len]
			marker_w := max(f32(12), rl.MeasureTextLine(FONT_BODY, BODY_FS, marker, 0).x)
			width := wrap_w > 0 ? wrap_w : (selectable ? body_wrap_w() : 0)
			if clay.UI(clay.ID("MsgListItem", block_id))({layout = {padding = {left = 12}}}) {
				if clay.UI(clay.ID("MsgListMarker", block_id))(
				{layout = {sizing = {width = clay.SizingFixed(marker_w)}}},
				) {
					clay.Text(marker, {fontId = FONT_BODY, fontSize = BODY_FS, textColor = TEXT})
				}
				if clay.UI(clay.ID("MsgListBody", block_id))(
				{layout = {layoutDirection = .TopToBottom}},
				) {
					used = body_text(
						block_id + 2,
						block.text[block.marker_len:],
						BODY_FS,
						TEXT,
						selectable,
						width > 0 ? max(f32(1), width - 12 - marker_w) : 0,
						remaining,
						text_fonts(block.fonts, block.marker_len, len(block.text)),
					)
				}
			}
		case .Image:
			tex := nev_img(block.text)
			if tex == nil {
				clay.Text(block.text, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
				remaining -= 1
				continue
			}
			ratio := tex.height > 0 ? f32(tex.width) / f32(tex.height) : 1
			if clay.UI(clay.ID("MdImage", block_id))(
			{
				layout = {sizing = {width = clay.SizingFixed(wrap_w > 0 ? wrap_w : att_w())}},
				aspectRatio = {ratio},
				image = {imageData = tex},
				cornerRadius = rr(8),
			},
			) {}
		case .Rule:
			if clay.UI(clay.ID("MsgRule", block_id))(
			{
				layout = {sizing = {width = clay.SizingFixed(240), height = clay.SizingFixed(1)}},
				backgroundColor = TEXT_DIM,
			},
			) {}
		case .Table:
			used = len(block.cells)
			md_table(block_id, block.cells[:min(used, remaining)], block.cell_fonts)
		}
		if used > remaining {return true}
		remaining -= used
	}
	return false
}

// One body_line per physical line. `selectable` registers the lines
// with bodysel.odin, which needs each line's byte range inside `text`;
// the walk therefore slices `text` itself instead of split_lines, whose
// copies carry no offsets. Selectable bodies are also wrapped here
// rather than by clay: a selection highlight splits a line into three
// spans, and clay only wraps a whole Text element. Break points come
// from measured widths, like the slint renderer's greedy wrapper.
// `wrap_w` forces wrapping at that width for non-selectable bodies
// whose container clay can't wrap into (reply previews, edit history).
body_text :: proc(
	id: u32,
	text: string,
	font_size: u16,
	color: clay.Color,
	selectable := false,
	wrap_w: f32 = 0,
	max_lines: int = max(int),
	fonts: string = "",
) -> int {
	wrap := wrap_w > 0 ? wrap_w : (selectable ? body_wrap_w() : 0)
	tile_px := body_tile_size(text, font_size)
	lines := wrapped_lines(text, wrap, font_size, gh_cards_on ? .Cards : .Text, fonts)
	count := len(lines)
	lines = lines[:min(len(lines), max_lines)]
	// Parse destinations before wrapping: every visible fragment keeps
	// the original URL, including a fragment without an http prefix.
	links := make([dynamic]Inline_Link, context.temp_allocator)
	visible_end := len(lines) > 0 ? lines[len(lines) - 1].end : 0
	for at := 0; at < visible_end; {
		if end, url, ok := url_at(text, at); ok {
			append(&links, Inline_Link{at, end, url})
			at = end
		} else {at += 1}
	}
	first := 0
	for line in lines {
		for first < len(links) && links[first].end <= line.start {first += 1}
		last := first
		for last < len(links) && links[last].start < line.end {last += 1}
		line_id := id * 8 + line.index
		if selectable {
			sel_register(
				line_id,
				id,
				line.start,
				text[line.start:line.end],
				text,
				font_size,
				tile_px,
				text_fonts(fonts, line.start, line.end),
			)
			body_line(
				line_id,
				text[line.start:line.end],
				font_size,
				color,
				sel_range(id, line.start, line.end - line.start),
				true,
				tile_px,
				text_fonts(fonts, line.start, line.end),
				links[first:last],
				line.start,
			)
		} else {
			body_line(
				line_id,
				text[line.start:line.end],
				font_size,
				color,
				tile_px = tile_px,
				fonts = text_fonts(fonts, line.start, line.end),
				links = links[first:last],
				offset = line.start,
			)
		}
	}
	return count
}

@(private)
MESSAGE_LINES :: 6

// Plain fallback for pending messages and records without parsed blocks.
@(private)
message_excerpt :: proc(id: u32, text: string, color: clay.Color) -> bool {
	if len(wrapped_lines(text, body_wrap_w(), BODY_FS)) <= MESSAGE_LINES {return false}
	cards := gh_cards_on
	gh_cards_on = false
	body_text(id, text, BODY_FS, color, true, max_lines = MESSAGE_LINES)
	gh_cards_on = cards
	message_more(id)
	return true
}

@(private)
message_more :: proc(id: u32) {
	if clay.UI(clay.ID("MessageMore", id))(
	{
		layout = {padding = {top = 4, bottom = 4}},
		backgroundColor = hovered() ? HOVER : {},
		cornerRadius = rr(4),
	},
	) {
		clay.Text(tr("Read more"), {fontId = FONT_BODY, fontSize = 12, textColor = ACCENT})
	}
}

// Text width available to a message body: the timeline column from the
// previous frame, minus the row padding, the avatar and its gap. The
// pre-layout default is a readable measure, corrected on frame two.
// The box is capped by what the window can hold: it is one frame
// behind and inflated by its own over-long lines, so after a shrink
// the rewrap otherwise crawls toward the new width a word per frame.
body_wrap_w :: proc() -> f32 {
	MSG_ROW_CHROME :: f32(16 + 16 + 28 + 10 + 8) // paddings, avatar, gap, slack
	tl := clay.GetElementData(clay.ID("Timeline"))
	if !tl.found {
		return 480
	}
	avail := page_w(g_ui)
	if g_ui.issues_open {avail = tl.boundingBox.width - (page_w(g_ui) < 720 ? 40 : 64)}
	return max(min(tl.boundingBox.width, avail) - MSG_ROW_CHROME, 120)
}

// Widest an attachment tile draws: its design width, or the message
// column when that is narrower. A 320px tile in a 300px column is the
// same clipped edge a fixed-width modal gives a narrow window.
att_w :: proc(w: f32 = 320) -> f32 {
	return min(w, body_wrap_w())
}

// Pick emoji size for the whole body, so a short wrapped tail does
// not grow larger than the tiles used to measure its line.
@(private)
body_tile_size :: proc(text: string, font_size: u16) -> f32 {
	tiles := 0
	it := utf8.decode_grapheme_iterator_make(text)
	for cluster, _ in utf8.decode_grapheme_iterate(&it) {
		if text_emoji(cluster) != nil {
			tiles += 1
			if tiles > 6 {return f32(font_size) + 4}
		} else if len(strings.trim_space(cluster)) > 0 {
			return f32(font_size) + 4
		}
	}
	return tiles > 0 ? 28 : f32(font_size) + 4
}

// Greedy break at whole words, or whole graphemes in an over-long word.
wrap_break :: proc(
	text: string,
	at, end: int,
	width: f32,
	font_size: u16,
	mode: Wrap_Mode = .Text,
	tile_px: f32 = 0,
	fonts: string = "",
) -> int {
	// Only measure the current line. Measuring the whole next word
	// rescans a long unbroken suffix once per line (quadratic work).
	fit := rune_fit(text, at, end, width, font_size, mode, tile_px, fonts)
	if fit == end || text[fit] == ' ' {
		return fit
	}
	cut := fit
	for cut > at && text[cut - 1] != ' ' {
		cut -= 1
	}
	for cut > at && text[cut - 1] == ' ' {
		cut -= 1
	}
	if cut > at {
		if mode == .Compose {
			for cut < fit && text[cut] == ' ' {cut += 1}
		}
		return cut
	}
	// An event token stays whole because its card replaces the text.
	word := at
	for word < fit && text[word] == ' ' {
		word += 1
	}
	if mode != .Compose {
		if tok_end, _, _, is_event := nevent_at(text, word);
		   is_event && tok_end <= end {return tok_end}
	}
	return fit
}

// Longest prefix of [at, end) that fits `width`, keeping emoji
// graphemes intact and returning at least one cluster.
rune_fit :: proc(
	text: string,
	at, end: int,
	width: f32,
	font_size: u16,
	mode: Wrap_Mode = .Text,
	tile_px: f32 = 0,
	fonts: string = "",
) -> int {
	pen: f32 = 0
	previous_emoji := false
	skip := at
	it := utf8.decode_grapheme_iterator_make(text[at:end])
	for cluster, grapheme in utf8.decode_grapheme_iterate(&it) {
		i := at + grapheme.byte_index
		if i < skip {continue}
		if mode != .Compose {
			if next, atom_width := body_atom(text[:end], i, font_size); next > i {
				adv := atom_width + (i > at ? 2 : 0)
				if i > at && pen + adv > width {return i}
				pen += adv
				skip, previous_emoji = next, true
				continue
			}
		}
		adv := rl.MeasureTextLine(text_font(fonts, i), font_size, cluster, 0).x
		emoji := text_emoji(cluster) != nil
		if emoji {adv = mode == .Compose ? 18 : (tile_px > 0 ? tile_px : f32(font_size) + 4)}
		// Body segments have a 2px gap; plain graphemes share one run.
		if mode != .Compose && i > at && (emoji || previous_emoji) {adv += 2}
		if i > at && pen + adv > width {
			return i
		}
		pen += adv
		previous_emoji = emoji
	}
	return end
}

// One row of the message context menu, the slint MenuItem: 16px glyph
// column, hover highlight, 32px tall.


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
		micro_button(fmt.tprintf("ThemeApply%d", index), "Use this theme")
	}
}
