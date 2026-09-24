// Torrent attachments (.torrent metainfo, BEP 3 v1, BEP 52 v2 and
// hybrids) listed inline: the torrent's name, its files with sizes, and
// a magnet link to copy into a client. Nothing touches the swarm; the
// tile reads only the metainfo that was sent.
//
//   metainfo ── tor_parse ──► Tor_Meta (temp) ── tor_view_make ──► Tor_View
//      │                                                              │
//      └── raw `info` span ── SHA-1 (btih) / SHA-256 (btmh) ──► magnet ┘
package main

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:net"
import "core:strings"

import clay "../vendor/clay/bindings/odin/clay-odin"

TOR_MAX_DEPTH :: 32 // bencode nesting cap for hostile input
TOR_MAX_TRACKERS :: 16 // tr= params carried into the magnet

Tor_File :: struct {
	path: string,
	size: i64,
}

Tor_View :: struct {
	name:     string, // info.name
	files:    []Tor_File, // first ARC_MAX_ENTRIES files, padding dropped
	count:    int, // every file, including those past the cap
	total:    i64, // bytes across every file
	magnet:   string,
	expanded: bool, // the tile lists every stored file, not just the first rows
}

// One file listing as read: v1 `files` and v2 `file tree` are kept
// apart because a hybrid carries both. Paths live in the temp allocator.
@(private = "file")
Tor_List :: struct {
	files: [dynamic]Tor_File,
	count: int,
	total: i64,
}

@(private = "file")
Tor_Meta :: struct {
	info:     []u8, // raw bencoded `info` dict, what the infohash covers
	trackers: [dynamic]string,
	name:     string,
	length:   i64, // single-file v1 size, -1 when absent
	v1, v2:   bool, // `pieces` present / `meta version` 2
	files:    Tor_List, // v1 `files`
	tree:     Tor_List, // v2 `file tree`
}

// Bencode read cursor. Strings it returns alias `data`.
@(private = "file")
Bcur :: struct {
	data: []u8,
	pos:  int,
}

@(private = "file")
bpeek :: proc(c: ^Bcur) -> u8 {
	return c.pos < len(c.data) ? c.data[c.pos] : 0
}

@(private = "file")
bexpect :: proc(c: ^Bcur, ch: u8) -> bool {
	if bpeek(c) != ch {
		return false
	}
	c.pos += 1
	return true
}

// `4:spam`
@(private = "file")
bstr :: proc(c: ^Bcur) -> (s: string, ok: bool) {
	start := c.pos
	n := 0
	for bpeek(c) >= '0' && bpeek(c) <= '9' {
		if n > len(c.data) {
			return
		}
		n = n * 10 + int(bpeek(c) - '0')
		c.pos += 1
	}
	if c.pos == start || !bexpect(c, ':') || n > len(c.data) - c.pos {
		return
	}
	s = string(c.data[c.pos:c.pos + n])
	c.pos += n
	return s, true
}

// `i42e`
@(private = "file")
bint :: proc(c: ^Bcur) -> (v: i64, ok: bool) {
	bexpect(c, 'i') or_return
	negative := bexpect(c, '-')
	digits := 0
	for bpeek(c) >= '0' && bpeek(c) <= '9' {
		if v > (max(i64) - 9) / 10 {
			return
		}
		v = v * 10 + i64(bpeek(c) - '0')
		c.pos += 1
		digits += 1
	}
	if digits == 0 || !bexpect(c, 'e') {
		return
	}
	return negative ? -v : v, true
}

@(private = "file")
bskip :: proc(c: ^Bcur, depth: int) -> bool {
	if depth > TOR_MAX_DEPTH {
		return false
	}
	switch bpeek(c) {
	case 'i':
		_, ok := bint(c)
		return ok
	case 'l', 'd':
		c.pos += 1
		for bpeek(c) != 'e' {
			bskip(c, depth + 1) or_return
		}
		c.pos += 1
		return true
	}
	_, ok := bstr(c)
	return ok
}

// `l4:spam4:eggse` appended onto out.
@(private = "file")
bstrs :: proc(c: ^Bcur, out: ^[dynamic]string) -> bool {
	bexpect(c, 'l') or_return
	for bpeek(c) != 'e' {
		s := bstr(c) or_return
		append(out, s)
	}
	c.pos += 1
	return true
}

@(private = "file")
tor_add :: proc(list: ^Tor_List, path: string, size: i64) -> bool {
	if size < 0 || size > max(i64) - list.total {
		return false
	}
	list.total += size
	list.count += 1
	if len(list.files) < ARC_MAX_ENTRIES {
		append(&list.files, Tor_File{path, size})
	}
	return true
}

