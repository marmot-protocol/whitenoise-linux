// Inline video tiles: each video attachment gets its own mpv embed,
// playing straight from the decrypted bytes in memory (stream-cb, no
// temp file) and software-rendered into a streaming SDL texture.
//
//   video_view_make: mpv handle + "wnl://" stream over view.data,
//                    loaded paused so the first frame shows
//   advance_videos:  per frame, drain events, adopt the real video
//                    size once known, pull new frames into the texture
//   click on tile:   cycle pause (audio goes through mpv's own ao)
package main

import "core:c"
import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Texture cap; the tile is 320 layout px (480 physical at UI_ZOOM),
// mpv's sw scaler brings larger videos down to this.
VIDEO_MAX_TEX_W :: 480
VIDEO_SW_FORMAT: cstring : "rgb0" // R,G,B,X bytes; texture blend is off

Video_View :: struct {
	data:                             []u8, // decrypted attachment bytes, owned by the view
	pos:                              i64, // stream-cb read cursor
	mpv:                              ^mpv_handle,
	rctx:                             ^mpv_render_context,
	tex:                              rl.Texture2D, // streaming; &tex is the clay imageData
	buf:                              []u8, // sw render target, w*h*4
	w, h:                             i32, // texture size (placeholder until mpv reports)
	sized:                            bool, // real video dimensions adopted
	paused:                           bool,
	looping:                          bool, // GIF mode: autoplay, loop, no scrub bar
	audio:                            bool, // audio-only: no frames, the tile is the controls
	transcript:                       string, // locally recognized text; owned by this view
	transcript_model:                 int, // model index + 1; zero means not checked
	transcript_done, transcript_open: bool,
	audio_hash:                       [32]u8,
	failed:                           bool,
	time:                             f64, // playback position, seconds
	dur:                              f64, // duration, seconds (0 until known)
	dw, dh:                           i64, // mpv's display size, 0 until it reports (post-rotation)
	at_eof:                           bool, // parked at the end by keep-open, so play restarts
}

// Observed properties, identified by reply id so the event handler
// never compares strings. Reading these with mpv_get_property instead
// would block the UI thread until mpv's core answers, which during a
// seek on a large frame is hundreds of milliseconds.
@(private = "file")
PROP_PAUSE :: 1
@(private = "file")
PROP_TIME :: 2
@(private = "file")
PROP_DUR :: 3
@(private = "file")
PROP_DW :: 4
@(private = "file")
PROP_DH :: 5
@(private = "file")
PROP_EOF :: 6

// Stream callbacks run on mpv's demux thread; they only touch the
// view's data slice and read cursor, which nothing else mutates.
@(private = "file")
stream_read :: proc "c" (cookie: rawptr, buf: [^]u8, nbytes: u64) -> i64 {
	view := (^Video_View)(cookie)
	remaining := i64(len(view.data)) - view.pos
	if remaining <= 0 {
		return 0 // EOF
	}
	n := min(i64(nbytes), remaining)
	copy(buf[:n], view.data[view.pos:][:n])
	view.pos += n
	return n
}

@(private = "file")
stream_seek :: proc "c" (cookie: rawptr, offset: i64) -> i64 {
	view := (^Video_View)(cookie)
	if offset < 0 || offset > i64(len(view.data)) {
		return -1
	}
	view.pos = offset
	return offset
}

@(private = "file")
stream_size :: proc "c" (cookie: rawptr) -> i64 {
	return i64(len((^Video_View)(cookie).data))
}

@(private = "file")
stream_close :: proc "c" (cookie: rawptr) {}

@(private = "file")
stream_open :: proc "c" (user_data: rawptr, uri: cstring, info: ^mpv_stream_cb_info) -> c.int {
	info.cookie = user_data // the view; one protocol per mpv handle
	info.read_fn = stream_read
	info.seek_fn = stream_seek
	info.size_fn = stream_size
	info.close_fn = stream_close
	return 0
}

// data ownership transfers to the view. Loop mode is for GIFs:
// autoplay, repeat forever, no scrub bar.
Video_Mode :: enum {
	Clip, // start paused on the first frame, keep-open at EOF
	Loop,
	Audio, // clip behavior, but no video track to render
}

