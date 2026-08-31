// Archive attachments (zip, rar, 7z, tar…) listed inline through
// libarchive, straight from the decrypted bytes; nothing is written
// to disk. Clicking an entry decompresses just that entry into
// memory and opens it in the preview modal, which reuses the same
// renderers as the timeline tiles.
package main

import "core:c"
import "core:fmt"
import "core:strings"

foreign import la "system:archive"

ARCHIVE_OK :: 0
ARCHIVE_EOF :: 1
AE_IFMT :: 0o170000
AE_IFREG :: 0o100000

ARC_MAX_ENTRIES :: 2000 // listing cap for hostile archives
ARC_MAX_ENTRY_BYTES :: 64 * 1024 * 1024 // per-entry decompression cap
ARC_TILE_ROWS :: 12 // entries shown on the tile

archive_t :: struct {}
archive_entry_t :: struct {}

@(default_calling_convention = "c")
foreign la {
	archive_read_new :: proc() -> ^archive_t ---
	archive_read_free :: proc(a: ^archive_t) -> c.int ---
	archive_read_support_filter_all :: proc(a: ^archive_t) -> c.int ---
	archive_read_support_format_all :: proc(a: ^archive_t) -> c.int ---
	archive_read_open_memory :: proc(a: ^archive_t, buf: rawptr, size: c.size_t) -> c.int ---
	archive_read_next_header :: proc(a: ^archive_t, entry: ^^archive_entry_t) -> c.int ---
	archive_read_data :: proc(a: ^archive_t, buf: rawptr, size: c.size_t) -> c.ssize_t ---
	archive_entry_pathname_utf8 :: proc(entry: ^archive_entry_t) -> cstring ---
	archive_entry_size :: proc(entry: ^archive_entry_t) -> i64 ---
	archive_entry_filetype :: proc(entry: ^archive_entry_t) -> c.uint ---
}

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
arc_open :: proc(data: []u8) -> ^archive_t {
	a := archive_read_new()
	if a == nil {
		return nil
	}
	archive_read_support_filter_all(a)
	archive_read_support_format_all(a)
	if archive_read_open_memory(a, raw_data(data), c.size_t(len(data))) != ARCHIVE_OK {
		archive_read_free(a)
		return nil
	}
	return a
}

// data ownership transfers to the view. nil = not a readable archive.
arc_view_make :: proc(data: []u8) -> ^Arc_View {
	a := arc_open(data)
	if a == nil {
		return nil
	}
	defer archive_read_free(a)

	entries := make([dynamic]Arc_Entry)
	entry: ^archive_entry_t
	for index := 0; len(entries) < ARC_MAX_ENTRIES; index += 1 {
		status := archive_read_next_header(a, &entry)
		if status == ARCHIVE_EOF {
			break
		}
		if status != ARCHIVE_OK {
			// A bad header on an otherwise listable archive: keep
			// what was read; nothing at all means not an archive.
			break
		}
		if archive_entry_filetype(entry) & AE_IFMT != AE_IFREG {
			continue
		}
		path := archive_entry_pathname_utf8(entry)
		if path == nil {
			continue
		}
		append(&entries, Arc_Entry{
			name  = strings.clone(string(path)),
			size  = archive_entry_size(entry),
			index = index,
		})
	}

	if len(entries) == 0 {
		delete(entries)
		return nil
	}
	view := new(Arc_View)
	view^ = {data = data, entries = entries[:]}
	return view
}

// Decompress one entry into memory (never to disk), capped so a
// hostile archive can't balloon.
arc_entry_bytes :: proc(view: ^Arc_View, header_index: int) -> ([]u8, bool) {
	a := arc_open(view.data)
	if a == nil {
		return nil, false
	}
	defer archive_read_free(a)

	entry: ^archive_entry_t
	for index := 0; ; index += 1 {
		if archive_read_next_header(a, &entry) != ARCHIVE_OK {
			return nil, false
		}
		if index == header_index {
			break
		}
	}

	declared := archive_entry_size(entry)
	if declared < 0 || declared > ARC_MAX_ENTRY_BYTES {
		return nil, false
	}

	out := make([dynamic]u8)
	chunk: [64 * 1024]u8
	for {
		n := archive_read_data(a, &chunk[0], len(chunk))
		if n < 0 || len(out) + int(n) > ARC_MAX_ENTRY_BYTES {
			delete(out)
			return nil, false
		}
		if n == 0 {
			break
		}
		append(&out, ..chunk[:n])
	}
	return out[:], true
}

// "1.4 MiB" style label for the entry rows.
arc_size_label :: proc(size: i64) -> string {
	switch {
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
	preview_show(arc_hover.name, bytes)
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
