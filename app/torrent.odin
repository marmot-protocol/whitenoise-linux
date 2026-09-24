// Torrent attachments (.torrent metainfo, BEP 3 v1, BEP 52 v2 and
// hybrids) shown inline: the torrent's name and size, its files when
// there is more than one, and a magnet link to copy into a client.
// Nothing touches the swarm; the tile reads only the metainfo that was
// sent.
//
//   metainfo ── tor_parse ──► Tor_Meta (temp) ── tor_view_make ──► Tor_View
//      │                                                              │
//      └── raw `info` span ── SHA-1 (btih) / SHA-256 (btmh) ──► magnet ┘
//
// The infohash covers the `info` bytes exactly as sent. Decoding and
// re-encoding would change it for any non-canonical metainfo.
package main

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"

import clay "../vendor/clay/bindings/odin/clay-odin"
import rl "sdlrl"

TOR_MAX_DEPTH :: 32 // bencode nesting cap, file tree included
TOR_MAX_FILES :: 500 // files kept for the listing; the rest are only counted
TOR_MAX_PATH_BYTES :: 64 * 1024 // path bytes kept across the listing
TOR_MAX_TRACKERS :: 16 // tr= params carried into the magnet
TOR_MAX_TRACKER_BYTES :: 4096 // tracker URL bytes carried into the magnet
TOR_MAX_NOTE_BYTES :: 512 // comment / created-by kept for the details
TOR_LIST_MAX_H :: 260 // the open listing scrolls past this
TOR_KEY_W :: 76 // the details' key column
TOR_TILE_W :: 380

@(private = "file")
ICON_MAGNET :: "\uf076"
@(private = "file")
ICON_CHEVRON_DOWN :: "\uf078"
@(private = "file")
ICON_CHEVRON_UP :: "\uf077"

Tor_File :: struct {
	path: string,
	size: i64,
}

Tor_View :: struct {
	name:       string, // info.name
	files:      []Tor_File, // the kept part of the listing, padding dropped
	count:      int, // every file, including those past the caps
	total:      i64, // bytes across every file
	magnet:     string,
	infohash:   string, // btih hex for v1 and hybrids, else btmh hex
	trackers:   []string, // the ones the magnet carries
	piece_len:  i64,
	created:    i64, // unix seconds, 0 when absent
	created_by: string,
	comment:    string,
	private:    bool, // BEP 27: DHT and PEX off, trackers only
	open:       bool, // click on the header: files and details shown
}

// One file listing as read: v1 `files` and v2 `file tree` are kept
// apart because a hybrid carries both. Paths live in the temp allocator.
@(private = "file")
Tor_List :: struct {
	files:      [dynamic]Tor_File,
	path_bytes: int,
	count:      int,
	total:      i64,
}

@(private = "file")
Tor_Meta :: struct {
	info:          []u8, // raw bencoded `info` dict, what the infohash covers
	trackers:      [dynamic]string,
	tracker_bytes: int,
	name:          string,
	length:        i64, // single-file v1 size, -1 when absent
	v1, v2:        bool, // `pieces` present / `meta version` 2
	piece_len:     i64,
	private:       bool,
	created:       i64,
	created_by:    string,
	comment:       string,
	files:         Tor_List, // v1 `files`
	tree:          Tor_List, // v2 `file tree`
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

// `4:spam`. A declared length past the end of the input fails before
// anything is sliced.
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
	if len(list.files) < TOR_MAX_FILES && list.path_bytes + len(path) <= TOR_MAX_PATH_BYTES {
		append(&list.files, Tor_File{path, size})
		list.path_bytes += len(path)
	}
	return true
}

// One v1 `files` entry: {attr, length, path: [dir, …, name]}.
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
// holds the empty key, whose value carries `length` and, for BEP 47
// padding, `attr`.
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
		padding := false
		for bpeek(c) != 'e' {
			switch bstr(c) or_return {
			case "length":
				size = bint(c) or_return
			case "attr":
				attr := bstr(c) or_return
				padding = strings.contains(attr, "p")
			case:
				bskip(c, 0) or_return
			}
		}
		c.pos += 1
		if !padding {
			tor_add(list, path, size) or_return
		}
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
		case "piece length":
			meta.piece_len = bint(&c) or_return
		case "private":
			flag := bint(&c) or_return
			meta.private = flag == 1
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

