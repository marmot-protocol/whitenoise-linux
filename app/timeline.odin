package main

import "core:c"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:text/edit"
import "core:unicode/utf8"
import "core:sync"
import "core:thread"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

import marmot "../marmot"

pending_row :: proc(index: u32, ui: ^Ui_State, p: Pending_Send) {
	body_color := p.failed ? DANGER : TEXT_DIM
	if clay.UI(clay.ID("PendingRow", index))(
	{layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 16, right = 16, top = 6, bottom = 6}, childGap = 10}, backgroundColor = hovered() ? HOVER : {}},
	) {
	avatar("PendingAvatar", index, ui.account_ref, p.sender, 28, url_pic(ui.my_pic_url))
	if clay.UI(clay.ID("PendingCol", index))(
	{layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 3}},
	) {
		if clay.UI(clay.ID("PendingHead", index))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 8, childAlignment = {y = .Center}}}) {
			clay.Text(p.sender, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT_DIM})
			clay.Text(p.failed ? "failed" : p.queued ? "queued" : "sending…", {fontId = FONT_BODY, fontSize = 11, textColor = p.failed ? DANGER : TEXT_LO})
		}

		for a, j in p.atts {
			if a.tex == nil {
				continue
			}
			ratio := a.tex.height > 0 ? f32(a.tex.width) / f32(a.tex.height) : 1
			if clay.UI(clay.ID("PendingImage", index * 1024 + u32(j)))(
			{layout = {sizing = {width = clay.SizingFixed(320)}}, aspectRatio = {ratio}, image = {imageData = a.tex}, cornerRadius = rr(8)},
			) {}
		}

		body_text(0xF00000 + index * 8, p.body, 14, body_color)
		if p.failed {
			clay.Text(tr("failed · tap to retry"), {fontId = FONT_BODY, fontSize = 11, textColor = DANGER})
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
AUDIO_BAR_W :: 244 // 320 tile - padding - play button - gaps

audio_tile :: proc(id: u32, msg_id: string, att: int, name: string, size_label: string, view: ^Video_View) {
	if clay.UI(clay.ID("MsgAudio", id))(
	{layout = {sizing = {width = clay.SizingFixed(320)}, padding = clay.PaddingAll(10), childGap = 10, childAlignment = {y = .Center}}, backgroundColor = PLATE, cornerRadius = rr(8)},
	) {
		att_dl_button("DlAud", id, msg_id, att, name)
		if clay.UI(clay.ID("MsgAudioPlay", id))(
		{layout = {sizing = {width = clay.SizingFixed(36), height = clay.SizingFixed(36)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = ACCENT, cornerRadius = rr(18)},
		) {
			if hovered() {
				video_hover = view // handle_video cycles pause
			}
			clay.Text(view.paused ? "" : "", {fontId = FONT_ICON, fontSize = 14, textColor = ON_ACCENT})
		}
		if clay.UI(clay.ID("MsgAudioCol", id))(
		{layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 4}},
		) {
			clay.Text(name, {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})

			// Scrub bar, same registration as the video bar: the drag
			// spans frames and seeks as it moves. Voice notes (decoded
			// WAV) draw waveform buckets instead of the plain fill; the
			// whole strip is still the drag target.
			bar_id := clay.ID("MsgAudioBar", id)
			append(&video_bars, Video_Bar{bar_id, view})
			frac := view.dur > 0 ? f32(view.time / view.dur) : 0
			if view.bars != nil {
				played := int(frac * VOICE_BARS)
				if clay.UI(bar_id)(
				{layout = {sizing = {width = clay.SizingFixed(AUDIO_BAR_W), height = clay.SizingFixed(26)}, childGap = 1, childAlignment = {y = .Center}}},
				) {
					for amp, k in view.bars {
						if clay.UI(clay.ID("MsgAudioWave", id * 64 + u32(k)))(
						{layout = {sizing = {width = clay.SizingFixed(5), height = clay.SizingFixed(max(3, amp * 24))}}, backgroundColor = k < played ? ACCENT : FIELD_BORDER, cornerRadius = rr(2)},
						) {}
					}
				}
			} else if clay.UI(bar_id)(
			{layout = {sizing = {width = clay.SizingFixed(AUDIO_BAR_W), height = clay.SizingFixed(14)}, padding = {left = 2, right = 2}, childAlignment = {y = .Center}}, backgroundColor = ROW_BG, cornerRadius = rr(7)},
			) {
				if clay.UI(clay.ID("MsgAudioFill", id))(
				{layout = {sizing = {width = clay.SizingFixed(max(10, frac * (AUDIO_BAR_W - 4))), height = clay.SizingFixed(10)}}, backgroundColor = ACCENT, cornerRadius = rr(5)},
				) {}
			}

			if clay.UI(clay.ID("MsgAudioMeta", id))({layout = {sizing = {width = clay.SizingGrow()}, childGap = 8}}) {
				if len(size_label) > 0 {
					clay.Text(size_label, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
				}
				if clay.UI(clay.ID("MsgAudioPad", id))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
				clay.Text(fmt.tprintf("%s / %s", fmt_clock(view.time), fmt_clock(view.dur)), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
			}
		}
	}
}

// Group-system line (kind-1210): one dim sentence in a centered pill,
// the slint SystemLine. No avatar, no actions, no message chrome.
// Centered by grow spacers, like the unread divider (a cross-axis
// x=center child drops in this clay build, quirks).
system_row :: proc(index: u32, msg: Msg_Ui) {
	if clay.UI(clay.ID("SysRow", index))(
	{layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 16, right = 16, top = 4, bottom = 4}, childAlignment = {y = .Center}}},
	) {
		if clay.UI(clay.ID("SysGapL", index))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
		if clay.UI(clay.ID("SysPill", index))(
		{
			layout = {padding = {left = 12, right = 12, top = 4, bottom = 4}, childGap = 8, childAlignment = {y = .Center}},
			backgroundColor = PLATE,
			cornerRadius = rr(11),
			border = {color = FIELD_BORDER, width = bw()},
		},
		) {
			clay.Text(msg.body, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
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
		layout = {sizing = {width = clay.SizingFixed(size), height = clay.SizingFixed(size)}, childAlignment = {x = .Center, y = .Center}},
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
		clay.Text(ICON_DOWN, {fontId = FONT_ICON, fontSize = 14, textColor = fade(hovered() ? ON_ACCENT : TEXT_DIM, t)})
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
		layout = {sizing = {height = clay.SizingFixed(COUNT_LINE)}, layoutDirection = .TopToBottom},
		clip = {vertical = true, childOffset = {0, -t * COUNT_LINE}},
	},
	) {
		clay.Text(was, {fontId = FONT_BODY, fontSize = COUNT_FS, textColor = TEXT_LO})
		clay.Text(count, {fontId = FONT_BODY, fontSize = COUNT_FS, textColor = TEXT})
	}
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
			sizing = {width = clay.SizingGrow(), height = collapsing ? clay.SizingFixed(collapse_h) : {}},
			padding = {left = 16, right = 16, top = lag_top, bottom = lag_bottom},
			childGap = 10,
		},
		backgroundColor = mix_color(hovered() ? HOVER : {}, SELECTED, fresh * 0.85),
		clip = collapsing ? clay.ClipElementConfig{vertical = true} : {},
	},
	) {
	burst_layer(index, msg.id) // particle effect anchored to this row
	avatar("MsgAvatar", index, msg.sender_id, msg.sender, 28, url_pic(msg.pic_url), fade(ACCENT, fresh))
	if clay.UI(clay.ID("MsgCol", index))(
	{layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 3}},
	) {
		// The head reserves an action chip's height whether or not the
		// chips are showing, so hovering a row doesn't resize it.
		if clay.UI(clay.ID("MsgHead", index))(
		{layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFit({min = chip_h()})}, childGap = 8, childAlignment = {y = .Center}}},
		) {
			clay.Text(msg.sender, {fontId = FONT_TITLE, fontSize = 13, textColor = TEXT})
			if clay.UI(clay.ID("MsgTime", index))({layout = {}}) {
				clay.Text(msg.at, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO})
				// Full date on hover.
				if hovered() && len(msg.at_full) > 0 {
					if clay.UI(clay.ID("MsgTimeTip", index))(
					{
						layout = {padding = {left = 8, right = 8, top = 4, bottom = 4}},
						floating = {attachTo = .Parent, zIndex = 12, attachment = {element = .LeftBottom, parent = .LeftTop}},
						backgroundColor = CARD,
						cornerRadius = rr(6),
						border = {color = ELEVATED_BORDER, width = bw()},
					},
					) {
						clay.Text(msg.at_full, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT})
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
				if len(msg.thread_of) == 0 {
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
		// (h = row_width / sum(aspects), so nothing is cropped); a
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
		aspect :: proc(c: Img_Cell) -> f32 {
			if c.tex != nil && c.tex.height > 0 {
				return f32(c.tex.width) / f32(c.tex.height)
			}
			return 4.0 / 3.0
		}
		Mosaic_Row :: struct {
			start, count: int,
			h:            f32,
		}
		n := len(img_cells)
		album_w := f32(n == 1 ? 320 : 400)
		rows := make([dynamic]Mosaic_Row, context.temp_allocator)
		i := 0
		if n >= 3 && aspect(img_cells[0]) >= 1.15 {
			append(&rows, Mosaic_Row{0, 1, 0})
			i = 1
		}
		for i < n {
			start := i
			sum: f32
			for i < n && i - start < 3 {
				sum += aspect(img_cells[i])
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
			for c in img_cells[row.start:row.start + row.count] {
				sum += aspect(c)
			}
			row.h = min((album_w - ALBUM_GAP * f32(row.count - 1)) / sum, 320)
		}
		if len(rows) > 0 {
		if clay.UI(clay.ID("MsgAlbum", index))({layout = {layoutDirection = .TopToBottom, childGap = ALBUM_GAP}}) {
		for row, r in rows {
			if clay.UI(clay.ID("MsgImgRow", index * 1024 + u32(r)))({layout = {childGap = ALBUM_GAP}}) {
			for cell in img_cells[row.start:row.start + row.count] {
				cell_id := index * 1024 + u32(cell.att)
				cw := row.h * aspect(cell)
				if cell.tex != nil {
					if clay.UI(clay.ID("MsgImage", cell_id))(
					{layout = {sizing = {width = clay.SizingFixed(cw), height = clay.SizingFixed(row.h)}}, image = {imageData = cell.tex}, cornerRadius = rr(8)},
					) {
						// Click opens the lightbox slideshow on this
						// image (handle_img_click; dl chip wins via
						// att_hover).
						if hovered() {
							img_hover = {msg_id = msg.id, att = cell.att}
						}
						att_dl_button("DlImg", cell_id, msg.id, cell.att, msg.att_names[cell.att])
					}
				} else {
					if clay.UI(clay.ID("MsgImgFail", cell_id))(
					{layout = {sizing = {width = clay.SizingFixed(cw), height = clay.SizingFixed(row.h)}, padding = clay.PaddingAll(10), childAlignment = {x = .Center, y = .Center}}, backgroundColor = hovered() ? HOVER : PLATE, cornerRadius = rr(8)},
					) {
						if hovered() {
							img_retry_hover = cell.key
						}
						clay.Text(tr("Couldn't load image. Click to retry."), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
					}
				}
			}
			}
		}
		}
		}
		// Video tiles: the mpv-fed texture, with a play glyph while
		// paused. Click toggles pause (handle_video).
		for entry, j in msg.videos {
			view := entry.view
			ratio := view.h > 0 ? f32(view.w) / f32(view.h) : 16.0 / 9.0
			if clay.UI(clay.ID("MsgVideo", index * 1024 + u32(j)))(
			{layout = {sizing = {width = clay.SizingFixed(320)}, childAlignment = {x = .Center, y = .Center}}, aspectRatio = {ratio}, image = {imageData = &view.tex}, cornerRadius = rr(8)},
			) {
				att_dl_button("DlVid", index * 1024 + u32(j), msg.id, entry.att, msg.att_names[entry.att])
				if hovered() {
					video_hover = view
				}
				if view.paused {
					if clay.UI(clay.ID("MsgVideoPlay", index * 1024 + u32(j)))(
					{layout = {sizing = {width = clay.SizingFixed(44), height = clay.SizingFixed(44)}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = {0, 0, 0, 140}, cornerRadius = rr(22)},
					) {
						clay.Text("", {fontId = FONT_ICON, fontSize = 18, textColor = {255, 255, 255, 230}})
					}
				}
				// Duration stamp, bottom-right (the slint tile's badge).
				if !view.looping && view.dur > 0 {
					if clay.UI(clay.ID("MsgVideoDur", index * 1024 + u32(j)))(
					{
						layout = {padding = {left = 6, right = 6, top = 2, bottom = 2}},
						floating = {attachTo = .Parent, zIndex = 6, offset = {-6, -6}, attachment = {element = .RightBottom, parent = .RightBottom}},
						backgroundColor = {0, 0, 0, 150},
						cornerRadius = rr(4),
					},
					) {
						clay.Text(fmt_clock(view.dur), {fontId = FONT_BODY, fontSize = 11, textColor = {255, 255, 255, 230}})
					}
				}
			}
			// Scrub bar: drag seeks; hidden for looping GIFs.
			if !view.looping {
				bar_id := clay.ID("MsgVideoBar", index * 1024 + u32(j))
				append(&video_bars, Video_Bar{bar_id, view})
				frac := view.dur > 0 ? f32(view.time / view.dur) : 0
				if clay.UI(bar_id)(
				{layout = {sizing = {width = clay.SizingFixed(320), height = clay.SizingFixed(14)}, padding = {left = 2, right = 2}, childAlignment = {y = .Center}}, backgroundColor = ROW_BG, cornerRadius = rr(7)},
				) {
					if clay.UI(clay.ID("MsgVideoFill", index * 1024 + u32(j)))(
					{layout = {sizing = {width = clay.SizingFixed(max(10, frac * 316)), height = clay.SizingFixed(10)}}, backgroundColor = ACCENT, cornerRadius = rr(5)},
					) {}
				}
			}
		}

		// Audio tiles: mpv plays through its own ao, no frames; the
		// tile is the controls.
		for entry, j in msg.audios {
			audio_tile(index * 1024 + u32(j), msg.id, entry.att, msg.att_names[entry.att], att_size_label(msg, entry.att), entry.view)
		}

		// PDF tiles: one rendered page; prev/next chips when there
		// are more.
		for entry, j in msg.pdfs {
			view := entry.view
			ratio := view.h > 0 ? f32(view.w) / f32(view.h) : 0.77
			if clay.UI(clay.ID("MsgPdf", index * 1024 + u32(j)))(
			{layout = {sizing = {width = clay.SizingFixed(320)}, childAlignment = {x = .Center, y = .Bottom}}, aspectRatio = {ratio}, image = {imageData = &view.tex}, cornerRadius = rr(8)},
			) {
				att_dl_button("DlPdf", index * 1024 + u32(j), msg.id, entry.att, msg.att_names[entry.att])
				if view.pages > 1 {
					if clay.UI(clay.ID("MsgPdfNav", index * 1024 + u32(j)))(
					{layout = {padding = {left = 8, right = 8, top = 4, bottom = 4}, childGap = 10, childAlignment = {y = .Center}}, backgroundColor = {0, 0, 0, 140}, cornerRadius = rr(12)},
					) {
						if clay.UI(clay.ID("MsgPdfPrev", index * 1024 + u32(j)))(
						{layout = {padding = clay.PaddingAll(4)}},
						) {
							if hovered() {
								pdf_flip_hover = view
								pdf_flip_dir = -1
							}
							clay.Text("<", {fontId = FONT_TITLE, fontSize = 13, textColor = {255, 255, 255, 230}})
						}
						clay.Text(fmt.tprintf("%d / %d", view.page + 1, view.pages), {fontId = FONT_BODY, fontSize = 11, textColor = {255, 255, 255, 230}})
						if clay.UI(clay.ID("MsgPdfNext", index * 1024 + u32(j)))(
						{layout = {padding = clay.PaddingAll(4)}},
						) {
							if hovered() {
								pdf_flip_hover = view
								pdf_flip_dir = 1
							}
							clay.Text(">", {fontId = FONT_TITLE, fontSize = 13, textColor = {255, 255, 255, 230}})
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
		for entry, j in msg.models {
			view := entry.view
			if clay.UI(clay.ID("MsgModel", index * 1024 + u32(j)))(
			{layout = {sizing = {width = clay.SizingFixed(320), height = clay.SizingFixed(320)}}, backgroundColor = PLATE, cornerRadius = rr(8)},
			) {
				att_dl_button("DlMesh", index * 1024 + u32(j), msg.id, entry.att, msg.att_names[entry.att])
				if clay.UI(clay.ID("MsgModelView", index * 1024 + u32(j)))(
				{layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}}, custom = {customData = view}},
				) {
					if hovered() {
						orbit_hover = &view.orbit
						model_hover = {msg.id, entry.att, msg.att_names[entry.att]}
					}
				}
			}
		}

		// G-code tiles: same shape plus the print-progress slider.
		for entry, j in msg.gcodes {
			view := entry.view
			if clay.UI(clay.ID("MsgGcode", index * 1024 + u32(j)))(
			{layout = {sizing = {width = clay.SizingFixed(320), height = clay.SizingFixed(320)}}, backgroundColor = PLATE, cornerRadius = rr(8)},
			) {
				att_dl_button("DlGc", index * 1024 + u32(j), msg.id, entry.att, msg.att_names[entry.att])
				if clay.UI(clay.ID("MsgGcodeView", index * 1024 + u32(j)))(
				{layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}}, custom = {customData = view}},
				) {
					if hovered() {
						orbit_hover = &view.orbit
					}
				}
			}
			bar_id := clay.ID("MsgGcodeBar", index * 1024 + u32(j))
			append(&gcode_bars, Gcode_Bar{bar_id, view})
			if clay.UI(bar_id)(
			{layout = {sizing = {width = clay.SizingFixed(320), height = clay.SizingFixed(14)}, padding = {left = 2, right = 2}, childAlignment = {y = .Center}}, backgroundColor = ROW_BG, cornerRadius = rr(7)},
			) {
				if clay.UI(clay.ID("MsgGcodeFill", index * 1024 + u32(j)))(
				{layout = {sizing = {width = clay.SizingFixed(max(10, view.frac * 316)), height = clay.SizingFixed(10)}}, backgroundColor = ACCENT, cornerRadius = rr(5)},
				) {}
			}
		}

		// Archive tiles: the file listing; clicking an entry opens it
		// in the preview modal.
		for entry, j in msg.arcs {
			view := entry.view
			if clay.UI(clay.ID("MsgArc", index * 1024 + u32(j)))(
			{layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(320)}, padding = clay.PaddingAll(8), childGap = 2}, backgroundColor = PLATE, cornerRadius = rr(8)},
			) {
				att_dl_button("DlArc", index * 1024 + u32(j), msg.id, entry.att, msg.att_names[entry.att])
				// The archive's own name, above its listing.
				if clay.UI(clay.ID("MsgArcName", index * 1024 + u32(j)))({layout = {padding = {left = 6, bottom = 4}}}) {
					clay.Text(arc_short_name(msg.att_names[entry.att]), {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})
				}
				rows := view.expanded ? len(view.entries) : ARC_TILE_ROWS
				for entry, k in view.entries {
					if k >= rows {
						break
					}
					if clay.UI(clay.ID("MsgArcRow", index * 65536 + u32(j) * 4096 + u32(k)))(
					{layout = {sizing = {width = clay.SizingGrow()}, childGap = 8, padding = {left = 6, right = 6, top = 4, bottom = 4}, childAlignment = {y = .Center}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)},
					) {
						if hovered() {
							arc_hover = {view, entry.index, entry.name}
						}
						clay.Text(entry.name, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT})
						if clay.UI(clay.ID("MsgArcPad", index * 65536 + u32(j) * 4096 + u32(k)))({layout = {sizing = {width = clay.SizingGrow()}}}) {}
						clay.Text(arc_size_label(entry.size), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
					}
				}
				// Tap to list the rest, tap again to fold it back.
				if len(view.entries) > ARC_TILE_ROWS {
					if clay.UI(clay.ID("MsgArcMore", index * 1024 + u32(j)))(
					{layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 6, right = 6, top = 4, bottom = 4}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(6)},
					) {
						if hovered() {
							arc_more_hover = view
						}
						label := view.expanded \
							? "Show fewer files" \
							: fmt.tprintf("and %d more files", len(view.entries) - ARC_TILE_ROWS)
						clay.Text(label, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
					}
				}
			}
		}

		// Webxdc app tiles: icon + name, no execution.
		for entry, j in msg.xdcs {
			xdc_tile(entry.view, index * 1024 + u32(j), msg.id, entry.att, msg.att_names[entry.att])
		}

		// Text/markdown tiles: the shared block renderer on a plate.
		for entry, j in msg.txts {
			view := entry.view
			if clay.UI(clay.ID("MsgTxt", index * 1024 + u32(j)))(
			{layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(320)}, padding = clay.PaddingAll(10), childGap = 6}, backgroundColor = PLATE, cornerRadius = rr(8)},
			) {
				att_dl_button("DlTxt", index * 1024 + u32(j), msg.id, entry.att, msg.att_names[entry.att])
				shown := min(len(view.blocks), TXT_TILE_BLOCKS)
				md_blocks(view.blocks[:shown], index * 4096 + 2048 + u32(j) * 512)
				if len(view.blocks) > shown {
					clay.Text(fmt.tprintf("and %d more blocks", len(view.blocks) - shown), {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
				}
			}
		}

		// Source tiles: highlighted lines with the file name on top.
		for entry, j in msg.codes {
			view := entry.view
			if clay.UI(clay.ID("MsgCode", index * 1024 + u32(j)))(
			{layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(360)}, padding = clay.PaddingAll(10), childGap = 2}, backgroundColor = PLATE, cornerRadius = rr(8)},
			) {
				att_dl_button("DlCode", index * 1024 + u32(j), msg.id, entry.att, msg.att_names[entry.att])
				if clay.UI(clay.ID("MsgCodeName", index * 1024 + u32(j)))({layout = {padding = {bottom = 4}, childGap = 8}}) {
					clay.Text(msg.att_names[entry.att], {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})
					clay.Text(view.lang, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
				}
				code_lines(view, index * 4096 + 3072 + u32(j) * 512, CODE_TILE_LINES)
			}
		}

		// Source tiles: highlighted lines with the file name on top.
		for entry, j in msg.codes {
			view := entry.view
			if clay.UI(clay.ID("MsgCode", index * 1024 + u32(j)))(
			{layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(360)}, padding = clay.PaddingAll(10), childGap = 2}, backgroundColor = PLATE, cornerRadius = rr(8)},
			) {
				att_dl_button("DlCode", index * 1024 + u32(j), msg.id, entry.att, msg.att_names[entry.att])
				if clay.UI(clay.ID("MsgCodeName", index * 1024 + u32(j)))({layout = {padding = {bottom = 4}, childGap = 8}}) {
					clay.Text(msg.att_names[entry.att], {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})
					clay.Text(view.lang, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
				}
				code_lines(view, index * 4096 + 3072 + u32(j) * 512, CODE_TILE_LINES)
			}
		}

		// Source tiles: highlighted lines with the file name on top.
		for entry, j in msg.codes {
			view := entry.view
			if clay.UI(clay.ID("MsgCode", index * 1024 + u32(j)))(
			{layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingFixed(360)}, padding = clay.PaddingAll(10), childGap = 2}, backgroundColor = PLATE, cornerRadius = rr(8)},
			) {
				att_dl_button("DlCode", index * 1024 + u32(j), msg.id, entry.att, msg.att_names[entry.att])
				if clay.UI(clay.ID("MsgCodeName", index * 1024 + u32(j)))({layout = {padding = {bottom = 4}, childGap = 8}}) {
					clay.Text(msg.att_names[entry.att], {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})
					clay.Text(view.lang, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
				}
				code_lines(view, index * 4096 + 3072 + u32(j) * 512, CODE_TILE_LINES)
			}
		}

		// Font tiles: the rasterized specimen.
		for entry, j in msg.fonts {
			view := entry.view
			ratio := view.h > 0 ? f32(view.w) / f32(view.h) : 4
			if clay.UI(clay.ID("MsgFont", index * 1024 + u32(j)))(
			{layout = {sizing = {width = clay.SizingFixed(320)}}, aspectRatio = {ratio}, image = {imageData = &view.tex}, cornerRadius = rr(8)},
			) {
				att_dl_button("DlFont", index * 1024 + u32(j), msg.id, entry.att, msg.att_names[entry.att])
			}
		}

		// File chips (no inline renderer): name + size when this
		// session knows it, offer the download.
		for att_index, j in msg.files {
			if clay.UI(clay.ID("MsgFile", index * 1024 + u32(j)))(
			{layout = {padding = clay.PaddingAll(10), childGap = 10, childAlignment = {y = .Center}}, backgroundColor = hovered() ? HOVER : PLATE, cornerRadius = rr(8)},
			) {
				if hovered() {
					// group is filled at click time (no ui here).
					att_hover = {msg_id = msg.id, index = att_index, name = msg.att_names[att_index]}
				}
				clay.Text(ICON_DOWNLOAD, {fontId = FONT_ICON, fontSize = 14, textColor = TEXT_DIM})
				if clay.UI(clay.ID("MsgFileCol", index * 1024 + u32(j)))(
				{layout = {layoutDirection = .TopToBottom, childGap = 2}},
				) {
					clay.Text(msg.att_names[att_index], {fontId = FONT_TITLE, fontSize = 12, textColor = TEXT})
					size := att_size_label(msg, att_index)
					clay.Text(len(size) > 0 ? fmt.tprintf("%s · Click to download.", size) : "Click to download.", {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
				}
			}
		}

		if msg.media_failed {
			if clay.UI(clay.ID("MsgMediaFail", index))(
			{layout = {padding = clay.PaddingAll(10)}, backgroundColor = hovered() ? HOVER : PLATE, cornerRadius = rr(8)},
			) {
				if hovered() {
					media_retry_hover = true
				}
				clay.Text(tr("Couldn't load attachment. Click to retry."), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM})
			}
		}

		// The quoted parent sits above the body it answers; a click
		// centers that message (handle_reply_jump).
		if len(msg.reply_from) > 0 || len(msg.reply_text) > 0 {
			jumpable := len(msg.reply_id) > 0
			if clay.UI(clay.ID("MsgReplyPrev", index))(
			{layout = {sizing = {width = clay.SizingGrow()}, childGap = 8, padding = clay.PaddingAll(8)}, backgroundColor = jumpable && hovered() ? HOVER : ROW_BG, cornerRadius = rr(6)},
			) {
				if jumpable && hovered() {
					reply_jump_hover = msg.reply_id
				}
				if clay.UI(clay.ID("MsgReplyBar", index))({layout = {sizing = {width = clay.SizingFixed(3), height = clay.SizingGrow()}}, backgroundColor = ACCENT, cornerRadius = rr(2)}) {}
				if clay.UI(clay.ID("MsgReplyCol", index))({layout = {layoutDirection = .TopToBottom, childGap = 2}}) {
					// No author line when the parent is unavailable.
					if len(msg.reply_from) > 0 {
						clay.Text(msg.reply_from, {fontId = FONT_TITLE, fontSize = 11, textColor = ACCENT})
					}
					// Wrapped so a long token (a cashu string, a URL)
					// breaks instead of pushing the bubble off-pane.
					body_text(index * 4096 + 3072, msg.reply_text, 12, TEXT_DIM, wrap_w = body_wrap_w() - 40)
				}
			}
		}

		if len(msg.blocks) == 0 && len(msg.body) > 0 {
			body_text(index * 4096, msg.body, 14, TEXT, true)
		}

		// A shared theme: swatches off the pack itself, so the offer
		// shows what it would do before it is taken.
		if len(msg.theme_name) > 0 {
			theme_offer(index, msg)
		}

		// Tombstone placeholder body, the slint deleted row.
		if msg.deleted {
			clay.Text(tr("This message was deleted"), {fontId = FONT_BODY, fontSize = 13, textColor = TEXT_LO})
		}

		md_blocks(msg.blocks[:], index * 4096, true)

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
						layout = {padding = {left = 8 + pad, right = 8 + pad, top = 3, bottom = 3}, childGap = 4, childAlignment = {y = .Center}},
						backgroundColor = ROW_BG,
						cornerRadius = rr(10),
						border = chip.mine ? clay.BorderElementConfig{color = chip.ghost ? ACCENT_DIM : ACCENT, width = bw()} : {},
					},
					) {
						// Twemoji tile + count, text fallback when the
						// sheet has no tile for this emoji.
						if tex := emoji_tex(chip.emoji); tex != nil {
							if clay.UI(clay.ID("MsgReactionImg", slot))(
							{layout = {sizing = {width = clay.SizingFixed(14)}}, aspectRatio = {1}, image = {imageData = tex}},
							) {}
							if chip.ghost {
								// Nothing to roll: the count is a guess
								// until the ack lands.
								clay.Text(chip.count, {fontId = FONT_BODY, fontSize = COUNT_FS, textColor = TEXT_LO})
							} else {
								count_roll(slot, chip.count, was, roll)
							}
						} else {
							clay.Text(chip.label, {fontId = FONT_BODY, fontSize = 12, textColor = chip.ghost ? TEXT_LO : TEXT})
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
			{layout = {padding = {left = 8, right = 8, top = 3, bottom = 3}, childGap = 5, childAlignment = {y = .Center}}, backgroundColor = hovered() ? HOVER : ROW_BG, cornerRadius = rr(10)},
			) {
				clay.Text(ICON_COMMENTS, {fontId = FONT_ICON, fontSize = 11, textColor = ACCENT})
				clay.Text(fmt.tprintf(tr("%d replies"), msg.thread_replies), {fontId = FONT_BODY, fontSize = 12, textColor = TEXT})
			}
		}

		// Tiny accent "edited" marker, click opens the history modal.
		if msg.edited {
			if clay.UI(clay.ID("MsgEdited", index))({layout = {padding = {top = 1, bottom = 1, right = 4}}}) {
				clay.Text(tr("edited"), {fontId = FONT_BODY, fontSize = 10, textColor = ACCENT})
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

caret :: proc(h: f32 = 16) {
	alpha := f32(1)
	if since := rl.GetTime() - caret_at; since > CARET_SOLID && motion_on() {
		// A cosine clipped above 1: on for most of the cycle, with the
		// edges softened. A hard toggle reads as a glitch next to
		// everything else that moves here.
		TAU :: 6.28318530717959
		phase := since - f64(i64(since / CARET_BLINK)) * CARET_BLINK
		alpha = clamp(1.8 * (0.5 + 0.5 * sin_approx(phase * TAU / CARET_BLINK + TAU / 4)), 0, 1)
	}
	if clay.UI(clay.ID_LOCAL("Caret"))(
	{layout = {sizing = {width = clay.SizingFixed(CARET_W), height = clay.SizingFixed(h)}}, backgroundColor = fade(TEXT, alpha)},
	) {}
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
scrollbar :: proc(container: clay.ElementId) {
	data := clay.GetScrollContainerData(container)
	if !data.found || data.contentDimensions.height <= data.scrollContainerDimensions.height {
		return
	}
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
		floating = {attachTo = .ElementWithId, parentId = container.id, offset = {-3, y}, zIndex = 5, attachment = {element = .RightTop, parent = .RightTop}},
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
	text: string,
	tex:  ^rl.Texture2D,
	hex:  string, // mentioned account, "" = not a mention
	url:  string, // http(s) link, "" = not a link (linkguard.odin)
	fx:   u8, // glyph-effect bits from {name} markup (effects.odin)
}

// Render one line of body text with emoji as Twemoji tiles: split into
// text runs and emoji clusters (VS16/ZWJ ride along; a cluster the
// sheet misses falls back per rune, then to raw text). An emoji-only
// line draws bigger tiles, like the slint body.
// ponytail: mixed emoji+text lines lose clay's text wrapping; port the
// slint run/line model if long mixed lines become common.
// Split text into text runs and emoji clusters (VS16/ZWJ ride along;
// a cluster the sheet misses falls back per rune, then raw text).
inline_segs :: proc(text: string) -> [dynamic]Inline_Seg {
	segs := make([dynamic]Inline_Seg, context.temp_allocator)
	plain_start := 0
	i := 0
	for i < len(text) {
		r, w := utf8.decode_rune_in_string(text[i:])
		if r == 'm' || r == 'M' {
			// marmot://profile deep link becomes one mention chip too;
			// clicking it opens the profile like a mention.
			if end, hx, ok := marmot_link_at(text, i); ok {
				if i > plain_start {
					append(&segs, Inline_Seg{text = text[plain_start:i]})
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
					append(&segs, Inline_Seg{text = text[plain_start:i]})
				}
				for seg in inline_segs(text[after:inner_end]) {
					tagged := seg
					tagged.fx |= bit
					// Motion acts per glyph, like slint's RunCell, so a
					// moving text seg splits into letters. A very long run
					// stays whole: the per-letter ids would collide.
					plain := tagged.tex == nil && len(tagged.hex) == 0 && len(tagged.url) == 0
					if tagged.fx & FX_MOTION == 0 || !plain || len(tagged.text) > FX_LETTERS_MAX {
						append(&segs, tagged)
						continue
					}
					for at := 0; at < len(tagged.text); {
						_, w := utf8.decode_rune_in_string(tagged.text[at:])
						letter := tagged
						letter.text = tagged.text[at:at + w]
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
					append(&segs, Inline_Seg{text = text[plain_start:i]})
				}
				append(&segs, Inline_Seg{text = link, url = link})
				i = end
				plain_start = end
				continue
			}
		}
		if r == '@' || r == 'n' {
			// npub/nprofile token (bare, "@"- or "nostr:"-prefixed)
			// becomes a mention seg; body lines draw it as a chip.
			if end, hx, ok := mention_at(text, i); ok {
				if i > plain_start {
					append(&segs, Inline_Seg{text = text[plain_start:i]})
				}
				append(&segs, Inline_Seg{text = text[i:end], hex = hx})
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
					append(&segs, Inline_Seg{text = text[plain_start:i]})
				}
				append(&segs, Inline_Seg{tex = ctex})
				i = end
				plain_start = end
				continue
			}
		}
		if !is_emoji_rune(r) {
			i += w
			continue
		}
		if i > plain_start {
			append(&segs, Inline_Seg{text = text[plain_start:i]})
		}
		j := i + w
		for j < len(text) {
			r2, w2 := utf8.decode_rune_in_string(text[j:])
			if !is_emoji_rune(r2) && r2 != 0xFE0F && r2 != 0x200D {
				break
			}
			j += w2
		}
		if tex := emoji_tex(text[i:j]); tex != nil {
			append(&segs, Inline_Seg{tex = tex})
		} else {
			k := i
			for k < j {
				r3, w3 := utf8.decode_rune_in_string(text[k:])
				sub := text[k:k + w3]
				k += w3
				if r3 == 0xFE0F || r3 == 0x200D {
					continue
				}
				if tex2 := emoji_tex(sub); tex2 != nil {
					append(&segs, Inline_Seg{tex = tex2})
				} else {
					append(&segs, Inline_Seg{text = sub})
				}
			}
		}
		i = j
		plain_start = j
	}
	if plain_start < len(text) {
		append(&segs, Inline_Seg{text = text[plain_start:]})
	}
	return segs
}

// Emit segments inline into the current parent element. chips draws
// mention segs as name plates (bodies); composer lines keep the raw
// token so caret hit-mapping stays byte-accurate.
render_segs :: proc(id: u32, segs: []Inline_Seg, font_size: u16, color: clay.Color, tile_px: f32, chips := false) {
	for seg, k in segs {
		if seg.tex != nil {
			if clay.UI(clay.ID("SegEmoji", id * 128 + u32(k)))(
			{layout = {sizing = {width = clay.SizingFixed(tile_px)}}, aspectRatio = {1}, image = {imageData = seg.tex}},
			) {}
		} else if chips && len(seg.url) > 0 {
			// Links only in bodies: composer lines keep the raw text so
			// caret hit-mapping stays byte-accurate.
			if clay.UI(clay.ID("SegLink", id * 128 + u32(k)))(
			{layout = {padding = {left = 2, right = 2}}, backgroundColor = hovered() ? HOVER : {}, cornerRadius = rr(4)},
			) {
				if hovered() {
					link_hover = seg.url
				}
				clay.Text(seg.text, {fontId = FONT_BODY, fontSize = font_size, textColor = ACCENT})
			}
		} else if chips && len(seg.hex) > 0 {
			// Chip tinted by the account's stable avatar hue; a mention
			// of me gets the accent border. Click opens the profile.
			me := g_ui != nil && seg.hex == g_ui.account_ref
			if clay.UI(clay.ID("SegMention", id * 128 + u32(k)))(
			{
				layout = {padding = {left = 6, right = 6, top = 1, bottom = 1}},
				backgroundColor = avatar_color(seg.hex),
				cornerRadius = rr(7),
				border = me ? clay.BorderElementConfig{color = ACCENT, width = bw()} : {},
			},
			) {
				if hovered() {
					mention_hover = seg.hex
				}
				clay.Text(fmt.tprintf("@%s", mention_label(seg.hex)), {fontId = FONT_TITLE, fontSize = font_size, textColor = {255, 255, 255, 235}})
			}
		} else if seg.fx != 0 {
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
					sizing = {width = clay.SizingFixed(cell + 2 * FX_AMP), height = clay.SizingFixed(f32(size) + 2 + 2 * FX_AMP)},
					padding = {left = u16(FX_AMP + clamp(dx, -FX_AMP, FX_AMP)), top = u16(FX_AMP + clamp(dy, -FX_AMP, FX_AMP))},
				},
			},
			) {
				clay.Text(seg.text, {fontId = FONT_BODY, fontSize = size, textColor = tint})
			}
		} else {
			clay.Text(seg.text, {fontId = FONT_BODY, fontSize = font_size, textColor = color})
		}
	}
}

// Text width available in the composer pill: last frame's box minus
// the paddings, buttons, and gaps around the text column.
compose_wrap_w :: proc() -> f32 {
	COMPOSE_CHROME :: f32(210)
	box := clay.GetElementData(clay.ID("ComposeBox"))
	if !box.found {
		return 480
	}
	return max(box.boundingBox.width - COMPOSE_CHROME, 120)
}

// Byte ranges of the composer's visual lines: each physical '\n' line
// greedily wrapped to the pill's text width. Spaces at a wrap stay on
// the upper line so every byte keeps exactly one row and caret
// hit-mapping stays byte-accurate.
compose_lines :: proc(text: string) -> [dynamic][2]int {
	lines := make([dynamic][2]int, context.temp_allocator)
	width := compose_wrap_w()
	start := 0
	for {
		end := len(text)
		if nl := strings.index_byte(text[start:], '\n'); nl >= 0 {
			end = start + nl
		}
		at := start
		for {
			cut := wrap_break(text, at, end, width, BODY_FS)
			for cut < end && text[cut] == ' ' {
				cut += 1
			}
			append(&lines, [2]int{at, cut})
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
	return lines
}

// One physical composer line [ls, le): up to three spans split at the
// selection [lo, hi) (middle span highlighted), the caret at the
// selection head, the IME preedit riding at the caret.
compose_line :: proc(i: u32, text: string, ls, le, lo, hi, head: int) {
	if clay.UI(clay.ID("ComposeLine", i))(
	{layout = {sizing = {height = clay.SizingFit({min = 20})}, childGap = 1, childAlignment = {y = .Center}}},
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
			if clay.UI(clay.ID("ComposeSel", i))({backgroundColor = ACCENT, layout = {childGap = 1, childAlignment = {y = .Center}}}) {
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

// Render one line of body text with emoji as Twemoji tiles. An
// emoji-only line draws bigger tiles, like the slint body.
// ponytail: mixed emoji+text lines lose clay's text wrapping; port the
// slint run/line model if long mixed lines become common.
// `sel` is the selected byte range inside this line ({-1,-1} = none,
// bodysel.odin), drawn as a highlighted middle span like the composer.
// `boxed` wraps the line in an element hit-testing can measure; the
// caller sets it for pre-wrapped (selectable) bodies only, because an
// element around a plain Text would take clay's own wrapping away.
body_line :: proc(id: u32, text: string, font_size: u16, color: clay.Color, sel := [2]int{-1, -1}, boxed := false) {
	if sel[0] >= 0 {
		if clay.UI(clay.ID("BodyLine", id))({layout = {childGap = 2, childAlignment = {y = .Center}}}) {
			if sel[0] > 0 {
				render_segs(id * 4, inline_segs(text[:sel[0]])[:], font_size, color, f32(font_size) + 4, true)
			}
			if clay.UI(clay.ID("BodySel", id))({layout = {childGap = 2, childAlignment = {y = .Center}}, backgroundColor = ACCENT}) {
				render_segs(id * 4 + 1, inline_segs(text[sel[0]:sel[1]])[:], font_size, ON_ACCENT, f32(font_size) + 4)
			}
			if sel[1] < len(text) {
				render_segs(id * 4 + 2, inline_segs(text[sel[1]:])[:], font_size, color, f32(font_size) + 4, true)
			}
		}
		return
	}

	segs := inline_segs(text)
	if len(segs) == 1 && segs[0].tex == nil && len(segs[0].hex) == 0 && len(segs[0].url) == 0 && len(segs[0].text) == len(text) {
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

	emoji_only := true
	tiles := 0
	for seg in segs {
		if seg.tex == nil && len(strings.trim_space(seg.text)) > 0 {
			emoji_only = false
		}
		tiles += seg.tex != nil ? 1 : 0
	}
	tile_px := emoji_only && tiles <= 6 ? f32(28) : f32(font_size) + 4

	if clay.UI(clay.ID("BodyLine", id))({layout = {childGap = 2, childAlignment = {y = .Center}}}) {
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

md_table :: proc(id: u32, cells: [][]string) {
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
	for row in cells {
		for cell, c in row {
			widths[c] = max(widths[c], rl.MeasureTextLine(FONT_BODY, 13, cell, 0).x)
		}
	}
	for &w in widths {
		w = min(w, MD_TABLE_COL_MAX) + MD_TABLE_PAD * 2
	}

	if clay.UI(clay.ID("MsgTable", id))(
	{layout = {layoutDirection = .TopToBottom}, border = {color = FIELD_BORDER, width = bw()}, cornerRadius = rr(4)},
	) {
		for row, r in cells {
			if clay.UI(clay.ID("MsgTableRow", id + u32(r) * 64))(
			{layout = {}, backgroundColor = r == 0 ? PLATE : {}},
			) {
				for c in 0 ..< cols {
					text := c < len(row) ? row[c] : ""
					if clay.UI(clay.ID("MsgTableCell", id + u32(r) * 64 + u32(c)))(
					{layout = {sizing = {width = clay.SizingFixed(widths[c]), height = clay.SizingGrow()}, padding = clay.PaddingAll(MD_TABLE_PAD)}, border = {color = FIELD_BORDER, width = {0, c < cols - 1 ? 1 : 0, 0, r < len(cells) - 1 ? 1 : 0, 0}}},
					) {
						clay.Text(text, {fontId = r == 0 ? FONT_TITLE : FONT_BODY, fontSize = 13, textColor = r == 0 ? TEXT : TEXT_DIM})
					}
				}
			}
		}
	}
}
// the preview modal. id_base namespaces the clay ids per call site.
md_blocks :: proc(blocks: []Md_Block_Ui, id_base: u32, selectable := false) {
	for block, j in blocks {
		block_id := id_base + u32(j) * 16
		switch block.kind {
		case .Para:
			body_text(block_id + 1, block.text, BODY_FS, TEXT, selectable)
		case .Heading:
			size := u16(max(24 - block.level * 2, 15))
			clay.Text(block.text, {fontId = FONT_TITLE, fontSize = size, textColor = TEXT})
		case .Code:
			if clay.UI(clay.ID("MsgCode", block_id))(
			{layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(10)}, backgroundColor = PLATE, cornerRadius = rr(6)},
			) {
				clay.Text(block.text, {fontId = FONT_MONO, fontSize = 13, textColor = TEXT})
			}
		case .Quote:
			if clay.UI(clay.ID("MsgQuote", block_id))({layout = {childGap = 8}}) {
				if clay.UI(clay.ID("MsgQuoteBar", block_id))({layout = {sizing = {width = clay.SizingFixed(3), height = clay.SizingGrow()}}, backgroundColor = ACCENT, cornerRadius = rr(2)}) {}
				clay.Text(block.text, {fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM})
			}
		case .List_Item:
			body_text(block_id + 2, block.text, BODY_FS, TEXT, selectable)
		case .Rule:
			if clay.UI(clay.ID("MsgRule", block_id))({layout = {sizing = {width = clay.SizingFixed(240), height = clay.SizingFixed(1)}}, backgroundColor = TEXT_DIM}) {}
		case .Table:
			md_table(block_id, block.cells)
		}
	}
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
body_text :: proc(id: u32, text: string, font_size: u16, color: clay.Color, selectable := false, wrap_w: f32 = 0) {
	wrap := wrap_w > 0 ? wrap_w : (selectable ? body_wrap_w() : 0)
	start := 0
	i := u32(0)
	for {
		end := len(text)
		if nl := strings.index_byte(text[start:], '\n'); nl >= 0 {
			end = start + nl
		}
		at := start
		for at < end {
			cut := wrap > 0 ? wrap_break(text, at, end, wrap, font_size) : end
			line_id := id * 8 + i
			i += 1
			if selectable {
				sel_register(line_id, id, at, text[at:cut], text, font_size)
				body_line(line_id, text[at:cut], font_size, color, sel_range(id, at, cut - at), true)
			} else {
				body_line(line_id, text[at:cut], font_size, color)
			}
			at = cut
			// A break at a space swallows it, like every wrapper.
			if at < end && text[at] == ' ' {
				at += 1
			}
		}
		if end == len(text) {
			break
		}
		start = end + 1
		i += 1
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
	avail := f32(rl.GetScreenWidth()) / UI_ZOOM - rail_width(g_ui) - 40
	return max(min(tl.boundingBox.width, avail) - MSG_ROW_CHROME, 120)
}

// Greedy break: the longest run of whole words from `at` that fits
// `width`, or one over-long word. Widths are measured with the body
// font, so emoji tiles and mention chips (drawn wider) can push a line
// slightly over, the same estimate the slint wrapper makes.
wrap_break :: proc(text: string, at, end: int, width: f32, font_size: u16) -> int {
	cut := at
	for {
		next := cut
		for next < end && text[next] == ' ' {
			next += 1
		}
		for next < end && text[next] != ' ' {
			next += 1
		}
		if next == cut {
			break
		}
		if rl.MeasureTextLine(FONT_BODY, font_size, text[at:next], 0).x > width {
			if cut > at {
				return cut
			}
			// One word wider than the line (a cashu token, a long
			// URL): break it mid-word at the last rune that fits.
			return rune_fit(text, at, next, width, font_size)
		}
		cut = next
		if cut >= end {
			break
		}
	}
	return end
}

// Longest prefix of [at, end) that fits `width`, cut on a rune
// boundary, never empty. Per-rune advances (no kerning), the same
// estimate hit_compose_line makes.
rune_fit :: proc(text: string, at, end: int, width: f32, font_size: u16) -> int {
	pen: f32 = 0
	i := at
	for i < end {
		_, w := utf8.decode_rune_in_string(text[i:])
		adv := rl.MeasureTextLine(FONT_BODY, font_size, text[i:i + w], 0).x
		if i > at && pen + adv > width {
			return i
		}
		pen += adv
		i += w
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
		layout = {sizing = {width = clay.SizingFixed(260)}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(12), childGap = 8},
		backgroundColor = PLATE,
		cornerRadius = rr(10),
		border = {color = CARD_BORDER, width = bw()},
	},
	) {
		clay.Text(tr("SHARED THEME"), {fontId = FONT_MONO, fontSize = 10, textColor = TEXT_LO, letterSpacing = 2})
		clay.Text(msg.theme_name, {fontId = FONT_TITLE, fontSize = 14, textColor = TEXT})
		if clay.UI(clay.ID("ThemeSwatches", index))({layout = {childGap = 4}}) {
			for color, i in msg.theme_swatch {
				if clay.UI(clay.ID("ThemeSwatch", index * 16 + u32(i)))(
				{layout = {sizing = {width = clay.SizingFixed(28), height = clay.SizingFixed(28)}}, backgroundColor = color, cornerRadius = rr(6), border = {color = DIVIDER, width = bw()}},
				) {}
			}
		}
		micro_button(fmt.tprintf("ThemeApply%d", index), "Use this theme")
	}
}
