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
import "core:fmt"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

// Texture cap; the tile is 320 layout px (480 physical at UI_ZOOM),
// mpv's sw scaler brings larger videos down to this.
VIDEO_MAX_TEX_W :: 480
VIDEO_SW_FORMAT: cstring : "rgb0" // R,G,B,X bytes; texture blend is off

Video_View :: struct {
	data:    []u8, // decrypted attachment bytes, owned by the view
	pos:     i64, // stream-cb read cursor
	mpv:     ^mpv_handle,
	rctx:    ^mpv_render_context,
	tex:     rl.Texture2D, // streaming; &tex is the clay imageData
	buf:     []u8, // sw render target, w*h*4
	w, h:    i32, // texture size (placeholder until mpv reports)
	sized:   bool, // real video dimensions adopted
	paused:  bool,
	looping: bool, // GIF mode: autoplay, loop, no scrub bar
	audio:   bool, // audio-only: no frames, the tile is the controls
	bars:    []f32, // waveform amplitudes (WAV voice notes), nil = plain scrub bar
	failed:  bool,
	time:    f64, // playback position, seconds
	dur:     f64, // duration, seconds (0 until known)
}

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

video_view_make :: proc(data: []u8, mode: Video_Mode = .Clip) -> ^Video_View {
	view := new(Video_View)
	view.data = data
	view.paused = mode != .Loop
	view.looping = mode == .Loop
	view.audio = mode == .Audio
	view.w, view.h = 320, 180
	view.buf = make([]u8, int(view.w) * int(view.h) * 4)
	view.tex = rl.CreateStreamTexture(view.w, view.h)

	view.mpv = mpv_create()
	if view.mpv == nil {
		view.failed = true
		return view
	}
	mpv_set_option_string(view.mpv, "vo", "libmpv")
	mpv_set_option_string(view.mpv, "terminal", "no")
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
		params := [2]mpv_render_param{
			{MPV_RENDER_PARAM_API_TYPE, transmute(rawptr)MPV_RENDER_API_TYPE_SW},
			{MPV_RENDER_PARAM_INVALID, nil},
		}
		ok = mpv_render_context_create(&view.rctx, view.mpv, &params[0]) == 0
	}
	if ok {
		cmd := [3]cstring{"loadfile", "wnl://chat", nil}
		ok = mpv_command(view.mpv, &cmd[0]) == 0
	}
	if !ok {
		view.failed = true
		fmt.eprintfln("video: mpv setup failed")
	}
	return view
}

// Once mpv knows the real dimensions, size the texture to the video's
// aspect (capped) so the tile stops being a 16:9 placeholder.
@(private = "file")
adopt_size :: proc(view: ^Video_View) {
	w, h: i64
	if mpv_get_property(view.mpv, "video-params/w", MPV_FORMAT_INT64, &w) != 0 ||
	   mpv_get_property(view.mpv, "video-params/h", MPV_FORMAT_INT64, &h) != 0 ||
	   w <= 0 || h <= 0 {
		return
	}
	view.sized = true

	tw := min(i64(VIDEO_MAX_TEX_W), w)
	th := max(1, h * tw / w)
	view.w, view.h = i32(tw), i32(th)
	delete(view.buf)
	view.buf = make([]u8, int(tw) * int(th) * 4)
	rl.UnloadTexture(view.tex)
	view.tex = rl.CreateStreamTexture(view.w, view.h)
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
	delete(view.bars)
	delete(view.data)
	free(view)
}

// Per-frame service pass for every live embed (timeline cache plus
// the preview modal's video); runs on the render thread (texture
// updates must). mpv decodes on its own threads, the sw blit here is
// tile-sized and cheap.
advance_videos :: proc() {
	for _, view in video_views {
		advance_one(view)
	}
	if preview_shown && preview.vid != nil {
		advance_one(preview.vid)
	}
}

@(private = "file")
advance_one :: proc(view: ^Video_View) {
	if view == nil || view.failed {
		return
	}

	for {
		event := mpv_wait_event(view.mpv, 0)
		if event == nil || event.event_id == MPV_EVENT_NONE {
			break
		}
	}

	if !view.sized && !view.audio {
		adopt_size(view)
	}

	pause_flag: c.int = 1
	if mpv_get_property(view.mpv, "pause", MPV_FORMAT_FLAG, &pause_flag) == 0 {
		view.paused = pause_flag != 0
	}
	mpv_get_property(view.mpv, "time-pos", MPV_FORMAT_DOUBLE, &view.time)
	mpv_get_property(view.mpv, "duration", MPV_FORMAT_DOUBLE, &view.dur)

	if view.rctx == nil || mpv_render_context_update(view.rctx) & MPV_RENDER_UPDATE_FRAME == 0 {
		return
	}
	size := [2]c.int{c.int(view.w), c.int(view.h)}
	stride := c.size_t(view.w * 4)
	params := [5]mpv_render_param{
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

// Hover recorded during the layout build, click handled after it.
video_hover: ^Video_View

handle_video :: proc() {
	// att_hover set = the pointer is on the download chip, not the video.
	if video_hover == nil || !mouse_released() || att_hover.msg_id != "" {
		return
	}

	// Play at the end restarts (keep-open parks the clip at EOF).
	eof: c.int
	if mpv_get_property(video_hover.mpv, "eof-reached", MPV_FORMAT_FLAG, &eof) == 0 && eof != 0 {
		seek := [4]cstring{"seek", "0", "absolute", nil}
		mpv_command(video_hover.mpv, &seek[0])
	}
	cmd := [3]cstring{"cycle", "pause", nil}
	mpv_command(video_hover.mpv, &cmd[0])
}

// Scrub bars, same registration shape as the g-code slider: rebuilt
// every build, the drag spans frames and seeks as it moves.
Video_Bar :: struct {
	id:   clay.ElementId,
	view: ^Video_View,
}

video_bars: [dynamic]Video_Bar
video_bar_drag: Video_Bar

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
	if !rl.IsMouseButtonDown(.LEFT) {
		video_bar_drag = {}
		return
	}

	bb := clay.GetElementData(video_bar_drag.id).boundingBox
	view := video_bar_drag.view
	if bb.width <= 0 || view.dur <= 0 {
		return
	}
	frac := clamp((rl.GetMousePosition().x / UI_ZOOM - bb.x) / bb.width, 0, 1)
	target := strings.clone_to_cstring(fmt.tprintf("%.3f", f64(frac) * view.dur), context.temp_allocator)
	cmd := [4]cstring{"seek", target, "absolute", nil}
	mpv_command(view.mpv, &cmd[0])
}