// Only trackers a client can announce to go into the magnet; anything
// else in `announce` is dropped rather than handed on.
@(private = "file")
tor_tracker_ok :: proc(url: string) -> bool {
	for scheme in ([]string{"http://", "https://", "udp://"}) {
		if strings.has_prefix(url, scheme) && len(url) > len(scheme) {
			return true
		}
	}
	return false
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
		case "creation date":
			meta.created = bint(&c) or_return
		case "created by":
			meta.created_by = bstr(&c) or_return
		case "comment":
			meta.comment = bstr(&c) or_return
		case:
			bskip(&c, 0) or_return
		}
	}
	for url in tiers {
		if len(meta.trackers) >= TOR_MAX_TRACKERS {
			break
		}
		if !tor_tracker_ok(url) || meta.tracker_bytes + len(url) > TOR_MAX_TRACKER_BYTES {
			continue
		}
		seen := false
		for have in meta.trackers {
			seen ||= have == url
		}
		if !seen {
			append(&meta.trackers, url)
			meta.tracker_bytes += len(url)
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
	infohash: string
	if meta.v2 {
		// multihash prefix: 0x12 = sha2-256, 0x20 = 32 bytes.
		sum := hash.hash_bytes(.SHA256, meta.info, context.temp_allocator)
		infohash = string(hex.encode(sum, context.temp_allocator))
		append(&params, fmt.tprintf("xt=urn:btmh:1220%s", infohash))
	}
	if meta.v1 {
		// v1 first: every client reads btih, not all read btmh.
		sum := hash.hash_bytes(.Insecure_SHA1, meta.info, context.temp_allocator)
		infohash = string(hex.encode(sum, context.temp_allocator))
		inject_at(&params, 0, fmt.tprintf("xt=urn:btih:%s", infohash))
	}
	append(&params, fmt.tprintf("dn=%s", net.percent_encode(meta.name, context.temp_allocator)))
	for url in meta.trackers {
		append(&params, fmt.tprintf("tr=%s", net.percent_encode(url, context.temp_allocator)))
	}

	files := make([]Tor_File, len(list.files))
	for file, i in list.files {
		files[i] = {strings.clone(file.path), file.size}
	}
	trackers := make([]string, len(meta.trackers))
	for url, i in meta.trackers {
		trackers[i] = strings.clone(url)
	}
	view := new(Tor_View)
	view^ = {
		name       = strings.clone(meta.name),
		files      = files,
		count      = list.count,
		total      = list.total,
		magnet     = strings.concatenate(
			{"magnet:?", strings.join(params[:], "&", context.temp_allocator)},
		),
		infohash   = strings.clone(infohash),
		trackers   = trackers,
		piece_len  = max(meta.piece_len, 0),
		created    = max(meta.created, 0),
		created_by = strings.clone(tor_note(meta.created_by)),
		comment    = strings.clone(tor_note(meta.comment)),
		private    = meta.private,
	}
	return view
}

// Free text from the metainfo, capped for the details rows at a rune
// boundary.
@(private = "file")
tor_note :: proc(text: string) -> string {
	if len(text) <= TOR_MAX_NOTE_BYTES {
		return text
	}
	cut := TOR_MAX_NOTE_BYTES
	for cut > 0 && text[cut] & 0xc0 == 0x80 {
		cut -= 1
	}
	return text[:cut]
}

// The tor_views cache owns its views for the session; this is for the
// shutdown sweep and the tests.
tor_view_free :: proc(view: ^Tor_View) {
	for file in view.files {
		delete(file.path)
	}
	delete(view.files)
	delete(view.name)
	delete(view.magnet)
	delete(view.infohash)
	for url in view.trackers {
		delete(url)
	}
	delete(view.trackers)
	delete(view.created_by)
	delete(view.comment)
	free(view)
}

// Header, magnet button and hash row under the pointer, rebound every
// build like arc_hover.
tor_open_hover: ^Tor_View
tor_magnet_hover: ^Tor_View
tor_hash_hover: ^Tor_View

handle_tor_click :: proc(ui: ^Ui_State) {
	// att_hover set = the click is on the download chip.
	if !mouse_released() || att_hover.msg_id != "" {
		return
	}
	switch {
	case tor_open_hover != nil:
		tor_open_hover.open = !tor_open_hover.open
	case tor_magnet_hover != nil:
		copy_text(ui, tor_magnet_hover.magnet, "Magnet link copied")
	case tor_hash_hover != nil:
		copy_text(ui, tor_hash_hover.infohash, "Info hash copied")
	}
}

// Shorten to width with the ellipsis in the middle. Release names put
// the title and episode at the front and quality and extension at the
// back, so both ends stay:
//   GTO.2026.EP10.1080p.NF.WEB-DL.AAC2.0.H.264-MagicStar.mkv
//   GTO.2026.EP10.1080p…H.264-MagicStar.mkv
@(private = "file")
tor_fit :: proc(text: string, width: f32, font, size: u16) -> string {
	if rl.MeasureTextLine(font, size, text, 0).x <= width {
		return text
	}
	half := max(0, (width - rl.MeasureTextLine(font, size, "…", 0).x) / 2)

	cuts := tor_cuts(text)

	// Longest head that fits in half: the last cut whose prefix fits.
	lo, hi := 0, len(cuts) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if rl.MeasureTextLine(font, size, text[:cuts[mid]], 0).x <=
		   half {lo = mid} else {hi = mid - 1}
	}
	head := lo

	// Longest tail that fits in half: the first cut past the head whose
	// suffix fits (the last cut, an empty suffix, always does).
	lo, hi = head, len(cuts) - 1
	for lo < hi {
		mid := (lo + hi) / 2
		if rl.MeasureTextLine(font, size, text[cuts[mid]:], 0).x <=
		   half {hi = mid} else {lo = mid + 1}
	}
	return fmt.tprintf("%s…%s", text[:cuts[head]], text[cuts[lo]:])
}