video_view_make :: proc(
	data: []u8,
	mode: Video_Mode = .Clip,
	phase: Media_Phase = .Present,
) -> ^Video_View {
	view := new(Video_View)
	view.data = data
	view.paused = mode != .Loop
	view.looping = mode == .Loop
	view.audio = mode == .Audio
	if view.audio {
		ctx: sha2.Context_256
		sha2.init_256(&ctx)
		sha2.update(&ctx, data)
		sha2.final(&ctx, view.audio_hash[:])
	}
	view.w, view.h = 320, 180
	view.buf = make([]u8, int(view.w) * int(view.h) * 4)
	if phase == .Present {
		view.tex = rl.CreateStreamTexture(view.w, view.h)
	}

	view.mpv = mpv_create()
	if view.mpv == nil {
		view.failed = true
		return view
	}
	mpv_set_option_string(view.mpv, "vo", "libmpv")
	// Render ahead by nothing: with the default 50ms offset,
	// mpv_render_context_render() blocks on the UI thread until the
	// frame's target display time, costing up to a frame period per
	// playing video per frame.
	mpv_set_option_string(view.mpv, "video-timing-offset", "0")
	// WN_DEBUG_MPV=log lets mpv's own log out (it is thousands of
	// lines a second, enough to skew what the metrics measure);
	// any other value keeps just the per-second metrics line.
	if mpv_log() {
		mpv_set_option_string(view.mpv, "terminal", "yes")
		mpv_set_option_string(view.mpv, "msg-level", "all=v")
	} else {
		mpv_set_option_string(view.mpv, "terminal", "no")
	}
	if mode == .Loop {
		mpv_set_option_string(view.mpv, "loop-file", "inf")
	} else {
		mpv_set_option_string(view.mpv, "keep-open", "yes")
		mpv_set_option_string(view.mpv, "pause", "yes")
	}

	ok :=
		mpv_initialize(view.mpv) == 0 &&
		mpv_stream_cb_add_ro(view.mpv, "wnl", view, stream_open) == 0

	if ok {
		mpv_observe_property(view.mpv, PROP_PAUSE, "pause", MPV_FORMAT_FLAG)
		mpv_observe_property(view.mpv, PROP_TIME, "time-pos", MPV_FORMAT_DOUBLE)
		mpv_observe_property(view.mpv, PROP_DUR, "duration", MPV_FORMAT_DOUBLE)
		mpv_observe_property(view.mpv, PROP_DW, "dwidth", MPV_FORMAT_INT64)
		mpv_observe_property(view.mpv, PROP_DH, "dheight", MPV_FORMAT_INT64)
		mpv_observe_property(view.mpv, PROP_EOF, "eof-reached", MPV_FORMAT_FLAG)
	}
	if ok {
		params := [2]mpv_render_param {
			{MPV_RENDER_PARAM_API_TYPE, transmute(rawptr)MPV_RENDER_API_TYPE_SW},
			{MPV_RENDER_PARAM_INVALID, nil},
		}
		ok = mpv_render_context_create(&view.rctx, view.mpv, &params[0]) == 0
	}
	if ok {
		cmd := [3]cstring{"loadfile", "wnl://chat", nil}
		ok = mpv_command_async(view.mpv, 0, &cmd[0]) == 0
	}
	if !ok {
		view.failed = true
		fmt.eprintfln("video: mpv setup failed")
	}
	return view
}

// Once mpv knows the real dimensions, size the texture to the video's
// aspect (capped) so the tile stops being a 16:9 placeholder. Returns
// whether the texture was replaced, which costs its contents.
@(private = "file")
adopt_size :: proc(view: ^Video_View) -> bool {
	w, h := view.dw, view.dh
	if w <= 0 || h <= 0 {
		return false
	}
	view.sized = true

	tw := min(i64(VIDEO_MAX_TEX_W), w)
	th := max(1, h * tw / w)
	view.w, view.h = i32(tw), i32(th)
	delete(view.buf)
	view.buf = make([]u8, int(tw) * int(th) * 4)
	rl.UnloadTexture(view.tex)
	view.tex = rl.CreateStreamTexture(view.w, view.h)
	return true
}

// The modal preview owns its own mpv instance; the render context
// must go before the handle (mpv requirement).
video_view_free :: proc(view: ^Video_View) {
	if view.rctx != nil {
		mpv_render_context_free(view.rctx)
	}
	if view.mpv != nil {
		mpv_terminate_destroy(view.mpv)
	}
	rl.UnloadTexture(view.tex)
	delete(view.buf)
	delete(view.transcript)
	delete(view.data)
	free(view)
}

