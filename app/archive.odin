// Archive attachments are listed and extracted by the isolated wn-archive
// helper. The parent validates metadata before publishing a view; neither
// side writes decompressed entries to disk.
package main

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

foreign import arc_decoder {WN_BUILD_DIR + "/libwndecoder.a"}

@(private)
Arc_Op :: enum c.int {
	List,
	Entry,
}

@(private, default_calling_convention = "c")
foreign arc_decoder {
	wn_archive_read :: proc(helper: cstring, data: [^]u8, size: c.int, op: Arc_Op, index: c.uint, count, length: ^c.uint) -> [^]u8 ---
}

ARC_MAX_ENTRIES :: 2000
ARC_MAX_ENTRY_BYTES :: 64 * 1024 * 1024
ARC_TILE_ROWS :: 12
@(private)
ARC_MAX_INPUT_BYTES :: 128 * 1024 * 1024
@(private)
ARC_MAX_LIST_BYTES :: 8 * 1024 * 1024
@(private)
ARC_MAX_HEADERS :: 65536
@(private)
ARC_MAX_NAME_BYTES :: 4096

Arc_Entry :: struct {
	name:  string,
	size:  i64,
	index: int, // header position in the archive stream
}

Arc_View :: struct {
	data:     []u8, // the archive bytes, owned by the view
	entries:  []Arc_Entry, // regular files only
	expanded: bool, // the tile lists every entry, not just the first rows
}

@(private = "file")
arc_u32 :: proc(data: []u8) -> u32 {
	return u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24
}

// Validate the complete untrusted listing before handing any entries to a
// caller. Names are cloned because the transport buffer is malloc-owned.
@(private)
arc_parse_entries :: proc(payload: []u8, count: u32) -> ([]Arc_Entry, bool) {
	if count > ARC_MAX_ENTRIES || len(payload) > ARC_MAX_LIST_BYTES {
		return nil, false
	}
	entries := make([]Arc_Entry, int(count))
	complete := false
	defer {
		if !complete {
			for entry in entries {delete(entry.name)}
			delete(entries)
		}
	}
	position, previous := 0, -1
	for &entry in entries {
		if len(payload) - position < 16 {return nil, false}
		record := payload[position:]
		index := arc_u32(record)
		length := arc_u32(record[4:])
		bits := u64(arc_u32(record[8:])) | u64(arc_u32(record[12:])) << 32
		declared := transmute(i64)bits
		position += 16
		if index >= ARC_MAX_HEADERS ||
		   int(index) <= previous ||
		   length == 0 ||
		   length > ARC_MAX_NAME_BYTES ||
		   int(length) > len(payload) - position ||
		   declared < -1 {
			return nil, false
		}
		name := string(payload[position:position + int(length)])
		if !utf8.valid_string(name) || strings.contains(name, "\x00") {
			return nil, false
		}
		entry = {
			name  = strings.clone(name),
			size  = declared,
			index = int(index),
		}
		position += int(length)
		previous = int(index)
	}
	if position != len(payload) {return nil, false}
	complete = true
	return entries, true
}

// Ownership transfers only on success. Empty archives are not previewable.
arc_view_make :: proc(data: []u8) -> ^Arc_View {
	if len(data) == 0 || len(data) > ARC_MAX_INPUT_BYTES {return nil}
	helper := strings.clone_to_cstring(helper_path("wn-archive"))
	defer delete(helper)
	count, length: c.uint
	payload := wn_archive_read(helper, raw_data(data), c.int(len(data)), .List, 0, &count, &length)
	if payload == nil {return nil}
	defer libc.free(payload)
	if count == 0 {return nil}
	entries, ok := arc_parse_entries(payload[:int(length)], u32(count))
	if !ok {return nil}
	view := new(Arc_View)
	view^ = {
		data    = data,
		entries = entries,
	}
	return view
}

// The returned bytes retain the caller's Odin allocator ownership. In
// particular, previews may retain them in the reload allocator.
arc_entry_bytes :: proc(view: ^Arc_View, header_index: int) -> ([]u8, bool) {
	if view == nil ||
	   len(view.data) == 0 ||
	   len(view.data) > ARC_MAX_INPUT_BYTES ||
	   header_index < 0 ||
	   header_index >= ARC_MAX_HEADERS {
		return nil, false
	}
	helper := strings.clone_to_cstring(helper_path("wn-archive"))
	defer delete(helper)
	count, length: c.uint
	payload := wn_archive_read(
		helper,
		raw_data(view.data),
		c.int(len(view.data)),
		.Entry,
		c.uint(header_index),
		&count,
		&length,
	)
	if payload == nil {return nil, false}
	defer libc.free(payload)
	if count != 0 || length > ARC_MAX_ENTRY_BYTES {return nil, false}
	return slice.clone(payload[:int(length)]), true
}

// "1.4 MiB" style label for the entry rows.
arc_size_label :: proc(size: i64) -> string {
	switch {
	case size >= 1 << 30:
		return fmt.tprintf("%.1f GiB", f64(size) / f64(1 << 30))
	case size >= 1 << 20:
		return fmt.tprintf("%.1f MiB", f64(size) / f64(1 << 20))
	case size >= 1 << 10:
		return fmt.tprintf("%.1f KiB", f64(size) / f64(1 << 10))
	}
	return fmt.tprintf("%d B", size)
}

// Entry row under the pointer, rebound every build.
Arc_Hover :: struct {
	view:  ^Arc_View,
	entry: int, // header index
	name:  string,
}

arc_hover: Arc_Hover

// The "and N more files" row under the tile listing, rebound every
// build like arc_hover.
arc_more_hover: ^Arc_View

// Tile header cap: a path with no spaces can't word-wrap, so a long
// archive name would push the tile past its fixed width.
ARC_NAME_MAX :: 40

arc_short_name :: proc(name: string) -> string {
	if len(name) <= ARC_NAME_MAX {
		return name
	}
	// Keep the tail: the extension and the distinctive part sit there.
	return fmt.tprintf("…%s", name[len(name) - ARC_NAME_MAX + 1:])
}

handle_arc_click :: proc(ui: ^Ui_State) {
	// att_hover set = the click is on the download chip, not a row.
	if !mouse_released() || att_hover.msg_id != "" {
		return
	}
	// The expand row sits under the listing, so it is checked first.
	if arc_more_hover != nil {
		arc_more_hover.expanded = !arc_more_hover.expanded
		return
	}
	if arc_hover.view == nil {
		return
	}
	bytes, ok := arc_entry_bytes(arc_hover.view, arc_hover.entry)
	if !ok {
		ui.client_status = fmt.aprintf("couldn't read %s", arc_hover.name)
		return
	}
	preview_show(arc_hover.name, bytes, arc_hover.view)
}

// Only the rejection paths need this: the timeline caches keep their
// views for the session.
arc_view_free :: proc(view: ^Arc_View) {
	for entry in view.entries {
		delete(entry.name)
	}
	delete(view.entries)
	delete(view.data)
	free(view)
}