// Rune starts plus the end, so searches never cut inside a UTF-8
// sequence.
@(private = "file")
tor_cuts :: proc(text: string) -> []int {
	cuts := make([dynamic]int, 0, len(text) + 1, context.temp_allocator)
	for i in 0 ..< len(text) {
		if text[i] & 0xc0 != 0x80 {append(&cuts, i)}
	}
	append(&cuts, len(text))
	return cuts[:]
}

// Closed, the tile is the header and the magnet button. A click on the
// header opens the file list and the metainfo details under it.
//   ┌───────────────────────────────────────────┐
//   │ [magnet]  GTO.2026.EP10…MagicStar.mkv  v  │  click: open / close
//   │           Torrent · 3 files · 1.6 GiB      │
//   │ FILES                                      │  open only
//   │ ┌───────────────────────────────────────┐ │
//   │ │ Season 1/E01.mkv             812 MiB  │ │  scrolls past TOR_LIST_MAX_H
//   │ └───────────────────────────────────────┘ │
//   │ DETAILS                                    │
//   │ Info hash   c94bd4a4…08cd05cb              │  click copies
//   │ Pieces      16.0 KiB × 1                   │
//   │ [        magnet  Copy magnet link        ] │
//   └───────────────────────────────────────────┘
tor_tile :: proc(view: ^Tor_View, id: u32, msg_id: string, att: int, file_name: string) {
	w := att_w(TOR_TILE_W)
	PAD :: 10
	BADGE :: 36
	inner := w - 2 * PAD
	if clay.UI(clay.ID("MsgTor", id))(
	{
		layout = {
			layoutDirection = .TopToBottom,
			sizing = {width = clay.SizingFixed(w)},
			padding = clay.PaddingAll(PAD),
			childGap = 8,
		},
		backgroundColor = PLATE,
		cornerRadius = rr(10),
	},
	) {
		att_dl_button("DlTor", id, msg_id, att, file_name)

		if clay.UI(clay.ID_LOCAL("MsgTorHead"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				padding = clay.PaddingAll(6),
				childGap = 10,
				childAlignment = {y = .Center},
			},
			backgroundColor = hovered() ? HOVER : {},
			cornerRadius = rr(8),
		},
		) {
			if hovered() {
				tor_open_hover = view
			}
			if clay.UI(clay.ID_LOCAL("MsgTorBadge"))(
			{
				layout = {
					sizing = {clay.SizingFixed(BADGE), clay.SizingFixed(BADGE)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = ROW_BG,
				cornerRadius = rr(8),
			},
			) {
				clay.Text(ICON_MAGNET, {fontId = FONT_ICON, fontSize = 16, textColor = ACCENT})
			}
			if clay.UI(clay.ID_LOCAL("MsgTorTitle"))(
			{
				layout = {
					layoutDirection = .TopToBottom,
					sizing = {width = clay.SizingGrow()},
					childGap = 3,
				},
			},
			) {
				// Header width less its padding, badge, chevron and gaps.
				clay.Text(
					tor_fit(view.name, inner - 12 - BADGE - 12 - 20, FONT_TITLE, 13),
					{fontId = FONT_TITLE, fontSize = 13, textColor = TEXT, wrapMode = .None},
				)
				size := arc_size_label(view.total)
				meta :=
					view.count == 1 ? fmt.tprintf("%s · %s", tr("Torrent"), size) : fmt.tprintf("%s · %s · %s", tr("Torrent"), fmt.tprintf(tr("%d files"), view.count), size)
				clay.Text(
					meta,
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM, wrapMode = .None},
				)
			}
			clay.Text(
				view.open ? ICON_CHEVRON_UP : ICON_CHEVRON_DOWN,
				{fontId = FONT_ICON, fontSize = 11, textColor = TEXT_DIM},
			)
		}

		if view.open {
			tor_eyebrow(tr("FILES"))
			if clay.UI(clay.ID_LOCAL("MsgTorList"))(
			{
				layout = {
					layoutDirection = .TopToBottom,
					sizing = {
						width = clay.SizingGrow(),
						height = clay.SizingFit({max = TOR_LIST_MAX_H}),
					},
					padding = clay.PaddingAll(4),
				},
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
				backgroundColor = ROW_BG,
				cornerRadius = rr(8),
			},
			) {
				for file, k in view.files {
					size := arc_size_label(file.size)
					// List width less its padding, the row's, the gap, the size.
					name_w := inner - 8 - 16 - 12 - rl.MeasureTextLine(FONT_BODY, 11, size, 0).x
					if clay.UI(clay.ID_LOCAL("MsgTorRow", u32(k)))(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							padding = {left = 8, right = 8, top = 5, bottom = 5},
							childGap = 12,
							childAlignment = {y = .Center},
						},
					},
					) {
						clay.Text(
							tor_fit(file.path, name_w, FONT_BODY, 12),
							{
								fontId = FONT_BODY,
								fontSize = 12,
								textColor = TEXT,
								wrapMode = .None,
							},
						)
						if clay.UI(clay.ID_LOCAL("MsgTorPad"))(
						{layout = {sizing = {width = clay.SizingGrow()}}},
						) {}
						clay.Text(
							size,
							{
								fontId = FONT_BODY,
								fontSize = 11,
								textColor = TEXT_DIM,
								wrapMode = .None,
							},
						)
					}
				}
				if view.count > len(view.files) {
					if clay.UI(clay.ID_LOCAL("MsgTorUnlisted"))(
					{layout = {padding = {left = 8, right = 8, top = 5, bottom = 5}}},
					) {
						clay.Text(
							fmt.tprintf(tr("and %d more files"), view.count - len(view.files)),
							{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
						)
					}
				}
			}

			tor_eyebrow(tr("DETAILS"))
			if clay.UI(clay.ID_LOCAL("MsgTorDetails"))(
			{layout = {layoutDirection = .TopToBottom, sizing = {width = clay.SizingGrow()}}},
			) {
				value_w := inner - TOR_KEY_W - 16 - 8
				if clay.UI(clay.ID_LOCAL("MsgTorHash"))(
				{
					layout = {
						sizing = {width = clay.SizingGrow()},
						padding = {left = 8, right = 8, top = 4, bottom = 4},
						childGap = 8,
					},
					backgroundColor = hovered() ? HOVER : {},
					cornerRadius = rr(6),
				},
				) {
					if hovered() {
						tor_hash_hover = view
						tooltip("Copy info hash")
					}
					tor_key(tr("Info hash"))
					clay.Text(
						tor_fit(view.infohash, value_w, FONT_MONO, 11),
						{fontId = FONT_MONO, fontSize = 11, textColor = TEXT, wrapMode = .None},
					)
				}
				if view.piece_len > 0 {
					pieces :=
						view.total / view.piece_len + (view.total % view.piece_len != 0 ? 1 : 0)
					tor_detail(
						tr("Pieces"),
						fmt.tprintf("%s × %d", arc_size_label(view.piece_len), pieces),
						value_w,
					)
				}
				if view.created > 0 {
					year, month, day := time.date(time.unix(view.created, 0))
					tor_detail(
						tr("Created"),
						fmt.tprintf("%04d-%02d-%02d", year, int(month), day),
						value_w,
					)
				}
				if view.created_by != "" {
					tor_detail(tr("Created by"), view.created_by, value_w)
				}
				if view.private {
					tor_detail(
						tr("Private"),
						tr("Trackers only, no DHT or peer exchange."),
						value_w,
					)
				}
				for url, k in view.trackers {
					// "udp://tracker.example:80/announce" → "tracker.example:80"
					host := url[strings.index(url, "://") + 3:]
					if slash := strings.index_byte(host, '/'); slash >= 0 {
						host = host[:slash]
					}
					tor_detail(k == 0 ? tr("Trackers") : "", host, value_w)
				}
				if view.comment != "" {
					tor_detail(tr("Comment"), view.comment, value_w)
				}
			}
		}

		if clay.UI(clay.ID_LOCAL("MsgTorMagnet"))(
		{
			layout = {
				sizing = {width = clay.SizingGrow()},
				padding = {top = 8, bottom = 8},
				childGap = 8,
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = hovered() ? ACCENT : ROW_BG,
			cornerRadius = rr(8),
		},
		) {
			on := hovered()
			if on {
				tor_magnet_hover = view
			}
			clay.Text(
				ICON_MAGNET,
				{fontId = FONT_ICON, fontSize = 12, textColor = on ? ON_ACCENT : ACCENT},
			)
			clay.Text(
				tr("Copy magnet link"),
				{
					fontId = FONT_TITLE,
					fontSize = 12,
					textColor = on ? ON_ACCENT : TEXT,
					wrapMode = .None,
				},
			)
		}
	}
}