// Per-frame service pass for every live embed (timeline cache plus
// the preview modal's video); runs on the render thread (texture
// updates must). mpv decodes on its own threads, the sw blit here is
// tile-sized and cheap.
advance_videos :: proc() {
	start := time.tick_now()
	for _, view in video_views {
		advance_one(view)
	}
	if preview_shown && preview.vid != nil && !preview.vid_shared {
		advance_one(preview.vid)
	}
	if g_ui != nil && g_ui.picker_open && g_ui.gif_tab {
		advance_one(g_ui.gif_view)
	}

	// WN_DEBUG_MPV: where a laggy frame actually goes. "advance" is
	// this pass, "frame" is the whole previous frame.
	if !mpv_debug() {
		return
	}
	dbg_tick += 1
	spent := f32(time.duration_milliseconds(time.tick_since(start)))
	dbg_spent = max(dbg_spent, spent)
	dbg_frame = max(dbg_frame, rl.GetFrameTime() * 1000)
	if dbg_tick % 60 == 0 {
		fmt.eprintfln(
			"video: %d views | worst frame %.1f ms (%.0f fps) = advance %.1f + build %.1f + draw %.1f | seeks %d",
			len(video_views),
			dbg_frame,
			1000 / max(dbg_frame, 0.001),
			dbg_spent,
			video_dbg_build,
			video_dbg_draw,
			dbg_seeks,
		)
		dbg_spent, dbg_frame, dbg_seeks = 0, 0, 0
		video_dbg_build, video_dbg_draw = 0, 0
	}
}

@(private = "file")
dbg_tick: int
@(private = "file")
dbg_spent, dbg_frame: f32

// Worst build_layout and draw_frame of the last second, filled in by
// the frame loop: a laggy frame is one of these three or none of them.
video_dbg_build, video_dbg_draw: f32
@(private = "file")
dbg_seeks: int

@(private = "file")
advance_one :: proc(view: ^Video_View) {
	if view == nil || view.failed {
		return
	}

	// Playback that dies mid-file (bad demux, missing codec) is
	// otherwise a tile that stays blank forever.
	for {
		event := mpv_wait_event(view.mpv, 0)
		if event == nil || event.event_id == MPV_EVENT_NONE {
			break
		}
		if event.data == nil {
			continue
		}
		if event.event_id == MPV_EVENT_END_FILE {
			end := (^mpv_event_end_file)(event.data)
			if end.reason == MPV_END_FILE_REASON_ERROR {
				view.failed = true
				fmt.eprintfln("video: playback failed (%s)", mpv_error_string(end.error))
				return
			}
			continue
		}
		if event.event_id != MPV_EVENT_PROPERTY_CHANGE {
			continue
		}
		prop := (^mpv_event_property)(event.data)
		if prop.data == nil {
			continue // MPV_FORMAT_NONE: not available yet
		}
		switch event.reply_userdata {
		case PROP_PAUSE:
			view.paused = (^c.int)(prop.data)^ != 0
		case PROP_TIME:
			view.time = (^f64)(prop.data)^
		case PROP_DUR:
			view.dur = (^f64)(prop.data)^
		case PROP_DW:
			view.dw = (^i64)(prop.data)^
		case PROP_DH:
			view.dh = (^i64)(prop.data)^
		case PROP_EOF:
			view.at_eof = (^c.int)(prop.data)^ != 0
		}
	}

	// A paused clip raises the frame flag exactly once, and it can
	// arrive before mpv knows video-params. Resizing then throws that
	// frame away with the old texture, so repaint the new one instead
	// of waiting for a flag that never comes.
	resized := !view.sized && !view.audio && adopt_size(view)

	if view.rctx == nil {
		return
	}
	fresh := mpv_render_context_update(view.rctx) & MPV_RENDER_UPDATE_FRAME != 0
	if fresh || resized {
		size := [2]c.int{c.int(view.w), c.int(view.h)}
		stride := c.size_t(view.w * 4)
		params := [5]mpv_render_param {
			{MPV_RENDER_PARAM_SW_SIZE, &size},
			{MPV_RENDER_PARAM_SW_FORMAT, transmute(rawptr)VIDEO_SW_FORMAT},
			{MPV_RENDER_PARAM_SW_STRIDE, &stride},
			{MPV_RENDER_PARAM_SW_POINTER, raw_data(view.buf)},
			{MPV_RENDER_PARAM_INVALID, nil},
		}
		if mpv_render_context_render(view.rctx, &params[0]) == 0 {
			rl.UpdateTexturePixels(&view.tex, raw_data(view.buf))
		}
	}
}

@(private = "file")
dbg_on := -1

@(private = "file")
mpv_debug :: proc() -> bool {
	if dbg_on < 0 {
		dbg_on = os.get_env("WN_DEBUG_MPV", context.temp_allocator) != "" ? 1 : 0
	}
	return dbg_on == 1
}

@(private = "file")
mpv_log :: proc() -> bool {
	return os.get_env("WN_DEBUG_MPV", context.temp_allocator) == "log"
}

// Hover recorded during the layout build, click handled after it.
video_hover: ^Video_View

