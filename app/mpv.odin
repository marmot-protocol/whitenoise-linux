// Minimal libmpv bindings for the inline video tiles: one mpv handle
// per video, fed from memory via the stream-cb protocol, rendered
// with the "sw" render API into an RGBA buffer (no GL interop; the
// app draws through the SDL 2D renderer).
package main

import "core:c"

foreign import libmpv "system:mpv"

mpv_handle :: struct {}
mpv_render_context :: struct {}

mpv_render_param :: struct {
	type: c.int,
	data: rawptr,
}

// render.h
MPV_RENDER_PARAM_INVALID :: 0
MPV_RENDER_PARAM_API_TYPE :: 1
MPV_RENDER_PARAM_SW_SIZE :: 17
MPV_RENDER_PARAM_SW_FORMAT :: 18
MPV_RENDER_PARAM_SW_STRIDE :: 19
MPV_RENDER_PARAM_SW_POINTER :: 20
MPV_RENDER_API_TYPE_SW: cstring : "sw"
MPV_RENDER_UPDATE_FRAME :: 1

// client.h
MPV_EVENT_NONE :: 0
MPV_EVENT_END_FILE :: 7
MPV_EVENT_PROPERTY_CHANGE :: 22
MPV_END_FILE_REASON_ERROR :: 4
MPV_FORMAT_FLAG :: 3
MPV_FORMAT_INT64 :: 4
MPV_FORMAT_DOUBLE :: 5

mpv_event :: struct {
	event_id:       c.int,
	error:          c.int,
	reply_userdata: u64,
	data:           rawptr,
}

mpv_event_property :: struct {
	name:   cstring,
	format: c.int, // MPV_FORMAT_NONE when the value is unavailable
	data:   rawptr,
}

mpv_event_end_file :: struct {
	reason:                    c.int,
	error:                     c.int,
	playlist_entry_id:         i64,
	playlist_insert_id:        i64,
	playlist_insert_num_entries: c.int,
}

mpv_stream_cb_info :: struct {
	cookie:    rawptr,
	read_fn:   proc "c" (cookie: rawptr, buf: [^]u8, nbytes: u64) -> i64,
	seek_fn:   proc "c" (cookie: rawptr, offset: i64) -> i64,
	size_fn:   proc "c" (cookie: rawptr) -> i64,
	close_fn:  proc "c" (cookie: rawptr),
	cancel_fn: proc "c" (cookie: rawptr),
}

mpv_stream_cb_open_fn :: proc "c" (user_data: rawptr, uri: cstring, info: ^mpv_stream_cb_info) -> c.int

@(default_calling_convention = "c")
foreign libmpv {
	mpv_create :: proc() -> ^mpv_handle ---
	mpv_error_string :: proc(error: c.int) -> cstring ---
	mpv_initialize :: proc(ctx: ^mpv_handle) -> c.int ---
	mpv_terminate_destroy :: proc(ctx: ^mpv_handle) ---
	mpv_set_option_string :: proc(ctx: ^mpv_handle, name, data: cstring) -> c.int ---
	mpv_command :: proc(ctx: ^mpv_handle, args: [^]cstring) -> c.int ---
	// Synchronous mpv_command waits for the core to process the command:
	// at drag rate that is ~365ms per seek, on the UI thread. Anything
	// issued from input handling goes through the async form.
	mpv_command_async :: proc(ctx: ^mpv_handle, reply_userdata: u64, args: [^]cstring) -> c.int ---
	mpv_get_property :: proc(ctx: ^mpv_handle, name: cstring, format: c.int, data: rawptr) -> c.int ---
	mpv_observe_property :: proc(ctx: ^mpv_handle, reply_userdata: u64, name: cstring, format: c.int) -> c.int ---
	mpv_wait_event :: proc(ctx: ^mpv_handle, timeout: f64) -> ^mpv_event ---
	mpv_stream_cb_add_ro :: proc(ctx: ^mpv_handle, protocol: cstring, user_data: rawptr, open_fn: mpv_stream_cb_open_fn) -> c.int ---
	mpv_render_context_create :: proc(res: ^^mpv_render_context, ctx: ^mpv_handle, params: [^]mpv_render_param) -> c.int ---
	mpv_render_context_update :: proc(ctx: ^mpv_render_context) -> u64 ---
	mpv_render_context_render :: proc(ctx: ^mpv_render_context, params: [^]mpv_render_param) -> c.int ---
	mpv_render_context_free :: proc(ctx: ^mpv_render_context) ---
}