// One v1 `files` entry: {length, path: [dir, …, name], attr}.
// BEP 47 padding files (attr has 'p') are alignment filler, not content.
@(private = "file")
tor_v1_file :: proc(c: ^Bcur, list: ^Tor_List) -> bool {
	bexpect(c, 'd') or_return
	size: i64 = -1
	padding := false
	parts := make([dynamic]string, context.temp_allocator)
	for bpeek(c) != 'e' {
		key := bstr(c) or_return
		switch key {
		case "length":
			size = bint(c) or_return
		case "path":
			bstrs(c, &parts) or_return
		case "attr":
			attr := bstr(c) or_return
			padding = strings.contains(attr, "p")
		case:
			bskip(c, 0) or_return
		}
	}
	c.pos += 1
	if padding {
		return true
	}
	if len(parts) == 0 {
		return false
	}
	return tor_add(list, strings.join(parts[:], "/", context.temp_allocator), size)
}

// v2 `file tree`: nested dicts keyed by path component; a file's dict
// holds the empty key, whose value carries `length`.
//   {"dir": {"a.txt": {"": {length: 3, pieces root: …}}}}
@(private = "file")
tor_tree :: proc(c: ^Bcur, list: ^Tor_List, path: string, depth: int) -> bool {
	if depth > TOR_MAX_DEPTH {
		return false
	}
	bexpect(c, 'd') or_return
	for bpeek(c) != 'e' {
		key := bstr(c) or_return
		if key != "" {
			child :=
				path == "" ? key : strings.concatenate({path, "/", key}, context.temp_allocator)
			tor_tree(c, list, child, depth + 1) or_return
			continue
		}
		bexpect(c, 'd') or_return
		size: i64 = -1
		for bpeek(c) != 'e' {
			prop := bstr(c) or_return
			if prop == "length" {
				size = bint(c) or_return
			} else {
				bskip(c, 0) or_return
			}
		}
		c.pos += 1
		tor_add(list, path, size) or_return
	}
	c.pos += 1
	return true
}

@(private = "file")
tor_info :: proc(meta: ^Tor_Meta) -> bool {
	c := Bcur {
		data = meta.info,
	}
	bexpect(&c, 'd') or_return
	for bpeek(&c) != 'e' {
		key := bstr(&c) or_return
		switch key {
		case "name":
			meta.name = bstr(&c) or_return
		case "length":
			meta.length = bint(&c) or_return
		case "pieces":
			bstr(&c) or_return
			meta.v1 = true
		case "meta version":
			version := bint(&c) or_return
			meta.v2 = version == 2
		case "files":
			bexpect(&c, 'l') or_return
			for bpeek(&c) != 'e' {
				tor_v1_file(&c, &meta.files) or_return
			}
			c.pos += 1
		case "file tree":
			tor_tree(&c, &meta.tree, "", 0) or_return
		case:
			bskip(&c, 0) or_return
		}
	}
	return true
}

@(private = "file")
tor_parse :: proc(data: []u8, meta: ^Tor_Meta) -> bool {
	c := Bcur {
		data = data,
	}
	bexpect(&c, 'd') or_return
	tiers := make([dynamic]string, context.temp_allocator)
	for bpeek(&c) != 'e' {
		key := bstr(&c) or_return
		switch key {
		case "announce":
			url := bstr(&c) or_return
			append(&tiers, url)
		case "announce-list":
			// BEP 12: a list of tiers, each a list of URLs.
			bexpect(&c, 'l') or_return
			for bpeek(&c) != 'e' {
				bstrs(&c, &tiers) or_return
			}
			c.pos += 1
		case "info":
			start := c.pos
			bskip(&c, 0) or_return
			meta.info = data[start:c.pos]
		case:
			bskip(&c, 0) or_return
		}
	}
	for url in tiers {
		if url == "" || len(meta.trackers) >= TOR_MAX_TRACKERS {
			continue
		}
		seen := false
		for have in meta.trackers {
			seen ||= have == url
		}
		if !seen {
			append(&meta.trackers, url)
		}
	}
	return meta.info != nil && tor_info(meta)
}