handle_video :: proc() {
	if video_full_hover.view != nil && mouse_released() && !video_bar_active() {
		preview_close()
		preview = {
			kind       = .Video,
			name       = strings.clone(video_full_hover.name),
			vid        = video_full_hover.view,
			vid_shared = true,
			bytes      = video_full_hover.view.data,
		}
		preview_shown = true
		rl.SetFullscreen(true)
		video_full_hover = {}
		return
	}
	// att_hover set = the pointer is on the download chip, not the video.
	if video_hover == nil || !mouse_released() || att_hover.msg_id != "" || video_bar_active() {
		return
	}

	// Play at the end restarts (keep-open parks the clip at EOF).
	if video_hover.at_eof {
		seek := [4]cstring{"seek", "0", "absolute", nil}
		mpv_command_async(video_hover.mpv, 0, &seek[0])
	}
	cmd := [3]cstring{"cycle", "pause", nil}
	mpv_command_async(video_hover.mpv, 0, &cmd[0])
}

// Scrub bars, same registration shape as the g-code slider: rebuilt
// every build, the drag spans frames and seeks as it moves.
Video_Bar :: struct {
	id:   clay.ElementId,
	view: ^Video_View,
}

video_bars: [dynamic]Video_Bar
video_bar_drag: Video_Bar

@(private)
video_full_hover: struct {
	view: ^Video_View,
	name: string,
}

// Seeking owns the gesture even after the pointer leaves the bar.
@(private)
video_bar_active :: proc() -> bool {
	if video_bar_drag.view != nil {return true}
	for bar in video_bars {
		if clay.PointerOver(bar.id) {return true}
	}
	return false
}

@(private)
video_scrub_bar :: proc(id: clay.ElementId, view: ^Video_View, width: f32, z_index: i16 = 7) {
	if view.looping {return}
	expanded := hovered() || clay.PointerOver(id) || video_bar_drag.view == view
	append(&video_bars, Video_Bar{id, view})
	frac := view.dur > 0 ? clamp(f32(view.time / view.dur), 0, 1) : 0
	if clay.UI(id)(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(width),
				height = clay.SizingFixed(expanded ? 14 : 2),
			},
			childAlignment = {y = .Center},
		},
		floating = {
			attachTo = .Parent,
			clipTo = .AttachedParent,
			zIndex = z_index,
			attachment = {element = .LeftBottom, parent = .LeftBottom},
		},
		backgroundColor = {0, 0, 0, 150},
	},
	) {
		if hovered() {video_hover = nil}
		if clay.UI(clay.ID("VideoFill", id.id))(
		{
			layout = {
				sizing = {
					width = clay.SizingFixed(frac * width),
					height = clay.SizingFixed(expanded ? 10 : 2),
				},
			},
			backgroundColor = ACCENT,
		},
		) {}
	}
}

@(private = "file")
bar_sent: f64 = -1 // last position asked for, so a still pointer stays quiet

handle_video_bar :: proc() {
	if rl.IsMouseButtonPressed(.LEFT) {
		for bar in video_bars {
			if clay.PointerOver(bar.id) {
				video_bar_drag = bar
				break
			}
		}
	}
	if video_bar_drag.view == nil {
		return
	}
	// Release lands the exact frame; the drag itself never does.
	if !rl.IsMouseButtonDown(.LEFT) {
		if bar_sent >= 0 {
			seek_to(video_bar_drag.view, bar_sent, "absolute")
		}
		video_bar_drag = {}
		bar_sent = -1
		return
	}

	bb := clay.GetElementData(video_bar_drag.id).boundingBox
	view := video_bar_drag.view
	if bb.width <= 0 || view.dur <= 0 {
		return
	}
	frac := clamp((rl.GetMousePosition().x / UI_ZOOM - bb.x) / bb.width, 0, 1)
	target := f64(frac) * view.dur
	if abs(target - bar_sent) < 0.05 {
		return
	}
	bar_sent = target

	// Keyframes only while dragging: an exact seek decodes every frame
	// from the preceding keyframe, which on a large 60fps clip costs
	// more than the frame budget and turns the drag into a slideshow.
	seek_to(view, target, "absolute+keyframes")
}

@(private = "file")
seek_to :: proc(view: ^Video_View, seconds: f64, flags: cstring) {
	target := strings.clone_to_cstring(fmt.tprintf("%.3f", seconds), context.temp_allocator)
	cmd := [4]cstring{"seek", target, flags, nil}
	dbg_seeks += 1
	mpv_command_async(view.mpv, 0, &cmd[0])
}

// Other clients send octet-stream for attachments, so the timeline
// and the preview both match extensions as well as the media type.
is_video_name :: proc(lower: string) -> bool {
	return(
		strings.has_suffix(lower, ".mp4") ||
		strings.has_suffix(lower, ".webm") ||
		strings.has_suffix(lower, ".mkv") ||
		strings.has_suffix(lower, ".mov") ||
		strings.has_suffix(lower, ".avi") \
	)
}