@(private = "file")
tor_eyebrow :: proc(label: string) {
	if clay.UI()({layout = {padding = {left = 6, top = 4}}}) {
		clay.Text(
			label,
			{fontId = FONT_TITLE, fontSize = 10, textColor = TEXT_LO, letterSpacing = 1},
		)
	}
}

@(private = "file")
tor_key :: proc(label: string) {
	if clay.UI()({layout = {sizing = {width = clay.SizingFixed(TOR_KEY_W)}}}) {
		clay.Text(
			label,
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM, wrapMode = .None},
		)
	}
}

// One key/value row of the details; the value is broken into lines
// that fit width.
@(private = "file")
tor_detail :: proc(key, value: string, width: f32) {
	if clay.UI()(
	{
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {left = 8, right = 8, top = 4, bottom = 4},
			childGap = 8,
		},
	},
	) {
		tor_key(key)
		if clay.UI()(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {width = clay.SizingGrow()},
				childGap = 2,
			},
		},
		) {
			// wrapped_lines hard-breaks tokens with no space, like URLs,
			// which clay's word wrap would let run past the tile.
			for line in wrapped_lines(value, width, 11) {
				clay.Text(
					value[line.start:line.end],
					{fontId = FONT_BODY, fontSize = 11, textColor = TEXT, wrapMode = .None},
				)
			}
		}
	}
}