// nil = not a readable torrent, and the caller falls back to the plain
// file chip. The view copies what it keeps; data stays the caller's.
tor_view_make :: proc(data: []u8) -> ^Tor_View {
	meta := Tor_Meta {
		length = -1,
		trackers = make([dynamic]string, context.temp_allocator),
		files = {files = make([dynamic]Tor_File, context.temp_allocator)},
		tree = {files = make([dynamic]Tor_File, context.temp_allocator)},
	}
	if !tor_parse(data, &meta) || meta.name == "" || !(meta.v1 || meta.v2) {
		return nil
	}

	// A hybrid lists its files twice; v1 comes first, padding stripped.
	list := meta.files.count > 0 ? meta.files : meta.tree
	if list.count == 0 {
		if !tor_add(&list, meta.name, meta.length) {
			return nil
		}
	}

	params := make([dynamic]string, context.temp_allocator)
	if meta.v1 {
		sum := hash.hash_bytes(.Insecure_SHA1, meta.info, context.temp_allocator)
		append(
			&params,
			fmt.tprintf("xt=urn:btih:%s", string(hex.encode(sum, context.temp_allocator))),
		)
	}
	if meta.v2 {
		// multihash prefix: 0x12 = sha2-256, 0x20 = 32 bytes.
		sum := hash.hash_bytes(.SHA256, meta.info, context.temp_allocator)
		append(
			&params,
			fmt.tprintf("xt=urn:btmh:1220%s", string(hex.encode(sum, context.temp_allocator))),
		)
	}
	append(&params, fmt.tprintf("dn=%s", net.percent_encode(meta.name, context.temp_allocator)))
	for url in meta.trackers {
		append(&params, fmt.tprintf("tr=%s", net.percent_encode(url, context.temp_allocator)))
	}

	files := make([]Tor_File, len(list.files))
	for file, i in list.files {
		files[i] = {strings.clone(file.path), file.size}
	}
	view := new(Tor_View)
	view^ = {
		name   = strings.clone(meta.name),
		files  = files,
		count  = list.count,
		total  = list.total,
		magnet = strings.concatenate(
			{"magnet:?", strings.join(params[:], "&", context.temp_allocator)},
		),
	}
	return view
}

// Rows and buttons under the pointer, rebound every build like arc_hover.
tor_more_hover: ^Tor_View
tor_magnet_hover: ^Tor_View

handle_tor_click :: proc(ui: ^Ui_State) {
	// att_hover set = the click is on the download chip.
	if !mouse_released() || att_hover.msg_id != "" {
		return
	}
	if tor_more_hover != nil {
		tor_more_hover.expanded = !tor_more_hover.expanded
		return
	}
	if tor_magnet_hover != nil {
		copy_text(ui, tor_magnet_hover.magnet, "Magnet link copied")
	}
}

// Name, "N files · size", the file rows, and the magnet button. Sized
// and plated like the archive tile.
tor_tile :: proc(view: ^Tor_View, id: u32, msg_id: string, att: int, file_name: string) {
	if clay.UI(clay.ID("MsgTor", id))(
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
		att_dl_button("DlTor", id, msg_id, att, file_name)
		if clay.UI(clay.ID_LOCAL("MsgTorHead"))(
		{
			layout = {
				layoutDirection = .TopToBottom,
				padding = {left = 6, bottom = 4},
				childGap = 2,
			},
		},
		) {
			clay.Text(
				arc_short_name(view.name),
				{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT},
			)
			files := view.count == 1 ? tr("1 file") : fmt.tprintf(tr("%d files"), view.count)
			clay.Text(
				fmt.tprintf("%s · %s", files, arc_size_label(view.total)),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
			)
		}
		rows := view.expanded ? len(view.files) : min(len(view.files), ARC_TILE_ROWS)
		for file, k in view.files[:rows] {
			if clay.UI(clay.ID_LOCAL("MsgTorRow", u32(k)))(
			{
				layout = {
					sizing = {width = clay.SizingGrow()},
					childGap = 8,
					padding = {left = 6, right = 6, top = 4, bottom = 4},
					childAlignment = {y = .Center},
				},
			},
			) {
				clay.Text(file.path, {fontId = FONT_BODY, fontSize = 12, textColor = TEXT})
				if clay.UI(clay.ID_LOCAL("MsgTorPad"))(
				{layout = {sizing = {width = clay.SizingGrow()}}},
				) {}
				clay.Text(
					arc_size_label(file.size),
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
				)
			}
		}
		// Tap to list the rest, tap again to fold it back. Files past
		// ARC_MAX_ENTRIES are counted in the header but never listed.
		if view.count > ARC_TILE_ROWS {
			if clay.UI(clay.ID_LOCAL("MsgTorMore"))(
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
					tor_more_hover = view
				}
				label :=
					view.expanded ? tr("Show fewer files") : fmt.tprintf(tr("and %d more files"), view.count - ARC_TILE_ROWS)
				clay.Text(label, {fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM})
			}
		}
		if clay.UI(clay.ID_LOCAL("MsgTorMagnet"))(
		{
			layout = {padding = {left = 12, right = 12, top = 6, bottom = 6}},
			backgroundColor = hovered() ? ACCENT : ROW_BG,
			cornerRadius = rr(6),
		},
		) {
			if hovered() {
				tor_magnet_hover = view
			}
			clay.Text(
				tr("Copy magnet link"),
				{fontId = FONT_TITLE, fontSize = 12, textColor = TEXT},
			)
		}
	}
}
